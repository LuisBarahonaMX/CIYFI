param(
 [string]$Proyecto = '',
 [ValidateRange(1,100)][int]$Ciclos = 5,
 [ValidateSet('auto','cpu','cuda')][string]$Dispositivo = 'auto',
 [ValidateRange(1,8)][int]$Hilos = 4,
 [ValidateRange(2,8)][int]$P = 4,
 [ValidateRange(2,4)][int]$K = 2
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Proyecto)) { $Proyecto = $PSScriptRoot }
if (-not (Test-Path -LiteralPath (Join-Path $Proyecto 'reid3_0') -PathType Container)) {
 throw 'Guarda el script en la raiz de zproyecto3_0 o usa -Proyecto con la ruta de esa carpeta.'
}
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
 throw 'No se encontro .venv\Scripts\python.exe. En un equipo nuevo hay que crear un entorno local; no copiar .venv del anterior.'
}
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$env:PYTHONUNBUFFERED = '1'
$env:PYTHONFAULTHANDLER = '1'
& $python -c "import torch, torchvision, numpy; from PIL import Image; print('Python y dependencias disponibles:', torch.__version__)"
if ($LASTEXITCODE -ne 0) { throw 'No se pudieron cargar las dependencias del entorno. Comparte el error antes de iniciar.' }
@'
import csv,hashlib,json,math,random,sys,time,traceback,zipfile
from pathlib import Path,PureWindowsPath
from datetime import datetime
from collections import defaultdict,Counter
import numpy as np
from PIL import Image,ImageOps,ImageDraw

ALGORITHM='ciyfi_piloto_resnet50_256_triplet_pk_sessions_v1'
def require(c,msg):
    if not c:raise ValueError(msg)
