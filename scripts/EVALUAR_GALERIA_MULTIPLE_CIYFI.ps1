param([string]$Proyecto = '', [ValidateSet('auto','cpu','cuda')][string]$Dispositivo = 'cpu', [ValidateRange(1,8)][int]$Hilos = 4)
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

def main(project,requested,threads):
    import torch,torchvision
    from torchvision.models import resnet50
    from torchvision.transforms import Compose,ToTensor,Normalize
    torch.set_num_threads(threads);torch.set_num_interop_threads(1)
    part,gallery,cfg,train,val,refs,crops=select_inputs(project)
    matches=[]
    for p in (project/'runs3_0').glob('reid_piloto_*'):
        try:
            c=load(p/'configuracion.json');s=load(p/'resumen.json')
            if s['estado']=='COMPLETO' and c['parametros']['train']==sha(part/'entrenamiento.csv') and c['parametros']['validacion']==sha(part/'validacion.csv') and c['parametros']['galeria']==sha(gallery/'galeria.csv') and (p/'mejor.pt').is_file():matches.append(p)
        except (OSError,ValueError,KeyError):pass
    require(len(matches)==1,'Se requiere exactamente un piloto completo compatible. No se seleccionaran pesos ambiguos.')
    pilot=matches[0];pc=load(pilot/'configuracion.json');weights=pilot/'mejor.pt';weight_hash=sha(weights)
    signature=hashlib.sha256(json.dumps({'modelo':weight_hash,'train':sha(part/'entrenamiento.csv'),'val':sha(part/'validacion.csv'),'galeria':sha(gallery/'galeria.csv'),'algoritmo':'max_coseno_por_individuo_v1_letterbox224'},sort_keys=True).encode()).hexdigest()
    dest=project/'reid3_0'/('galeria_multiple_'+signature[:16]);dest.mkdir(parents=True,exist_ok=True)
    try:
        device='cuda' if requested=='auto' and torch.cuda.is_available() else ('cpu' if requested=='auto' else requested)
        require(device!='cuda' or torch.cuda.is_available(),'CUDA no disponible.')
        print('Salida:',dest,'\nDispositivo:',device,flush=True)
        for i,r in enumerate(train+val,1):
            require(sha(safe(crops,r['recorte']))==r['sha256_archivo'],'Recorte modificado: '+r['recorte'])
            if i%500==0:print('Verificadas',i,'/',len(train)+len(val),flush=True)
        state=torch.load(weights,map_location='cpu',weights_only=True)
        require(state['firma']==pc['firma'],'Firma de modelo incompatible.')
        require(state['ciclo']==load(pilot/'resumen.json')['mejor_ciclo_modelo256'],'Modelo y resumen discrepan.')
        model=resnet50(weights=None);model.fc=torch.nn.Linear(2048,256);model.load_state_dict(state['modelo']);model.to(device);model.eval()
        atomic_json(dest/'configuracion.json',{'firma':signature,'modelo_sha256':weight_hash,'modelo':str(weights),'ciclo':state['ciclo'],'particiones':str(part),'carpeta_recortes':str(crops),'dispositivo':device,'torch':str(torch.__version__),'torchvision':str(torchvision.__version__),'regla':'Maximo coseno entre fotos de entrenamiento de cada individuo; Top5 de identidades distintas. Empates por orden alfabetico.','limites':'Galeria desigual: individuos con mas fotos tienen mas oportunidades de coincidencia. Seleccion exploratoria en validacion; no demuestra rendimiento de prueba. Parte de recortes sin revision e identidades no auditadas.','prueba_final_evaluada':False})
        transform=Compose([ToTensor(),Normalize([.485,.456,.406],[.229,.224,.225])])
        g=cached_extract(model,train,crops,transform,device,torch,dest/'cache_train','Galeria ampliada')
        q=cached_extract(model,val,crops,transform,device,torch,dest/'cache_validacion','Validacion')
        lookup={r['original']:i for i,r in enumerate(train)}
        baseline,br,_,_=rank(g[[lookup[r['original']] for r in refs]],q,refs,val)
        previous=state['metricas'];require(abs(baseline['top1_porcentaje']-previous['top1_porcentaje'])<.13 and abs(baseline['top5_porcentaje']-previous['top5_porcentaje'])<.13,'La referencia recalculada difiere del piloto: comparte reporte antes de interpretar.')
        metrics,rows=multi_rank(g,q,train,val)
        write(dest/'galeria_entrenamiento.csv',train,list(train[0]));write(dest/'validacion_top5.csv',rows,list(rows[0]));write(dest/'fallos_top1.csv',[r for r in rows if not r['top1_correcto']],list(rows[0]));write(dest/'referencia_una_foto_top5.csv',br,list(br[0]))
        comparison=[{'galeria':'Una foto por individuo','fotos':len(refs),'top1':baseline['top1_porcentaje'],'top5':baseline['top5_porcentaje']},{'galeria':'Todas las fotos de entrenamiento','fotos':len(train),'top1':metrics['top1_porcentaje'],'top5':metrics['top5_porcentaje']}];write(dest/'comparacion.csv',comparison,list(comparison[0]))
        summary={'estado':'COMPLETO','ciclo_modelo':state['ciclo'],'referencia_una_foto':baseline,'galeria_multiple':metrics,'delta_top1_puntos':metrics['top1_porcentaje']-baseline['top1_porcentaje'],'delta_top5_puntos':metrics['top5_porcentaje']-baseline['top5_porcentaje'],'prueba_final_evaluada':False,'reentrenamiento':False}
        review_examples(dest,rows,crops);atomic_json(dest/'resumen.json',summary);(dest/'resumen.txt').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
        if (dest/'error.txt').exists():(dest/'error.txt').unlink()
        atomic_json(dest/'estado.json',{'estado':'COMPLETO'});package(dest)
        print(f'TERMINADO | Una foto Top1 {baseline["top1_porcentaje"]:.2f}% Top5 {baseline["top5_porcentaje"]:.2f}% | Multiple Top1 {metrics["top1_porcentaje"]:.2f}% Top5 {metrics["top5_porcentaje"]:.2f}%',flush=True)
        print('ABRIR PARA REVISAR:',dest/'REVISAR_RESULTADOS.html',flush=True)
    except (Exception,KeyboardInterrupt) as e:
        (dest/'error.txt').write_text(traceback.format_exc(),encoding='utf-8');atomic_json(dest/'estado.json',{'estado':'ERROR','error':str(e)});package(dest);raise

if __name__=='__main__':main(Path(sys.argv[1]),sys.argv[2],int(sys.argv[3]))

'@ | & $python - $Proyecto $Dispositivo $Hilos
if ($LASTEXITCODE -ne 0) { throw 'No se completo. Comparte el error o el ZIP. El mismo comando reutiliza los bloques de embeddings guardados.' }
