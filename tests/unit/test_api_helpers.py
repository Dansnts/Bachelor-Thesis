"""Pure helpers of the API, tested in isolation (no HTTP, no cluster)."""

import json
import types

import pytest


# --- default_output_prefix -------------------------------------------------
class TestDefaultOutputPrefix:
    """Results location derived from the images prefix when s3OutputUri is omitted."""

    def test_from_01_images_prefix(self, api_module):
        assert (
            api_module.default_output_prefix("data/acquisitions/Vevey/01_images/")
            == "data/acquisitions/Vevey/09_Pipeline_result/"
        )

    def test_from_acquisition_root_without_01_images(self, api_module):
        # testValentin layout: images sit directly under the acquisition folder
        assert (
            api_module.default_output_prefix("data/acquisitions/testValentin")
            == "data/acquisitions/testValentin/09_Pipeline_result/"
        )

    def test_from_full_s3_uri(self, api_module):
        assert (
            api_module.default_output_prefix("s3://nearai/data/acquisitions/Vevey/01_images/")
            == "data/acquisitions/Vevey/09_Pipeline_result/"
        )

    def test_deep_prefix_cuts_at_01_images(self, api_module):
        assert (
            api_module.default_output_prefix("data/acquisitions/HSN/01_images/S001/")
            == "data/acquisitions/HSN/09_Pipeline_result/"
        )

    def test_leading_and_trailing_slashes_are_normalised(self, api_module):
        assert (
            api_module.default_output_prefix("/data/acquisitions/Vevey/01_images")
            == "data/acquisitions/Vevey/09_Pipeline_result/"
        )


# --- to_s3_uri -------------------------------------------------------------
class TestToS3Uri:
    def test_plain_path_gets_bucket_prefix(self, api_module):
        assert api_module.to_s3_uri("nearai", "data/x.jpg") == "s3://nearai/data/x.jpg"

    def test_leading_slash_is_stripped(self, api_module):
        assert api_module.to_s3_uri("nearai", "/data/x.jpg") == "s3://nearai/data/x.jpg"

    def test_already_a_uri_is_untouched(self, api_module):
        assert api_module.to_s3_uri("ignored", "s3://other/x.jpg") == "s3://other/x.jpg"


# --- job_status ------------------------------------------------------------
def _job(name="sam3-solo-x", **flags):
    return types.SimpleNamespace(
        metadata=types.SimpleNamespace(name=name),
        status=types.SimpleNamespace(**flags),
    )


class TestJobStatus:
    @pytest.mark.parametrize(
        "flags,expected",
        [
            (dict(succeeded=1, failed=None, active=None), "Succeeded"),
            (dict(succeeded=None, failed=1, active=None), "Failed"),
            (dict(succeeded=None, failed=None, active=None), "Pending"),
        ],
    )
    def test_mapping(self, api_module, flags, expected):
        assert api_module.job_status(_job(**flags)) == expected

    @pytest.mark.parametrize(
        "phase,expected",
        [
            ("Running", "Running"),   # the pod really runs
            ("Pending", "Pending"),   # pod queued, e.g. waiting for a GPU
            (None, "Pending"),        # no pod visible yet
        ],
    )
    def test_active_job_reads_pod_phase(self, api_module, monkeypatch, phase, expected):
        pods = []
        if phase:
            pods = [types.SimpleNamespace(status=types.SimpleNamespace(phase=phase))]
        fake_core = types.SimpleNamespace(
            list_namespaced_pod=lambda ns, label_selector=None: types.SimpleNamespace(items=pods)
        )
        monkeypatch.setattr(api_module, "core_v1", fake_core)
        job = _job(succeeded=None, failed=None, active=1)
        assert api_module.job_status(job) == expected

    def test_succeeded_wins_over_active(self, api_module):
        # a job that had active pods but is now done reports Succeeded
        job = _job(succeeded=1, failed=None, active=1)
        assert api_module.job_status(job) == "Succeeded"

    def test_retry_pod_wins_over_failed(self, api_module, monkeypatch):
        # failed only counts dead pods : while a retry pod runs, the job runs
        pods = [types.SimpleNamespace(status=types.SimpleNamespace(phase="Running"))]
        fake_core = types.SimpleNamespace(
            list_namespaced_pod=lambda ns, label_selector=None: types.SimpleNamespace(items=pods)
        )
        monkeypatch.setattr(api_module, "core_v1", fake_core)
        job = _job(succeeded=None, failed=1, active=1)
        assert api_module.job_status(job) == "Running"


