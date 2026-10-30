# CIYFI Detector Model Card

## Modelo

YOLOv8n reforzado para deteccion de cabezas de tortuga marina.

## Clase

0 - cabeza_tortuga

## Desarrollo

- 95 imagenes train iniciales
- 24 imagenes validation
- 40 casos dificiles incorporados al entrenamiento
- 135 imagenes train finales
- 24 imagenes validation
- 159 imagenes de desarrollo

## Configuracion

- Input: 640 px
- Optimizer: AdamW
- Epochs maximas: 40
- Batch: 4
- Patience: 12
- Learning rate refuerzo: 0.0003

## Validacion de desarrollo

- Precision: 99.70 %
- Recall: 95.83 %
- mAP50: 99.34 %
- mAP50-95: 78.59 %

La evaluacion independiente de 50 individuos se incorporara
posteriormente desde la computadora 2.
