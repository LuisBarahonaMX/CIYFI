param(
 [string]$Proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0',
 [string]$Preparacion = 'AUTO'
)
$ErrorActionPreference = 'Stop'
$python = Join-Path $Proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No se encontro Python: $python" }
if ([string]::IsNullOrWhiteSpace($Preparacion)) { $Preparacion = 'AUTO' }
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$env:PYTHONUNBUFFERED = '1'
& $python -c "from PIL import Image"
if ($LASTEXITCODE -ne 0) { throw 'No se pudo cargar Pillow en .venv. Comparte el error.' }
@'
import csv, hashlib, json, re, sys, time, zipfile
from pathlib import Path
from datetime import datetime
from collections import Counter, defaultdict
from PIL import Image

def load(p):
    return json.loads(p.read_text(encoding='utf-8-sig'))

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def safe(base, rel):
    if not rel:
        raise ValueError('Ruta original vacia')
    p = (base / rel).resolve()
    if not p.is_relative_to(base.resolve()):
        raise ValueError('Ruta fuera del dataset')
    return p

def clean(value):
    if isinstance(value, bytes):
        value = value.decode('ascii', errors='replace')
    return str(value or '').strip().strip('\x00')

def parse_date(value):
    text = clean(value)
    for fmt in ('%Y:%m:%d %H:%M:%S', '%Y-%m-%d %H:%M:%S'):
        try:
            d = datetime.strptime(text, fmt)
            if 1990 <= d.year <= datetime.now().year:
                return d.isoformat()
        except ValueError:
            pass
    return ''

def hints(rel):
    # Solo indicios en el nombre/ruta: nunca se interpretan como sesiones confirmadas.
    dates = set()
    for m in re.finditer(r'(?<!\d)((?:19|20)\d{2})[-_]?([01]\d)[-_]?([0-3]\d)(?!\d)', rel):
        try:
            dates.add(datetime(int(m[1]), int(m[2]), int(m[3])).date().isoformat())
        except ValueError:
            pass
    years = set(re.findall(r'(?<!\d)((?:19|20)\d{2})(?!\d)', rel))
    return ';'.join(sorted(dates)), ';'.join(sorted(years))

def inspect(p):
    with Image.open(p) as im:
        exif = im.getexif()
        nested_error = ''
        try:
            nested = exif.get_ifd(34665) if 34665 in exif else {}
        except Exception as e:
            nested = {}
            nested_error = str(e)
        original = clean(nested.get(36867, exif.get(36867, '')))
        digitized = clean(nested.get(36868, exif.get(36868, '')))
        modification = clean(exif.get(306, ''))
        dt = parse_date(original)
        return {
            'fecha_original_exif': original,
            'fecha_digitalizacion_exif': digitized,
            'fecha_modificacion_exif': modification,
            'fecha_captura_propuesta': dt,
            'dia_captura_propuesto': dt[:10],
            'orientacion_exif': clean(exif.get(274, '')),
            'camara': (clean(exif.get(271, '')) + ' ' + clean(exif.get(272, ''))).strip(),
            'aviso_exif': nested_error,
        }