# --- rows_to_label_studio --------------------------------------------------
class TestRowsToLabelStudio:
    def _row(self, image_key, label="sign", points="[[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]",
             latitude=46.38, longitude=6.23):
        return {
            "image_key": image_key,
            "label": label,
            "points": points,
            "original_width": 8000,
            "original_height": 4000,
            "latitude": latitude,
            "longitude": longitude,
        }

    def test_groups_polygons_by_image(self, api_module):
        rows = [
            self._row("a.jpg", "sign"),
            self._row("a.jpg", "manhole"),
            self._row("b.jpg", "sign"),
        ]
        tasks = api_module.rows_to_label_studio("nearai", rows)
        assert len(tasks) == 2                       # two distinct images
        a = next(t for t in tasks if t["data"]["image"].endswith("a.jpg"))
        assert len(a["predictions"][0]["result"]) == 2   # both polygons on a.jpg

    def test_points_are_parsed_from_json_string(self, api_module):
        tasks = api_module.rows_to_label_studio("nearai", [self._row("a.jpg")])
        pts = tasks[0]["predictions"][0]["result"][0]["value"]["points"]
        assert pts == [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]   # list, not a string

    def test_label_studio_contract_fields(self, api_module):
        res = api_module.rows_to_label_studio("nearai", [self._row("a.jpg")])[0]
        r0 = res["predictions"][0]["result"][0]
        # from_name/to_name must match the Label Studio XML or polygons show grey
        assert r0["from_name"] == "label" and r0["to_name"] == "image"
        assert r0["type"] == "polygonlabels"
        assert res["data"]["image"] == "s3://nearai/a.jpg"

    def test_empty_rows_gives_no_tasks(self, api_module):
        assert api_module.rows_to_label_studio("nearai", []) == []

    def test_gps_travels_in_task_data(self, api_module):
        # lat/lon must reach Label Studio in the task data, not be dropped
        task = api_module.rows_to_label_studio("nearai", [self._row("a.jpg")])[0]
        assert task["data"]["latitude"] == 46.38
        assert task["data"]["longitude"] == 6.23

    def test_missing_gps_is_null_not_crash(self, api_module):
        row = self._row("a.jpg", latitude=None, longitude=None)
        task = api_module.rows_to_label_studio("nearai", [row])[0]
        assert task["data"]["latitude"] is None
        assert task["data"]["longitude"] is None

    def test_score_travels_rounded(self, api_module):
        # the Parquet rows carry the detection score: it must reach Label Studio
        row = self._row("a.jpg")
        row["score"] = 0.87654
        r0 = api_module.rows_to_label_studio("nearai", [row])[0]["predictions"][0]["result"][0]
        assert r0["score"] == 0.8765

    def test_missing_score_omits_the_field(self, api_module):
        r0 = api_module.rows_to_label_studio("nearai", [self._row("a.jpg")])[0]["predictions"][0]["result"][0]
        assert "score" not in r0


# --- iter_label_studio_json ------------------------------------------------
class TestIterLabelStudioJson:
    def test_frames_tasks_as_json_array(self, api_module):
        tasks = [{"a": 1}, {"b": 2}]
        out = b"".join(api_module.iter_label_studio_json(iter(tasks)))
        assert json.loads(out) == tasks              # valid JSON, order preserved

    def test_empty_iterator_is_empty_array(self, api_module):
        out = b"".join(api_module.iter_label_studio_json(iter([])))
        assert out == b"[]"
        assert json.loads(out) == []


