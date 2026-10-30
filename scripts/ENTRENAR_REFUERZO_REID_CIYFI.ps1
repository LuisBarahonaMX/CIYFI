param([string]$Proyecto = '', [ValidateRange(1,30)][int]$Ciclos = 5, [ValidateSet('cpu','auto','cuda')][string]$Dispositivo = 'cpu', [ValidateRange(1,8)][int]$Hilos = 4)
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


def cached_extract(model,rows,crops,transform,device,torch,folder,label):
    folder.mkdir(exist_ok=True);chunks=[]
    for off in range(0,len(rows),128):
        path=folder/f'{off:05d}.npy';count=min(128,len(rows)-off)
        if path.exists():
            a=np.load(path,allow_pickle=False)
            require(a.shape==(count,256) and np.isfinite(a).all(),'Cache invalida: '+str(path))
        else:
            a=extract(model,rows[off:off+128],crops,transform,device,torch,unit=True,label=f'{label} {off}/{len(rows)}')
            tmp=path.with_suffix('.npy.tmp')
            with tmp.open('wb') as f:np.save(f,a)
            tmp.replace(path)
        chunks.append(a);print(f'{label}: {off+count}/{len(rows)} guardadas',flush=True)
    return normalize(np.concatenate(chunks))

def multi_rank(g,q,train,val):
    ids=sorted({r['individuo'] for r in train});groups=[[i for i,r in enumerate(train) if r['individuo']==identity] for identity in ids]
    scores=np.empty((len(q),len(ids)),dtype=np.float32);best=np.empty((len(q),len(ids)),dtype=np.int32)
    for off in range(0,len(q),64):
        sim=q[off:off+64]@g.T
        for j,indices in enumerate(groups):
            local=sim[:,indices].argmax(axis=1);chosen=np.asarray(indices)[local]
            best[off:off+len(sim),j]=chosen;scores[off:off+len(sim),j]=sim[np.arange(len(sim)),chosen]
    order=np.argsort(-scores,axis=1,kind='stable')[:,:5];rows=[];by_id=defaultdict(list)
    for i,r in enumerate(val):
        ranked=[ids[j] for j in order[i]];one=int(ranked[0]==r['individuo']);five=int(r['individuo'] in ranked)
        d={k:r[k] for k in ('numero','individuo','original','recorte','revision_calidad')};d.update(top1_correcto=one,top5_correcto=five)
        for pos,j in enumerate(order[i],1):
            ref=train[best[i,j]];d.update({f'top{pos}_individuo':ids[j],f'top{pos}_similitud':float(scores[i,j]),f'top{pos}_recorte':ref['recorte'],f'top{pos}_numero':ref['numero']})
        j=ids.index(r['individuo']);d['referencia_correcta_recorte']=train[best[i,j]]['recorte'];d['similitud_correcta']=float(scores[i,j]);rows.append(d);by_id[r['individuo']].append((one,five))
    metrics={'consultas':len(rows),'individuos_consultados':len(by_id),'individuos_galeria':len(ids),'fotos_galeria':len(train),'top1_porcentaje':100*np.mean([r['top1_correcto'] for r in rows]).item(),'top5_porcentaje':100*np.mean([r['top5_correcto'] for r in rows]).item(),'macro_top1_porcentaje':100*np.mean([np.mean([a for a,b in v]) for v in by_id.values()]).item(),'macro_top5_porcentaje':100*np.mean([np.mean([b for a,b in v]) for v in by_id.values()]).item()}
    return metrics,rows

