$ErrorActionPreference = 'Stop'
$proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0'
$python = Join-Path $proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'No se encontro Python del proyecto.' }
@'
import csv
import hashlib
import importlib.util
import json
import math
import random
import time
import zipfile
from collections import Counter
from datetime import datetime
from pathlib import Path
from PIL import Image, ImageDraw, ImageOps
from ultralytics import YOLO

def main():
    proyecto = Path(r"C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0")
    dataset = proyecto / "tortugascm (1033 ind con muchas fotos)"
    # Reutiliza las funciones del script de prueba que ya ejecutaste.
    spec = importlib.util.spec_from_file_location("prueba_anterior", proyecto / "scripts3_0/probar_ciyfi_100.py")
    util = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(util)
    pesos = {
        "piloto": proyecto / "runs3_0/detector_piloto_20261003_215435_480847/entrenamiento/weights/best.pt",
        "refuerzo": proyecto / "runs3_0/ciyfi_refuerzo_20261003_231304_294942/entrenamiento/weights/best.pt"}
    for p in pesos.values():
        if not p.is_file():
            raise FileNotFoundError(p)
    excluidos = set()
    for lote in ["piloto40", "ampliacion80", "refuerzo_detector"]:
        registros = json.loads((proyecto / "anotaciones3_0" / lote / "manifest.json").read_text(encoding="utf-8-sig"))
        excluidos.update(util.identidad(r["individuo"]) for r in registros)
    # Excluye tambien todos los individuos de la primera prueba de 100.
    reportes = sorted((proyecto / "reportes3_0").glob("prueba_ciyfi100_*/muestra.json"))
    if not reportes:
        raise FileNotFoundError("Falta muestra.json de la prueba anterior de 100 fotos.")
    for p in reportes:
        registros = json.loads(p.read_text(encoding="utf-8-sig"))
        excluidos.update(util.identidad(r["individuo"]) for r in registros)
    candidatos = []
    for c in sorted(dataset.iterdir(), key=lambda p: p.name.lower()):
        if not c.is_dir():
            continue
        try:
            ident = util.identidad(c.name)
        except ValueError:
            continue
        if ident in excluidos:
            continue
        fotos = sorted(p for p in c.iterdir() if p.is_file() and p.suffix.lower() in util.EXTENSIONES)
        if fotos:
            candidatos.append((c, fotos))
    if len(candidatos) < 100:
        raise ValueError("No hay 100 individuos nuevos disponibles.")
    rng = random.Random(20261005)
    seleccion = [{"grupo": "nueva", "numero": str(i), "individuo": c.name,
                  "ruta_original": str(rng.choice(fotos).relative_to(dataset))}
                 for i, (c, fotos) in enumerate(rng.sample(candidatos, 100), 1)]
    refuerzo = json.loads((proyecto / "anotaciones3_0/refuerzo_detector/manifest.json").read_text(encoding="utf-8-sig"))
    for anterior in [10, 62]:
        r = next(r for r in refuerzo if int(r.get("numero_prueba100", -1)) == anterior)
        seleccion.append({"grupo": "correccion_entrenada", "numero": str(anterior),
                          "individuo": r["individuo"], "ruta_original": r["ruta_original"]})
    salida = proyecto / "reportes3_0" / ("comparacion_ciyfi_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f"))
    for d in ["revision_nuevas", "correcciones_entrenadas"]:
        (salida / d).mkdir(parents=True, exist_ok=True)
    (salida / "muestra.json").write_text(json.dumps(seleccion, indent=2, ensure_ascii=False), encoding="utf-8")
    configuracion = {"modelos": {k: {"ruta": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                                for k, p in pesos.items()}, "confianza": 0.25, "iou": 0.7,
                     "imgsz": 640, "margen_por_lado": 0.05, "semilla": 20261005,
                     "individuos_excluidos": sorted(excluidos)}
    (salida / "configuracion.json").write_text(json.dumps(configuracion, indent=2), encoding="utf-8")
    modelos = {k: YOLO(str(p)) for k, p in pesos.items()}
    filas, detalle = [], []
    inicio = time.perf_counter()
    for i, r in enumerate(seleccion, 1):
        comparacion = Image.new("RGB", (1280, 1040), "#252525")
        for j, (nombre, modelo) in enumerate(modelos.items()):
            fila = {**r, "modelo": nombre, "estado": "", "detecciones": 0, "confianza": "", "error": ""}
            try:
                with Image.open(dataset / r["ruta_original"]) as fuente:
                    fuente.seek(0)
                    imagen = ImageOps.exif_transpose(fuente).convert("RGB")
                    imagen.load()
                w, h = imagen.size
                resultado = modelo.predict(imagen, device="cpu", imgsz=640, conf=0.25, iou=0.7, verbose=False)[0]
                cajas = resultado.boxes.xyxy.cpu().tolist()
                scores = resultado.boxes.conf.cpu().tolist()
                mejor = max(range(len(scores)), key=lambda k: scores[k]) if scores else None
                detalle.append({**r, "modelo": nombre, "ancho": w, "alto": h,
                                "cajas": cajas, "confianzas": scores, "indice_elegido": mejor})
                marcada = imagen.copy()
                dibujo = ImageDraw.Draw(marcada)
                for k, caja in enumerate(cajas):
                    color = "lime" if k == mejor else "orange"
                    dibujo.rectangle(caja, outline=color, width=max(2, round(max(w, h)/400)))
                    dibujo.text((caja[0]+3, caja[1]+3), f"{scores[k]:.2f}", fill=color)
                fila["detecciones"] = len(cajas)
                recorte = Image.new("RGB", (640, 480), "#252525")
                if mejor is not None:
                    x1, y1, x2, y2 = cajas[mejor]
                    dx, dy = .05*(x2-x1), .05*(y2-y1)
                    recorte = imagen.crop((max(0, math.floor(x1-dx)), max(0, math.floor(y1-dy)),
                                          min(w, math.ceil(x2+dx)), min(h, math.ceil(y2+dy))))
                    fila["estado"] = "UNA" if len(cajas) == 1 else "VARIAS"
                    fila["confianza"] = round(scores[mejor], 5)
                else:
                    fila["estado"] = "SIN_DETECCION"
                comparacion.paste(util.panel(marcada, f"{nombre.upper()} | {r['individuo']} | {fila['estado']}"), (0, j*520))
                comparacion.paste(util.panel(recorte, f"Recorte {nombre}; caja de mayor confianza"), (640, j*520))
            except Exception as e:
                fila.update(estado="ERROR", error=str(e))
                ImageDraw.Draw(comparacion).text((12, j*520+15), f"{nombre}: ERROR {e}", fill="white")
            filas.append(fila)
        carpeta = "revision_nuevas" if r["grupo"] == "nueva" else "correcciones_entrenadas"
        comparacion.save(salida / carpeta / f"{int(r['numero']):03d}_ind{util.identidad(r['individuo']):04d}.jpg", quality=92)
        print(f"{i}/102 | {r['grupo']} | {r['individuo']}", flush=True)
    with (salida / "resultados.csv").open("w", encoding="utf-8-sig", newline="") as f:
        escritor = csv.DictWriter(f, fieldnames=list(filas[0]))
        escritor.writeheader()
        escritor.writerows(filas)
    (salida / "cajas.json").write_text(json.dumps(detalle, indent=2), encoding="utf-8")
    resumen = ["CIYFI - COMPARACION VISUAL", f"Tiempo: {(time.perf_counter()-inicio)/60:.2f} minutos"]
    for nombre in modelos:
        conteos = Counter(f["estado"] for f in filas if f["grupo"] == "nueva" and f["modelo"] == nombre)
        resumen.append(f"100 nuevas - {nombre}: {dict(conteos)}")
    resumen += ["", "100 fotos de individuos ajenos a las anotaciones y a la primera prueba.",
                "Arriba: piloto. Abajo: refuerzo. Izquierda: cajas. Derecha: recorte.",
                "Verde: caja elegida. Naranja: otras detecciones.",
                "010 y 062 en carpeta aparte: ya participaron en entrenamiento; solo comprueban correccion.",
                "No hay mAP independiente sin anotaciones de estas nuevas imagenes.",
                "La confianza y el numero de cajas no confirman acierto ni reidentificacion.",
                "Solapamiento con entrenamiento historico desconocido. Originales intactos."]
    texto = "\n".join(resumen)
    (salida / "RESUMEN.txt").write_text(texto, encoding="utf-8")
    archivos = sorted(p for p in salida.rglob("*") if p.is_file())
    archivo_zip = salida / "COMPARACION_CIYFI.zip"
    with zipfile.ZipFile(archivo_zip, "w", zipfile.ZIP_DEFLATED) as z:
        for p in archivos:
            z.write(p, p.relative_to(salida))
    print("\n" + texto)
    print(f"ZIP PARA COMPARTIR: {archivo_zip}")

if __name__ == "__main__":
    main()
'@ | & $python -
if ($LASTEXITCODE -ne 0) { throw 'La comparacion no termino. Comparte el error de la terminal.' }
