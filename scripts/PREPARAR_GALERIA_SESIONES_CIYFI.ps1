param(
 [string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0',
 [string]$Particiones = 'AUTO'
)
$ErrorActionPreference = 'Stop'
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No se encontro Python: $python" }
if ([string]::IsNullOrWhiteSpace($Particiones)) { $Particiones = 'AUTO' }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
@'
import csv,hashlib,json,sys,time,zipfile
from pathlib import Path
from datetime import datetime
from collections import defaultdict,Counter

def load(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()
def read(p):
    with p.open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
def write(p,rows,fields):
    with p.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(rows)
def require(c,msg):
    if not c:raise ValueError(msg)
def choose(rows):
    groups=defaultdict(list)
    for r in rows:groups[r['individuo']].append(r)
    # La seleccion no consulta validacion/prueba ni utiliza sus resultados.
    return [dict(min(rs,key=lambda r:(r['revision_calidad']!='ACEPTADO_MANUAL',r['sha256_archivo'],r['original'])),rol='REFERENCIA_DE_ENTRENAMIENTO') for _,rs in sorted(groups.items())]

def run(project,partition='AUTO'):
    start=time.perf_counter()
    if partition=='AUTO':
        candidates=[]
        for p in (project/'reid3_0').glob('particiones_sesiones_*'):
            try:
                if p.is_dir() and load(p/'resumen.json')['estado']=='CSV_GENERADOS':candidates.append(p)
            except (ValueError,OSError,KeyError):pass
        require(bool(candidates),'No se encontraron particiones validas en reid3_0.')
        source=max(candidates,key=lambda p:p.name)
    else:source=Path(partition)
    config=load(source/'configuracion.json');crops=Path(config['carpeta_recortes'])
    # Verificar los CSV congelados. No se leen imagenes de validacion/prueba.
    for name,expected in config['hashes_csv'].items():require(sha(source/name)==expected,'Cambio el CSV '+name+'. No se creo galeria.')
    train=read(source/'entrenamiento.csv');val=read(source/'validacion.csv');test=read(source/'prueba.csv')
    require(bool(train) and all(r['particion']=='entrenamiento' for r in train),'Entrenamiento vacio o inconsistente.')
    require(len({r['original'] for r in train})==len(train),'Entrenamiento con originales repetidos.')
    selected=choose(train)
    for key in ('original','recorte','sesion','sha256_archivo','sha256_pixeles'):
        references={r[key] for r in selected}
        require(not references & {r[key] for r in val+test},'Referencia compartida con validacion/prueba: '+key)
    require(len({r['individuo'] for r in selected})==len(selected),'Referencias repetidas por individuo.')
    for key in ('original','recorte','sha256_archivo','sha256_pixeles'):
        require(len({r[key] for r in selected})==len(selected),'Referencia duplicada: '+key)
    ids={r['individuo'] for r in selected};require({r['individuo'] for r in val+test}<=ids,'Consulta sin individuo en galeria.')
    print('Particiones:',source,flush=True)
    print('Comprobando',len(selected),'recortes de entrenamiento seleccionados...',flush=True)
    for i,r in enumerate(selected,1):
        require(bool(r['recorte']),'Ruta de recorte vacia.')
        p=(crops/r['recorte']).resolve()
        require(p.is_relative_to(crops.resolve()) and p.is_file(),'Recorte inexistente o fuera de carpeta: '+r['recorte'])
        require(sha(p)==r['sha256_archivo'],'El recorte cambio desde la auditoria: '+r['recorte'])
        if i%100==0 or i==len(selected):print(f'Comprobados {i}/{len(selected)} | {time.perf_counter()-start:.1f} s',flush=True)
    dest=project/'reid3_0'/('galeria_sesiones_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));dest.mkdir(parents=True,exist_ok=False)
    fields=list(train[0])+['rol']
    write(dest/'galeria.csv',selected,fields)
    evaluable=[r for r in selected if r['individuo_evaluable']=='SI']
    write(dest/'galeria_individuos_evaluables.csv',evaluable,fields)
    write(dest/'referencias_sin_revision_manual.csv',[r for r in selected if r['revision_calidad']!='ACEPTADO_MANUAL'],fields)
    stats={'estado':'REFERENCIAS_PREPARADAS','referencias_galeria':len(selected),'individuos':len(ids),'referencias_individuos_evaluables':len(evaluable),'calidad':dict(Counter(r['revision_calidad'] for r in selected)),'consultas_validacion':len(val),'consultas_prueba_reservadas':len(test),'segundos':round(time.perf_counter()-start,1),'embeddings_generados':False,'modelo_entrenado':False,'sha256_recortes_revalidado':True}
    (dest/'resumen.json').write_text(json.dumps(stats,ensure_ascii=False,indent=2),encoding='utf-8')
    cfg={'particiones':str(source),'carpeta_recortes':str(crops),'dataset':config['dataset'],'seleccion':'Una referencia por individuo. Primero ACEPTADO_MANUAL; desempate determinista por SHA256 y original. No se optimizo con validacion/prueba.',
         'galeria_principal':'galeria.csv incluye todos los individuos de entrenamiento como candidatos, incluidos distractores. galeria_individuos_evaluables.csv es solo una lista auxiliar; no sustituir la galeria principal sin declarar el cambio de protocolo.',
         'relacion_con_entrenamiento':'Las referencias son fotos de entrenamiento reutilizadas como galeria para evaluar individuos conocidos. No son consultas independientes.',
         'limites':'Parte de referencias aun sin revision manual. Sin embeddings ni indice FAISS en este paso. Una referencia por individuo es una base inicial. Debe medirse una nueva linea base por sesiones; los porcentajes de la evaluacion previa no son directamente comparables.',
         'hashes_csv':{p.name:sha(p) for p in dest.glob('*.csv')},'hash_entrenamiento':sha(source/'entrenamiento.csv'),'hash_validacion':sha(source/'validacion.csv'),'hash_prueba':sha(source/'prueba.csv')}
    (dest/'configuracion.json').write_text(json.dumps(cfg,ensure_ascii=False,indent=2),encoding='utf-8')
    text='GALERIA CIYFI POR SESIONES\n\n'+json.dumps(stats,ensure_ascii=False,indent=2)+'\n\n'+cfg['seleccion']+'\n\n'+cfg['limites']+'\n\nNo se copiaron, movieron ni modificaron imagenes. CSV con rutas relativas a carpeta_recortes.\n'
    (dest/'resumen.txt').write_text(text,encoding='utf-8')
    zp=dest.with_suffix('.zip')
    with zipfile.ZipFile(zp,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(dest.iterdir()):z.write(p,p.name)
    print(text,flush=True);print('ZIP PARA COMPARTIR:',zp,flush=True)

if __name__=='__main__':run(Path(sys.argv[1]),sys.argv[2])

'@ | & $python - $Proyecto $Particiones
if ($LASTEXITCODE -ne 0) { throw 'No se completo la preparacion de galeria. Comparte el error mostrado arriba.' }
