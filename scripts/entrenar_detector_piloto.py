import json
import time
import zipfile
from datetime import datetime
from pathlib import Path
import sys

from ultralytics import YOLO


def metricas(resultado):
    return {
        clave: float(valor)
        for clave, valor in resultado.results_dict.items()
    }


def main():
    proyecto = Path(sys.argv[1]).resolve()

    dataset = (
        proyecto / "datasets3_0"
        / "detector_piloto_20261003_214257_846676"
    )
    configuracion = dataset / "data.yaml"
    pesos_iniciales = (
        proyecto / "recuperacion_yolo/prueba1/weights/best.pt"
    )

    for ruta in (configuracion, pesos_iniciales):
        if not ruta.is_file():
            raise FileNotFoundError(f"No se encuentra: {ruta}")

    for particion, esperado in (("train", 95), ("val", 24)):
        imagenes = list((dataset / "images" / particion).glob("*.jpg"))
        if len(imagenes) != esperado:
            raise RuntimeError(
                f"{particion}: hay {len(imagenes)} imagenes; "
                f"se esperaban {esperado}."
            )
        for imagen in imagenes:
            etiqueta = (
                dataset / "labels" / particion
                / imagen.with_suffix(".txt").name
            )
            if not etiqueta.is_file():
                raise FileNotFoundError(f"Falta etiqueta: {etiqueta}")

    salida = proyecto / "runs3_0" / (
        "detector_piloto_"
        + datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    )
    salida.mkdir(parents=True, exist_ok=False)
    inicio = time.perf_counter()

    modelo = YOLO(str(pesos_iniciales))

    print("\n=== VALIDACION ANTES DEL AJUSTE ===", flush=True)
    antes = modelo.val(
        data=str(configuracion),
        split="val",
        imgsz=640,
        batch=4,
        device="cpu",
        workers=0,
        conf=0.001,
        iou=0.7,
        plots=True,
        project=str(salida),
        name="antes",
    )
    valores_antes = metricas(antes)
    (salida / "metricas_antes.json").write_text(
        json.dumps(valores_antes, indent=2), encoding="utf-8"
    )

    print("\n=== ENTRENAMIENTO PILOTO EN CPU ===", flush=True)
    modelo.train(
        data=str(configuracion),
        epochs=40,
        patience=12,
        imgsz=640,
        batch=4,
        device="cpu",
        workers=0,
        amp=False,
        cache=False,
        optimizer="AdamW",
        lr0=0.0005,
        lrf=0.1,
        freeze=0,
        seed=42,
        deterministic=True,
        mosaic=0.5,
        close_mosaic=10,
        mixup=0.0,
        degrees=15.0,
        translate=0.1,
        scale=0.3,
        fliplr=0.5,
        flipud=0.0,
        save=True,
        plots=True,
        project=str(salida),
        name="entrenamiento",
    )

    carpeta_entrenamiento = Path(modelo.trainer.save_dir)
    mejor_peso = carpeta_entrenamiento / "weights/best.pt"
    if not mejor_peso.is_file():
        raise RuntimeError("No se genero weights/best.pt.")

    print("\n=== VALIDACION DESPUES DEL AJUSTE ===", flush=True)
    mejor_modelo = YOLO(str(mejor_peso))
    despues = mejor_modelo.val(
        data=str(configuracion),
        split="val",
        imgsz=640,
        batch=4,
        device="cpu",
        workers=0,
        conf=0.001,
        iou=0.7,
        plots=True,
        project=str(salida),
        name="despues",
    )
    valores_despues = metricas(despues)

    comparacion = {
        "dataset": str(dataset),
        "pesos_iniciales": str(pesos_iniciales),
        "mejor_peso": str(mejor_peso),
        "minutos_totales": round(
            (time.perf_counter() - inicio) / 60, 2
        ),
        "antes": valores_antes,
        "despues": valores_despues,
        "nota": (
            "Validacion piloto utilizada para seleccionar el modelo. "
            "No es una prueba final independiente."
        ),
    }
    (salida / "comparacion_metricas.json").write_text(
        json.dumps(comparacion, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )

    lineas = [
        "ENTRENAMIENTO PILOTO DEL DETECTOR",
        f"Mejor modelo: {mejor_peso}",
        f"Tiempo total: {comparacion['minutos_totales']} minutos",
        "",
        "METRICAS ANTES / DESPUES",
    ]
    for clave in valores_antes:
        if clave in valores_despues:
            lineas.append(
                f"{clave}: {valores_antes[clave]:.4f} / "
                f"{valores_despues[clave]:.4f}"
            )
    lineas.extend([
        "",
        comparacion["nota"],
        "Tambien deben revisarse visualmente las cajas predichas.",
        "No se modificaron los pesos iniciales ni las anotaciones.",
    ])
    texto = "\n".join(lineas)
    (salida / "RESUMEN.txt").write_text(texto, encoding="utf-8")

    # Incluye el mejor modelo, métricas y gráficos.
    # Omite last.pt y archivos temporales.
    ruta_zip = salida / "RESULTADO_ENTRENAMIENTO.zip"
    archivos = [
        p for p in salida.rglob("*")
        if p.is_file()
        and (
            p.suffix.lower() in {".json", ".txt", ".csv", ".yaml", ".png", ".jpg"}
            or p == mejor_peso
        )
    ]
    with zipfile.ZipFile(
        ruta_zip, "w", compression=zipfile.ZIP_DEFLATED
    ) as archivo:
        for ruta in sorted(archivos):
            archivo.write(
                ruta, arcname=str(ruta.relative_to(salida))
            )

    print("\n" + texto, flush=True)
    print(f"\nZIP PARA COMPARTIR: {ruta_zip}", flush=True)


if __name__ == "__main__":
    main()
