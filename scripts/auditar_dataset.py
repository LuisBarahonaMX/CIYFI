import argparse
import csv
import hashlib
import re
import time
import zipfile
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageOps


def guardar_csv(ruta, columnas, filas):
    with ruta.open("w", encoding="utf-8-sig", newline="") as archivo:
        escritor = csv.DictWriter(archivo, fieldnames=columnas)
        escritor.writeheader()
        escritor.writerows(filas)


def sha256(ruta):
    resumen = hashlib.sha256()
    with ruta.open("rb") as archivo:
        for bloque in iter(lambda: archivo.read(1024 * 1024), b""):
            resumen.update(bloque)
    return resumen.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--proyecto", required=True)
    args = parser.parse_args()

    dataset = Path(args.dataset).resolve()
    proyecto = Path(args.proyecto).resolve()
    inicio = time.perf_counter()

    salida = proyecto / "reportes3_0" / (
        "auditoria_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    )
    salida.mkdir(parents=True, exist_ok=False)

    extensiones = {
        ".jpg", ".jpeg", ".png", ".bmp", ".tif",
        ".tiff", ".webp", ".gif", ".jfif"
    }

    carpetas = sorted(
        (
            p for p in dataset.iterdir()
            if p.is_dir()
            and re.fullmatch(r"individuo\s+\d+", p.name, re.IGNORECASE)
        ),
        key=lambda p: int(re.search(r"\d+$", p.name).group())
    )

    if not carpetas:
        raise RuntimeError(
            "No se encontraron carpetas con nombre 'individuo N'. "
            "Revisa el nombre real de las carpetas."
        )

    registros = []
    individuos = []
    grupos_hash = defaultdict(list)
    dimensiones = defaultdict(int)

    print(f"Dataset: {dataset}", flush=True)
    print(f"Carpetas de individuos: {len(carpetas)}", flush=True)
    print("Revisando imagenes; no se modificaran los originales.", flush=True)

    for numero_carpeta, carpeta in enumerate(carpetas, 1):
        archivos = sorted(p for p in carpeta.rglob("*") if p.is_file())
        fotos = [p for p in archivos if p.suffix.lower() in extensiones]
        legibles = 0

        for foto in fotos:
            registro = {
                "individuo": carpeta.name,
                "ruta_relativa": str(foto.relative_to(dataset)),
                "extension": foto.suffix.lower(),
                "bytes": "",
                "ancho": "",
                "alto": "",
                "modo": "",
                "formato": "",
                "fotogramas": "",
                "sha256": "",
                "lectura": "ERROR",
                "error": "",
                "observacion": "",
            }
            errores = []
            observaciones = []

            try:
                registro["bytes"] = foto.stat().st_size
                registro["sha256"] = sha256(foto)
                grupos_hash[registro["sha256"]].append(registro)
            except Exception as error:
                errores.append(f"Archivo/hash: {type(error).__name__}: {error}")

            try:
                # Verifica estructura y vuelve a abrir para decodificar.
                with Image.open(foto) as imagen:
                    imagen.verify()

                with Image.open(foto) as imagen:
                    registro["formato"] = imagen.format
                    registro["modo"] = imagen.mode
                    fotogramas = getattr(imagen, "n_frames", 1)
                    registro["fotogramas"] = fotogramas

                    for indice in range(fotogramas):
                        imagen.seek(indice)
                        imagen.load()

                    imagen.seek(0)
                    orientada = ImageOps.exif_transpose(imagen)
                    try:
                        ancho, alto = orientada.size
                    finally:
                        if orientada is not imagen:
                            orientada.close()

                registro["ancho"] = ancho
                registro["alto"] = alto
                registro["lectura"] = "OK"
                legibles += 1
                dimensiones[(ancho, alto)] += 1

                if min(ancho, alto) < 224:
                    observaciones.append("Lado menor inferior a 224 px")
                if fotogramas > 1:
                    observaciones.append("Archivo con varios fotogramas")

            except Exception as error:
                errores.append(f"Imagen: {type(error).__name__}: {error}")

            registro["error"] = " | ".join(errores)
            registro["observacion"] = " | ".join(observaciones)
            registros.append(registro)

            if len(registros) % 100 == 0:
                print(
                    f"Procesadas: {len(registros)} | "
                    f"Tiempo: {time.perf_counter() - inicio:.1f} s",
                    flush=True
                )

        individuos.append({
            "individuo": carpeta.name,
            "imagenes": len(fotos),
            "legibles": legibles,
            "errores_lectura": len(fotos) - legibles,
            "otros_archivos": len(archivos) - len(fotos),
            "imagenes_en_subcarpetas": sum(
                p.parent != carpeta for p in fotos
            ),
            "sin_imagenes": "SI" if not fotos else "NO",
            "carpeta_vacia": "SI" if not archivos else "NO",
        })

        if numero_carpeta % 100 == 0:
            print(
                f"Carpetas revisadas: {numero_carpeta}/{len(carpetas)}",
                flush=True
            )

    duplicados = []
    grupos_duplicados = 0
    grupos_entre_individuos = 0
    copias_adicionales = 0

    for resumen, grupo in grupos_hash.items():
        if len(grupo) < 2:
            continue

        grupos_duplicados += 1
        copias_adicionales += len(grupo) - 1
        identidades = sorted({r["individuo"] for r in grupo})
        cruzado = len(identidades) > 1
        grupos_entre_individuos += int(cruzado)

        for registro in grupo:
            duplicados.append({
                "grupo": grupos_duplicados,
                "sha256": resumen,
                "cantidad": len(grupo),
                "entre_individuos": "SI" if cruzado else "NO",
                "individuos_del_grupo": " | ".join(identidades),
                "individuo": registro["individuo"],
                "ruta_relativa": registro["ruta_relativa"],
            })

    columnas_imagen = [
        "individuo", "ruta_relativa", "extension", "bytes",
        "ancho", "alto", "modo", "formato", "fotogramas",
        "sha256", "lectura", "error", "observacion"
    ]

    guardar_csv(salida / "imagenes.csv", columnas_imagen, registros)
    guardar_csv(
        salida / "individuos.csv",
        [
            "individuo", "imagenes", "legibles", "errores_lectura",
            "otros_archivos", "imagenes_en_subcarpetas",
            "sin_imagenes", "carpeta_vacia"
        ],
        individuos
    )
    guardar_csv(
        salida / "duplicados_exactos.csv",
        [
            "grupo", "sha256", "cantidad", "entre_individuos",
            "individuos_del_grupo", "individuo", "ruta_relativa"
        ],
        duplicados
    )
    guardar_csv(
        salida / "incidencias.csv",
        columnas_imagen,
        [r for r in registros if r["error"] or r["observacion"]]
    )
    guardar_csv(
        salida / "dimensiones.csv",
        ["ancho", "alto", "cantidad"],
        [
            {"ancho": w, "alto": h, "cantidad": n}
            for (w, h), n in sorted(
                dimensiones.items(), key=lambda item: (-item[1], item[0])
            )
        ]
    )

    legibles = sum(r["lectura"] == "OK" for r in registros)
    fallos_hash = sum(not r["sha256"] for r in registros)
    pequenas = sum(
        r["lectura"] == "OK" and min(r["ancho"], r["alto"]) < 224
        for r in registros
    )

    texto = "\n".join([
        "AUDITORIA DEL DATASET TORTUGAS - PROYECTO 3.0",
        f"Fecha: {datetime.now().isoformat(timespec='seconds')}",
        f"Dataset: {dataset}",
        "",
        f"Carpetas de individuos: {len(individuos)}",
        f"Imagenes encontradas: {len(registros)}",
        f"Imagenes con lectura completa correcta: {legibles}",
        f"Imagenes con error de lectura: {len(registros) - legibles}",
        f"Archivos sin hash calculado: {fallos_hash}",
        f"Carpetas sin imagenes: {sum(r['imagenes'] == 0 for r in individuos)}",
        f"Carpetas realmente vacias: {sum(r['carpeta_vacia'] == 'SI' for r in individuos)}",
        f"Individuos con una imagen: {sum(r['imagenes'] == 1 for r in individuos)}",
        f"Individuos con dos o mas imagenes: {sum(r['imagenes'] >= 2 for r in individuos)}",
        f"Otros archivos dentro de individuos: {sum(r['otros_archivos'] for r in individuos)}",
        f"Imagenes en subcarpetas: {sum(r['imagenes_en_subcarpetas'] for r in individuos)}",
        "",
        f"Grupos de duplicados exactos: {grupos_duplicados}",
        f"Copias adicionales dentro de esos grupos: {copias_adicionales}",
        f"Grupos repetidos entre distintos individuos: {grupos_entre_individuos}",
        f"Imagenes legibles con lado menor inferior a 224 px: {pequenas}",
        f"Tiempo total: {time.perf_counter() - inicio:.1f} segundos",
        "",
        "ALCANCE:",
        "Duplicado exacto significa contenido del archivo identico por SHA-256.",
        "No detecta fotos parecidas ni copias recomprimidas.",
        "La dimension inferior a 224 px es una observacion, no un descarte.",
        "Esta auditoria no confirma identidad, nitidez ni visibilidad de la cabeza.",
        "Solo se procesan imagenes dentro de carpetas 'individuo N'.",
        "No se borraron, renombraron ni modificaron imagenes.",
    ])

    (salida / "RESUMEN_AUDITORIA.txt").write_text(texto, encoding="utf-8")

    archivo_zip = salida.with_suffix(".zip")
    with zipfile.ZipFile(
        archivo_zip, "w", compression=zipfile.ZIP_DEFLATED
    ) as comprimido:
        for archivo in sorted(salida.iterdir()):
            comprimido.write(archivo, arcname=archivo.name)

    print("\n" + texto, flush=True)
    print(f"\nReportes: {salida}", flush=True)
    print(f"\nZIP PARA COMPARTIR: {archivo_zip}", flush=True)


if __name__ == "__main__":
    main()
