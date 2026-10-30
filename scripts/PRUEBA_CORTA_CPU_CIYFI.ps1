param(
 [string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0',
 [string]$Particiones = 'AUTO',
 [ValidateRange(5,100)][int]$Lotes = 20,
 [ValidateRange(1,8)][int]$Hilos = 4,
 [ValidateRange(2,8)][int]$P = 4,
 [ValidateRange(2,4)][int]$K = 2
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Proyecto -PathType Container)) { throw 'No existe la carpeta del proyecto.' }
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No se encontro Python: $python" }
if ([string]::IsNullOrWhiteSpace($Particiones)) { $Particiones = 'AUTO' }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$env:PYTHONUNBUFFERED = '1'
$env:PYTHONFAULTHANDLER = '1'
@'
import csv,hashlib,json,math,platform,random,statistics,sys,time,traceback,zipfile
from pathlib import Path
from datetime import datetime
from collections import defaultdict
from PIL import Image,ImageOps

def load(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()
def read(p):
    with p.open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
def require(c,msg):
    if not c:raise ValueError(msg)
def safe(base,rel):
    require(bool(rel),'Ruta de recorte vacia.')
    p=(base/rel).resolve();require(p.is_relative_to(base.resolve()),'Ruta fuera de carpeta.');return p

def pool_and_plan(rows,p,k,steps,seed=30):
    groups=defaultdict(list)
    for r in rows:
        require(r['particion']=='entrenamiento','El CSV contiene fotos fuera de entrenamiento.')
        groups[r['individuo']].append(r)
    require(len({r['original'] for r in rows})==len(rows),'Originales repetidos en entrenamiento.')
    eligible={i:sorted(rr,key=lambda r:r['original']) for i,rr in groups.items() if len(rr)>=k}
    require(len(eligible)>=p,'No hay individuos suficientes con K fotos distintas.')
    rng=random.Random(seed);ids=sorted(eligible);rng.shuffle(ids);position=0;plan=[]
    for _ in range(steps):
        if position+p>len(ids):rng.shuffle(ids);position=0
        batch=[]
        for identity in ids[position:position+p]:batch.extend(rng.sample(eligible[identity],k))
        position+=p;plan.append(batch)
    return eligible,plan

def letterbox(p):
    with Image.open(p) as f:
        f.seek(0);im=ImageOps.exif_transpose(f).convert('RGB');im.load()
    im=ImageOps.contain(im,(224,224),method=Image.Resampling.BILINEAR)
    canvas=Image.new('RGB',(224,224),(124,116,104));canvas.paste(im,((224-im.width)//2,(224-im.height)//2));return canvas

def hard_triplet_loss(emb,labels,criterion,torch):
    distances=torch.cdist(emb.detach(),emb.detach(),p=2)
    same=labels[:,None].eq(labels[None,:])
    same.fill_diagonal_(False)
    negatives=labels[:,None].ne(labels[None,:])
    require(bool(same.any(dim=1).all()) and bool(negatives.any(dim=1).all()),'Lote sin positivos o negativos.')
    positive_indices=distances.masked_fill(~same,float('-inf')).argmax(dim=1)
    negative_indices=distances.masked_fill(~negatives,float('inf')).argmin(dim=1)
    return criterion(emb,emb[positive_indices],emb[negative_indices])

def report_zip(dest):
    zp=dest.with_suffix('.zip')
    with zipfile.ZipFile(zp,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(dest.iterdir()):
            if p.is_file():z.write(p,p.name)
    print('ZIP PARA COMPARTIR:',zp,flush=True)

def measure(project,dest,partition,steps,threads,p,k):
    start=time.perf_counter()
    if partition=='AUTO':
        options=[]
        for q in (project/'reid3_0').glob('particiones_sesiones_*'):
            try:
                if q.is_dir() and load(q/'resumen.json')['estado']=='CSV_GENERADOS':options.append(q)
            except (OSError,ValueError,KeyError):pass
        require(bool(options),'No se encontraron particiones completas.')
        source=max(options,key=lambda q:q.name)
    else:source=Path(partition)
    cfg=load(source/'configuracion.json');trainpath=source/'entrenamiento.csv'
    require(sha(trainpath)==cfg['hashes_csv']['entrenamiento.csv'],'Cambio entrenamiento.csv desde la particion.')
    rows=read(trainpath);eligible,plan=pool_and_plan(rows,p,k,steps+2)
    crops=Path(cfg['carpeta_recortes']);labels_map={i:j for j,i in enumerate(sorted(eligible))}
    selection=[];unique={}
    for bi,batch in enumerate(plan,1):
        for r in batch:
            selection.append({'lote':bi,'calentamiento':'SI' if bi<=2 else 'NO','individuo':r['individuo'],'original':r['original'],'recorte':r['recorte'],'sha256_archivo':r['sha256_archivo']})
            unique[r['recorte']]=r
    with (dest/'muestra_entrenamiento.csv').open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(selection[0]));w.writeheader();w.writerows(selection)
    print('Comprobando',len(unique),'recortes distintos, solo de entrenamiento...',flush=True)
    for r in unique.values():require(sha(safe(crops,r['recorte']))==r['sha256_archivo'],'Recorte modificado: '+r['recorte'])
    print('Cargando PyTorch y ResNet50...',flush=True)
    import torch,torchvision
    from torchvision.models import resnet50,ResNet50_Weights
    from torchvision.transforms import Compose,ToTensor,Normalize
    torch.set_num_threads(threads);torch.set_num_interop_threads(1);torch.manual_seed(30)
    cache=project/'modelos3_0/torch_cache';torch.hub.set_dir(str(cache))
    weights=ResNet50_Weights.IMAGENET1K_V2
    checkpoint=cache/'checkpoints'/Path(weights.url).name
    if not checkpoint.is_file():print('No esta el peso en cache: se descargara desde Torchvision (aprox. 98 MB). La descarga no cuenta como entrenamiento.',flush=True)
    model=resnet50(weights=weights).cpu()
    model.fc=torch.nn.Linear(model.fc.in_features,256)
    model.train()
    optimizer=torch.optim.AdamW(model.parameters(),lr=1e-4,weight_decay=1e-4)
    criterion=torch.nn.TripletMarginLoss(margin=0.3,p=2,eps=1e-6)
    transform=Compose([ToTensor(),Normalize(mean=[0.485,0.456,0.406],std=[0.229,0.224,0.225])])
    config={'particiones':str(source),'sha256_entrenamiento_csv':sha(trainpath),'peso_inicial':'ResNet50_Weights.IMAGENET1K_V2','sha256_peso_inicial':sha(checkpoint),'modelo':'ResNet50 completa entrenable + Linear(2048,256) + normalizacion L2','perdida':'TripletMarginLoss margin=0.3 p=2, positivo mas lejano y negativo mas cercano dentro del lote','optimizador':'AdamW lr=0.0001 weight_decay=0.0001; clip_grad_norm=5','dispositivo':'cpu','hilos':threads,'P':p,'K':k,'batch':p*k,'lotes_calentamiento':2,'lotes_medidos':steps,'semilla':30,'individuos_aptos':len(eligible),'fotos_aptas':sum(len(rr) for rr in eligible.values()),'preprocesamiento':'EXIF RGB; letterbox224 bilinear, relleno124/116/104, media/std ImageNet. Sin aumentos.','versiones':{'python':sys.version.split()[0],'torch':torch.__version__,'torchvision':torchvision.__version__},'sistema':{'os':platform.platform(),'procesador':platform.processor()},'limites':'Prueba de velocidad, no de precision. No usa validacion/prueba, no crea embeddings/FAISS y no guarda pesos entrenados. Estimaciones excluyen evaluacion, checkpoints y preparacion; configuraciones distintas requieren otra medicion.'}
    (dest/'configuracion.json').write_text(json.dumps(config,ensure_ascii=False,indent=2),encoding='utf-8')
    setup=time.perf_counter()-start;timings=[]
    fields=['lote','calentamiento','carga_segundos','calculo_y_actualizacion_segundos','total_segundos','loss']
    with (dest/'tiempos_lotes.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader();f.flush()
        for bi,batch in enumerate(plan,1):
            t=time.perf_counter()
            x=torch.stack([transform(letterbox(safe(crops,r['recorte']))) for r in batch])
            lab=torch.tensor([labels_map[r['individuo']] for r in batch],dtype=torch.long)
            after_load=time.perf_counter()
            optimizer.zero_grad(set_to_none=True)
            raw=model(x)
            require(bool(torch.isfinite(raw).all()),'Salida del modelo no finita.')
            emb=torch.nn.functional.normalize(raw,p=2,dim=1)
            loss=hard_triplet_loss(emb,lab,criterion,torch)
            require(bool(torch.isfinite(loss)),'Perdida no finita.')
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(),5.0,error_if_nonfinite=True)
            optimizer.step()
            done=time.perf_counter()
            record={'lote':bi,'calentamiento':'SI' if bi<=2 else 'NO','carga_segundos':after_load-t,'calculo_y_actualizacion_segundos':done-after_load,'total_segundos':done-t,'loss':loss.item()}
            writer.writerow(record);f.flush()
            if bi>2:timings.append(record)
            progress={'estado':'EN_PROCESO','lotes_totales_completados':bi,'lotes_medidos_completados':len(timings),'modelo_guardado':False}
            tmp=dest/'avance.tmp';tmp.write_text(json.dumps(progress,indent=2),encoding='utf-8');tmp.replace(dest/'estado.json')
            tag=f'Calentamiento {bi}/2' if bi<=2 else f'Lote medido {bi-2}/{steps}'
            print(f'{tag} | {record["total_segundos"]:.2f} s | loss {record["loss"]:.4f}',flush=True)
    totals=[r['total_segundos'] for r in timings];avg=statistics.mean(totals)
    # Ciclo balanceado: cada identidad aporta K fotos, no todas sus fotografias.
    cycle=math.ceil(len(eligible)/p)
    volume=math.ceil(config['fotos_aptas']/(p*k))
    summary={'estado':'COMPLETO','lotes_medidos':len(timings),'batch':p*k,'segundos_preparacion_y_carga_modelo':round(setup,2),'segundos_prueba_total':round(time.perf_counter()-start,2),'segundos_promedio_lote':round(avg,3),'segundos_mediana_lote':round(statistics.median(totals),3),'segundos_minimo_lote':round(min(totals),3),'segundos_maximo_lote':round(max(totals),3),'segundos_promedio_carga':round(statistics.mean(r['carga_segundos'] for r in timings),3),'individuos_aptos':len(eligible),'fotos_aptas':config['fotos_aptas'],'lotes_por_ciclo_balanceado':cycle,'minutos_estimados_ciclo_balanceado':round(cycle*avg/60,2),'horas_estimadas_20_ciclos_solo_entrenamiento':round(20*cycle*avg/3600,2),'lotes_equivalentes_volumen_fotos':volume,'minutos_equivalentes_volumen_fotos':round(volume*avg/60,2),'nota_estimacion':'Ciclo: cada identidad contribuye K fotos; no recorre todas las fotos. Volumen equivalente: extrapolacion por cantidad, no garantiza cobertura con muestreo PK. No incluye validacion, lectura de galeria ni guardado.','modelo_guardado':False,'metricas_identificacion_calculadas':False}
    (dest/'resumen.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    (dest/'estado.json').write_text(json.dumps({'estado':'COMPLETO','lotes_medidos':len(timings),'modelo_guardado':False},indent=2),encoding='utf-8')
    text='PRUEBA CPU CIYFI - TIEMPOS, NO PRECISION\n\n'+json.dumps(summary,ensure_ascii=False,indent=2)+'\n\n'+config['limites']+'\n'
    (dest/'resumen.txt').write_text(text,encoding='utf-8');print('\n'+text,flush=True)

def run(project,partition='AUTO',steps=20,threads=4,p=4,k=2):
    require(5<=steps<=100 and 1<=threads<=8 and 2<=p<=8 and 2<=k<=4,'Parametros fuera de rango.')
    dest=project/'reportes3_0'/('prueba_cpu_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));dest.mkdir(parents=True,exist_ok=False)
    try:measure(project,dest,partition,steps,threads,p,k)
    except (Exception,KeyboardInterrupt) as error:
        detail=traceback.format_exc();(dest/'error.txt').write_text(detail,encoding='utf-8')
        (dest/'estado.json').write_text(json.dumps({'estado':'INTERRUMPIDO' if isinstance(error,KeyboardInterrupt) else 'ERROR','error':str(error),'modelo_guardado':False},indent=2),encoding='utf-8')
        print(detail,flush=True);report_zip(dest);raise
    report_zip(dest)

if __name__=='__main__':run(Path(sys.argv[1]),sys.argv[2],int(sys.argv[3]),int(sys.argv[4]),int(sys.argv[5]),int(sys.argv[6]))

'@ | & $python - $Proyecto $Particiones $Lotes $Hilos $P $K
if ($LASTEXITCODE -ne 0) { throw 'La prueba CPU no se completo. Comparte el ZIP de error o el mensaje mostrado arriba.' }
