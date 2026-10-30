# CIYFI - Independent Detector Evaluation

## Test independiente

- Images: 50
- Individuals: 50
- Ground Truth boxes: 50
- Model: frozen reinforced YOLOv8n
- Input resolution: 640 px
- Batch: 1
- Device: NVIDIA GeForce 940MX 2 GB

## Official Ultralytics metrics

- Precision: 0.994
- Recall: 0.980
- mAP50: 0.975
- mAP50-95: 0.777

## Performance

- Preprocess: 2.8 ms/image
- Inference: 37.1 ms/image
- Postprocess: 2.2 ms/image
- Approximate total evaluation time: 9.3 seconds for 50 images

## Important

These metrics correspond to the official independent Ultralytics validation.

The separate error-analysis counts were calculated using a fixed
confidence threshold of 0.25 and IoU >= 0.50 for visual review.
They must not be interpreted as an alternative calculation of mAP.
