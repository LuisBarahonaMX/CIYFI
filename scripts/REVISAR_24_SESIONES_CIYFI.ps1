param([string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0')
$ErrorActionPreference = 'Stop'
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No se encontro Python: $python" }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
@'
import csv, hashlib, html, json, sys
from pathlib import Path

def load(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def read(p):
    with p.open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def esc(s):return html.escape(str(s),quote=True)
def safe(base,rel):
    if not rel:raise ValueError('Ruta vacia')
    p=(base/rel).resolve()
    if not p.is_relative_to(base.resolve()):raise ValueError('Ruta fuera de carpeta: '+rel)
    return p

def make_page(sessions,photos,dataset,crops,signature,config):
    mixed=[s for s in sessions if s['varias_camaras']=='SI']
    selected={s['sesion'] for s in mixed}
    if len(selected)!=len(mixed):raise ValueError('Sesiones repetidas')
    groups={sid:[] for sid in selected}
    for r in photos:
        if r['sesion'] in selected:groups[r['sesion']].append(r)
    blocks=[]
    for i,s in enumerate(mixed,1):
        sid=s['sesion'];group=sorted(groups[sid],key=lambda r:(r['fecha_captura_propuesta'],r['original']))
        if len(group)!=int(s['fotos']):raise ValueError('Numero de fotos inconsistente: '+sid)
        cards=[]
        for r in group:
            original=safe(dataset,r['original']);crop=safe(crops,r['recorte'])
            cards.append(f'''<article><b>Foto {esc(r['numero'])}</b><p>{esc(r['fecha_captura_propuesta'])}<br>{esc(r.get('camara',''))}</p>
<a href="{esc(original.as_uri())}" target="_blank"><img loading="lazy" src="{esc(original.as_uri())}" alt="Original"></a>
<a href="{esc(crop.as_uri())}" target="_blank"><img loading="lazy" class="crop" src="{esc(crop.as_uri())}" alt="Recorte"></a>
<p class="path">{esc(r['original'])}</p></article>''')
        blocks.append(f'''<section data-session="{esc(sid)}"><h2>{i}/{len(mixed)} · {esc(sid)} · {len(group)} fotos</h2>
<p>{esc(s['inicio_exif'])} → {esc(s['fin_exif'])}</p><div class="grid">{''.join(cards)}</div>
<div class="decision"><label>Decision: <select><option value="PENDIENTE">Pendiente</option><option value="MANTENER">Mantener juntas</option><option value="REVISAR_SEPARACION">Revisar separacion</option><option value="DUDA">Duda</option></select></label>
<label>Observaciones: <input type="text" placeholder="Si hay grupos distintos, escribe los numeros de las fotos"></label></div></section>''')
    metadata={'firma':signature,'agrupacion':config,'sesiones':[s['sesion'] for s in mixed],'fotos_revisables':sum(len(v) for v in groups.values())}
    script=r'''
const meta=METADATA;
const key='ciyfi_revision24_'+meta.firma;
const sections=[...document.querySelectorAll('section')];
function collect(){return sections.map(s=>({sesion:s.dataset.session,decision:s.querySelector('select').value,observaciones:s.querySelector('input').value}));}
function update(){const ds=collect();document.querySelector('#count').textContent=ds.filter(d=>d.decision!=='PENDIENTE').length+' / '+ds.length+' sesiones revisadas';try{localStorage.setItem(key,JSON.stringify(ds));}catch(e){document.querySelector('#save').textContent='El navegador no guardo el avance: exporta el JSON antes de cerrar.';}}
function restore(ds){for(const s of sections){const d=ds.find(d=>d.sesion===s.dataset.session);if(d){s.querySelector('select').value=d.decision;s.querySelector('input').value=d.observaciones||'';}}update();}
try{const old=JSON.parse(localStorage.getItem(key)||'[]');restore(old);}catch(e){update();}
for(const s of sections){s.querySelector('select').addEventListener('change',update);s.querySelector('input').addEventListener('input',update);}
document.querySelector('#export').onclick=()=>{const data={...meta,fecha_exportacion:new Date().toISOString(),decisiones:collect()};const blob=new Blob([JSON.stringify(data,null,2)],{type:'application/json'});const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download='REVISION_24_SESIONES.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
document.querySelector('#import').onchange=async e=>{try{const data=JSON.parse(await e.target.files[0].text());if(data.firma!==meta.firma||!Array.isArray(data.decisiones))throw Error('El JSON corresponde a otra agrupacion.');const allowed=new Set(['PENDIENTE','MANTENER','REVISAR_SEPARACION','DUDA']);if(data.decisiones.some(d=>!meta.sesiones.includes(d.sesion)||!allowed.has(d.decision)))throw Error('Decisiones invalidas.');restore(data.decisiones);}catch(error){alert(error.message);}};
'''.replace('METADATA',json.dumps(metadata,ensure_ascii=True).replace('<','\\u003c'))
    return '''<!doctype html><html lang="es"><meta charset="utf-8"><title>CIYFI - Revision de sesiones</title>
<style>body{font-family:Arial;background:#f1f5f8;color:#172b35;margin:20px}header{position:sticky;top:0;background:#fff;padding:12px;border:1px solid #aaa;z-index:2}section{background:white;padding:15px;margin:20px 0;border-radius:8px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}article{border:1px solid #ddd;padding:10px}img{width:100%;height:240px;object-fit:contain;background:#eee}.crop{height:160px}.path{font-size:12px;overflow-wrap:anywhere}.decision{margin-top:15px;display:flex;gap:20px;flex-wrap:wrap}input[type=text]{width:350px;max-width:100%}button,select,input{padding:8px}h2{font-size:20px}</style>
<header><b>CIYFI · Revision de 24 sesiones</b><p id="count"></p><button id="export">Exportar decisiones JSON</button> <label>Restaurar JSON: <input id="import" type="file" accept=".json"></label><small id="save"></small></header>
<p>Compara originales y recortes. Pulsa una imagen para ampliarla. <b>Mantener juntas</b>: misma captura o secuencia compatible. <b>Revisar separacion</b>: observas capturas distintas; anota los numeros de fotos por grupo. <b>Duda</b>: no puedes determinarlo. Cambiar de camara por si solo no obliga a separar.</p>
<p>Las decisiones no cambian fotos ni sesiones. Exporta el JSON al terminar o antes de cerrar. Conserva la pagina en su carpeta; necesita las rutas locales del proyecto.</p>
'''+''.join(blocks)+'<script>'+script+'</script></html>'

def run(project):
    choices=[p for p in (project/'reid3_0').glob('agrupacion_sesiones_*') if p.is_dir() and (p/'sesiones.csv').is_file()]
    if not choices:raise ValueError('No se encontro la agrupacion de sesiones en reid3_0.')
    source=max(choices,key=lambda p:p.name);cfg=load(source/'configuracion.json')
    prep=Path(cfg['preparacion']);pcfg=load(prep/'configuracion.json');crops=Path(pcfg['carpeta_recortes']);dataset=Path(cfg['dataset'])
    if sha(prep/'inventario_verificado.csv')!=cfg['inventario_sha256']:raise ValueError('El inventario cambio desde la agrupacion.')
    if not crops.is_dir() or not dataset.is_dir():raise ValueError('No se encontraron las carpetas locales de originales o recortes.')
    sessions=read(source/'sesiones.csv');photos=read(source/'fotos_con_sesion.csv')
    signature=hashlib.sha256((sha(source/'sesiones.csv')+sha(source/'fotos_con_sesion.csv')).encode()).hexdigest()
    page=make_page(sessions,photos,dataset,crops,signature,{'carpeta':str(source),'inventario_sha256':cfg['inventario_sha256']})
    path=source/'REVISION_24_SESIONES.html';path.write_text(page,encoding='utf-8')
    print('Pagina creada:',path)
    print('Al terminar, pulsa Exportar decisiones JSON y comparte REVISION_24_SESIONES.json.')
    # La apertura del navegador no altera datos.
    import os
    os.startfile(str(path))

if __name__=='__main__':run(Path(sys.argv[1]))

'@ | & $python - $Proyecto
if ($LASTEXITCODE -ne 0) { throw 'No se pudo abrir la revision de sesiones. Comparte el error mostrado arriba.' }
