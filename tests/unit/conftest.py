"""Shared fixtures for the unit test-suite.

The pipeline modules pull in a heavy ML stack (SAM3, torch, ray, ultralytics)
and, for the API, load a Kubernetes config at import time. None of that is
available — nor wanted — in a CI runner. This conftest makes the modules
importable in isolation:

  - `ray` and `torch` are replaced by stub modules (batch/solo import them at
    module level but the code under test never calls into them);
  - the Kubernetes config loaders are neutralised before the API is imported;
  - every module is loaded by file path under a unique name, so the four
    `main.py` files do not collide in `sys.modules`.

Nothing here talks to a real cluster, a real MinIO or a real GPU.
"""

import importlib.util
import os
import sys
import types
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
JOBS = REPO / "deploy" / "jobs"

# jobCore is imported as a package by batch/solo/segment/worker.
if str(JOBS) not in sys.path:
    sys.path.insert(0, str(JOBS))


def _stub(name, **attrs):
    """Register a bare stub module under `name` if it is not installed."""
    if name in sys.modules:
        return sys.modules[name]
    mod = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(mod, k, v)
    sys.modules[name] = mod
    return mod


def _install_heavy_stubs():
    """Stub the ML/distributed deps so batch/solo/worker import offline.

    `ray.remote(...)` is used as a decorator on the actor classes: the stub
    returns a decorator that hands the class straight back, so importing the
    module keeps the class object intact (we never *run* the actor here).
    """
    if "ray" not in sys.modules:
        ray = types.ModuleType("ray")

        def remote(*a, **k):
            # support both @ray.remote and @ray.remote(num_gpus=1)
            if len(a) == 1 and callable(a[0]) and not k:
                return a[0]
            return lambda cls: cls

        ray.remote = remote
        ray.init = lambda *a, **k: None
        ray.get = lambda x: x
        ray.shutdown = lambda: None
        ray.nodes = lambda: []
        ray.wait = lambda pending, num_returns=1: (pending[:num_returns], pending[num_returns:])
        sys.modules["ray"] = ray

    if "torch" not in sys.modules:
        torch = types.ModuleType("torch")
        torch.cuda = types.SimpleNamespace(is_available=lambda: False)
        torch.bfloat16 = "bfloat16"
        torch.device = lambda d: d
        torch.inference_mode = lambda: _nullctx()
        torch.autocast = lambda *a, **k: _nullctx()
        sys.modules["torch"] = torch


class _nullctx:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _load(path, name):
    """Import a source file as a uniquely named module."""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


# --- API module ------------------------------------------------------------
@pytest.fixture(scope="session")
def api_module():
    """The FastAPI app module, imported with the k8s config load neutralised."""
    import kubernetes.config as kconfig

    orig_incluster = kconfig.load_incluster_config
    orig_kube = kconfig.load_kube_config
    # import time: skip real config loading (no kubeconfig in CI)
    kconfig.load_incluster_config = lambda *a, **k: None
    kconfig.load_kube_config = lambda *a, **k: None
    try:
        mod = _load(REPO / "deploy" / "api" / "python" / "main.py", "api_main")
    finally:
        kconfig.load_incluster_config = orig_incluster
        kconfig.load_kube_config = orig_kube
    return mod


@pytest.fixture
def client(api_module, fake_k8s, fake_s3, monkeypatch):
    """A FastAPI TestClient with k8s and S3 fully mocked."""
    from fastapi.testclient import TestClient

    monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
    monkeypatch.setattr(api_module, "core_v1", fake_k8s.core)
    monkeypatch.setattr(api_module, "apps_v1", fake_k8s.apps)
    monkeypatch.setattr(api_module, "s3_client", lambda: fake_s3)
    return TestClient(api_module.app)


# --- batch / solo / cli / segment ------------------------------------------
@pytest.fixture(scope="session")
def batch_module():
    _install_heavy_stubs()
    return _load(JOBS / "batch" / "main.py", "batch_main")


@pytest.fixture(scope="session")
def solo_module():
    _install_heavy_stubs()
    return _load(JOBS / "solo" / "python" / "main.py", "solo_main")


@pytest.fixture(scope="session")
def cli_module():
    return _load(REPO / "cli" / "nearai.py", "nearai_cli")


@pytest.fixture(scope="session")
def segment_module():
    return _load(REPO / "deploy" / "segment" / "python" / "main.py", "segment_main")


