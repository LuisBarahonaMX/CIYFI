# CIYFI - Error Analysis

Visual review configuration:

- Confidence threshold: 0.25
- Matching threshold: IoU >= 0.50

Results:

- True Positives: 48
- False Negatives: 2
- Additional False Positives: 5
- Images with no detection: 1
- Images with multiple predictions: 3
- Mean best-prediction IoU: 0.8468

IoU distribution:

- IoU < 0.50: 2
- IoU 0.50-0.75: 2
- IoU 0.75-0.90: 26
- IoU >= 0.90: 20

Therefore:

46 of 50 images obtained IoU >= 0.75.

Important cases:

- 008.jpg -> FN, no detection
- 031.jpg -> TP + additional FP
- 041.jpg -> TP + additional FP
- 042.jpg -> TP + additional FP
- 049.jpg -> FN + FP

Important:

These values belong to a fixed-threshold visual error analysis.
They are different from the official mAP computation performed by Ultralytics.
