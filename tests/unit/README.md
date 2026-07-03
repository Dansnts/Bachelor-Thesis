# Unit tests

Fast, offline unit tests for the pipeline's Python code. **No GPU, no model, no
cluster, no MinIO** — Kubernetes and S3 are mocked, and `ray`/`torch` are
stubbed at import time (see `conftest.py`). The whole suite runs in ~1 s.

## Run

```sh
# one-time: create the test venv and install the deps
uv venv .venv
uv pip install --python .venv/bin/python -r tests/unit/requirements-test.txt

# run
.venv/bin/python -m pytest tests/unit -q
```

Expected: **115 passed, 7 xfailed**.

## What is covered

| File | Target | Focus |
|------|--------|-------|
| `test_api_validation.py`  | `api/python/main.py` | request validation — "everything a user can do wrong" |
| `test_api_endpoints.py`   | `api/python/main.py` | endpoint behaviour + failure paths (404, 502, cluster refusal) |
| `test_api_helpers.py`     | `api/python/main.py` | pure helpers, `build_job`, streaming upload |
| `test_tiling.py`          | `jobCore/tiling.py`  | tile coverage, overlap, padding, stride>tile gaps |
| `test_postprocess.py`     | `jobCore/postprocess.py` | mask → polygon, tile stitching, score weighting |
| `test_batch_helpers.py`   | `jobs/batch/main.py` | EXIF conversion, acquisition id, progress file, S3 listing |
| `test_solo_cli.py`        | `jobs/solo`, `cli/nearai.py` | Label Studio output, CLI request bodies |
| `test_segment.py`         | `segment/python/main.py` | interactive endpoint with a fake model |

## The 7 `xfail`

`test_api_validation.py::TestHardeningGaps` documents validation the API does
**not** enforce yet: negative/zero tile size, `downsample` outside `[0, 1]`,
`stride > tile`, zero workers, empty labels list. Each `xfail` is a hardening
task — add the Pydantic guard (`Field(gt=0)`, `Field(ge=0, le=1)`, a
`model_validator` for `stride <= tile` and non-empty `labels`) and the test
flips to passing.

## Out of scope (needs a GPU / real integration)

`Sam3Model.infer`, the Ray actors' `process`, `download_image` EXIF parsing on
real files, `upload_parquet` / `write_dataset_info`, and the batch `main()`
orchestration loop. These require the model or live services and belong to a
separate integration suite.
