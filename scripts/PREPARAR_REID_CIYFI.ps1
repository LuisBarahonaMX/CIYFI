param(
 [string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0',
 [string]$Salida = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0\recortes3_0\ciyfi_20261004_001459_146400'
)
$ErrorActionPreference = 'Stop'
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No se encontro Python: $python" }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
@'
import csv, hashlib, json, random, sys, time, zipfile
from pathlib import Path
from datetime import datetime
from collections import defaultdict, Counter
from PIL import Image, ImageOps

FIELDS=['numero','individuo','original','recorte','revision_calidad','origen_recorte','ancho','alto','sha256_archivo','sha256_pixeles']
def digest(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()
def load(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def safe(base,rel):
    if not rel:raise ValueError('Ruta de archivo vacia')
    p=(base/rel).resolve()
    if not p.is_relative_to(base.resolve()):raise ValueError('Ruta fuera de la carpeta: '+rel)
    return p

def write_csv(p,rows,fields):
    with p.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(rows)
def split(pool,seed=30):
    groups=defaultdict(list)
    for r in pool:groups[r['individuo']].append(r)
    gallery=[];query=[];rng=random.Random(seed)
    for ident in sorted(groups):
        images=sorted(groups[ident],key=lambda x:int(x['numero']));rng.shuffle(images)
        gallery.append(images[0]);query.extend(images[1:])
    assert not ({r['original'] for r in gallery}&{r['original'] for r in query})
    assert not ({r['sha256_pixeles'] for r in gallery}&{r['sha256_pixeles'] for r in query})
    return gallery,query

def main(project,out):
    project=Path(project);out=Path(out)
    m=out/'manifest_recortes.csv';corrected=out/'correcciones_manual/manifest_corregido.csv'
    decpath=out/'revision_manual/decisiones.json';fixpath=out/'correcciones_manual/correcciones.json'
    dec=load(decpath);fix=load(fixpath);mh=digest(m)
    if dec['sha256_manifest']!=mh or fix['sha256_manifest']!=mh:raise ValueError('Los reportes no pertenecen al mismo manifiesto.')
    rows=list(csv.DictReader(corrected.open(encoding='utf-8-sig',newline='')))
    base=list(csv.DictReader(m.open(encoding='utf-8-sig',newline='')))
    if len(rows)!=len(base) or len({r['original'] for r in rows})!=len(base):raise ValueError('Manifiesto corregido incompleto o repetido.')
    originals={r['original']:r for r in base}; queue=[]
    for r in rows:
        if r['original'] not in originals or r['individuo']!=originals[r['original']]['individuo']:raise ValueError('Original o individuo inconsistente.')
        prior=dec['decisiones'].get(r['original'],{}).get('decision','PENDIENTE')
        v=fix['correcciones'].get(r['original']) if prior=='CORREGIR' else None
        if prior=='CORREGIR' and not v:raise ValueError('Quedan correcciones pendientes. Abre el corrector y exporta de nuevo.')
        expected=v['decision_final'] if v else prior
        if r['decision_final']!=expected or r['decision_manual']!=prior:raise ValueError('Reporte desactualizado. Exporta de nuevo desde el corrector.')
        if expected=='ACEPTAR':
            path=v['recorte_final'] if v else originals[r['original']]['recorte']
            if r['recorte_final']!=path:raise ValueError('Ruta corregida inconsistente.')
            queue.append((r,path,'ACEPTADO_MANUAL',v))
        elif expected=='PENDIENTE' and r['estado']=='CANDIDATO':queue.append((r,originals[r['original']]['recorte'],'CANDIDATO_SIN_REVISION',None))
        elif expected=='PENDIENTE':raise ValueError('Quedan incidencias sin clasificar.')
    dest=project/'reid3_0'/('preparacion_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));dest.mkdir(parents=True)
    print('Recortes a comprobar:',len(queue));print('Salida:',dest);print('No se modificaran imagenes.');start=time.perf_counter()
    pool=[];errors=[];dataset=Path(load(out/'configuracion.json')['dataset'])
    for i,(r,rel,quality,v) in enumerate(queue,1):
        try:
            p=safe(out,rel)
            with Image.open(p) as f:
                f.seek(0);im=ImageOps.exif_transpose(f).convert('RGB');im.load()
            if v:
                if im.size!=(v['ancho_recorte'],v['alto_recorte']):raise ValueError('Dimensiones del recorte manual cambiaron.')
                if digest(safe(dataset,r['original']))!=v['sha256_original']:raise ValueError('La foto original cambio desde la correccion.')
            hp=hashlib.sha256((str(im.size)+'|RGB|').encode()+im.tobytes()).hexdigest()
            pool.append({'numero':r['numero'],'individuo':r['individuo'],'original':r['original'],'recorte':rel,'revision_calidad':quality,'origen_recorte':r['origen_recorte'],'ancho':im.width,'alto':im.height,'sha256_archivo':digest(p),'sha256_pixeles':hp})
        except Exception as e:errors.append({'numero':r['numero'],'original':r['original'],'recorte':rel,'error':str(e)})
        if i%100==0 or i==len(queue):print(f'Comprobadas {i}/{len(queue)} | {time.perf_counter()-start:.1f} s',flush=True)
    write_csv(dest/'inventario_verificado.csv',pool,FIELDS);write_csv(dest/'errores.csv',errors,['numero','original','recorte','error'])
    byhash=defaultdict(list)
    for r in pool:byhash[r['sha256_pixeles']].append(r)
    duplicate_rows=[];clean=[];cross=0
    for h,group in byhash.items():
        group.sort(key=lambda r:(r['revision_calidad']!='ACEPTADO_MANUAL',int(r['numero'])))
        shared=len({r['individuo'] for r in group})>1
        if shared:cross+=1
        clean.append(group[0])
        if len(group)>1:
            for r in group:duplicate_rows.append(dict(r,tipo='ENTRE_INDIVIDUOS' if shared else 'MISMO_INDIVIDUO',conservar='SI' if r is group[0] and not shared else 'NO'))
    write_csv(dest/'duplicados_pixeles.csv',duplicate_rows,FIELDS+['tipo','conservar'])
    blocked=bool(errors or cross)
    config={'fecha':datetime.now().isoformat(),'carpeta_recortes':str(out.resolve()),'sha256_manifest':mh,'sha256_manifest_corregido':digest(corrected),'sha256_decisiones':digest(decpath),'sha256_correcciones':digest(fixpath),'semilla':30,'protocolo':'Una foto aleatoria de galeria por individuo; las restantes son consultas. Sin entrenamiento.','limites':'Separacion por fotografia, no por sesion o anio. No detecta duplicados visuales recomprimidos ni confirma identidad. Los candidatos sin revision se incluyen provisionalmente y se distinguen en el CSV.'}
    (dest/'configuracion.json').write_text(json.dumps(config,ensure_ascii=False,indent=2),encoding='utf-8')
    stats={'estado':'BLOQUEADO' if blocked else 'LISTO','propuestos':len(queue),'legibles':len(pool),'errores':len(errors),'grupos_duplicados_entre_individuos':cross,'duplicados_adicionales':len(pool)-len(clean),'excluidos_manualmente':sum(r['decision_final']=='EXCLUIR' for r in rows),'segundos':round(time.perf_counter()-start,1)}
    if not blocked:
        gallery,queries=split(clean)
        write_csv(dest/'galeria.csv',gallery,FIELDS);write_csv(dest/'consultas.csv',queries,FIELDS)
        write_csv(dest/'consultas_aceptadas_manualmente.csv',[r for r in queries if r['revision_calidad']=='ACEPTADO_MANUAL'],FIELDS)
        counts=Counter(r['individuo'] for r in clean)
        stats.update(recortes_utilizables=len(clean),individuos=len(counts),galeria=len(gallery),consultas=len(queries),individuos_evaluables=sum(n>=2 for n in counts.values()),individuos_solo_galeria=sum(n==1 for n in counts.values()),calidad=dict(Counter(r['revision_calidad'] for r in clean)))
    (dest/'resumen.json').write_text(json.dumps(stats,ensure_ascii=False,indent=2),encoding='utf-8')
    report=json.dumps(stats,ensure_ascii=False,indent=2)+'\n\n'+config['protocolo']+'\n'+config['limites']
    (dest/'resumen.txt').write_text(report,encoding='utf-8');print(report)
    zp=dest/'PREPARACION_REID_PARA_COMPARTIR.zip'
    with zipfile.ZipFile(zp,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(dest.iterdir()):
            if p.suffix in ['.csv','.json','.txt']:z.write(p,p.name)
    print('\nZIP PARA COMPARTIR:',zp)
    if blocked:raise ValueError('No se creo la galeria: revisa errores.csv o duplicados entre individuos y comparte el ZIP.')

if __name__=='__main__':
    try:main(sys.argv[1],sys.argv[2])
    except Exception as e:print('ERROR:',e);sys.exit(1)

'@ | & $python - $Proyecto $Salida
if ($LASTEXITCODE -ne 0) { throw 'La preparacion no pudo completarse. Comparte la salida y el ZIP si se genero.' }
