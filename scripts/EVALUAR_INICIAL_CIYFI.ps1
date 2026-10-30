param(
 [string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0',
 [string]$Preparacion = '',
 [int]$Batch = 8,
 [int]$Threads = 4
)
$ErrorActionPreference = 'Stop'
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No se encontro Python: $python" }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
if ([string]::IsNullOrWhiteSpace($Preparacion)) { $Preparacion = 'AUTO' }
& $python -c "import torch, torchvision, numpy, PIL; print('PyTorch:', torch.__version__); print('Torchvision:', torchvision.__version__)"
if ($LASTEXITCODE -ne 0) { throw 'No cargan las dependencias existentes. Comparte este error antes de cambiar el entorno.' }
& $python -c "import faiss; print('FAISS:', faiss.__version__)"
if ($LASTEXITCODE -ne 0) {
 Write-Host 'Instalando FAISS CPU en el entorno del proyecto...' -ForegroundColor Cyan
 & $python -m pip install --only-binary=:all: faiss-cpu
 if ($LASTEXITCODE -ne 0) { throw 'No se pudo instalar FAISS. Comparte la salida.' }
}
@'
import csv, hashlib, json, os, random, sys, time, zipfile
from pathlib import Path
from datetime import datetime
from collections import defaultdict, Counter
import numpy as np
from PIL import Image, ImageOps, ImageDraw

ALGORITHM='resnet50_imagenet1k_v2_letterbox224_l2_v1'
def digest(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for block in iter(lambda:f.read(1048576),b''):h.update(block)
    return h.hexdigest()
def load(p):return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def save(p,obj):
    p=Path(p);tmp=p.with_suffix('.tmp');tmp.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8');tmp.replace(p)
def rows(p):
    with Path(p).open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
def csvout(p,data,fields):
    with Path(p).open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(data)
def safe(base,relative):
    p=(base/relative).resolve()
    if not relative or not p.is_relative_to(base.resolve()):raise ValueError('Ruta de recorte no valida: '+relative)
    return p

def read_image(p):
    with Image.open(p) as f:
        f.seek(0);im=ImageOps.exif_transpose(f).convert('RGB');im.load();return im

def letterbox(im):
    # Conserva toda la cabeza, sin recorte central. El relleno se aproxima a la media ImageNet.
    im=ImageOps.contain(im,(224,224),method=Image.Resampling.BILINEAR)
    canvas=Image.new('RGB',(224,224),(124,116,104));canvas.paste(im,((224-im.width)//2,(224-im.height)//2));return canvas

def normalize(v):
    v=np.asarray(v,dtype=np.float32);norm=np.linalg.norm(v,axis=1,keepdims=True)
    if not np.isfinite(v).all() or np.any(norm<1e-12):raise ValueError('Embeddings no finitos o de norma cero.')
    return np.ascontiguousarray(v/norm)

def metrics(results):
    if not results:return {'consultas':0,'individuos':0,'top1_porcentaje':None,'top5_porcentaje':None,'macro_top1_porcentaje':None,'macro_top5_porcentaje':None}
    byid=defaultdict(list)
    for r in results:byid[r['individuo_real']].append(r)
    return {'consultas':len(results),'individuos':len(byid),'top1_porcentaje':round(100*sum(r['acierto_top1'] for r in results)/len(results),4),'top5_porcentaje':round(100*sum(r['acierto_top5'] for r in results)/len(results),4),'macro_top1_porcentaje':round(100*np.mean([np.mean([r['acierto_top1'] for r in group]) for group in byid.values()]),4),'macro_top5_porcentaje':round(100*np.mean([np.mean([r['acierto_top5'] for r in group]) for group in byid.values()]),4)}

def evaluate(g,q,G,Q,faiss):
    G=normalize(G);Q=normalize(Q)
    if len({r['individuo'] for r in g})!=len(g):raise ValueError('Debe haber una sola foto de galeria por individuo.')
    index=faiss.IndexFlatIP(G.shape[1]);index.add(G)
    scores,ids=index.search(Q,min(5,len(g)));results=[];lookup={r['individuo']:r for r in g}
    for i,r in enumerate(q):
        if r['individuo'] not in lookup:raise ValueError('Consulta sin identidad en galeria.')
        true=lookup[r['individuo']];predicted=[g[int(k)]['individuo'] for k in ids[i]]
        rank=predicted.index(r['individuo'])+1 if r['individuo'] in predicted else 0
        result={'numero':r['numero'],'original_consulta':r['original'],'recorte_consulta':r['recorte'],'individuo_real':r['individuo'],'calidad_consulta':r['revision_calidad'],'calidad_galeria_real':true['revision_calidad'],'acierto_top1':int(rank==1),'acierto_top5':int(rank>0),'puesto_correcto_en_top5':rank}
        for j,k in enumerate(ids[i],1):
            p=g[int(k)];result.update({f'individuo_top{j}':p['individuo'],f'similitud_top{j}':float(scores[i,j-1]),f'recorte_top{j}':p['recorte']})
        results.append(result)
    summary={'todas':metrics(results),'consultas_aceptadas_manualmente':metrics([r for r in results if r['calidad_consulta']=='ACEPTADO_MANUAL']),'consulta_y_galeria_real_aceptadas_manualmente':metrics([r for r in results if r['calidad_consulta']=='ACEPTADO_MANUAL' and r['calidad_galeria_real']=='ACEPTADO_MANUAL'])}
    return index,results,summary

def embed(reg,group,name,model,torch,transform,batch,signature):
    dest=reg['dest'];base=reg['base'];fp=dest/(name+'_embeddings.npy');sp=dest/(name+'_avance.json')
    count=0
    if sp.exists():
        state=load(sp)
        if state['firma']!=signature:raise ValueError('El checkpoint no coincide; cambia la carpeta de salida.')
        count=state['completadas']
        if not fp.exists():raise ValueError('Falta el archivo de embeddings del checkpoint.')
        vec=np.load(fp,mmap_mode='r+')
        if vec.shape!=(len(group),2048):raise ValueError('Checkpoint con dimensiones incorrectas.')
    else:
        vec=np.lib.format.open_memmap(fp,mode='w+',dtype=np.float32,shape=(len(group),2048));save(sp,{'firma':signature,'completadas':0})
    if not 0<=count<=len(group):raise ValueError('Checkpoint invalido.')
    initial=count;start=time.perf_counter()
    print(f'{name}: reanudando en {count}/{len(group)}',flush=True)
    for pos in range(count,len(group),batch):
        subset=group[pos:pos+batch];tensors=[]
        for r in subset:tensors.append(transform(letterbox(read_image(safe(base,r['recorte'])))))
        x=torch.stack(tensors)
        with torch.inference_mode():output=model(x).cpu().numpy()
        v=normalize(output)
        if v.shape!=(len(subset),2048):raise ValueError('La salida no tiene 2048 dimensiones.')
        vec[pos:pos+len(subset)]=v;vec.flush();count=pos+len(subset)
        save(sp,{'firma':signature,'completadas':count})
        if pos==initial or count==len(group) or count//100!=(pos//100):
            elapsed=time.perf_counter()-start;rate=(count-initial)/max(elapsed,1e-6);remaining=(len(group)-count)/rate/60
            print(f'{name}: {count}/{len(group)} | {elapsed/60:.1f} min | faltan aprox. {remaining:.1f} min',flush=True)
    return np.asarray(vec)

def panels(results,base,dest,k):
    output=dest/'ejemplos';output.mkdir(exist_ok=True);rng=random.Random(30);chosen=[]
    for title,subset in [('acierto_top1',[r for r in results if r['acierto_top1']]),('acierto_solo_top5',[r for r in results if r['acierto_top5'] and not r['acierto_top1']]),('fallo_top5',[r for r in results if not r['acierto_top5']])]:
        chosen.extend((title,r) for r in rng.sample(subset,min(20,len(subset))))
    for title,r in chosen:
        canvas=Image.new('RGB',((k+1)*240,305),'white');draw=ImageDraw.Draw(canvas)
        entries=[('Consulta: '+r['individuo_real'],r['recorte_consulta'],'')]+[(f'Top {j}: '+r[f'individuo_top{j}'],r[f'recorte_top{j}'],f'Coseno: {r[f"similitud_top{j}"]:.4f}') for j in range(1,k+1)]
        for j,(label,rel,score) in enumerate(entries):
            im=ImageOps.contain(read_image(safe(base,rel)),(224,224));canvas.paste(im,(j*240+(240-im.width)//2,40+(224-im.height)//2));draw.text((j*240+4,5),label,fill='black');draw.text((j*240+4,24),score,fill='black')
        draw.text((5,280),title+' | Foto '+r['numero']+' | Las similitudes NO son probabilidades.',fill='black')
        canvas.save(output/(title+'_'+r['numero'].zfill(5)+'.jpg'),quality=85)
    return len(chosen)

def main(project,prep_arg,batch,threads):
    import torch,torchvision,faiss
    from torchvision.models import resnet50,ResNet50_Weights
    from torchvision.transforms import Compose,ToTensor,Normalize
    project=Path(project);batch=int(batch);threads=int(threads)
    if not 1<=batch<=64 or not 1<=threads<=64:raise ValueError('Batch y Threads deben estar entre 1 y 64.')
    if prep_arg and prep_arg!='AUTO':prep=Path(prep_arg)
    else:
        options=sorted((project/'reid3_0').glob('preparacion_*'),reverse=True)
        prep=next((p for p in options if (p/'resumen.json').exists() and load(p/'resumen.json').get('estado')=='LISTO'),None)
        if prep is None:raise ValueError('No se encontro una preparacion LISTO.')
    if load(prep/'resumen.json').get('estado')!='LISTO':raise ValueError('La preparacion no esta lista.')
    config=load(prep/'configuracion.json');base=Path(config['carpeta_recortes']);g=rows(prep/'galeria.csv');q=rows(prep/'consultas.csv')
    if not g or not q:raise ValueError('Galeria o consultas vacias.')
    allrows=g+q
    if len({r['original'] for r in allrows})!=len(allrows):raise ValueError('Hay fotos repetidas entre galeria y consultas.')
    if {r['sha256_pixeles'] for r in g}&{r['sha256_pixeles'] for r in q}:raise ValueError('Hay duplicados entre galeria y consultas.')
    print('Preparacion:',prep);print(f'Galeria: {len(g)} | Consultas: {len(q)} | CPU | Batch: {batch} | Hilos: {threads}',flush=True)
    print('Comprobando que los recortes no cambiaron desde la preparacion...',flush=True)
    for i,r in enumerate(allrows,1):
        if digest(safe(base,r['recorte']))!=r['sha256_archivo']:raise ValueError('Recorte modificado desde la preparacion: '+r['recorte'])
        if i%500==0 or i==len(allrows):print(f'Archivos comprobados: {i}/{len(allrows)}',flush=True)
    dest=prep/'evaluacion_resnet50_v1';dest.mkdir(exist_ok=True)
    versions={'python':sys.version.split()[0],'torch':torch.__version__,'torchvision':torchvision.__version__,'numpy':np.__version__,'faiss':getattr(faiss,'__version__','desconocida')}
    settings={'algoritmo':ALGORITHM,'sha256_galeria_csv':digest(prep/'galeria.csv'),'sha256_consultas_csv':digest(prep/'consultas.csv'),'sha256_config_preparacion':digest(prep/'configuracion.json'),'batch':batch,'threads':threads,'versiones':versions,'preprocesamiento':'EXIF RGB; letterbox 224x224 bilinear, relleno RGB 124 116 104; normalizacion media/std ImageNet; sin recorte central','dimensiones':2048,'pesos':'ResNet50_Weights.IMAGENET1K_V2','entrenamiento_tortugas':False,'indice':'FAISS IndexFlatIP exacto; embeddings L2; coseno','limites':config['limites']+' Evaluacion cerrada, todos los individuos consultados estan en galeria. No hay umbral de desconocidos calibrado. Los subconjuntos manuales no son muestras aleatorias de la poblacion.'}
    signature=hashlib.sha256(json.dumps(settings,sort_keys=True).encode()).hexdigest()
    configpath=dest/'configuracion.json'
    if configpath.exists() and load(configpath)['firma']!=signature:raise ValueError('Cambiaste parametros o versiones. Repite el comando original para reanudar; no se mezclaran resultados.')
    save(configpath,dict(settings,firma=signature))
    torch.set_num_threads(threads);torch.set_num_interop_threads(1);faiss.omp_set_num_threads(threads)
    torch.hub.set_dir(str(project/'modelos3_0/torch_cache'))
    weights=ResNet50_Weights.IMAGENET1K_V2
    print('Cargando pesos ImageNet; primera vez puede descargar unos 100 MB.',flush=True)
    model=resnet50(weights=weights,progress=True);model.fc=torch.nn.Identity();model=model.cpu().eval()
    checkpoint=Path(torch.hub.get_dir())/'checkpoints'/weights.url.rsplit('/',1)[1]
    weightsha=digest(checkpoint);weightsmeta=dest/'pesos.json'
    if weightsmeta.exists() and load(weightsmeta)['sha256']!=weightsha:raise ValueError('Los pesos cambiaron desde la extraccion anterior.')
    save(weightsmeta,{'ruta':str(checkpoint),'sha256':weightsha,'url':weights.url})
    transform=Compose([ToTensor(),Normalize(mean=[0.485,0.456,0.406],std=[0.229,0.224,0.225])])
    start=time.perf_counter();reg={'dest':dest,'base':base}
    G=embed(reg,g,'galeria',model,torch,transform,batch,signature);Q=embed(reg,q,'consultas',model,torch,transform,batch,signature)
    print('Calculando coincidencias exactas con FAISS...',flush=True)
    index,results,summary=evaluate(g,q,G,Q,faiss)
    # Serializacion en memoria evita problemas con rutas Unicode en FAISS/Windows.
    (dest/'galeria.faiss').write_bytes(faiss.serialize_index(index).tobytes())
    csvout(dest/'galeria_metadata.csv',g,list(g[0]));csvout(dest/'consultas_metadata.csv',q,list(q[0]));csvout(dest/'resultados_top5.csv',results,list(results[0]))
    save(dest/'metricas.json',summary)
    count=panels(results,base,dest,min(5,len(g)))
    txt='CIYFI - EVALUACION INICIAL\nResNet50 ImageNet sin entrenamiento para individuos de tortuga.\n\n'+json.dumps(summary,ensure_ascii=False,indent=2)+'\n\n'+settings['limites']+'\nSimilitudes de coseno; no son probabilidades de identidad.\n'
    (dest/'resumen.txt').write_text(txt,encoding='utf-8');print(txt)
    save(dest/'estado.json',{'estado':'COMPLETO','galeria':len(g),'consultas':len(q),'ejemplos':count,'segundos_esta_ejecucion':round(time.perf_counter()-start,1),'firma':signature})
    zp=dest/'EVALUACION_INICIAL_PARA_COMPARTIR.zip'
    with zipfile.ZipFile(zp,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(dest.iterdir()):
            if p.suffix in ['.json','.csv','.txt']:z.write(p,p.name)
        for p in sorted((dest/'ejemplos').glob('*.jpg')):z.write(p,'ejemplos/'+p.name)
    print('Embeddings e indice guardados en:',dest);print('ZIP PARA COMPARTIR:',zp,flush=True)

if __name__=='__main__':
    try:main(*sys.argv[1:])
    except Exception as e:print('ERROR:',e,flush=True);sys.exit(1)

'@ | & $python - $Proyecto $Preparacion $Batch $Threads
if ($LASTEXITCODE -ne 0) { throw 'La evaluacion no se completo. Comparte el error; el avance guardado se conserva.' }
