\# CIYFI



\## Detección de cabezas de tortuga marina como etapa inicial para la reidentificación de individuos



CIYFI es un proyecto de \*\*visión por computadora aplicado a conservación de fauna marina\*\* orientado a desarrollar una base técnica para la futura reidentificación automática de tortugas marinas a partir de características visuales de su cabeza y patrones de escamas.



La primera etapa del proyecto se enfoca en localizar correctamente la cabeza de la tortuga utilizando \*\*YOLOv8n\*\*, ya que una detección consistente de esta región es necesaria antes de comparar individuos mediante embeddings y búsqueda por similitud.



\---



\## Objetivo



Diseñar, entrenar y evaluar un detector de cabezas de tortuga marina que permita obtener regiones de interés consistentes para una futura etapa de reidentificación individual.



El proyecto separa claramente dos procesos:



```text

DETECCIÓN

Imagen

&#x20; ↓

YOLOv8n

&#x20; ↓

Cabeza de tortuga

&#x20; ↓

Recorte de región de interés





REIDENTIFICACIÓN

Recorte de cabeza

&#x20; ↓

Embedding

&#x20; ↓

Normalización

&#x20; ↓

FAISS

&#x20; ↓

Top-1 / Top-5

```



> El resultado principal validado actualmente corresponde a la \*\*detección de cabeza\*\*.  

> La reidentificación individual continúa como una etapa experimental y de desarrollo posterior.



\---



\# Resultados principales



El detector reforzado fue evaluado sobre un conjunto independiente compuesto por:



\- \*\*50 imágenes\*\*

\- \*\*50 individuos diferentes\*\*

\- \*\*50 anotaciones Ground Truth\*\*

\- \*\*50 archivos únicos\*\*

\- \*\*50 hashes SHA-256 únicos\*\*



\### Evaluación independiente



| Métrica | Resultado |

|---|---:|

| Precision | \*\*99.4 %\*\* |

| Recall | \*\*98.0 %\*\* |

| mAP50 | \*\*97.5 %\*\* |

| mAP50–95 | \*\*77.7 %\*\* |



La evaluación independiente mantuvo un rendimiento cercano al observado durante la fase de desarrollo.



\---



\## Comparación con desarrollo



| Conjunto | Precision | Recall | mAP50 | mAP50–95 |

|---|---:|---:|---:|---:|

| Piloto — 24 val | 96.0 % | 99.97 % | 99.34 % | 77.16 % |

| Refuerzo — 24 val | 99.70 % | 95.83 % | 99.34 % | 78.59 % |

| \*\*Test independiente — 50\*\* | \*\*99.4 %\*\* | \*\*98.0 %\*\* | \*\*97.5 %\*\* | \*\*77.7 %\*\* |



\---



\# Dataset de desarrollo



El corpus general fue auditado antes del entrenamiento.



\### Corpus auditado



\- \*\*1,033 individuos / carpetas\*\*

\- \*\*6,604 fotografías\*\*

\- \*\*6,272 imágenes válidas\*\* en una etapa previa de auditoría



\### Desarrollo del detector



\#### Modelo piloto



```text

119 imágenes

├── 95 train

└── 24 validation

```



\#### Refuerzo



Se añadieron \*\*40 casos difíciles exclusivamente al entrenamiento\*\*.



```text

159 imágenes de desarrollo

├── 135 train

└── 24 validation

```



Las 24 imágenes de validación se mantuvieron durante el proceso de desarrollo para permitir una comparación consistente.



\---



\# Flujo metodológico



```text

Corpus original

&#x20;     ↓

Auditoría de imágenes

&#x20;     ↓

Selección de conjuntos

&#x20;     ↓

Anotación manual

&#x20;     ↓

Entrenamiento YOLOv8n

&#x20;     ↓

Modelo piloto

&#x20;     ↓

Casos difíciles

&#x20;     ↓

Modelo reforzado

&#x20;     ↓

Congelación de best.pt

&#x20;     ↓

Test independiente

&#x20;     ↓

Evaluación

&#x20;     ↓

Análisis de errores

```



\---



\# Detector YOLOv8n



El detector aprende a localizar una única clase:



```text

Clase 0 = cabeza\_tortuga

```



Flujo conceptual:



```text

Imagen 640 × 640

&#x20;     ↓

Backbone CNN

&#x20;     ↓

Extracción de características

&#x20;     ↓

Fusión multiescala

&#x20;     ↓

Detection Head

&#x20;     ↓

Bounding Box

(x, y, width, height)

&#x20;     +

confianza

```



YOLOv8n \*\*no identifica todavía al individuo\*\*. Su función actual es encontrar correctamente la región de la cabeza.



\---



\# Configuración de entrenamiento



\### Modelo



```text

YOLOv8n

```