@pytest.fixture(scope="session")
def tiling_module():
    return _load(JOBS / "jobCore" / "tiling.py", "jc_tiling")


@pytest.fixture(scope="session")
def postprocess_module():
    return _load(JOBS / "jobCore" / "postprocess.py", "jc_postprocess")


# --- fakes -----------------------------------------------------------------
class _FakeApiException(Exception):
    """Mimics kubernetes.client.ApiException (status + reason attributes)."""

    def __init__(self, status=500, reason="error"):
        super().__init__(reason)
        self.status = status
        self.reason = reason


class FakeBatchApi:
    """In-memory stand-in for BatchV1Api. Jobs live in a dict."""

    def __init__(self):
        self.jobs = {}
        self.create_error = None
        self.list_error = None

    def create_namespaced_job(self, namespace, job):
        if self.create_error:
            raise self.create_error
        self.jobs[job.metadata.name] = job
        return job

    def read_namespaced_job(self, name, namespace):
        if name not in self.jobs:
            raise _FakeApiException(status=404, reason="Not Found")
        return self.jobs[name]

    def list_namespaced_job(self, namespace):
        if self.list_error:
            raise self.list_error
        return types.SimpleNamespace(items=list(self.jobs.values()))


class FakeCoreApi:
    def __init__(self):
        self.error = None

    def list_namespaced_pod(self, namespace, limit=None):
        if self.error:
            raise self.error
        return types.SimpleNamespace(items=[])


class FakeAppsApi:
    def __init__(self):
        self.scaled_to = None
        self.error = None

    def patch_namespaced_deployment_scale(self, name, namespace, body):
        if self.error:
            raise self.error
        self.scaled_to = body["spec"]["replicas"]
        return body


@pytest.fixture
def fake_k8s(api_module):
    # make the API's `client.ApiException` be our fake so `except ApiException`
    # in the endpoints actually catches what the fakes raise
    api_module.client.ApiException = _FakeApiException
    return types.SimpleNamespace(
        batch=FakeBatchApi(),
        core=FakeCoreApi(),
        apps=FakeAppsApi(),
        ApiException=_FakeApiException,
    )


class FakeS3:
    """Minimal in-memory S3: put/get/list + NoSuchKey, enough for the API."""

    class NoSuchKey(Exception):
        pass

    def __init__(self):
        self.store = {}  # (bucket, key) -> bytes
        self.exceptions = types.SimpleNamespace(NoSuchKey=FakeS3.NoSuchKey)
        self._upload_parts = {}

    # object ops
    def put_object(self, Bucket, Key, Body, **kw):
        self.store[(Bucket, Key)] = Body if isinstance(Body, bytes) else bytes(Body)
        return {}

    def get_object(self, Bucket, Key):
        if (Bucket, Key) not in self.store:
            raise self.NoSuchKey(Key)
        data = self.store[(Bucket, Key)]
        return {"Body": types.SimpleNamespace(read=lambda: data)}

    # listing
    def get_paginator(self, _op):
        store = self.store

        class _Pag:
            def paginate(self, Bucket, Prefix=""):
                contents = [
                    {"Key": k}
                    for (b, k) in store
                    if b == Bucket and k.startswith(Prefix)
                ]
                yield {"Contents": contents}

        return _Pag()

    # multipart (used by stream_to_s3)
    def create_multipart_upload(self, Bucket, Key, **kw):
        uid = f"upload-{len(self._upload_parts)}"
        self._upload_parts[uid] = {"bucket": Bucket, "key": Key, "parts": {}}
        return {"UploadId": uid}

    def upload_part(self, Bucket, Key, PartNumber, UploadId, Body):
        self._upload_parts[UploadId]["parts"][PartNumber] = bytes(Body)
        return {"ETag": f"etag-{PartNumber}"}

    def complete_multipart_upload(self, Bucket, Key, UploadId, MultipartUpload):
        parts = self._upload_parts.pop(UploadId)
        joined = b"".join(parts["parts"][p] for p in sorted(parts["parts"]))
        self.store[(Bucket, Key)] = joined
        return {}

    def abort_multipart_upload(self, Bucket, Key, UploadId):
        self._upload_parts.pop(UploadId, None)
        return {}


@pytest.fixture
def fake_s3():
    return FakeS3()