def write_csv(p, rows, fields):
    with p.open('w', encoding='utf-8-sig', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
        w.writeheader()
        w.writerows(rows)

def run(project, preparation='AUTO'):
    start = time.perf_counter()
    if preparation == 'AUTO':
        candidates = []
        for p in (project / 'reid3_0').glob('preparacion_*'):
            try:
                if load(p / 'resumen.json').get('estado') == 'LISTO' and (p / 'inventario_verificado.csv').is_file():
                    candidates.append(p)
            except (OSError, ValueError):
                pass
        if not candidates:
            raise ValueError('No hay una preparacion LISTO con inventario_verificado.csv en reid3_0.')
        prep = max(candidates, key=lambda p: p.name)
    else:
        prep = Path(preparation)
        if load(prep / 'resumen.json').get('estado') != 'LISTO':
            raise ValueError('La preparacion seleccionada no esta LISTO.')
    config = load(prep / 'configuracion.json')
    crops = Path(config['carpeta_recortes'])
    dataset = Path(load(crops / 'configuracion.json')['dataset'])
    if not dataset.is_dir():
        raise ValueError('No existe la ruta original del dataset: ' + str(dataset))
    inventory = prep / 'inventario_verificado.csv'
    with inventory.open(encoding='utf-8-sig', newline='') as f:
        rows = list(csv.DictReader(f))
    if not rows or any(not r.get('original') or not r.get('individuo') for r in rows):
        raise ValueError('Inventario vacio o sin original/individuo.')
    if len({r['original'] for r in rows}) != len(rows):
        raise ValueError('El inventario contiene originales repetidos.')
    dest = project / 'reportes3_0' / ('sesiones_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    dest.mkdir(parents=True, exist_ok=False)
    details, errors = [], []
    print('Preparacion:', prep, flush=True)
    print('Dataset original:', dataset, flush=True)
    print('Revisando metadatos de', len(rows), 'fotos. No se decodifican ni cambian los originales.', flush=True)
    for i, r in enumerate(rows, 1):
        info = {k: r.get(k, '') for k in ('numero', 'individuo', 'original', 'recorte', 'revision_calidad')}
        dates, years = hints(r['original'])
        info.update(indicios_fecha_nombre=dates, indicios_anio_nombre=years)
        try:
            info.update(inspect(safe(dataset, r['original'])))
            info['evidencia'] = 'EXIF_ORIGINAL_POR_VERIFICAR' if info['fecha_captura_propuesta'] else 'SIN_FECHA_CAPTURA_CONFIRMABLE'
            if info['aviso_exif']:
                errors.append({'original': r['original'], 'error': 'Aviso EXIF: ' + info['aviso_exif']})
        except Exception as e:
            info['evidencia'] = 'ERROR_METADATOS'
            errors.append({'original': r['original'], 'error': str(e)})
        # Un dia EXIF es solo una propuesta: no equivale a una sesion real.
        info['grupo_dia_propuesto'] = (r['individuo'] + '|' + info['dia_captura_propuesto']) if info.get('dia_captura_propuesto') else ''
        details.append(info)
        if i % 200 == 0 or i == len(rows):
            print(f'Revisadas {i}/{len(rows)} | {time.perf_counter()-start:.1f} s', flush=True)
    grouped = defaultdict(list)
    for r in details:
        grouped[r['individuo']].append(r)
    individual_rows = []
    for identity, photos in sorted(grouped.items()):
        days = {r['dia_captura_propuesto'] for r in photos if r.get('dia_captura_propuesto')}
        dated = sum(bool(r.get('dia_captura_propuesto')) for r in photos)
        individual_rows.append({'individuo': identity, 'fotos': len(photos), 'con_fecha_original_valida': dated,
                                'sin_fecha_original_valida': len(photos)-dated, 'dias_exif_distintos': len(days),
                                'dias_propuestos': ';'.join(sorted(days))})
    fields = ['numero','individuo','original','recorte','revision_calidad','evidencia','fecha_original_exif',
              'fecha_digitalizacion_exif','fecha_modificacion_exif','fecha_captura_propuesta',
              'dia_captura_propuesto','grupo_dia_propuesto','indicios_fecha_nombre','indicios_anio_nombre',
              'orientacion_exif','camara','aviso_exif']
    write_csv(dest / 'metadatos_fotos.csv', details, fields)
    write_csv(dest / 'resumen_individuos.csv', individual_rows, ['individuo','fotos','con_fecha_original_valida','sin_fecha_original_valida','dias_exif_distintos','dias_propuestos'])
    write_csv(dest / 'errores.csv', errors, ['original','error'])
    ndated = sum(bool(r.get('fecha_captura_propuesta')) for r in details)
    stats = {'estado': 'COMPLETO_CON_AVISOS' if errors else 'COMPLETO', 'fotos': len(details), 'individuos': len(grouped),
             'fotos_con_exif_original_valido': ndated, 'fotos_sin_exif_original_valido': len(details)-ndated,
             'fotos_con_indicios_fecha_en_nombre': sum(bool(r['indicios_fecha_nombre']) for r in details),
             'individuos_con_dos_o_mas_dias_exif': sum(r['dias_exif_distintos']>=2 for r in individual_rows),
             'individuos_con_tres_o_mas_dias_exif': sum(r['dias_exif_distintos']>=3 for r in individual_rows),
             'individuos_con_una_foto': sum(r['fotos']==1 for r in individual_rows),
             'errores_o_avisos': len(errors), 'segundos': round(time.perf_counter()-start, 1),
             'se_generaron_particiones': False}
    (dest / 'resumen.json').write_text(json.dumps(stats, ensure_ascii=False, indent=2), encoding='utf-8')
    (dest / 'configuracion.json').write_text(json.dumps({'preparacion': str(prep), 'dataset': str(dataset),
        'inventario_sha256': sha(inventory), 'fecha': datetime.now().isoformat(),
        'alcance': 'Solo fotos del inventario utilizable; lectura de metadatos de originales. No se crean train/val/test.',
        'criterio': 'DateTimeOriginal EXIF valido como indicio; digitalizacion y modificacion solo informativas. Sin usar fechas del sistema de archivos.',
        'limites': 'EXIF puede ser incorrecto o editado. Un mismo dia no garantiza una sesion, ni dias distintos independencia visual. No se detectan fotos casi iguales en este paso.'}, ensure_ascii=False, indent=2), encoding='utf-8')
    text = 'AUDITORIA DE SESIONES CIYFI\n\n' + '\n'.join(f'{k}: {v}' for k,v in stats.items())
    text += '\n\nNo se crearon particiones ni se modificaron fotos.\nLas fechas EXIF y los nombres son indicios para verificar, no sesiones confirmadas.\nNo se usaron fechas de creacion/modificacion de Windows para inferir capturas.\nSi faltan fechas, necesitaremos informacion de sesiones o revisar similitud visual.\n'
    (dest / 'resumen.txt').write_text(text, encoding='utf-8')
    zip_path = dest.with_suffix('.zip')
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        for p in sorted(dest.iterdir()):
            z.write(p, p.name)
    print('\n' + text, flush=True)
    print('ZIP PARA COMPARTIR:', zip_path, flush=True)

if __name__ == '__main__':
    run(Path(sys.argv[1]), sys.argv[2])

'@ | & $python - $Proyecto $Preparacion
if ($LASTEXITCODE -ne 0) { throw 'La auditoria de sesiones no se completo. Comparte el error mostrado arriba.' }
