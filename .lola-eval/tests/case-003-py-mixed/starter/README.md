# Dataproc

A data processing pipeline library for batch record transformation.

## Usage

```python
from dataproc.pipeline import process_batch
from dataproc.transform import normalize_record

records = [{"name": "alice", "email": "alice@example.com"}]
processed = process_batch(records)
```
