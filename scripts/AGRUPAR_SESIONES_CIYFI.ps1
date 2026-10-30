param(
 [string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0',
 [string]$Reporte = 'AUTO',
 [ValidateRange(0,23)][int]$HoraCorte = 6,
 [ValidateRange(1,48)][int]$IntervaloHoras = 6
)
$ErrorActionPreference = 'Stop'
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No se encontro Python: $python" }
if ([string]::IsNullOrWhiteSpace($Reporte)) { $Reporte = 'AUTO' }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
@'
import csv, hashlib, json, sys, zipfile
from pathlib import Path
from datetime import datetime, timedelta
from collections import defaultdict, Counter

def load(p):
    return json.loads(p.read_text(encoding='utf-8-sig'))

def read_csv(p):
    with p.open(encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))

def write_csv(p, rows, fields):
    with p.open('w', encoding='utf-8-sig', newline='') as f:
        w=csv.DictWriter(f, fieldnames=fields, extrasaction='ignore');w.writeheader();w.writerows(rows)

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def group_photos(rows, cutoff=6, gap_hours=6):
    groups=defaultdict(list);pending=[]
    for r in rows:
        r=dict(r)
        stamp=r.get('fecha_captura_propuesta','')
        if not stamp:
            r.update(sesion='',dia_operativo='',motivo_pendiente='Sin fecha original EXIF valida')
            pending.append(r);continue
        dt=datetime.fromisoformat(stamp)
        if dt.tzinfo is not None:
            raise ValueError('Se esperaban fechas locales EXIF sin zona horaria.')
        r['dia_operativo']=(dt-timedelta(hours=cutoff)).date().isoformat()
        r['reasignada_noche_anterior']='SI' if dt.hour<cutoff else 'NO'
        groups[r['individuo']].append((dt,r))
    assigned=[];sessions=[]
    for identity, items in sorted(groups.items()):
        items.sort(key=lambda x:(x[0],x[1]['original']))
        chunks=[]
        for dt,r in items:
            if not chunks:
                chunks.append([(dt,r)]);continue
            last_dt,last_r=chunks[-1][-1]
            # Conservador: mismo dia operativo siempre unido; tambien intervalos cortos cruzando dias.
            if r['dia_operativo']==last_r['dia_operativo'] or dt-last_dt<=timedelta(hours=gap_hours):
                chunks[-1].append((dt,r))
            else:
                chunks.append([(dt,r)])
        for number, chunk in enumerate(chunks,1):
            sid=f'{identity}|S{number:03d}'
            for dt,r in chunk:
                r.update(sesion=sid,motivo_pendiente='');assigned.append(r)
            cameras=sorted({r.get('camara','') for _,r in chunk if r.get('camara')})
            sessions.append({'individuo':identity,'sesion':sid,'fotos':len(chunk),
                'inicio_exif':chunk[0][0].isoformat(),'fin_exif':chunk[-1][0].isoformat(),
                'dias_operativos':';'.join(sorted({r['dia_operativo'] for _,r in chunk})),
                'fotos_noche_anterior':sum(r['reasignada_noche_anterior']=='SI' for _,r in chunk),
                'camaras':';'.join(cameras), 'varias_camaras':'SI' if len(cameras)>1 else 'NO'})
    return assigned,pending,sessions

