$ErrorActionPreference = 'Stop'
$proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0'
$python = Join-Path $proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "No se encontro Python del proyecto: $python"
}
$carpetaScripts = Join-Path $proyecto 'scripts3_0'
New-Item -ItemType Directory -Path $carpetaScripts -Force | Out-Null
$script = Join-Path $carpetaScripts 'probar_ciyfi_100.py'
@'
import csv
import hashlib
import json
import math
import random
import re
import time
import zipfile
from collections import Counter
from datetime import datetime
from pathlib import Path
from PIL import Image, ImageDraw, ImageOps
from ultralytics import YOLO

PROYECTO = Path(r"C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0")
DATASET = PROYECTO / "tortugascm (1033 ind con muchas fotos)"
PESOS = PROYECTO / "runs3_0/detector_piloto_20261003_215435_480847/entrenamiento/weights/best.pt"
SEMILLA = 20261004
CONFIANZA = 0.25
MARGEN = 0.05  # Por cada lado, como fraccion del ancho/alto de la caja.
EXTENSIONES = {".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".webp", ".mpo"}

def identidad(nombre):
    coincidencia = re.fullmatch(r"individuo\s+(\d+)", nombre.strip(), re.I)
    if not coincidencia:
        raise ValueError(f"Nombre de individuo inesperado: {nombre}")
    return int(coincidencia.group(1))

def panel(imagen, titulo):
    lienzo = Image.new("RGB", (640, 520), "#252525")
    ImageDraw.Draw(lienzo).text((12, 10), titulo, fill="white")
    vista = ImageOps.contain(imagen, (624, 480))
    lienzo.paste(vista, ((640-vista.width)//2, 32+(480-vista.height)//2))
    return lienzo

def main():
    inicio = time.perf_counter()
    if not DATASET.is_dir() or not PESOS.is_file():
        raise FileNotFoundError("No se encontro el dataset o el best.pt del entrenamiento piloto.")
    excluidos = set()
    for nombre, cantidad in [("piloto40", 40), ("ampliacion80", 80)]:
        archivo = PROYECTO / "anotaciones3_0" / nombre / "manifest.json"
        registros = json.loads(archivo.read_text(encoding="utf-8-sig"))
        ids = {identidad(r["individuo"]) for r in registros}
        if len(registros) != cantidad or len(ids) != cantidad:
            raise ValueError(f"El manifest de {nombre} no contiene {cantidad} individuos distintos.")
        excluidos.update(ids)
    if len(excluidos) != 120:
        raise ValueError("Los dos grupos de anotaciones no contienen 120 individuos distintos.")
    candidatos = []
    for carpeta in sorted(DATASET.iterdir(), key=lambda p: p.name.lower()):
        if not carpeta.is_dir() or not re.fullmatch(r"individuo\s+\d+", carpeta.name, re.I):
            continue
        if identidad(carpeta.name) in excluidos:
            continue
        fotos = sorted([p for p in carpeta.iterdir() if p.is_file() and p.suffix.lower() in EXTENSIONES])
        if fotos:
            candidatos.append((carpeta, fotos))
    if len(candidatos) < 100:
        raise ValueError(f"Solo hay {len(candidatos)} individuos candidatos.")
    rng = random.Random(SEMILLA)
    seleccion = [(carpeta, rng.choice(fotos)) for carpeta, fotos in rng.sample(candidatos, 100)]
    salida = PROYECTO / "reportes3_0" / ("prueba_ciyfi100_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f"))
    for subcarpeta in ["imagenes", "detecciones", "recortes", "revision"]:
        (salida / subcarpeta).mkdir(parents=True, exist_ok=True)
    muestra = [{"numero": i, "individuo": c.name, "ruta_original": str(p.relative_to(DATASET))}
               for i, (c, p) in enumerate(seleccion, 1)]
    (salida / "muestra.json").write_text(json.dumps(muestra, indent=2, ensure_ascii=False), encoding="utf-8")
    configuracion = {"dataset": str(DATASET), "modelo": str(PESOS),
                     "sha256_modelo": hashlib.sha256(PESOS.read_bytes()).hexdigest(),
                     "semilla": SEMILLA, "confianza": CONFIANZA, "imgsz": 640,
                     "margen_por_lado": MARGEN, "individuos_excluidos": sorted(excluidos)}
    (salida / "configuracion.json").write_text(json.dumps(configuracion, indent=2), encoding="utf-8")
    modelo = YOLO(str(PESOS))
    filas = []
    print(f"Prueba de 100 fotos; {len(excluidos)} individuos excluidos. Originales intactos.", flush=True)
    for i, (carpeta, ruta) in enumerate(seleccion, 1):
        nombre = f"{i:03d}_ind{identidad(carpeta.name):04d}.jpg"
        fila = {"numero": i, "individuo": carpeta.name, "ruta_original": str(ruta.relative_to(DATASET)),
                "archivo": nombre, "estado": "", "detecciones": 0, "confianza": "",
                "ancho": "", "alto": "", "x1": "", "y1": "", "x2": "", "y2": "",
                "fraccion_area_caja": "", "revision_manual": "", "observaciones": ""}
        try:
            with Image.open(ruta) as fuente:
                fuente.seek(0)  # Primer fotograma; admite JPG que internamente son MPO.
                imagen = ImageOps.exif_transpose(fuente).convert("RGB")
                imagen.load()
            w, h = imagen.size
            fila.update(ancho=w, alto=h)
            copia = imagen.copy()
            copia.thumbnail((1600, 1600))
            copia.save(salida / "imagenes" / nombre, quality=92)
            resultado = modelo.predict(source=imagen, device="cpu", imgsz=640,
                                       conf=CONFIANZA, iou=0.7, verbose=False)[0]
            cajas = resultado.boxes.xyxy.cpu().tolist()
            scores = resultado.boxes.conf.cpu().tolist()
            fila["detecciones"] = len(cajas)
            dibujada = imagen.copy()
            dibujo = ImageDraw.Draw(dibujada)
            recorte = None
            if cajas:
                mejor = max(range(len(scores)), key=lambda k: scores[k])
                for k, caja in enumerate(cajas):
                    color = "lime" if k == mejor else "orange"
                    dibujo.rectangle(caja, outline=color, width=max(2, round(max(w, h)/400)))
                    dibujo.text((caja[0]+3, caja[1]+3), f"{scores[k]:.2f}", fill=color)
                x1, y1, x2, y2 = cajas[mejor]
                area = ((x2-x1)*(y2-y1))/(w*h)
                fila.update(estado="DETECTADA" if len(cajas)==1 else "VARIAS_DETECCIONES",
                            confianza=round(scores[mejor], 5), x1=round(x1, 2), y1=round(y1, 2),
                            x2=round(x2, 2), y2=round(y2, 2), fraccion_area_caja=round(area, 5))
                dx, dy = MARGEN*(x2-x1), MARGEN*(y2-y1)
                limites = (max(0, math.floor(x1-dx)), max(0, math.floor(y1-dy)),
                           min(w, math.ceil(x2+dx)), min(h, math.ceil(y2+dy)))
                recorte = imagen.crop(limites)
                recorte.save(salida / "recortes" / nombre, quality=95)
            else:
                fila["estado"] = "SIN_DETECCION"
            dibujada.thumbnail((1600, 1600))
            dibujada.save(salida / "detecciones" / nombre, quality=92)
            comparacion = Image.new("RGB", (1280, 520), "#252525")
            comparacion.paste(panel(dibujada, f"{i:03d} | {carpeta.name} | {fila['estado']}"), (0, 0))
            if recorte is None:
                recorte = Image.new("RGB", (640, 480), "#252525")
            comparacion.paste(panel(recorte, "Recorte de mayor confianza + margen 5% por lado"), (640, 0))
            comparacion.save(salida / "revision" / nombre, quality=90)
        except Exception as error:
            fila["estado"] = "ERROR"
            fila["observaciones"] = str(error)
        filas.append(fila)
        print(f"{i:03d}/100 | {carpeta.name} | {fila['estado']}", flush=True)
    with (salida / "resultados.csv").open("w", encoding="utf-8-sig", newline="") as f:
        escritor = csv.DictWriter(f, fieldnames=list(filas[0]))
        escritor.writeheader()
        escritor.writerows(filas)
    conteos = Counter(r["estado"] for r in filas)
    resumen = ("CIYFI - PRUEBA VISUAL EN 100 FOTOGRAFIAS NUEVAS\n"
               f"Tiempo: {(time.perf_counter()-inicio)/60:.2f} minutos\n"
               + "\n".join(f"{k}: {v}" for k, v in sorted(conteos.items()))
               + "\n\nSeleccion previa a la inferencia: una foto aleatoria por individuo.\n"
               "120 individuos de las anotaciones anteriores excluidos.\n"
               "No se conoce el solapamiento con el dataset del entrenamiento historico.\n"
               "Deteccion no equivale a caja correcta ni a identificacion individual.\n"
               "Sin cajas manuales nuevas, no se calcula mAP independiente.\n"
               "Ver revision/: caja verde elegida; otras cajas en naranja.\n"
               "Recortes con margen del 5% por lado, sin deformar ni normalizar a 224.\n"
               "Originales sin modificaciones. Errores y ausencias se conservan en CSV.\n")
    (salida / "RESUMEN.txt").write_text(resumen, encoding="utf-8")
    archivos = sorted(p for p in salida.rglob("*") if p.is_file())
    archivo_zip = salida / "RESULTADO_PRUEBA_CIYFI100.zip"
    with zipfile.ZipFile(archivo_zip, "w", zipfile.ZIP_DEFLATED) as z:
        for archivo in archivos:
            z.write(archivo, archivo.relative_to(salida))
    print("\n" + resumen)
    print(f"REPORTES: {salida}")
    print(f"ZIP PARA COMPARTIR: {archivo_zip}")

if __name__ == "__main__":
    main()
'@ | Set-Content -LiteralPath $script -Encoding UTF8
& $python $script
if ($LASTEXITCODE -ne 0) {
    throw 'La prueba no termino. Comparte el error mostrado en la terminal.'
}
