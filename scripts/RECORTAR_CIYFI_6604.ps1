param(
    [string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0',
    [string]$Reanudar = ''
)
$ErrorActionPreference = 'Stop'
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No existe el Python del proyecto: $python" }
$env:PYTHONIOENCODING = 'utf-8'
@'
import csv, hashlib, json, math, random, re, sys, time, zipfile
from collections import Counter
from datetime import datetime
from pathlib import Path
from PIL import Image, ImageDraw, ImageOps
from ultralytics import YOLO

EXT = {'.jpg','.jpeg','.png','.bmp','.tif','.tiff','.webp','.mpo'}
DETECTAR, REVISAR, MARGEN = 0.25, 0.60, 0.05


def leer(p):
    with Image.open(p) as f:
        f.seek(0)  # Imagen principal de MPO; no exige leer cuadros secundarios.
        im = ImageOps.exif_transpose(f).convert('RGB')
        im.load()
        return im


def limites(b, w, h):
    x1,y1,x2,y2 = map(float,b)
    dx,dy = (x2-x1)*MARGEN,(y2-y1)*MARGEN
    c = (max(0,math.floor(x1-dx)), max(0,math.floor(y1-dy)),
         min(w,math.ceil(x2+dx)), min(h,math.ceil(y2+dy)))
    if c[2] <= c[0] or c[3] <= c[1]: raise ValueError('Caja sin area valida')
    return c


def panel(im, row, out):
    marked = im.copy()
    d = ImageDraw.Draw(marked)
    for j,b in enumerate(row['cajas']):
        color = 'lime' if j == 0 else 'orange'
        d.rectangle(b['xyxy'],outline=color,width=max(2,im.width//350))
    canvas = Image.new('RGB',(960,460),'#252525')
    left = ImageOps.contain(marked,(470,410))
    canvas.paste(left,((480-left.width)//2,40+(410-left.height)//2))
    if row['cajas']:
        crop = im.crop(limites(row['cajas'][0]['xyxy'],*im.size))
        right = ImageOps.contain(crop,(470,410))
        canvas.paste(right,(480+(480-right.width)//2,40+(410-right.height)//2))
    draw = ImageDraw.Draw(canvas)
    draw.text((8,8),f"{row['numero']:05d} | {row['individuo']} | {row['estado']}",fill='white')
    draw.text((488,8),'CANDIDATO; pendiente de revision',fill='white')
    if not row['cajas']: draw.text((505,200),'SIN RECORTE',fill='white')
    out.parent.mkdir(parents=True,exist_ok=True)
    canvas.save(out,quality=85)


def csv_guardar(p, rows):
    fields=['numero','individuo','original','estado','motivos','numero_cajas','confianza',
            'recorte','panel','ancho','alto','ancho_recorte','alto_recorte','revision','error']
    with p.open('w',encoding='utf-8-sig',newline='') as f:
        wr=csv.DictWriter(f,fieldnames=fields); wr.writeheader()
        for row in rows:
            r={k:row.get(k,'') for k in fields}
            r['motivos']=';'.join(row.get('motivos',[])); wr.writerow(r)


def main():
    proyecto=Path(sys.argv[1]).resolve()
    dataset=proyecto/'tortugascm (1033 ind con muchas fotos)'
    pesos=proyecto/'runs3_0/ciyfi_refuerzo_20261003_231304_294942/entrenamiento/weights/best.pt'
    if not dataset.is_dir(): raise FileNotFoundError(dataset)
    if not pesos.is_file(): raise FileNotFoundError(pesos)
    fotos=sorted((p for c in dataset.iterdir() if c.is_dir() and re.fullmatch(r'individuo\s*\d+',c.name,re.I)
                  for p in c.iterdir() if p.is_file() and p.suffix.lower() in EXT),key=lambda p:str(p).lower())
    if not fotos: raise ValueError('No se encontraron imagenes en carpetas individuo N.')
    fingerprint=[{'ruta':p.relative_to(dataset).as_posix(),'bytes':p.stat().st_size,
                  'mtime_ns':p.stat().st_mtime_ns} for p in fotos]
    config={'dataset':str(dataset),'modelo':str(pesos),
            'sha256_modelo':hashlib.sha256(pesos.read_bytes()).hexdigest(),
            'umbral_deteccion':DETECTAR,'umbral_revision':REVISAR,'margen_por_lado':MARGEN,
            'imgsz':640,'iou':0.7,'device':'cpu','imagenes':len(fotos),'inventario':fingerprint}
    resume=sys.argv[2] if len(sys.argv)>2 else ''
    if resume:
        salida=Path(resume).resolve()
        if json.loads((salida/'configuracion.json').read_text(encoding='utf-8')) != config:
            raise ValueError('Modelo, configuracion o archivos cambiaron. Inicia una nueva ejecucion.')
    else:
        salida=proyecto/'recortes3_0'/('ciyfi_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
        salida.mkdir(parents=True,exist_ok=False)
        (salida/'configuracion.json').write_text(json.dumps(config,ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'Imagenes: {len(fotos)} (esperadas en auditoria: 6604)',flush=True)
    if len(fotos)!=6604: print('AVISO: cantidad distinta; revisa el inventario del reporte.',flush=True)
    print('SALIDA / RUTA PARA REANUDAR:',salida,flush=True)
    log=salida/'registro.jsonl'; prev={}
    if log.exists():
        for line in log.read_text(encoding='utf-8').splitlines():
            try:
                r=json.loads(line); prev[r['original']]=r
            except json.JSONDecodeError: pass  # Una ultima linea interrumpida se reprocesa.
    modelo=YOLO(str(pesos))
    names=list(modelo.names.values()) if isinstance(modelo.names,dict) else list(modelo.names)
    if len(names)!=1: raise ValueError(f'Se esperaba detector de una clase, se encontraron: {names}')
    rows=[]; start=time.monotonic(); nuevas=0
    with log.open('a',encoding='utf-8') as journal:
        journal.write('\n'); journal.flush()
        for i,p in enumerate(fotos,1):
            rel=p.relative_to(dataset).as_posix()
            if rel in prev:
                rows.append(prev[rel]); continue
            row={'numero':i,'original':rel,'individuo':p.parent.name,'estado':'ERROR',
                 'motivos':[],'cajas':[],'revision':'PENDIENTE','error':''}
            try:
                im=leer(p); row.update(ancho=im.width,alto=im.height)
                result=modelo.predict(im,device='cpu',imgsz=640,conf=DETECTAR,iou=0.7,verbose=False)[0]
                boxes=result.boxes.xyxy.cpu().tolist(); scores=result.boxes.conf.cpu().tolist()
                row['cajas']=sorted([{'xyxy':b,'confianza':float(s)} for b,s in zip(boxes,scores)],
                                    key=lambda b:b['confianza'],reverse=True)
                n=len(row['cajas']); row['numero_cajas']=n
                if not n:
                    row['estado']='SIN_DETECCION'; row['motivos']=['sin_deteccion']
                else:
                    score=row['cajas'][0]['confianza']; row['confianza']=score
                    if n>1: row['motivos'].append('varias_cajas')
                    if score<REVISAR: row['motivos'].append('baja_confianza')
                    row['estado']='VARIAS_CAJAS' if n>1 else ('BAJA_CONFIANZA' if score<REVISAR else 'CANDIDATO')
                    # Una caja principal por foto; en casos multiples se conservan las alternativas.
                    for j,b in enumerate(row['cajas']):
                        crop=im.crop(limites(b['xyxy'],*im.size))
                        dest=Path('candidatos' if row['estado']=='CANDIDATO' else 'revision')/row['estado']/p.parent.name
                        dest=dest/f'{i:05d}_caja{j+1:02d}.jpg'
                        (salida/dest).parent.mkdir(parents=True,exist_ok=True)
                        crop.save(salida/dest,quality=95)
                        b['recorte']=dest.as_posix()
                        if j==0: row.update(recorte=dest.as_posix(),ancho_recorte=crop.width,alto_recorte=crop.height)
                if row['estado']!='CANDIDATO':
                    dest=Path('paneles_revision')/row['estado']/f'{i:05d}.jpg'
                    panel(im,row,salida/dest); row['panel']=dest.as_posix()
            except Exception as e:
                row.update(estado='ERROR',error=f'{type(e).__name__}: {e}',motivos=['error'])
            rows.append(row); nuevas+=1
            journal.write(json.dumps(row,ensure_ascii=False)+'\n'); journal.flush()
            if nuevas%50==0 or i==len(fotos):
                elapsed=time.monotonic()-start
                eta=(len(fotos)-i)*elapsed/max(1,nuevas)/60
                print(f'{i}/{len(fotos)} | Tiempo: {elapsed/60:.1f} min | Restante aprox.: {eta:.1f} min',flush=True)
    csv_guardar(salida/'manifest_recortes.csv',rows)
    for status in ['CANDIDATO','VARIAS_CAJAS','BAJA_CONFIANZA','SIN_DETECCION','ERROR']:
        csv_guardar(salida/f'{status}.csv',[r for r in rows if r['estado']==status])
    # Muestra reproducible de hasta 200 individuos de las cajas aparentemente correctas.
    groups={}
    for r in rows:
        if r['estado']=='CANDIDATO': groups.setdefault(r['individuo'],[]).append(r)
    rng=random.Random(20261004)
    selected=[rng.choice(groups[g]).copy() for g in rng.sample(sorted(groups),min(200,len(groups)))]
    for r in selected:
        dest=Path('muestra_candidatos')/f"{r['numero']:05d}.jpg"
        panel(leer(dataset/r['original']),r,salida/dest); r['panel']=dest.as_posix()
    csv_guardar(salida/'MUESTRA_PARA_REVISAR.csv',selected)
    counts=dict(Counter(r['estado'] for r in rows))
    summary={'imagenes':len(rows),'estados':counts,'muestra_candidatos':len(selected),
             'minutos_esta_ejecucion':round((time.monotonic()-start)/60,2),'reanudar':str(salida),
             'nota':'Todos los recortes son candidatos pendientes. No se generaron embeddings.'}
    (salida/'resumen.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    texto='CIYFI - RECORTES CANDIDATOS\n'+json.dumps(summary,ensure_ascii=False,indent=2)
    texto+='\nSin deteccion = ninguna caja con confianza >= 0.25. Baja confianza = mejor caja < 0.60.\n'
    texto+='La confianza no confirma identidad ni localizacion correcta. Originales intactos.\n'
    (salida/'RESUMEN.txt').write_text(texto,encoding='utf-8')
    # ZIP ligero: reportes, muestra y hasta 20 paneles por tipo de incidencia; no miles de recortes.
    share=salida/'REPORTE_PARA_COMPARTIR.zip'
    with zipfile.ZipFile(share,'w',zipfile.ZIP_DEFLATED) as z:
        for f in sorted(salida.glob('*.csv'))+list(salida.glob('RESUMEN.txt'))+list(salida.glob('resumen.json'))+list(salida.glob('configuracion.json')):
            z.write(f,f.relative_to(salida))
        for f in sorted((salida/'muestra_candidatos').glob('*.jpg')): z.write(f,f.relative_to(salida))
        for status in ['VARIAS_CAJAS','BAJA_CONFIANZA','SIN_DETECCION']:
            pool=[r for r in rows if r['estado']==status and r.get('panel')]
            for r in rng.sample(pool,min(20,len(pool))):
                f=salida/r['panel']; z.write(f,f.relative_to(salida))
    print('\n'+texto,flush=True)
    print('ZIP PARA COMPARTIR:',share,flush=True)

if __name__=='__main__': main()
'@ | & $python - $Proyecto $Reanudar
if ($LASTEXITCODE -ne 0) { throw 'El proceso se interrumpio. Conserva la ruta de salida para reanudar.' }
