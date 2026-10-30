# CIYFI - Computer 2

This package contains the independent evaluation stage of the CIYFI
sea turtle head detector.

Repository:

https://github.com/LuisBarahonaMX/CIYFI

## Included stage

1. Construction of an independent test
2. Identity independence verification
3. SHA-256 file verification
4. Manual Ground Truth annotation
5. Evaluation of the frozen reinforced YOLOv8n detector
6. Official detector metrics
7. Fixed-threshold visual error analysis

## Independent test

50 images from 50 different individuals.

## Results

- Precision: 99.4 %
- Recall: 98.0 %
- mAP50: 97.5 %
- mAP50-95: 77.7 %

## Relationship with Computer 1

Computer 1 contains detector development and training.

Computer 2 contains the independent final evaluation.