def run(project, report='AUTO', cutoff=6, gap_hours=6):
    if not 0<=cutoff<=23 or not 0<gap_hours<=48:
        raise ValueError('Hora de corte: 0 a 23. Intervalo: mayor que 0 y hasta 48 horas.')
    if report=='AUTO':
        choices=[p for p in (project/'reportes3_0').glob('sesiones_*') if p.is_dir() and (p/'metadatos_fotos.csv').is_file()]
        if not choices:raise ValueError('No se encontro la auditoria de sesiones en reportes3_0.')
        report_path=max(choices,key=lambda p:p.name)
    else:report_path=Path(report)
    config=load(report_path/'configuracion.json')
    prep=Path(config['preparacion']);inventory=prep/'inventario_verificado.csv'
    if sha(inventory)!=config['inventario_sha256']:
        raise ValueError('El inventario cambio desde la auditoria. No se agrupo.')
    rows=read_csv(report_path/'metadatos_fotos.csv');inv=read_csv(inventory)
    if len(rows)!=len(inv) or len({r['original'] for r in rows})!=len(rows):
        raise ValueError('El reporte esta incompleto o contiene originales repetidos.')
    src={r['original']:r for r in inv}
    for r in rows:
        other=src.get(r['original'])
        if other is None or any(r.get(k,'')!=other.get(k,'') for k in ('numero','individuo','recorte','revision_calidad')):
            raise ValueError('Reporte e inventario inconsistentes: '+r['original'])
    assigned,pending,sessions=group_photos(rows,cutoff,gap_hours)
    assert len(assigned)+len(pending)==len(rows)
    assert len({r['original'] for r in assigned+pending})==len(rows)
    assert all(r['sesion'] for r in assigned) and all(not r['sesion'] for r in pending)
    counts=Counter(s['individuo'] for s in sessions);unknown=Counter(r['individuo'] for r in pending)
    identities=sorted({r['individuo'] for r in rows})
    individual=[{'individuo':i,'sesiones_con_fecha':counts[i],'fotos_pendientes_fecha':unknown[i],
                 'tiene_tres_o_mas_sesiones':'SI' if counts[i]>=3 else 'NO'} for i in identities]
    dest=project/'reid3_0'/('agrupacion_sesiones_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    dest.mkdir(parents=True,exist_ok=False)
    fields=list(rows[0])+['dia_operativo','reasignada_noche_anterior','sesion','motivo_pendiente']
    write_csv(dest/'fotos_con_sesion.csv',assigned,fields)
    write_csv(dest/'pendientes_sin_fecha.csv',pending,fields)
    write_csv(dest/'sesiones.csv',sessions,['individuo','sesion','fotos','inicio_exif','fin_exif','dias_operativos','fotos_noche_anterior','camaras','varias_camaras'])
    write_csv(dest/'individuos.csv',individual,['individuo','sesiones_con_fecha','fotos_pendientes_fecha','tiene_tres_o_mas_sesiones'])
    stats={'estado':'AGRUPACION_PROPUESTA','fotos_total':len(rows),'fotos_agrupadas':len(assigned),'fotos_pendientes_fecha':len(pending),
           'individuos_total':len(identities),'sesiones_propuestas':len(sessions),
           'individuos_con_una_sesion':sum(n==1 for n in counts.values()),
           'individuos_con_dos_sesiones':sum(n==2 for n in counts.values()),
           'individuos_con_tres_o_mas_sesiones':sum(n>=3 for n in counts.values()),
           'individuos_sin_sesion_fechada':sum(counts[i]==0 for i in identities),
           'fotos_asignadas_noche_anterior':sum(r['reasignada_noche_anterior']=='SI' for r in assigned),
           'sesiones_con_varias_camaras':sum(s['varias_camaras']=='SI' for s in sessions),
           'particiones_creadas':False}
    (dest/'resumen.json').write_text(json.dumps(stats,ensure_ascii=False,indent=2),encoding='utf-8')
    cfg={'reporte_fuente':str(report_path),'preparacion':str(prep),'dataset':config['dataset'],
         'inventario_sha256':config['inventario_sha256'],'metadatos_sha256':sha(report_path/'metadatos_fotos.csv'),
         'hora_corte_noche':cutoff,'intervalo_union_horas':gap_hours,
         'regla':'Por individuo: agrupar mismo dia operativo (fecha menos hora de corte). Unir tambien fotos consecutivas separadas por un intervalo menor o igual al limite. No separar por camara.',
         'limites':'Sesiones inferidas temporalmente, no confirmadas visualmente. No garantiza ausencia de fotos parecidas entre sesiones. Mismos individuos aun no asignados a train/val/test. Fechas originales preservadas.'}
    (dest/'configuracion.json').write_text(json.dumps(cfg,ensure_ascii=False,indent=2),encoding='utf-8')
    text='AGRUPACION TEMPORAL CIYFI\n\n'+'\n'.join(f'{k}: {v}' for k,v in stats.items())
    text+='\n\nNo se movieron ni modificaron fotos. No se crearon train/val/test.\nSe conserva fecha EXIF original; dia_operativo registra el ajuste de noche.\nLas fotos sin fecha permanecen pendientes, fuera de las sesiones propuestas.\nCada sesion debera permanecer completa en una particion futura.\n'
    (dest/'resumen.txt').write_text(text,encoding='utf-8')
    zp=dest.with_suffix('.zip')
    with zipfile.ZipFile(zp,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(dest.iterdir()):z.write(p,p.name)
    print('Auditoria fuente:',report_path)
    print(text)
    print('ZIP PARA COMPARTIR:',zp)

if __name__=='__main__':
    run(Path(sys.argv[1]),sys.argv[2],int(sys.argv[3]),float(sys.argv[4]))

'@ | & $python - $Proyecto $Reporte $HoraCorte $IntervaloHoras
if ($LASTEXITCODE -ne 0) { throw 'No se completo la agrupacion. Comparte el error mostrado arriba.' }
