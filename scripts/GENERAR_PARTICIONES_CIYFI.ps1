param(
 [string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0',
 [string]$Agrupacion = 'AUTO',
 [string]$Revision = 'AUTO'
)
$ErrorActionPreference = 'Stop'
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No se encontro Python: $python" }
if ([string]::IsNullOrWhiteSpace($Agrupacion)) { $Agrupacion = 'AUTO' }
if ([string]::IsNullOrWhiteSpace($Revision)) { $Revision = 'AUTO' }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
@'
import csv, hashlib, json, sys, zipfile
from pathlib import Path
from datetime import datetime
from collections import defaultdict, Counter

def load(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):
    with p.open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
def write(p,rows,fields):
    with p.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(rows)
def require(condition,message):
    if not condition:raise ValueError(message)

def verify_review(review,sessions,signature):
    expected={s['sesion'] for s in sessions if s['varias_camaras']=='SI'}
    require(review.get('firma')==signature,'La revision corresponde a otra agrupacion.')
    ds=review.get('decisiones',[])
    require(len(ds)==len(expected) and len({d['sesion'] for d in ds})==len(ds) and {d['sesion'] for d in ds}==expected,'La revision esta incompleta o repetida.')
    require(all(d.get('decision')=='MANTENER' for d in ds),'Hay sesiones pendientes, dudosas o por separar. Comparte la revision antes de particionar.')

def split(sessions,photos):
    by_id=defaultdict(list)
    for s in sessions:by_id[s['individuo']].append(s)
    assignments={};eligible=set()
    for identity,ss in sorted(by_id.items()):
        ss.sort(key=lambda s:(datetime.fromisoformat(s['inicio_exif']),s['sesion']))
        for a,b in zip(ss,ss[1:]):
            require(datetime.fromisoformat(a['fin_exif'])<datetime.fromisoformat(b['inicio_exif']),'Sesiones temporalmente superpuestas: '+identity)
        if len(ss)>=3:eligible.add(identity)
        for i,s in enumerate(ss):
            partition='entrenamiento'
            if identity in eligible and i==len(ss)-2:partition='validacion'
            if identity in eligible and i==len(ss)-1:partition='prueba'
            assignments[s['sesion']]=partition
    labels={identity:i for i,identity in enumerate(sorted(by_id))}
    output={p:[] for p in ('entrenamiento','validacion','prueba')}
    for r in photos:
        require(r['sesion'] in assignments,'Sesion no reconocida: '+r['sesion'])
        part=assignments[r['sesion']]
        output[part].append(dict(r,particion=part,clase_idx=labels[r['individuo']],individuo_evaluable='SI' if r['individuo'] in eligible else 'NO'))
    return output,assignments,eligible,labels

def run(project, grouping='AUTO', revision='AUTO'):
    if grouping=='AUTO':
        options=[p for p in (project/'reid3_0').glob('agrupacion_sesiones_*') if p.is_dir() and (p/'sesiones.csv').is_file()]
        require(bool(options),'No se encontro agrupacion de sesiones en reid3_0.')
        source=max(options,key=lambda p:p.name)
    else:source=Path(grouping)
    cfg=load(source/'configuracion.json');prep=Path(cfg['preparacion']);inventory=prep/'inventario_verificado.csv'
    require(sha(inventory)==cfg['inventario_sha256'],'El inventario cambio desde la agrupacion.')
    pcfg=load(prep/'configuracion.json');crops=Path(pcfg['carpeta_recortes'])
    sessions=read(source/'sesiones.csv');photos=read(source/'fotos_con_sesion.csv');pending=read(source/'pendientes_sin_fecha.csv');inv=read(inventory)
    signature=hashlib.sha256((sha(source/'sesiones.csv')+sha(source/'fotos_con_sesion.csv')).encode()).hexdigest()
    if revision=='AUTO':
        paths=set(project.glob('REVISION_24_SESIONES*.json'))|set((Path.home()/'Downloads').glob('REVISION_24_SESIONES*.json'))
        matches=[]
        for p in paths:
            try:
                if load(p).get('firma')==signature:matches.append(p)
            except (ValueError,OSError):pass
        require(bool(matches),'Guarda REVISION_24_SESIONES.json en la carpeta del proyecto o indica -Revision con su ruta.')
        revpath=max(matches,key=lambda p:p.stat().st_mtime_ns)
    else:revpath=Path(revision)
    rev=load(revpath);verify_review(rev,sessions,signature)
    invmap={r['original']:r for r in inv};allrows=photos+pending
    require(len(invmap)==len(inv)==len(allrows)==len({r['original'] for r in allrows}),'Inventario o agrupacion incompleta/repetida.')
    require({r['original'] for r in allrows}==set(invmap),'La agrupacion no contiene los originales del inventario.')
    for r in allrows:
        original=invmap[r['original']]
        require(all(r.get(k,'')==original.get(k,'') for k in ('numero','individuo','recorte','revision_calidad')),'Registro distinto del inventario: '+r['original'])
        for k in ('origen_recorte','ancho','alto','sha256_archivo','sha256_pixeles'):r[k]=original[k]
        require(bool(r['sha256_archivo']) and bool(r['sha256_pixeles']),'Falta hash verificado.')
        crop=(crops/r['recorte']).resolve()
        require(crop.is_relative_to(crops.resolve()) and crop.is_file(),'No se encontro recorte dentro de su carpeta: '+r['recorte'])
    require(len({s['sesion'] for s in sessions})==len(sessions),'Sesiones repetidas.')
    count=Counter(r['sesion'] for r in photos)
    require(set(count)=={s['sesion'] for s in sessions} and all(count[s['sesion']]==int(s['fotos']) for s in sessions),'Conteo de sesiones inconsistente.')
    session_map={s['sesion']:s for s in sessions}
    for r in photos:
        ss=session_map[r['sesion']]
        require(r['individuo']==ss['individuo'],'Individuo de sesion inconsistente.')
        require(ss['inicio_exif']<=r['fecha_captura_propuesta']<=ss['fin_exif'],'Foto fuera del intervalo de sesion.')
        require(bool(r['fecha_captura_propuesta']),'Foto sin fecha dentro de sesiones.')
        datetime.fromisoformat(r['fecha_captura_propuesta'])
    require(all(not r.get('sesion') and not r.get('fecha_captura_propuesta') for r in pending),'Pendientes contienen sesiones o fechas asignadas.')
    output,assignments,eligible,labels=split(sessions,photos)
    require(bool(eligible),'No hay individuos con tres sesiones para evaluar.')
    train_ids={r['individuo'] for r in output['entrenamiento']}
    require({r['individuo'] for r in output['validacion']}==eligible=={r['individuo'] for r in output['prueba']},'Individuos evaluables inconsistentes.')
    require(eligible<=train_ids,'Hay consultas sin individuo entrenado.')
    checks={}
    for key in ('original','recorte','sesion','sha256_archivo','sha256_pixeles'):
        seen={}
        for part,rows in output.items():
            for r in rows:
                require(r[key] not in seen or seen[r[key]]==part,'Repeticion entre particiones: '+key+' '+r[key])
                seen[r[key]]=part
        checks['sin_repeticiones_entre_particiones_'+key]=True
    require(sum(len(v) for v in output.values())+len(pending)==len(inv),'Faltan fotos en las salidas.')
    dest=project/'reid3_0'/('particiones_sesiones_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));dest.mkdir(parents=True,exist_ok=False)
    fields=['numero','individuo','clase_idx','particion','individuo_evaluable','sesion','original','recorte','revision_calidad','origen_recorte','fecha_captura_propuesta','dia_operativo','camara','ancho','alto','sha256_archivo','sha256_pixeles']
    for part,rows in output.items():write(dest/(part+'.csv'),rows,fields)
    for r in pending:r.update(particion='PENDIENTE',clase_idx='',individuo_evaluable='')
    write(dest/'pendientes_sin_fecha.csv',pending,fields+['motivo_pendiente'])
    write(dest/'asignacion_sesiones.csv',[dict(s,particion=assignments[s['sesion']]) for s in sessions],list(sessions[0])+['particion'])
    train_counts=Counter(r['individuo'] for r in output['entrenamiento'])
    classes=[{'individuo':i,'clase_idx':label,'individuo_evaluable':'SI' if i in eligible else 'NO','fotos_entrenamiento':train_counts[i],'apto_positivo_triplet':'SI' if train_counts[i]>=2 else 'NO'} for i,label in labels.items()]
    write(dest/'clases.csv',classes,['individuo','clase_idx','individuo_evaluable','fotos_entrenamiento','apto_positivo_triplet'])
    stats={'estado':'CSV_GENERADOS','fotos_total':len(inv),'fotos_pendientes_fecha':len(pending),'individuos_evaluables':len(eligible),'individuos_entrenamiento':len(train_ids),'individuos_train_con_una_foto':sum(n==1 for n in train_counts.values())}
    for part,rows in output.items():stats[part]={'fotos':len(rows),'sesiones':len({r['sesion'] for r in rows}),'individuos':len({r['individuo'] for r in rows}),'calidad':dict(Counter(r['revision_calidad'] for r in rows))}
    stats['verificaciones']=checks
    (dest/'resumen.json').write_text(json.dumps(stats,ensure_ascii=False,indent=2),encoding='utf-8')
    configuration={'agrupacion':str(source),'preparacion':str(prep),'carpeta_recortes':str(crops),'dataset':cfg['dataset'],'revision_sha256':sha(revpath),'firma_revision':signature,'inventario_sha256':sha(inventory),
        'protocolo':'Individuos conocidos, sesiones cronologicas. Para >=3 sesiones: penultima validacion, ultima prueba, restantes entrenamiento. Para 1 o 2 sesiones: solo entrenamiento. Sin fecha: pendiente.',
        'galeria_futura':'Referencias solo de entrenamiento; nunca tomar fotos de validacion/prueba. No se genero galeria en este paso.',
        'limites':'No detecta similitud visual/recompresiones. Sesiones inferidas y 24 mixtas revisadas por el usuario. Parte de recortes sin revision manual. Evaluacion de individuos conocidos, no individuos nuevos. Una foto de train por individuo no permite positivos distintos en Triplet Loss.',
        'fotos_modificadas':False,'revalidacion_bytes_recortes':False,'hashes_csv':{p.name:sha(p) for p in dest.glob('*.csv')}}
    (dest/'configuracion.json').write_text(json.dumps(configuration,ensure_ascii=False,indent=2),encoding='utf-8')
    (dest/'revision_24_sesiones.json').write_text(json.dumps(rev,ensure_ascii=False,indent=2),encoding='utf-8')
    text='PARTICIONES CIYFI POR SESIONES\n\n'+json.dumps(stats,ensure_ascii=False,indent=2)+'\n\n'+configuration['protocolo']+'\n\n'+configuration['limites']+'\n\nNo se movieron, copiaron ni modificaron imagenes. CSV con rutas relativas a carpeta_recortes. No se entreno ningun modelo.\n'
    (dest/'resumen.txt').write_text(text,encoding='utf-8')
    zp=dest.with_suffix('.zip')
    with zipfile.ZipFile(zp,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(dest.iterdir()):z.write(p,p.name)
    print(text);print('ZIP PARA COMPARTIR:',zp)

if __name__=='__main__':run(Path(sys.argv[1]),sys.argv[2],sys.argv[3])

'@ | & $python - $Proyecto $Agrupacion $Revision
if ($LASTEXITCODE -ne 0) { throw 'No se generaron las particiones completas. Comparte el error mostrado arriba.' }
