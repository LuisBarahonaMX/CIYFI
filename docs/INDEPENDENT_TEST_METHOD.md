# Independent Test Construction

The final CIYFI detector test contains:

- 50 images
- 50 different sea turtle individuals
- 50 unique files
- 50 unique SHA-256 hashes

The identities were audited against individuals previously used during:

- pilot development
- exploratory evaluation
- reinforcement
- previous testing

Historical overlaps identified during candidate selection were replaced
before the final test was created.

The final 50 images were manually annotated using the same annotation
criterion used during detector development.

The reinforced model was frozen before evaluation and was not trained,
fine-tuned or adjusted using these 50 test images.