\### Configuración principal



| Parámetro | Valor |

|---|---:|

| Input | 640 px |

| Batch | 4 |

| Épocas máximas | 40 |

| Optimizer | AdamW |

| Patience | 12 |

| Learning rate piloto | 0.0005 |

| Learning rate refuerzo | 0.0003 |



El entrenamiento reforzado utilizó \*\*early stopping\*\* y finalizó alrededor de la época 23.



\---



\# Modelo disponible



El repositorio incluye el peso del detector reforzado:



```text

models/best.pt

```



También se incluye:



```text

models/MODEL\_CARD.md

models/SHA256.txt

```



\### SHA-256 del modelo



```text

71C02F61F4EB24B36A48213466D9FF1DBD9D50B1FD431C5A708053F3CCAA2ED5

```



Este hash permite verificar que se está utilizando exactamente el mismo modelo empleado en la evaluación independiente.



\---



\# Instalación



Se recomienda utilizar Python 3.10 o superior.



Clonar el repositorio:



```bash

git clone https://github.com/LuisBarahonaMX/CIYFI.git

cd CIYFI

```



Crear un entorno virtual:



\### Windows



```bash

python -m venv .venv

.venv\\Scripts\\activate

```



\### Linux



```bash

python3 -m venv .venv

source .venv/bin/activate

```



Instalar las principales dependencias:



```bash

pip install ultralytics torch torchvision opencv-python numpy pillow pandas matplotlib

```



Para la futura etapa de búsqueda por similitud también puede utilizarse:



```bash

pip install faiss-cpu

```



\---



\# Uso rápido del detector



Ejemplo básico en Python:



```python

from ultralytics import YOLO



model = YOLO("models/best.pt")



results = model.predict(

&#x20;   source="tortuga.jpg",

&#x20;   imgsz=640,

&#x20;   conf=0.25

)



for result in results:

&#x20;   print(result.boxes)

```



También puede utilizarse desde la CLI de Ultralytics:



```bash

yolo detect predict \\

model=models/best.pt \\

source=tortuga.jpg \\

imgsz=640 \\

conf=0.25

```



\---



\# Evaluación independiente



El conjunto final de prueba fue construido después del desarrollo del detector.



Antes de utilizarlo se verificó:



\- independencia por identidad;

\- independencia respecto a piloto y refuerzo;

\- hashes SHA-256;

\- archivos únicos;

\- anotación manual consistente;

\- modelo congelado antes de la prueba.



El modelo \*\*no fue entrenado ni ajustado utilizando las 50 imágenes del test independiente\*\*.



La configuración y documentación se encuentran en:



```text

configs/test.yaml

docs/INDEPENDENT\_TEST\_METHOD.md

evaluation/

```



\---



\# Análisis de errores



Además de las métricas oficiales de Ultralytics se realizó un análisis visual utilizando:



```text

Confidence threshold = 0.25

IoU matching threshold = 0.50

```



Resultados:



| Análisis | Resultado |

|---|---:|

| True Positives | 48 |

| False Negatives | 2 |

| FP adicionales | 5 |

| Sin detección | 1 |

| Imágenes con múltiples predicciones | 3 |

| IoU promedio | 0.8468 |



Distribución del IoU:



```text

IoU < 0.50       → 2 imágenes

IoU 0.50–0.75    → 2 imágenes

IoU 0.75–0.90    → 26 imágenes

IoU ≥ 0.90       → 20 imágenes

```



Por lo tanto:



```text

46 / 50 imágenes

obtuvieron IoU ≥ 0.75

```



Casos de interés:



```text

008 → FN / sin detección

031 → TP + FP adicional

041 → TP + FP adicional

042 → TP + FP adicional

049 → FN + FP

```



> Estos conteos pertenecen a un análisis visual con umbral fijo y \*\*no sustituyen el cálculo oficial de mAP realizado por Ultralytics\*\*.



\---



\# Hardware y reproducibilidad



El proyecto fue desarrollado utilizando dos computadoras diferentes.



\## Computadora 1 — entrenamiento



```text

CPU:

AMD Ryzen 5 4500U



RAM:

\~15.23 GB



GPU:

AMD integrada



CUDA:

No

```



Utilizada para:



\- auditoría;

\- preparación de datos;

\- entrenamiento piloto;

\- entrenamiento reforzado.



\---



\## Computadora 2 — evaluación independiente



```text

GPU:

NVIDIA GeForce 940MX



VRAM:

2 GB



Python:

3.10.11



PyTorch:

2.5.1+cu118



Ultralytics:

8.4.174



CUDA:

Disponible

```



Rendimiento aproximado:



```text

Preprocess   → 2.8 ms / imagen

Inference    → 37.1 ms / imagen

Postprocess  → 2.2 ms / imagen



50 imágenes ≈ 9.3 segundos

```