def review_examples(dest,rows,crops):
    import html
    # Muestra diagnostica determinista, no representativa de toda la poblacion.
    chosen=[]
    for label,subset in [('fallo_fuera_top5',[r for r in rows if not r['top5_correcto']]),('fallo_top1',[r for r in rows if not r['top1_correcto'] and r['top5_correcto']]),('acierto',[r for r in rows if r['top1_correcto']])]:
        for r in sorted(subset,key=lambda r:(-r['top1_similitud'],int(r['numero'])))[:15 if label!='acierto' else 10]:chosen.append((label,r))
    folder=dest/'ejemplos';folder.mkdir(exist_ok=True);cards=[]
    for label,r in chosen:
        canvas=Image.new('RGB',(1680,300),'white');draw=ImageDraw.Draw(canvas)
        panels=[('Consulta '+r['individuo'],r['recorte'],None)]+[(f'Top{j} '+r[f'top{j}_individuo'],r[f'top{j}_recorte'],r[f'top{j}_similitud']) for j in range(1,6)]+[('Referencia identidad correcta',r['referencia_correcta_recorte'],r['similitud_correcta'])]
        for j,(title,path,score) in enumerate(panels):
            im=ImageOps.contain(image(safe(crops,path)),(224,224));canvas.paste(im,(240*j+(240-im.width)//2,45+(224-im.height)//2));draw.text((240*j+4,4),title,fill='black')
            if score is not None:draw.text((240*j+4,24),f'Similitud {score:.4f}',fill='black')
        draw.text((5,278),f'Foto {r["numero"]} | {label} | {r["revision_calidad"]} | Las similitudes no son probabilidades.',fill='black')
        name=f'{label}_{r["numero"].zfill(5)}.jpg';canvas.save(folder/name,quality=85)
        cards.append(f'<h3>{html.escape(label)} - Foto {html.escape(r["numero"])}</h3><img src="ejemplos/{name}" style="width:100%;max-width:1680px">')
    (dest/'REVISAR_RESULTADOS.html').write_text('<!doctype html><html lang="es"><meta charset="utf-8"><title>CIYFI revision</title><body style="font-family:Arial"><h1>Revision de validacion CIYFI</h1><p>Muestra diagnostica seleccionada por similitud alta: no representa todos los casos. Revise cabeza visible, nitidez, orientacion y si la identidad de las carpetas parece coherente. La ultima columna muestra la mejor referencia de la identidad esperada.</p>'+''.join(cards)+'</body></html>',encoding='utf-8')

def package(dest):
    path=dest/'GALERIA_MULTIPLE_PARA_COMPARTIR.zip'
    with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(dest.iterdir()):
            if p.is_file() and p.suffix in ('.json','.csv','.txt','.html'):z.write(p,p.name)
        for p in sorted((dest/'ejemplos').glob('*.jpg')):z.write(p,'ejemplos/'+p.name)
    print('ZIP PARA COMPARTIR:',path,flush=True)


def save_checkpoint(path,data,torch):
    # Reintenta bloqueos transitorios de Windows sin eliminar el checkpoint anterior.
    import os
    tmp=path.with_suffix('.pt.tmp');torch.save(data,tmp)
    for attempt in range(8):
        try:os.replace(tmp,path);return
        except PermissionError:
            if attempt==7:raise
            print('Archivo ocupado; reintentando guardado...',flush=True);time.sleep(.5*(attempt+1))

def report_zip(dest):
    zp=dest/'REFUERZO_REID_PARA_COMPARTIR.zip';tmp=dest/'reporte.tmp.zip'
    with zipfile.ZipFile(tmp,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(dest.iterdir()):
            if p.is_file() and p.suffix in ('.json','.txt','.csv','.html'):z.write(p,p.name)
        for p in sorted((dest/'ejemplos').glob('*.jpg')):z.write(p,'ejemplos/'+p.name)
    tmp.replace(zp);print('ZIP PARA COMPARTIR:',zp,flush=True)

def finish(dest,state):
    best=load(dest/'mejor_validacion.json');base=load(dest/'referencia_galeria_multiple.json')
    summary={'estado':'COMPLETO','ciclos_refuerzo_completados':state['ciclo']-1,'mejor_ciclo_refuerzo':state['mejor_ciclo'],'modelo_origen_ciclo':21,'referencia':base,'mejor_validacion':best,'delta_top1_puntos':best['top1_porcentaje']-base['top1_porcentaje'],'delta_top5_puntos':best['top5_porcentaje']-base['top5_porcentaje'],'prueba_final_evaluada':False,'nota':'Ciclo0 conserva el modelo previo si el refuerzo no lo supera. Cambio de aumentos y tasa de aprendizaje; no atribuir causalidad a un solo cambio.'}
    atomic_json(dest/'resumen.json',summary);(dest/'resumen.txt').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8');atomic_json(dest/'estado.json',{'estado':'COMPLETO'})
    if (dest/'error.txt').exists():(dest/'error.txt').unlink()
    report_zip(dest);print('MEJOR MODELO:',dest/'mejor.pt',flush=True)

def reinforce(project,epochs,requested,threads):
    import torch,torchvision,shutil
    from torchvision.models import resnet50
    from torchvision.transforms import Compose,ToTensor,Normalize,ColorJitter,RandomGrayscale,RandomRotation,InterpolationMode
    torch.set_num_threads(threads);torch.set_num_interop_threads(1);torch.manual_seed(300)
    part,gallery,cfg,train,val,refs,crops=select_inputs(project)
    # Este ensayo corresponde al modelo evaluado y conservado del ciclo21.
    pilot=project/'runs3_0/reid_piloto_9aa2d4c2d5f1de27';source=pilot/'mejor.pt'
    require(source.is_file(),'No se encontro el modelo del piloto original.')
    source_hash=sha(source)
    require(source_hash=='ba6d0c524c13150c3b23ac209efd32a9586e93310dc26a3e54c11019892b59aa','El modelo original cambio. Comparte el reporte antes de iniciar este ensayo.')
    origin=torch.load(source,map_location='cpu',weights_only=True);require(origin['ciclo']==21,'Se esperaba el modelo del ciclo21.')
    pc=load(pilot/'configuracion.json');require(origin['firma']==pc['firma'],'Firma del modelo incorrecta.')
    require(pc['parametros']['train']==sha(part/'entrenamiento.csv') and pc['parametros']['validacion']==sha(part/'validacion.csv'),'Particiones diferentes al piloto.')
    semantic={'algoritmo':'ciyfi_refuerzo_aumentos_v1','source':source_hash,'train':sha(part/'entrenamiento.csv'),'validacion':sha(part/'validacion.csv'),'lr':.00003,'P':4,'K':2,'rotacion':15,'brillo':.25,'contraste':.25,'saturacion':.2,'hue':.02,'grises_p':.1,'seed':300,'regla':'max_coseno_por_individuo'}
    signature=hashlib.sha256(json.dumps(semantic,sort_keys=True).encode()).hexdigest();dest=project/'runs3_0'/('reid_refuerzo_'+signature[:16]);dest.mkdir(parents=True,exist_ok=True)
    try:
        require(shutil.disk_usage(project).free>1024**3,'Se requiere al menos 1 GB libre para los checkpoints temporales.')
        device='cuda' if requested=='auto' and torch.cuda.is_available() else ('cpu' if requested=='auto' else requested)
        require(device!='cuda' or torch.cuda.is_available(),'CUDA no disponible.')
        print('Salida:',dest,'\nDispositivo:',device,flush=True)
        for i,r in enumerate(train+val,1):
            require(sha(safe(crops,r['recorte']))==r['sha256_archivo'],'Recorte modificado: '+r['recorte'])
            if i%500==0:print('Verificadas',i,'/',len(train)+len(val),flush=True)
        transform=Compose([ToTensor(),Normalize([.485,.456,.406],[.229,.224,.225])])
        # Aumentos sobre RGB antes de normalizar. Rotacion expandida para conservar la cabeza.
        aug=Compose([RandomRotation(15,interpolation=InterpolationMode.BILINEAR,expand=True,fill=(124,116,104)),ColorJitter(brightness=.25,contrast=.25,saturation=.2,hue=.02),RandomGrayscale(p=.1)])
        model=resnet50(weights=None);model.fc=torch.nn.Linear(2048,256);model.to(device)
        optimizer=torch.optim.AdamW(model.parameters(),lr=3e-5,weight_decay=1e-4)
        last=dest/'ultimo.pt';pool=eligible_pool(train,2);labelmap={identity:i for i,identity in enumerate(sorted(pool))}
        info={'firma':signature,'parametros':semantic,'ciclos_solicitados':epochs,'dispositivo':device,'versiones':{'torch':str(torch.__version__),'torchvision':str(torchvision.__version__)},'modelo_origen':str(source),'carpeta_recortes':str(crops),'particiones':str(part),'validacion':'Todas las4495 fotos de train como galeria y806 consultas de validacion sin aumentos. Top5 de identidades diferentes.','limites':'No garantiza mejora. Variaciones moderadas no simulan necesariamente luz roja fuerte. Parte de recortes sin revision. Prueba final no leida.','reanudar':'Mismo comando. Hasta9 lotes pueden repetirse. Aumentos por lote con semilla determinista.'}
        atomic_json(dest/'configuracion.json',info)
        if last.exists():
            state=torch.load(last,map_location=device,weights_only=True);require(state['firma']==signature,'Checkpoint incompatible.');model.load_state_dict(state['modelo']);optimizer.load_state_dict(state['optimizador']);require(epochs>=state['ciclo']-1,'Ya se completaron mas ciclos que los solicitados.');print('Reanudando refuerzo ciclo',state['ciclo'],'lote',state['siguiente_lote'],flush=True)
        else:
            model.load_state_dict(origin['modelo']);del origin
            # Reutiliza los embeddings del modelo origen, comprobados contra las mismas particiones.
            key=hashlib.sha256(json.dumps({'modelo':source_hash,'train':sha(part/'entrenamiento.csv'),'val':sha(part/'validacion.csv'),'galeria':sha(gallery/'galeria.csv'),'algoritmo':'max_coseno_por_individuo_v1_letterbox224'},sort_keys=True).encode()).hexdigest()
            prev=project/'reid3_0'/('galeria_multiple_'+key[:16]);require(load(prev/'configuracion.json')['firma']==key and load(prev/'estado.json')['estado']=='COMPLETO','Completa primero la evaluacion de galeria multiple.')
            g=cached_extract(model,train,crops,transform,device,torch,prev/'cache_train','Referencia galeria')
            q=cached_extract(model,val,crops,transform,device,torch,prev/'cache_validacion','Referencia consultas')
            baseline,rr=multi_rank(g,q,train,val);expected=load(prev/'resumen.json')['galeria_multiple']
            require(abs(baseline['top1_porcentaje']-expected['top1_porcentaje'])<1e-6 and abs(baseline['top5_porcentaje']-expected['top5_porcentaje'])<1e-6,'Cache de referencia inconsistente.')
            atomic_json(dest/'referencia_galeria_multiple.json',baseline);atomic_json(dest/'mejor_validacion.json',baseline);write(dest/'mejor_validacion_top5.csv',rr,list(rr[0]));review_examples(dest,rr,crops)
            state={'firma':signature,'ciclo':1,'siguiente_lote':0,'loss_suma':0.,'segundos_train':0.,'mejor_ciclo':0,'mejor_top1':baseline['top1_porcentaje'],'mejor_top5':baseline['top5_porcentaje'],'historial':[{'ciclo_refuerzo':0,**baseline}],'modelo':model.state_dict(),'optimizador':optimizer.state_dict()}
            save_checkpoint(dest/'mejor.pt',{'firma':signature,'modelo':model.state_dict(),'ciclo_refuerzo':0,'metricas':baseline},torch);save_checkpoint(last,state,torch);del g,q
        criterion=torch.nn.TripletMarginLoss(margin=.3,p=2)
        for epoch in range(state['ciclo'],epochs+1):
            plan=cycle_plan(pool,4,2,1000+epoch);offset=state['siguiente_lote'];require(0<=offset<=len(plan),'Lote fuera de rango.');model.train();loss_sum=state['loss_suma'];seconds=state['segundos_train']
            for n in range(offset,len(plan)):
                start=time.perf_counter();torch.manual_seed(300000+epoch*10000+n);batch=plan[n]
                x=torch.stack([transform(letterbox(aug(image(safe(crops,r['recorte']))))) for r in batch]).to(device)
                labs=torch.tensor([labelmap[r['individuo']] for r in batch],dtype=torch.long,device=device)
                optimizer.zero_grad(set_to_none=True);emb=torch.nn.functional.normalize(model(x),p=2,dim=1);loss=triplet(emb,labs,torch,criterion);require(bool(torch.isfinite(loss)),'Loss no finita.');loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),5,error_if_nonfinite=True);optimizer.step();loss_sum+=loss.item()
                if device=='cuda':torch.cuda.synchronize()
                seconds+=time.perf_counter()-start
                state.update(ciclo=epoch,siguiente_lote=n+1,loss_suma=loss_sum,segundos_train=seconds,modelo=model.state_dict(),optimizador=optimizer.state_dict())
                if (n+1)%10==0 or n+1==len(plan):
                    save_checkpoint(last,state,torch);atomic_json(dest/'estado.json',{'estado':'ENTRENANDO','ciclo_refuerzo':epoch,'lote':n+1});print(f'Refuerzo {epoch}/{epochs} | lotes {n+1}/{len(plan)} | loss {loss_sum/(n+1):.4f}',flush=True)
            start=time.perf_counter();g=extract(model,train,crops,transform,device,torch,unit=True,label=f'Refuerzo{epoch} galeria');q=extract(model,val,crops,transform,device,torch,unit=True,label=f'Refuerzo{epoch} validacion');metrics,rr=multi_rank(g,q,train,val)
            row={'ciclo_refuerzo':epoch,'loss_train':loss_sum/len(plan),'segundos_train':seconds,'segundos_validacion':time.perf_counter()-start,**metrics};state['historial'].append(row);atomic_json(dest/f'validacion_ciclo_{epoch:02d}.json',row)
            if (metrics['top1_porcentaje'],metrics['top5_porcentaje'])>(state['mejor_top1'],state['mejor_top5']):
                state.update(mejor_ciclo=epoch,mejor_top1=metrics['top1_porcentaje'],mejor_top5=metrics['top5_porcentaje'])
                save_checkpoint(dest/'mejor.pt',{'firma':signature,'modelo':model.state_dict(),'ciclo_refuerzo':epoch,'metricas':metrics},torch);atomic_json(dest/'mejor_validacion.json',metrics);write(dest/'mejor_validacion_top5.csv',rr,list(rr[0]));review_examples(dest,rr,crops)
            state.update(ciclo=epoch+1,siguiente_lote=0,loss_suma=0.,segundos_train=0.,modelo=model.state_dict(),optimizador=optimizer.state_dict());save_checkpoint(last,state,torch);atomic_json(dest/'historial.json',state['historial'])
            print(f'VALIDACION refuerzo{epoch}: Top1 {metrics["top1_porcentaje"]:.2f}% | Top5 {metrics["top5_porcentaje"]:.2f}% | mejor refuerzo {state["mejor_ciclo"]}',flush=True);report_zip(dest);del g,q
        finish(dest,state)
    except (Exception,KeyboardInterrupt) as e:
        (dest/'error.txt').write_text(traceback.format_exc(),encoding='utf-8');atomic_json(dest/'estado.json',{'estado':'ERROR','error':str(e)});report_zip(dest);raise

if __name__=='__main__':reinforce(Path(sys.argv[1]),int(sys.argv[2]),sys.argv[3],int(sys.argv[4]))

'@ | & $python - $Proyecto $Ciclos $Dispositivo $Hilos
if ($LASTEXITCODE -ne 0) { throw 'El refuerzo no se completo. Comparte el error o el ZIP. Reanuda ejecutando el mismo comando.' }