def load(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
def read(p):
    with p.open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
def atomic_json(p,d):
    t=p.with_suffix('.json.tmp');t.write_text(json.dumps(d,ensure_ascii=False,indent=2),encoding='utf-8');t.replace(p)
def write(p,rows,fields):
    with p.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(rows)
def safe(base,rel):
    require(bool(rel),'Ruta vacia.');p=(base/rel).resolve();require(p.is_relative_to(base.resolve()),'Ruta fuera de recortes.');return p

def resolve_crops(project,old):
    # Prioridad a la copia del proyecto actual al migrar a otro equipo.
    parts=PureWindowsPath(old).parts
    if 'recortes3_0' in parts:
        candidate=project.joinpath(*parts[parts.index('recortes3_0'):])
        if candidate.is_dir():return candidate
    candidate=Path(old)
    require(candidate.is_dir(),'No se encontro la carpeta de recortes. Copia recortes3_0 completa al proyecto actual.')
    return candidate

def select_inputs(project):
    partitions=[]
    for p in (project/'reid3_0').glob('particiones_sesiones_*'):
        try:
            if p.is_dir() and load(p/'resumen.json')['estado']=='CSV_GENERADOS':partitions.append(p)
        except (ValueError,OSError,KeyError):pass
    require(bool(partitions),'No hay particiones completas en reid3_0.')
    part=max(partitions,key=lambda p:p.name);cfg=load(part/'configuracion.json')
    for n in ('entrenamiento.csv','validacion.csv'):require(sha(part/n)==cfg['hashes_csv'][n],'Cambio el CSV '+n)
    matches=[]
    for p in (project/'reid3_0').glob('galeria_sesiones_*'):
        try:
            gcfg=load(p/'configuracion.json')
            if p.is_dir() and gcfg['hash_entrenamiento']==sha(part/'entrenamiento.csv') and gcfg['hash_validacion']==sha(part/'validacion.csv'):matches.append(p)
        except (ValueError,OSError,KeyError):pass
    require(bool(matches),'No hay galeria compatible con las particiones actuales.')
    gallery=max(matches,key=lambda p:p.name);gcfg=load(gallery/'configuracion.json')
    require(sha(gallery/'galeria.csv')==gcfg['hashes_csv']['galeria.csv'],'Cambio galeria.csv.')
    train=read(part/'entrenamiento.csv');val=read(part/'validacion.csv');refs=read(gallery/'galeria.csv')
    require(train and val and refs,'Hay un CSV vacio.')
    tm={r['original']:r for r in train}
    require(len(tm)==len(train),'Originales repetidos en train.')
    require(all(r['particion']=='entrenamiento' for r in train+refs) and all(r['particion']=='validacion' for r in val),'Particion incorrecta.')
    for r in refs:require(r['original'] in tm and all(r[k]==tm[r['original']][k] for k in tm[r['original']]),'Referencia ajena a train.')
    require(len({r['individuo'] for r in refs})==len(refs),'Galeria tiene mas de una referencia por individuo.')
    require({r['individuo'] for r in val}<={r['individuo'] for r in refs},'Consulta sin referencia.')
    for k in ('original','recorte','sesion','sha256_archivo','sha256_pixeles'):
        require(not {r[k] for r in train}&{r[k] for r in val},'Train y validacion comparten '+k)
    return part,gallery,cfg,train,val,refs,resolve_crops(project,cfg['carpeta_recortes'])

def eligible_pool(rows,k):
    groups=defaultdict(list)
    for r in rows:groups[r['individuo']].append(r)
    return {i:sorted(rr,key=lambda r:r['original']) for i,rr in sorted(groups.items()) if len(rr)>=k}
def cycle_plan(pool,p,k,epoch):
    require(len(pool)>=p,'Individuos insuficientes para PK.')
    rng=random.Random(30+epoch);ids=sorted(pool);rng.shuffle(ids);batches=[]
    for offset in range(0,len(ids),p):
        chosen=ids[offset:offset+p]
        if len(chosen)<p:chosen+=rng.sample([i for i in ids if i not in chosen],p-len(chosen))
        batch=[]
        for identity in chosen:
            rr=pool[identity];sessions=defaultdict(list)
            for r in rr:sessions[r['sesion']].append(r)
            # Positivos de sesiones distintas cuando existen; siempre imagenes distintas.
            if len(sessions)>=k:
                selected=[rng.choice(sessions[s]) for s in rng.sample(sorted(sessions),k)]
            else:selected=rng.sample(rr,k)
            batch.extend(selected)
        batches.append(batch)
    return batches

def image(p):
    with Image.open(p) as f:f.seek(0);im=ImageOps.exif_transpose(f).convert('RGB');im.load();return im
def letterbox(im):
    im=ImageOps.contain(im,(224,224),method=Image.Resampling.BILINEAR);canvas=Image.new('RGB',(224,224),(124,116,104));canvas.paste(im,((224-im.width)//2,(224-im.height)//2));return canvas
def normalize(a):
    a=np.asarray(a,dtype=np.float32);norm=np.linalg.norm(a,axis=1,keepdims=True)
    require(np.isfinite(a).all() and np.all(norm>1e-12),'Embeddings invalidos.');return np.ascontiguousarray(a/norm)
def rank(g,q,refs,queries):
    scores=normalize(q)@normalize(g).T;order=np.argsort(-scores,axis=1,kind='stable')[:,:min(5,len(refs))]
    rows=[];by_id=defaultdict(list)
    for n,r in enumerate(queries):
        candidates=[refs[j]['individuo'] for j in order[n]];one=int(candidates[0]==r['individuo']);five=int(r['individuo'] in candidates)
        d={'numero':r['numero'],'individuo':r['individuo'],'original':r['original'],'recorte':r['recorte'],'revision_calidad':r['revision_calidad'],'top1_correcto':one,'top5_correcto':five}
        for j,index in enumerate(order[n],1):d[f'top{j}_individuo']=refs[index]['individuo'];d[f'top{j}_similitud']=float(scores[n,index])
        rows.append(d);by_id[r['individuo']].append((one,five))
    m={'consultas':len(rows),'individuos':len(by_id),'galeria':len(refs),'top1_porcentaje':100*sum(r['top1_correcto'] for r in rows)/len(rows),'top5_porcentaje':100*sum(r['top5_correcto'] for r in rows)/len(rows),'macro_top1_porcentaje':100*np.mean([np.mean([x[0] for x in v]) for v in by_id.values()]).item(),'macro_top5_porcentaje':100*np.mean([np.mean([x[1] for x in v]) for v in by_id.values()]).item()}
    return m,rows,order,scores

def extract(model,rows,crops,transform,device,torch,batch=8,unit=False,label=''):
    model.eval();chunks=[]
    with torch.inference_mode():
        for off in range(0,len(rows),batch):
            x=torch.stack([transform(letterbox(image(safe(crops,r['recorte'])))) for r in rows[off:off+batch]]).to(device)
            out=model(x).detach().cpu().numpy();require(np.isfinite(out).all(),'Modelo produjo valores no finitos.');chunks.append(out)
            if off==0 or (off//batch)%12==0 or off+batch>=len(rows):print(f'{label}: {min(off+batch,len(rows))}/{len(rows)}',flush=True)
    vectors=np.concatenate(chunks);return normalize(vectors) if unit else vectors

def triplet(emb,labels,torch,criterion):
    ds=torch.cdist(emb.detach(),emb.detach());same=labels[:,None].eq(labels[None,:]);same.fill_diagonal_(False);neg=labels[:,None].ne(labels[None,:])
    require(bool(same.any(dim=1).all()) and bool(neg.any(dim=1).all()),'Lote sin positivos/negativos.')
    pi=ds.masked_fill(~same,float('-inf')).argmax(dim=1);ni=ds.masked_fill(~neg,float('inf')).argmin(dim=1)
    return criterion(emb,emb[pi],emb[ni])

def save_torch(p,data,torch):
    tmp=p.with_suffix('.pt.tmp');torch.save(data,tmp);tmp.replace(p)
def pack(dest):
    zp=dest/'PILOTO_REID_PARA_COMPARTIR.zip'
    with zipfile.ZipFile(zp,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(dest.iterdir()):
            if p.is_file() and p.suffix in ('.json','.csv','.txt'):z.write(p,p.name)
        for p in sorted((dest/'ejemplos_validacion').glob('*.jpg')):z.write(p,'ejemplos_validacion/'+p.name)
    print('ZIP PARA COMPARTIR:',zp,flush=True)

def examples(dest,g,q,refs,val,crops):
    metrics,rows,order,scores=rank(g,q,refs,val);chosen=[]
    for hit in (1,0):chosen += [i for i,r in enumerate(rows) if r['top1_correcto']==hit][:10]
    folder=dest/'ejemplos_validacion';folder.mkdir(exist_ok=True)
    for i in chosen:
        canvas=Image.new('RGB',(1440,300),'white');draw=ImageDraw.Draw(canvas)
        indices=[None]+list(order[i])
        for j,index in enumerate(indices):
            r=val[i] if index is None else refs[index];im=ImageOps.contain(image(safe(crops,r['recorte'])),(224,224));canvas.paste(im,(j*240+(240-im.width)//2,45+(224-im.height)//2))
            draw.text((j*240+4,5),('Consulta ' if index is None else f'Top{j} ')+r['individuo'],fill='black')
            if index is not None:draw.text((j*240+4,24),f'Similitud {scores[i,index]:.4f}',fill='black')
        draw.text((5,278),f'Validacion foto {val[i]["numero"]}; similitudes no son probabilidades. Muestra por aciertos/fallos.',fill='black')
        canvas.save(folder/(val[i]['numero'].zfill(5)+'.jpg'),quality=85)

def train_pilot(project,epochs,requested,threads,p,k):
    import torch,torchvision
    from torchvision.models import resnet50,ResNet50_Weights
    from torchvision.transforms import Compose,ToTensor,Normalize
    torch.set_num_threads(threads);torch.set_num_interop_threads(1);torch.manual_seed(30)
    device='cuda' if requested=='auto' and torch.cuda.is_available() else ('cpu' if requested=='auto' else requested)
    require(device!='cuda' or torch.cuda.is_available(),'CUDA solicitada pero no disponible en este entorno PyTorch.')
    if device=='cuda':torch.ones(1,device=device).add_(1);torch.cuda.synchronize()
    print('Dispositivo:',device,torch.cuda.get_device_name(0) if device=='cuda' else '| CPU',flush=True)
    part,gallery,cfg,train,val,refs,crops=select_inputs(project);pool=eligible_pool(train,k)
    require(len(pool)>=p,'No hay individuos aptos para PK.')
    semantic={'algoritmo':ALGORITHM,'train':sha(part/'entrenamiento.csv'),'validacion':sha(part/'validacion.csv'),'galeria':sha(gallery/'galeria.csv'),'P':p,'K':k,'lr':0.0001,'margen':0.3,'seed':30,'batch_eval':8}
    signature=hashlib.sha256(json.dumps(semantic,sort_keys=True).encode()).hexdigest();dest=project/'runs3_0'/('reid_piloto_'+signature[:16]);dest.mkdir(parents=True,exist_ok=True)
    try:
        print('Salida:',dest,flush=True);print('Verificando recortes de entrenamiento y validacion (sin abrir prueba)...',flush=True)
        for i,r in enumerate(train+val,1):
            require(sha(safe(crops,r['recorte']))==r['sha256_archivo'],'Recorte cambio: '+r['recorte'])
            if i%500==0:print('Verificados:',i,flush=True)
        torch.hub.set_dir(str(project/'modelos3_0/torch_cache'))
        transform=Compose([ToTensor(),Normalize([0.485,0.456,0.406],[0.229,0.224,0.225])])
        last=dest/'ultimo.pt';resuming=last.is_file()
        previous_info=load(dest/'configuracion.json') if resuming and (dest/'configuracion.json').is_file() else {}
        model=resnet50(weights=None if resuming else ResNet50_Weights.IMAGENET1K_V2)
        versions={'torch':str(torch.__version__),'torchvision':str(torchvision.__version__),'python':sys.version.split()[0]}
        info={'firma':signature,'parametros':semantic,'particiones':str(part),'galeria':str(gallery),'carpeta_recortes':str(crops),'ciclos_solicitados':epochs,'dispositivo':device,'hilos':threads,'versiones':versions,'preprocesamiento':'Letterbox224 bilinear RGB EXIF, relleno124/116/104, normalizacion ImageNet. Sin aumentos.','protocolo':'Individuos conocidos, galeria reutilizada de train. 253 individuos con una foto no aportan al Triplet; permanecen candidatos de galeria. Prueba.csv y sus imagenes no usados.','muestreo':'Ciclo PK: cada identidad apta aporta K fotos; positivos de distintas sesiones cuando disponibles. No recorre todas las fotos en cada ciclo.','seleccion_modelo':'Mejor Top1 de validacion dentro del modelo256; desempate Top5. Ciclo0 con salida aleatoria tambien elegible. Referencia ImageNet2048 guardada para comparacion.','checkpoint':'Cada 10 lotes y antes/despues de validacion. Al reanudar puede repetir hasta 9 lotes no guardados.','limites':'Piloto exploratorio. Sesiones inferidas temporalmente. Parte de recortes sin revision manual. No comprueba identidad ni duplicados visuales recomprimidos. Mejorar validacion no demuestra rendimiento final en prueba.'}
        weights_path=project/'modelos3_0/torch_cache/checkpoints'/Path(ResNet50_Weights.IMAGENET1K_V2.url).name
        info['peso_inicial_sha256']=previous_info.get('peso_inicial_sha256','') if resuming else sha(weights_path)
        atomic_json(dest/'configuracion.json',info)
        if resuming:
            model.fc=torch.nn.Linear(2048,256);model.to(device);optimizer=torch.optim.AdamW(model.parameters(),lr=1e-4,weight_decay=1e-4)
            state=torch.load(last,map_location=device,weights_only=True);require(state['firma']==signature,'Checkpoint incompatible.');model.load_state_dict(state['modelo']);optimizer.load_state_dict(state['optimizador'])
            require(epochs>=state['ciclo']-1,'El piloto ya completo mas ciclos que los solicitados.')
            print('Reanudando ciclo',state['ciclo'],'lote',state['siguiente_lote'],flush=True)
        else:
            model.fc=torch.nn.Identity();model.to(device)
            rawg=extract(model,refs,crops,transform,device,torch,label='Referencia ImageNet: galeria')
            rawq=extract(model,val,crops,transform,device,torch,label='Referencia ImageNet: validacion')
            bm,br,_,_=rank(rawg,rawq,refs,val);atomic_json(dest/'referencia_imagenet2048.json',bm);write(dest/'referencia_imagenet2048_top5.csv',br,list(br[0]))
            torch.manual_seed(30);model.fc=torch.nn.Linear(2048,256).to(device)
            with torch.inference_mode():
                g=normalize(model.fc(torch.from_numpy(rawg).to(device)).cpu().numpy());q=normalize(model.fc(torch.from_numpy(rawq).to(device)).cpu().numpy())
            m,rr,_,_=rank(g,q,refs,val);atomic_json(dest/'referencia_inicial256.json',m)
            optimizer=torch.optim.AdamW(model.parameters(),lr=1e-4,weight_decay=1e-4)
            history=[{'ciclo':0,'loss_train':None,'segundos_train':0,**m}]
            state={'firma':signature,'modelo':model.state_dict(),'optimizador':optimizer.state_dict(),'ciclo':1,'siguiente_lote':0,'loss_suma':0.0,'segundos_train':0.0,'historial':history,'mejor_ciclo':0,'mejor_top1':m['top1_porcentaje'],'mejor_top5':m['top5_porcentaje']}
            save_torch(dest/'mejor.pt',{'firma':signature,'modelo':model.state_dict(),'ciclo':0,'metricas':m},torch)
            np.save(dest/'galeria_mejor.npy',g);np.save(dest/'validacion_mejor.npy',q)
            atomic_json(dest/'mejor_validacion.json',m);write(dest/'mejor_validacion_top5.csv',rr,list(rr[0]));save_torch(last,state,torch)
            del rawg,rawq,g,q
            print(f'Referencia ImageNet2048 Top1 {bm["top1_porcentaje"]:.2f}% | Inicial256 Top1 {m["top1_porcentaje"]:.2f}%',flush=True)
        criterion=torch.nn.TripletMarginLoss(margin=.3,p=2)
        labelmap={i:n for n,i in enumerate(sorted(pool))}
        for epoch in range(state['ciclo'],epochs+1):
            plan=cycle_plan(pool,p,k,epoch);offset=state['siguiente_lote'] if epoch==state['ciclo'] else 0
            require(0<=offset<=len(plan),'Offset de checkpoint fuera de rango.');model.train()
            loss_sum=float(state['loss_suma']);train_seconds=float(state['segundos_train'])
            for n in range(offset,len(plan)):
                t=time.perf_counter();batch=plan[n]
                x=torch.stack([transform(letterbox(image(safe(crops,r['recorte'])))) for r in batch]).to(device)
                labs=torch.tensor([labelmap[r['individuo']] for r in batch],dtype=torch.long,device=device)
                optimizer.zero_grad(set_to_none=True);emb=torch.nn.functional.normalize(model(x),p=2,dim=1);loss=triplet(emb,labs,torch,criterion)
                require(bool(torch.isfinite(loss)),'Loss no finita.');loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),5,error_if_nonfinite=True);optimizer.step()
                value=loss.item();loss_sum+=value
                if device=='cuda':torch.cuda.synchronize()
                train_seconds+=time.perf_counter()-t
                state.update(ciclo=epoch,siguiente_lote=n+1,loss_suma=loss_sum,segundos_train=train_seconds,modelo=model.state_dict(),optimizador=optimizer.state_dict())
                if (n+1)%10==0 or n+1==len(plan):
                    save_torch(last,state,torch);atomic_json(dest/'estado.json',{'estado':'ENTRENANDO','ciclo':epoch,'lote_guardado':n+1,'lotes_ciclo':len(plan)})
                    print(f'Ciclo {epoch}/{epochs} | lotes {n+1}/{len(plan)} | loss media {loss_sum/(n+1):.4f} | train {train_seconds/60:.1f} min',flush=True)
            evalstart=time.perf_counter()
            g=extract(model,refs,crops,transform,device,torch,unit=True,label=f'Ciclo{epoch} galeria')
            q=extract(model,val,crops,transform,device,torch,unit=True,label=f'Ciclo{epoch} validacion')
            m,rr,_,_=rank(g,q,refs,val)
            row={'ciclo':epoch,'loss_train':loss_sum/len(plan),'segundos_train':train_seconds,'segundos_validacion':time.perf_counter()-evalstart,**m}
            state['historial'].append(row);atomic_json(dest/f'validacion_ciclo_{epoch:02d}.json',row)
            if (m['top1_porcentaje'],m['top5_porcentaje'])>(state['mejor_top1'],state['mejor_top5']):
                state.update(mejor_ciclo=epoch,mejor_top1=m['top1_porcentaje'],mejor_top5=m['top5_porcentaje'])
                save_torch(dest/'mejor.pt',{'firma':signature,'modelo':model.state_dict(),'ciclo':epoch,'metricas':m},torch)
                np.save(dest/'galeria_mejor.npy',g);np.save(dest/'validacion_mejor.npy',q);atomic_json(dest/'mejor_validacion.json',m);write(dest/'mejor_validacion_top5.csv',rr,list(rr[0]))
            state.update(ciclo=epoch+1,siguiente_lote=0,loss_suma=0.0,segundos_train=0.0,modelo=model.state_dict(),optimizador=optimizer.state_dict());save_torch(last,state,torch)
            atomic_json(dest/'historial.json',state['historial']);print(f'VALIDACION ciclo{epoch}: Top1 {m["top1_porcentaje"]:.2f}% | Top5 {m["top5_porcentaje"]:.2f}% | mejor ciclo {state["mejor_ciclo"]}',flush=True)
            pack(dest)
        atomic_json(dest/'historial.json',state['historial'])
        baseline=load(dest/'referencia_imagenet2048.json');best=load(dest/'mejor_validacion.json')
        summary={'estado':'COMPLETO','ciclos_entrenados':state['ciclo']-1,'ciclos_solicitados':epochs,'mejor_ciclo_modelo256':state['mejor_ciclo'],'referencia_imagenet2048':baseline,'referencia_inicial256':load(dest/'referencia_inicial256.json'),'mejor_validacion256':best,'diferencia_top1_puntos_vs_imagenet2048':best['top1_porcentaje']-baseline['top1_porcentaje'],'prueba_final_evaluada':False,'checkpoint_mejor':'mejor.pt','checkpoint_reanudar':'ultimo.pt','nota':'Si mejor ciclo es 0, el entrenamiento no supero la salida inicial256. No es precision de prueba final. ZIP no incluye pesos ni embeddings.'}
        atomic_json(dest/'resumen.json',summary);atomic_json(dest/'estado.json',{'estado':'COMPLETO','ciclos_entrenados':state['ciclo']-1})
        (dest/'resumen.txt').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
        examples(dest,np.load(dest/'galeria_mejor.npy'),np.load(dest/'validacion_mejor.npy'),refs,val,crops)
        pack(dest);print('Mejor modelo:',dest/'mejor.pt',flush=True)
    except (Exception,KeyboardInterrupt) as error:
        (dest/'error.txt').write_text(traceback.format_exc(),encoding='utf-8');atomic_json(dest/'estado.json',{'estado':'INTERRUMPIDO' if isinstance(error,KeyboardInterrupt) else 'ERROR','error':str(error),'reanudar':'Ejecuta el mismo comando. Se recupera ultimo.pt si existe.'});pack(dest);raise

if __name__=='__main__':
    require(len(sys.argv)==7,'Argumentos: proyecto ciclos dispositivo hilos P K')
    train_pilot(Path(sys.argv[1]),int(sys.argv[2]),sys.argv[3],int(sys.argv[4]),int(sys.argv[5]),int(sys.argv[6]))

'@ | & $python - $Proyecto $Ciclos $Dispositivo $Hilos $P $K
if ($LASTEXITCODE -ne 0) { throw 'El piloto no se completo. Comparte el error o el ZIP; ejecutando el mismo comando se recupera ultimo.pt si existe.' }
