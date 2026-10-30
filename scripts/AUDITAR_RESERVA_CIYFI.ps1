param([string]$Proyecto = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Proyecto)) { $Proyecto = $PSScriptRoot }
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'No se encontro Python del proyecto. Guarda este script en zproyecto3_0.' }
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$codigo = @'
import csv,hashlib,json,sys,zipfile
from pathlib import Path
from datetime import datetime
from collections import Counter

def read_csv(p):
    with p.open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
def write_csv(p,rows,fields):
    with p.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)
def safe(base,rel):
    p=(base/rel.replace('\\','/')).resolve()
    if not p.is_relative_to(base.resolve()):raise ValueError('Ruta fuera del dataset: '+rel)
    return p

def audit(project):
    dataset=project/'tortugascm (1033 ind con muchas fotos)'
    partitions=project/'reid3_0/particiones_sesiones_20261005_180057_713242'
    expected={'entrenamiento.csv':'2a23c765c1f8a23a50d7e5e27197187fefbbd62e7777dd6d6781fc0965735d85','validacion.csv':'71c7a4594641fa006c8e735d7f056cbd3ceeddc63f4916d68bcb5d213cf7225b','prueba.csv':'2a3f8eede17819d17db02c9d6f262bad2670afb06b7b40c732aa7df2c1829e18'}
    if not dataset.is_dir():raise ValueError('No existe el dataset original: '+str(dataset))
    assigned={};counts={};missing=[];known_hashes={}
    for name,digest in expected.items():
        p=partitions/name
        if sha(p)!=digest:raise ValueError('El CSV cambio: '+name+'. No se modificara ni se continuara con otro protocolo.')
        rows=read_csv(p);counts[name]=len(rows)
        for r in rows:
            rel=r['original'].replace('\\','/');assigned[rel.casefold()]=name
            original=safe(dataset,rel)
            if not original.is_file():missing.append({'original':rel,'particion':name,'problema':'Original no encontrado'})
    pending=read_csv(partitions/'pendientes_sin_fecha.csv');pending_paths={r['original'].replace('\\','/').casefold() for r in pending}
    folder=project/'reportes3_0'/('auditoria_reserva_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));folder.mkdir(parents=True)
    extensions={'.jpg','.jpeg','.png','.bmp','.tif','.tiff','.webp','.mpo'}
    files=sorted((p for d in dataset.iterdir() if d.is_dir() and d.name.casefold().startswith('individuo ') for p in d.rglob('*') if p.is_file() and p.suffix.lower() in extensions),key=lambda p:str(p).casefold())
    inventory=[];errors=[]
    print(f'Fotos encontradas: {len(files)}. Calculando hashes para detectar copias renombradas.',flush=True)
    for i,p in enumerate(files,1):
        rel=p.relative_to(dataset).as_posix();part=assigned.get(rel.casefold(),'')
        try:digest=sha(p)
        except OSError as e:errors.append({'original':rel,'error':str(e)});digest=''
        row={'original':rel,'individuo':Path(rel).parts[0],'particion_actual':part,'sha256_original':digest};inventory.append(row)
        if part and digest:known_hashes.setdefault(digest,[]).append(rel)
        if i%250==0:print(f'Comprobadas {i}/{len(files)}',flush=True)
    candidates=[]
    for row in inventory:
        if row['particion_actual']:continue
        rel=row['original'];digest=row['sha256_original'];date='';camera='';width='';height='';status='';reason='';similar=''
        if not digest:status='ERROR_LECTURA';reason='No fue posible calcular hash.'
        elif digest in known_hashes:status='COPIA_EXACTA_DE_FOTO_USADA';similar=' | '.join(known_hashes[digest]);reason='No sirve como foto independiente aunque tenga otro nombre.'
        elif rel.casefold() in pending_paths:status='PENDIENTE_FECHA_Y_ANTECEDENTES';reason='Ya pertenecia al inventario valido; revisar tambien su uso en evaluaciones exploratorias anteriores.'
        else:status='FUERA_DE_PARTICIONES_REVISAR';reason='Puede haber sido excluida por calidad. No se considera reservada sin revisar antecedentes, identidad y sesion.'
        try:
            from PIL import Image
            with Image.open(safe(dataset,rel)) as im:
                im.seek(0);width,height=im.size
                exif=im.getexif()
                try:sub=exif.get_ifd(34665)
                except Exception:sub={}
                date=str(sub.get(36867) or exif.get(36867) or '')
                camera=str(exif.get(271,'')).strip()+' '+str(exif.get(272,'')).strip()
                im.load()
        except Exception as e:
            status='ERROR_LECTURA';reason=str(e)
        candidates.append(dict(row,estado=status,fecha_exif_sin_validar=date,camara=camera.strip(),ancho=width,alto=height,copia_de=similar,motivo=reason))
    write_csv(folder/'fotos_fuera_particiones.csv',candidates,['original','individuo','particion_actual','sha256_original','estado','fecha_exif_sin_validar','camara','ancho','alto','copia_de','motivo'])
    write_csv(folder/'pendientes_sin_fecha.csv',pending,list(pending[0]) if pending else ['original'])
    write_csv(folder/'originales_faltantes.csv',missing,['original','particion','problema'])
    write_csv(folder/'errores_hash.csv',errors,['original','error'])
    summary={'dataset':str(dataset),'particiones':str(partitions),'fotos_en_disco':len(files),'reparto_actual':counts,'pendientes_fecha':len(pending),'fuera_particiones':len(candidates),'estados':dict(Counter(r['estado'] for r in candidates)),'originales_faltantes':len(missing),'errores_hash':len(errors),'fotos_reservadas_automaticamente':0,'dataset_modificado':False}
    (folder/'resumen.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    text='AUDITORIA DE POSIBLE RESERVA CIYFI\n'+json.dumps(summary,ensure_ascii=False,indent=2)+'\n\nEsta auditoria NO crea una prueba independiente.\nLas fotos fuera de CSV pueden ser descartes, copias o fotos ya vistas.\nAntes de reservar: validar cabeza/identidad, fecha y sesion completa, antecedentes de uso, y semejanza con fotos usadas.\nLos hashes detectan solo copias exactas; no fotos parecidas o recomprimidas.\nNo reutilizar train/validacion/prueba anterior como si fueran fotos nuevas.\nLas 130 fotos sin fecha requieren evidencia de fecha y sesion; no asignarlas usando fecha de copia de Windows.\nSe conservaron todas las particiones y originales.\n'
    (folder/'resumen.txt').write_text(text,encoding='utf-8-sig')
    archive=folder.with_suffix('.zip')
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
        for p in folder.iterdir():z.write(p,p.name)
    print(text,flush=True);print('ZIP PARA COMPARTIR: '+str(archive),flush=True)
if __name__=='__main__':audit(Path(sys.argv[1]).resolve())

'@
$codigo | & $python - $Proyecto
if ($LASTEXITCODE -ne 0) { throw 'La auditoria no se completo. Comparte el error de la terminal.' }