# --- list_parquet_keys -----------------------------------------------------
class TestListParquetKeys:
    def test_only_parquet_under_prefix(self, api_module, fake_s3):
        for key in [
            "data/out/a.parquet",
            "data/out/b.parquet",
            "data/out/notes.txt",     # ignored: not parquet
            "data/other/c.parquet",   # ignored: different prefix
        ]:
            fake_s3.put_object(Bucket="nearai", Key=key, Body=b"x")
        keys = api_module.list_parquet_keys(fake_s3, "nearai", "data/out/")
        assert sorted(keys) == ["data/out/a.parquet", "data/out/b.parquet"]

    def test_no_match_returns_empty(self, api_module, fake_s3):
        assert api_module.list_parquet_keys(fake_s3, "nearai", "nothing/") == []


# --- stream_to_s3 ----------------------------------------------------------
class TestStreamToS3:
    def test_streams_and_returns_uri(self, api_module, fake_s3):
        chunks = [b"hello ", b"world"]
        uri = api_module.stream_to_s3(fake_s3, "nearai", "out/f.json", iter(chunks))
        assert uri == "s3://nearai/out/f.json"
        assert fake_s3.store[("nearai", "out/f.json")] == b"hello world"

    def test_empty_stream_still_creates_object(self, api_module, fake_s3):
        # the "buf or not parts" branch must upload one (empty) part
        uri = api_module.stream_to_s3(fake_s3, "nearai", "out/empty.json", iter([]))
        assert uri == "s3://nearai/out/empty.json"
        assert fake_s3.store[("nearai", "out/empty.json")] == b""

    def test_large_payload_is_multipart(self, api_module, fake_s3):
        # > 5 MiB forces at least two parts; the reassembled object must match
        big = b"a" * (6 * 1024 * 1024)
        api_module.stream_to_s3(fake_s3, "nearai", "out/big.json", iter([big]))
        assert fake_s3.store[("nearai", "out/big.json")] == big


# --- build_job -------------------------------------------------------------
class TestBuildJob:
    def test_gpu_job_has_nvidia_runtime_and_affinity(self, api_module, fake_k8s, monkeypatch):
        monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
        api_module.build_job("sam3-solo-1", "img", ["python"], ["--x"], gpu=True)
        job = fake_k8s.batch.jobs["sam3-solo-1"]
        spec = job.spec.template.spec
        assert spec.runtime_class_name == "nvidia"
        assert spec.containers[0].resources.limits["nvidia.com/gpu"] == "1"
        assert spec.affinity is not None

    def test_cpu_job_has_no_gpu(self, api_module, fake_k8s, monkeypatch):
        monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
        api_module.build_job("sam3-batch-1", "img", ["python"], ["--x"], gpu=False)
        spec = fake_k8s.batch.jobs["sam3-batch-1"].spec.template.spec
        assert spec.runtime_class_name is None
        assert "nvidia.com/gpu" not in (spec.containers[0].resources.limits or {})

    def test_ttl_and_app_label(self, api_module, fake_k8s, monkeypatch):
        monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
        api_module.build_job("sam3-batch-abcd1234", "img", ["python"], [], gpu=False)
        job = fake_k8s.batch.jobs["sam3-batch-abcd1234"]
        assert job.spec.ttl_seconds_after_finished == 172800   # 48 h
        # app label = job name without its uuid suffix, so Alloy tags logs by app
        assert job.spec.template.metadata.labels["app"] == "sam3-batch"

    def test_secrets_injected_as_env(self, api_module, fake_k8s, monkeypatch):
        monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
        api_module.build_job(
            "sam3-batch-2", "img", ["python"], [], gpu=False,
            access_key_env="AWS_ACCESS_KEY_ID",
        )
        env = fake_k8s.batch.jobs["sam3-batch-2"].spec.template.spec.containers[0].env
        names = {e.name for e in env}
        assert {"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "HF_TOKEN"} <= names
        # credentials come from secretKeyRef, never inlined
        access = next(e for e in env if e.name == "AWS_ACCESS_KEY_ID")
        assert access.value is None
        assert access.value_from.secret_key_ref.name == "minio-secret"

    def test_create_failure_raises_http_exception(self, api_module, fake_k8s, monkeypatch):
        monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
        fake_k8s.batch.create_error = fake_k8s.ApiException(status=409, reason="exists")
        with pytest.raises(api_module.HTTPException) as exc:
            api_module.build_job("dup", "img", ["python"], [], gpu=False)
        assert exc.value.status_code == 409
