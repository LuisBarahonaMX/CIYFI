$ErrorActionPreference = 'Stop'
$proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0'
$python = Join-Path $proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'No se encontro Python del proyecto.' }
$script = Join-Path $proyecto 'scripts3_0\entrenar_refuerzo_ciyfi.py'
New-Item -ItemType Directory -Path (Split-Path $script) -Force | Out-Null
@'
import csv
import hashlib
import json
import math
import shutil
import time
import zipfile
from datetime import datetime
from pathlib import Path
from PIL import Image
from ultralytics import YOLO

PROYECTO = Path(r"C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0")
PILOTO = PROYECTO / "datasets3_0/detector_piloto_20261003_214257_846676"
REFUERZO = PROYECTO / "anotaciones3_0/refuerzo_detector"
PESOS = PROYECTO / "runs3_0/detector_piloto_20261003_215435_480847/entrenamiento/weights/best.pt"

def metricas(resultado):
    return {k: float(v) for k, v in resultado.results_dict.items()}

def main():
    inicio = time.perf_counter()
    if not PESOS.is_file():
        raise FileNotFoundError(f"No se encontro el modelo inicial: {PESOS}")
    manifiesto = json.loads((REFUERZO / "manifest.json").read_text(encoding="utf-8-sig"))
    anotaciones = json.loads((REFUERZO / "anotaciones.json").read_text(encoding="utf-8-sig"))
    if len(manifiesto) != 40 or len(anotaciones) != 40:
        raise ValueError("El refuerzo debe contener 40 fotos anotadas.")
    anteriores = list(csv.DictReader((PILOTO / "particiones.csv").open(encoding="utf-8-sig", newline="")))
    if len(anteriores) != 119:
        raise ValueError("El dataset piloto debe contener 119 registros.")
    ids_antiguos = {r["individuo"] for r in anteriores}
    ids_nuevos = {r["individuo"] for r in manifiesto}
    if len(ids_nuevos) != 40 or ids_antiguos & ids_nuevos:
        raise ValueError("Hay individuos repetidos o solapamiento con el piloto.")
    # Validar las cajas antes de crear el dataset.
    for r in manifiesto:
        fuente = REFUERZO / "images" / r["archivo"]
        with Image.open(fuente) as im:
            im.load()
            w, h = im.size
        if (w, h) != (r["ancho_copia"], r["alto_copia"]):
            raise ValueError(f"Dimensiones inesperadas: {fuente}")
        caja = anotaciones[r["numero"]]["caja"]
        if len(caja) != 4 or not all(math.isfinite(v) for v in caja):
            raise ValueError(f"Caja invalida: {r['numero']}")
        x1, y1, x2, y2 = caja
        if not (0 <= x1 < x2 <= w and 0 <= y1 < y2 <= h):
            raise ValueError(f"Caja fuera de la imagen: {r['numero']}")
    sello = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    dataset = PROYECTO / "datasets3_0" / ("detector_refuerzo_" + sello)
    salida = PROYECTO / "runs3_0" / ("ciyfi_refuerzo_" + sello)
    salida.mkdir(parents=True)
    for sub in ["images/train", "images/val", "labels/train", "labels/val"]:
        (dataset / sub).mkdir(parents=True)
    particiones = []
    for r in anteriores:
        split, archivo = r["particion"], r["archivo"]
        if split not in {"train", "val"}:
            raise ValueError(f"Particion desconocida: {split}")
        for tipo, nombre in [("images", archivo), ("labels", str(Path(archivo).with_suffix('.txt')))]:
            shutil.copy2(PILOTO / tipo / split / nombre, dataset / tipo / split / nombre)
        particiones.append({"archivo": archivo, "particion": split, "individuo": r["individuo"],
                            "origen": "piloto", "ruta_original": r["ruta_original"]})
    for r in manifiesto:
        archivo = "refuerzo_" + r["archivo"]
        shutil.copy2(REFUERZO / "images" / r["archivo"], dataset / "images/train" / archivo)
        w, h = r["ancho_copia"], r["alto_copia"]
        x1, y1, x2, y2 = anotaciones[r["numero"]]["caja"]
        valores = [(x1+x2)/(2*w), (y1+y2)/(2*h), (x2-x1)/w, (y2-y1)/h]
        etiqueta = "0 " + " ".join(f"{v:.8f}" for v in valores) + "\n"
        (dataset / "labels/train" / Path(archivo).with_suffix('.txt')).write_text(etiqueta, encoding="utf-8")
        particiones.append({"archivo": archivo, "particion": "train", "individuo": r["individuo"],
                            "origen": "refuerzo", "ruta_original": r["ruta_original"]})
    for split, esperado in [("train", 135), ("val", 24)]:
        fotos = list((dataset / "images" / split).glob("*.jpg"))
        etiquetas = list((dataset / "labels" / split).glob("*.txt"))
        if len(fotos) != esperado or len(etiquetas) != esperado:
            raise ValueError(f"Cantidad inesperada en {split}.")
    hashes = [hashlib.sha256(p.read_bytes()).hexdigest() for p in (dataset / "images").rglob("*.jpg")]
    if len(set(hashes)) != 159:
        raise ValueError("Hay copias exactas repetidas en el dataset combinado.")
    config = dataset / "data.yaml"
    config.write_text(f'path: "{dataset.as_posix()}"\ntrain: images/train\nval: images/val\nnames:\n  0: cabeza_tortuga\n', encoding="utf-8")
    with (dataset / "particiones.csv").open("w", encoding="utf-8-sig", newline="") as f:
        escritor = csv.DictWriter(f, fieldnames=list(particiones[0]))
        escritor.writeheader()
        escritor.writerows(particiones)
    for nombre in ["data.yaml", "particiones.csv"]:
        shutil.copy2(dataset / nombre, salida / nombre)
    print(f"\nDataset preparado: {dataset}\nEntrenamiento: 135 | Validacion: 24", flush=True)
    modelo = YOLO(str(PESOS))
    evaluacion = dict(data=str(config), split="val", imgsz=640, batch=4, device="cpu",
                      workers=0, conf=0.001, iou=0.7, plots=True, project=str(salida))
    antes = metricas(modelo.val(**evaluacion, name="antes"))
    (salida / "metricas_antes.json").write_text(json.dumps(antes, indent=2), encoding="utf-8")
    modelo.train(data=str(config), epochs=40, patience=12, imgsz=640, batch=4,
                 device="cpu", workers=0, amp=False, cache=False, optimizer="AdamW",
                 lr0=0.0003, lrf=0.1, freeze=0, seed=42, deterministic=True,
                 mosaic=0.5, close_mosaic=10, mixup=0.0, degrees=15, translate=0.1,
                 scale=0.3, fliplr=0.5, flipud=0.0, save=True, plots=True,
                 project=str(salida), name="entrenamiento")
    mejor = Path(modelo.trainer.save_dir) / "weights/best.pt"
    despues = metricas(YOLO(str(mejor)).val(**evaluacion, name="despues"))
    minutos = (time.perf_counter()-inicio)/60
    informe = {"dataset": str(dataset), "pesos_iniciales": str(PESOS), "mejor_peso": str(mejor),
               "minutos_totales": round(minutos, 2), "antes": antes, "despues": despues,
               "nota": "Las mismas 24 fotos seleccionan el modelo; no es evaluacion final independiente."}
    (salida / "comparacion_metricas.json").write_text(json.dumps(informe, indent=2), encoding="utf-8")
    resumen = (f"CIYFI - SEGUNDO ENTRENAMIENTO\n135 train / 24 val\nTiempo: {minutos:.2f} minutos\n"
               f"Mejor modelo: {mejor}\n\n"
               + "\n".join(f"{k}: {antes[k]:.4f} / {despues[k]:.4f}" for k in antes)
               + "\n\nValidacion piloto; hace falta una nueva prueba de individuos no usados.\n"
               "Las 40 fotos de refuerzo ya forman parte del entrenamiento.\nOriginales y modelos previos intactos.\n")
    (salida / "RESUMEN.txt").write_text(resumen, encoding="utf-8")
    extensiones = {".json", ".txt", ".csv", ".yaml", ".png", ".jpg"}
    archivos = sorted(p for p in salida.rglob("*") if p.is_file() and (p.suffix in extensiones or p == mejor))
    archivo_zip = salida / "RESULTADO_REFUERZO_CIYFI.zip"
    with zipfile.ZipFile(archivo_zip, "w", zipfile.ZIP_DEFLATED) as z:
        for p in archivos:
            z.write(p, p.relative_to(salida))
    print("\n" + resumen)
    print(f"ZIP PARA COMPARTIR: {archivo_zip}")

if __name__ == "__main__":
    main()
'@ | Set-Content -LiteralPath $script -Encoding UTF8
& $python $script
if ($LASTEXITCODE -ne 0) { throw 'El proceso no termino. Comparte el error de la terminal.' }