\---



\# Estructura del repositorio



```text

CIYFI/

│

├── configs/

│   └── configuraciones de evaluación

│

├── docs/

│   ├── metodología

│   ├── entorno experimental

│   └── documentación técnica

│

├── error\_analysis/

│   ├── CSV

│   ├── resumen

│   └── análisis de errores

│

├── evaluation/

│   ├── resultados

│   └── ground\_truth\_labels/

│

├── metadata/

│   └── manifiestos y metadatos

│

├── models/

│   ├── best.pt

│   ├── MODEL\_CARD.md

│   └── SHA256.txt

│

├── results/

│   └── resultados de desarrollo

│

├── scripts/

│   └── scripts de entrenamiento y evaluación

│

├── README\_COMPU1.md

├── README\_COMPU2.md

└── README.md

```



\---



\# Segunda etapa: reidentificación



Una vez detectada la cabeza se puede construir un pipeline de reidentificación:



```text

Imagen

&#x20; ↓

YOLOv8n

&#x20; ↓

Recorte de cabeza

&#x20; ↓

Extractor de características

&#x20; ↓

Embedding

&#x20; ↓

Normalización L2

&#x20; ↓

FAISS

&#x20; ↓

Top-1 / Top-5

```



En el desarrollo experimental de CIYFI se han trabajado representaciones de \*\*256 dimensiones\*\* y búsqueda mediante similitud.



La meta es que fotografías pertenecientes al mismo individuo produzcan representaciones cercanas dentro del espacio vectorial.



\---



\# Evolución futura



Una siguiente mejora del sistema consiste en pasar de extracción de características a \*\*Metric Learning\*\*:



```text

FASE ACTUAL



Feature extraction

&#x20;       +

&#x20;     FAISS



&#x20;       ↓



FUTURA ETAPA



P-K Sampling

&#x20;       +

Batch-hard Triplet Mining

&#x20;       +

Triplet Loss



&#x20;       ↓



Embeddings optimizados

para identidad individual

```



Con este enfoque se busca:



```text

Mismo individuo

&#x20;     ↓

Embeddings cercanos





Individuos diferentes

&#x20;     ↓

Embeddings separados

```



\---



\# Aplicaciones potenciales



CIYFI busca contribuir al desarrollo de herramientas para:



\- monitoreo de tortugas marinas;

\- seguimiento visual de individuos;

\- apoyo a investigadores y especialistas;

\- reducción del esfuerzo manual de revisión;

\- organización de grandes colecciones fotográficas;

\- construcción de herramientas de reidentificación asistida por IA;

\- sistemas web o móviles para trabajo de campo.



\---



\# Limitaciones



El trabajo actual presenta varias limitaciones importantes:



\- el resultado principal corresponde a detección de cabeza, no a identificación completa;

\- el test independiente contiene 50 individuos;

\- las condiciones de campo pueden ser más variables;

\- la reidentificación todavía requiere una evaluación independiente específica;

\- es necesario aumentar la diversidad temporal, espacial y visual de los datos.



\---



\# Dataset de referencia



Entre los recursos utilizados dentro del desarrollo y comparación del proyecto se encuentra:



\*\*SeaTurtleID2022\*\*



L. Adam, V. Čermák, K. Papafitsoros y L. Picek.



> \*SeaTurtleID2022: A long-span dataset for reliable sea turtle re-identification.\*



Winter Conference on Applications of Computer Vision — WACV 2024.



Dataset:



https://www.kaggle.com/datasets/wildlifedatasets/seaturtleid2022



CIYFI no redistribuye automáticamente datasets externos; se recomienda obtenerlos desde sus fuentes originales respetando sus respectivas licencias.



\---



\# Tecnologías



```text

Python

PyTorch

Ultralytics

YOLOv8n

OpenCV

NumPy

Pandas

Matplotlib

FAISS

Git

GitHub

```



\---



\# Autor



\*\*Pedro Luis Pérez Barahona\*\*



Ingeniería en Datos e Inteligencia Organizacional  

Universidad del Caribe  

Quintana Roo, México



GitHub:



https://github.com/LuisBarahonaMX



\---



\# Estado del proyecto



```text

\[✓] Auditoría del corpus

\[✓] Anotación

\[✓] Detector piloto

\[✓] Detector reforzado

\[✓] Modelo best.pt

\[✓] Test independiente

\[✓] Análisis de errores

\[✓] Publicación de artefactos reproducibles



\[→] Desarrollo de reidentificación individual

\[→] Metric Learning

\[→] Evaluación Top-1 / Top-5 ampliada

\[→] Integración en aplicación

```



\---



\## CIYFI



\*\*Detectar correctamente la cabeza es el primer paso para intentar reconocer correctamente al individuo.\*\*

