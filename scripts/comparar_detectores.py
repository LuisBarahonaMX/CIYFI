import csv
import hashlib
import math
import random
import sys
import time
import zipfile
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from statistics import median

from PIL import Image, ImageDraw, ImageOps
from ultralytics import YOLO


def leer_csv(ruta):
    with ruta.open(encoding="utf-8-sig", newline="") as archivo:
        return list(csv.DictReader(archivo))


def escribir_csv(ruta, columnas, filas):
    with ruta.open("w", encoding="utf-8-sig", newline="") as archivo:
        escritor = csv.DictWriter(archivo, fieldnames=columnas)
        escritor.writeheader()
        escritor.writerows(filas)


def cargar_imagen(ruta):
    with Image.open(ruta) as imagen:
        imagen.seek(0)
        imagen.load()
        orientada = ImageOps.exif_transpose(imagen)
        try:
            return orientada.convert("RGB")
        finally:
            if orientada is not imagen:
                orientada.close()


def panel(imagen, titulo, detalle=""):
    fondo = Image.new("RGB", (320, 370), "white")
    dibujo = ImageDraw.Draw(fondo)
    dibujo.text((8, 8), titulo, fill="black")
    dibujo.text((8, 28), detalle, fill="black")
    if imagen is not None:
        vista = ImageOps.contain(imagen, (304, 300))
        fondo.paste(
            vista,
            ((320 - vista.width) // 2, 62 + (300 - vista.height) // 2)
        )
    return fondo


proyecto = Path(sys.argv[1]).resolve()
dataset = proyecto / "tortugascm (1033 ind con muchas fotos)"
auditoria = proyecto / "reportes3_0" / "auditoria_20261003_160437_465195"

rutas_modelos = {
    "baseline": proyecto / "recuperacion_yolo" / "baseline_detector"
        / "turtle_head_detector_baseline_best.pt",
    "prueba1": proyecto / "recuperacion_yolo" / "prueba1"
        / "weights" / "best.pt",
}

for ruta in [dataset, auditoria / "imagenes.csv", *rutas_modelos.values()]:
    if not ruta.exists():
        raise FileNotFoundError(f"No se encuentra: {ruta}")

filas = leer_csv(auditoria / "imagenes.csv")
rng = random.Random(42)

# Muestra intencional: 10 pequeñas, hasta 6 MPO pendientes
# que ya pasaron la revisión anterior, y otros individuos.
pequenas = [
    f for f in filas
    if f["lectura"] == "OK"
    and min(int(f["ancho"]), int(f["alto"])) < 224
]
mpo = [
    f for f in filas
    if f["lectura"] != "OK" and f["formato"] == "MPO"
]

seleccion = []
usadas = set()

def agregar(fila, motivo):
    if fila["ruta_relativa"] not in usadas:
        seleccion.append({**fila, "motivo": motivo})
        usadas.add(fila["ruta_relativa"])

for fila in pequenas[:10]:
    agregar(fila, "dimension_pequena")

for fila in rng.sample(mpo, min(6, len(mpo))):
    agregar(fila, "MPO_revisado")

identidades_usadas = {f["individuo"] for f in seleccion}
por_individuo = defaultdict(list)
for fila in filas:
    if (
        fila["lectura"] == "OK"
        and fila["individuo"] not in identidades_usadas
        and fila["ruta_relativa"] not in usadas
    ):
        por_individuo[fila["individuo"]].append(fila)

identidades = sorted(por_individuo)
rng.shuffle(identidades)
for identidad in identidades:
    if len(seleccion) >= 40:
        break
    agregar(rng.choice(por_individuo[identidad]), "otro_individuo")

salida = proyecto / "reportes3_0" / (
    "comparacion_detectores_"
    + datetime.now().strftime("%Y%m%d_%H%M%S_%f")
)
salida.mkdir(parents=True, exist_ok=False)
(salida / "comparaciones").mkdir()
(salida / "recortes224").mkdir()

escribir_csv(
    salida / "muestra.csv",
    ["numero", "individuo", "ruta_relativa", "motivo"],
    [
        {
            "numero": n,
            "individuo": f["individuo"],
            "ruta_relativa": f["ruta_relativa"],
            "motivo": f["motivo"],
        }
        for n, f in enumerate(seleccion, 1)
    ]
)

modelos = {}
informacion_modelos = []
for nombre, ruta in rutas_modelos.items():
    print(f"Cargando {nombre}: {ruta}", flush=True)
    modelo = YOLO(str(ruta))
    if modelo.task != "detect":
        raise RuntimeError(f"{nombre} no es un modelo de deteccion.")

    print(f"Clases: {modelo.names}", flush=True)
    if len(modelo.names) != 1:
        raise RuntimeError(
            f"{nombre} tiene varias clases; debemos identificar la clase cabeza."
        )

    # Calentamiento; no se incluye en los tiempos de la muestra.
    dummy = Image.new("RGB", (640, 640), (128, 128, 128))
    for _ in range(2):
        modelo.predict(
            source=dummy, device="cpu", imgsz=640,
            conf=0.25, verbose=False
        )
    dummy.close()
    modelos[nombre] = modelo
    informacion_modelos.append(
        f"{nombre}: {ruta}\n"
        f"SHA256: {hashlib.sha256(ruta.read_bytes()).hexdigest()}\n"
        f"Clases: {modelo.names}"
    )

resultados = []
for numero, fila in enumerate(seleccion, 1):
    identificador = f"{numero:03d}"
    print(
        f"[{numero}/{len(seleccion)}] {fila['ruta_relativa']}",
        flush=True
    )

    try:
        imagen = cargar_imagen(dataset / fila["ruta_relativa"])
    except Exception as error:
        for nombre in modelos:
            resultados.append({
                "numero": numero,
                "modelo": nombre,
                "individuo": fila["individuo"],
                "ruta_relativa": fila["ruta_relativa"],
                "estado": "ERROR_LECTURA",
                "error": str(error),
            })
        continue

    w, h = imagen.size
    paneles = [panel(imagen, "Original", fila["individuo"])]

    for nombre, modelo in modelos.items():
        registro = {
            "numero": numero,
            "modelo": nombre,
            "individuo": fila["individuo"],
            "ruta_relativa": fila["ruta_relativa"],
            "estado": "",
            "detecciones": 0,
            "confianza": "",
            "segundos_predict": "",
            "x1": "", "y1": "", "x2": "", "y2": "",
            "fraccion_area_caja": "",
            "recorte_ancho": "", "recorte_alto": "",
            "error": "",
        }

        try:
            inicio = time.perf_counter()
            resultado = modelo.predict(
                source=imagen, device="cpu", imgsz=640,
                conf=0.25, verbose=False
            )[0]
            registro["segundos_predict"] = round(
                time.perf_counter() - inicio, 4
            )

            cajas = resultado.boxes
            registro["detecciones"] = len(cajas)
            anotada = imagen.copy()
            recorte = None

            if len(cajas):
                indice = int(cajas.conf.argmax().item())
                confianza = float(cajas.conf[indice].item())
                x1, y1, x2, y2 = cajas.xyxy[indice].tolist()
                registro.update({
                    "estado": "DETECTADO",
                    "confianza": round(confianza, 5),
                    "x1": round(x1, 2), "y1": round(y1, 2),
                    "x2": round(x2, 2), "y2": round(y2, 2),
                    "fraccion_area_caja": round(
                        (x2 - x1) * (y2 - y1) / (w * h), 5
                    ),
                })

                dibujo = ImageDraw.Draw(anotada)
                for j, caja in enumerate(cajas.xyxy.tolist()):
                    dibujo.rectangle(
                        caja,
                        outline="lime" if j == indice else "orange",
                        width=max(2, round(min(w, h) / 250))
                    )

                # Margen del 10 % por lado; conserva proporciones.
                mx, my = (x2 - x1) * 0.10, (y2 - y1) * 0.10
                limites = (
                    max(0, math.floor(x1 - mx)),
                    max(0, math.floor(y1 - my)),
                    min(w, math.ceil(x2 + mx)),
                    min(h, math.ceil(y2 + my)),
                )
                if limites[2] <= limites[0] or limites[3] <= limites[1]:
                    raise ValueError("Caja de recorte vacia.")

                recorte = imagen.crop(limites)
                registro["recorte_ancho"], registro["recorte_alto"] = recorte.size
                normalizado = ImageOps.pad(
                    recorte, (224, 224),
                    method=Image.Resampling.LANCZOS,
                    color=(0, 0, 0)
                )
                normalizado.save(
                    salida / "recortes224"
                    / f"{identificador}_{nombre}.png"
                )
                normalizado.close()
                detalle = f"Conf: {confianza:.3f} | Cajas: {len(cajas)}"
            else:
                registro["estado"] = "SIN_DETECCION"
                detalle = "Sin deteccion"

            paneles.append(panel(anotada, nombre, detalle))
            paneles.append(panel(recorte, f"Recorte {nombre}"))
            anotada.close()
            if recorte is not None:
                recorte.close()

        except Exception as error:
            registro["estado"] = "ERROR"
            registro["error"] = f"{type(error).__name__}: {error}"
            paneles.append(panel(None, nombre, "ERROR: ver CSV"))
            paneles.append(panel(None, f"Recorte {nombre}"))

        resultados.append(registro)

    comparacion = Image.new("RGB", (320 * len(paneles), 370), "white")
    for columna, vista in enumerate(paneles):
        comparacion.paste(vista, (320 * columna, 0))
        vista.close()
    comparacion.save(
        salida / "comparaciones" / f"{identificador}.jpg",
        quality=90
    )
    comparacion.close()
    imagen.close()

columnas = [
    "numero", "modelo", "individuo", "ruta_relativa", "estado",
    "detecciones", "confianza", "segundos_predict",
    "x1", "y1", "x2", "y2", "fraccion_area_caja",
    "recorte_ancho", "recorte_alto", "error"
]
escribir_csv(salida / "resultados.csv", columnas, resultados)

resumen = [
    "COMPARACION DE DETECTORES - PROYECTO 3.0",
    f"Fotografias seleccionadas: {len(seleccion)}",
    "CPU | imgsz=640 | confianza minima=0.25 | margen=10% por lado",
    "",
]
for nombre in modelos:
    registros = [r for r in resultados if r["modelo"] == nombre]
    tiempos = [
        r["segundos_predict"] for r in registros
        if isinstance(r.get("segundos_predict"), (int, float))
    ]
    resumen.extend([
        nombre.upper(),
        f"Con deteccion: {sum(r['estado'] == 'DETECTADO' for r in registros)}",
        f"Sin deteccion: {sum(r['estado'] == 'SIN_DETECCION' for r in registros)}",
        f"Errores: {sum(r['estado'].startswith('ERROR') for r in registros)}",
    ])
    if tiempos:
        promedio = sum(tiempos) / len(tiempos)
        resumen.extend([
            f"Promedio predict: {promedio:.3f} segundos/foto",
            f"Mediana predict: {median(tiempos):.3f} segundos/foto",
            f"Proyeccion de predict para 6604 fotos: {promedio * 6604 / 60:.1f} minutos",
        ])
    resumen.append("")

resumen.extend([
    "La proyeccion excluye lectura y escritura de archivos.",
    "La muestra es intencional; no representa una evaluacion estadistica.",
    "No se calculan precision, recall ni mAP porque no hay cajas de referencia.",
    "Confianza alta no garantiza recorte correcto.",
    "Verde: caja elegida. Naranja: otras detecciones.",
    "El recorte elegido corresponde a la caja de mayor confianza.",
    "Los originales permanecen intactos.",
    "",
    *informacion_modelos,
])
texto = "\n".join(resumen)
(salida / "RESUMEN.txt").write_text(texto, encoding="utf-8")

escribir_csv(
    salida / "revision_visual.csv",
    [
        "numero", "modelo", "individuo", "ruta_relativa",
        "cabeza_completa", "escamas_visibles", "recorte_util", "comentario"
    ],
    [
        {
            "numero": r["numero"], "modelo": r["modelo"],
            "individuo": r["individuo"],
            "ruta_relativa": r["ruta_relativa"],
            "cabeza_completa": "", "escamas_visibles": "",
            "recorte_util": "", "comentario": ""
        }
        for r in resultados
    ]
)

ruta_zip = salida.with_suffix(".zip")
with zipfile.ZipFile(
    ruta_zip, "w", compression=zipfile.ZIP_DEFLATED
) as archivo:
    for ruta in sorted(salida.rglob("*")):
        if ruta.is_file():
            archivo.write(ruta, arcname=str(ruta.relative_to(salida)))

print("\n" + texto)
print(f"\nCARPETA DE RESULTADOS: {salida}")
print(f"\nZIP PARA COMPARTIR: {ruta_zip}")
