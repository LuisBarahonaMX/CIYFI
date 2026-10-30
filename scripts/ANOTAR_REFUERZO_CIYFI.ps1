$ErrorActionPreference = 'Stop'
$proyecto = 'C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0'
$python = Join-Path $proyecto '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'No se encontro Python del proyecto.' }
@'
import csv
import importlib.util
import json
import tkinter as tk
from pathlib import Path
from PIL import Image, ImageOps

proyecto = Path(r"C:\Users\cancu\Pictures\PROYECTO TORTUGAS\zproyecto3_0")
dataset = proyecto / "tortugascm (1033 ind con muchas fotos)"
herramienta = proyecto / "scripts3_0/anotador_cabezas.py"
base = proyecto / "anotaciones3_0/refuerzo_detector"
manifest = base / "manifest.json"
# Numeros de la prueba de 100, seleccionados tras la revision visual.
# Los dos errores principales van primero. El lote incluye ejemplos correctos dificiles.
numeros = [10, 62, 88, 37, 18, 21, 25, 31, 49, 54, 61, 70, 76, 79, 82, 84,
           86, 97, 98, 100, 6, 8, 9, 16, 17, 26, 29, 35, 39, 42, 47, 50,
           67, 71, 74, 77, 81, 83, 93, 94]
if not herramienta.is_file():
    raise FileNotFoundError(f"Falta la herramienta de anotacion: {herramienta}")
spec = importlib.util.spec_from_file_location("anotador_local", herramienta)
modulo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(modulo)

if manifest.exists():
    registros = json.loads(manifest.read_text(encoding="utf-8-sig"))
    if len(registros) != 40 or [int(r.get("numero_prueba100", -1)) for r in registros] != numeros:
        raise RuntimeError("La carpeta de refuerzo existente no coincide con este lote. No se sobrescribio.")
    for r in registros:
        if not (base / "images" / r["archivo"]).is_file():
            raise FileNotFoundError(f"Falta la copia {r['archivo']}; conserva las anotaciones y comparte el error.")
    print("Retomando las anotaciones guardadas.", flush=True)
else:
    reportes = sorted((proyecto / "reportes3_0").glob("prueba_ciyfi100_*/resultados.csv"), reverse=True)
    if not reportes:
        raise FileNotFoundError("No se encontro resultados.csv de la prueba de 100 fotografias.")
    filas = list(csv.DictReader(reportes[0].open(encoding="utf-8-sig", newline="")))
    por_numero = {int(r["numero"]): r for r in filas}
    if len(filas) != 100 or len(por_numero) != 100:
        raise ValueError("La prueba seleccionada no contiene 100 registros distintos.")
    if por_numero[10]["individuo"] != "individuo 0884" or por_numero[62]["individuo"] != "individuo 0139":
        raise ValueError("La muestra encontrada no coincide con la prueba que revisamos.")
    (base / "images").mkdir(parents=True, exist_ok=True)
    if (base / "anotaciones.json").exists():
        raise RuntimeError("Hay anotaciones sin manifest. No se modificaron; comparte el error.")
    registros = []
    for n, numero in enumerate(numeros, 1):
        fila = por_numero[numero]
        ruta = dataset / fila["ruta_original"]
        with Image.open(ruta) as fuente:
            fuente.seek(0)
            imagen = ImageOps.exif_transpose(fuente).convert("RGB")
            imagen.load()
        ancho, alto = imagen.size
        imagen.thumbnail((1600, 1600), Image.Resampling.LANCZOS)
        archivo = f"{n:03d}.jpg"
        imagen.save(base / "images" / archivo, quality=95)
        registros.append({"numero": str(n), "individuo": fila["individuo"],
                          "ruta_original": fila["ruta_original"], "archivo": archivo,
                          "ancho_original": ancho, "alto_original": alto,
                          "ancho_copia": imagen.width, "alto_copia": imagen.height,
                          "numero_prueba100": numero})
        imagen.close()
        print(f"Preparada {n}/40 | prueba100: {numero:03d} | {fila['individuo']}", flush=True)
    modulo.escribir_json(manifest, registros)
    modulo.escribir_json(base / "origen_refuerzo.json", {
        "reporte": str(reportes[0]), "numeros_prueba100": numeros,
        "uso": "Refuerzo de entrenamiento. Estas fotos ya no son prueba independiente."})

print(f"\nLote: {base}\nAbriendo anotador con 40 fotos. Originales intactos.", flush=True)
print("Las fotos 001 y 002 del lote corresponden a los errores 010 y 062 de la prueba.", flush=True)
root = tk.Tk()
app = modulo.Anotador(root, base, registros)
root.title("CiyFi - Refuerzo del detector - 40 fotos")
root.mainloop()
'@ | & $python -
if ($LASTEXITCODE -ne 0) { throw 'No se pudo completar. Comparte el error de la terminal.' }
