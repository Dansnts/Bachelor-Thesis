"""Interactive segmentation service (deploy/segment/python/main.py).

The SAM3/Ultralytics model is replaced by a fake whose predict() returns a
controllable mask, and get_image is monkeypatched to return a synthetic image.
The real mask_to_polygon (opencv) still runs, so the endpoint is exercised
end to end without a GPU.
"""

import io

import numpy as np
from PIL import Image


def _png_bytes(w=100, h=100):
    buf = io.BytesIO()
    Image.new("RGB", (w, h), (128, 128, 128)).save(buf, format="PNG")
    return buf.getvalue()


class _FakeTensor:
    def __init__(self, arr):
        self._arr = arr

    def cpu(self):
        return self

    def numpy(self):
        return self._arr


class _FakeMasks:
    def __init__(self, arrays):
        self.data = [_FakeTensor(a) for a in arrays]


class _FakePred:
    def __init__(self, masks):
        self.masks = masks


class _FakeModel:
    """predict() returns whatever masks we queue, ignoring the prompt."""

    def __init__(self, masks_per_call):
        self._queue = list(masks_per_call)

    def predict(self, source=None, points=None, labels=None, verbose=False):
        masks = self._queue.pop(0)
        return [_FakePred(masks)]


def _request(segment_module, items):
    return segment_module.SegmentRequest(
        url="img.jpg",
        items=[segment_module.SegmentItem(point=p, label=lbl) for p, lbl in items],
    )


def test_found_object_returns_polygon(segment_module, monkeypatch):
    filled = np.zeros((100, 100), dtype=np.uint8)
    filled[20:70, 20:70] = 1                      # a solid square -> a polygon
    monkeypatch.setattr(segment_module, "get_image", lambda b, k: _png_bytes())
    monkeypatch.setattr(segment_module, "model", _FakeModel([_FakeMasks([filled])]))

    out = segment_module.segment(_request(segment_module, [([50, 50], "manhole")]))
    res = out["results"][0]
    assert res["found"] is True
    assert res["label"] == "manhole"
    assert len(res["points"]) >= 3


def test_no_mask_returns_found_false(segment_module, monkeypatch):
    monkeypatch.setattr(segment_module, "get_image", lambda b, k: _png_bytes())
    monkeypatch.setattr(segment_module, "model", _FakeModel([None]))   # masks is None

    out = segment_module.segment(_request(segment_module, [([10, 10], "sign")]))
    assert out["results"][0] == {"label": "sign", "points": [], "found": False}


def test_empty_masks_list_returns_found_false(segment_module, monkeypatch):
    monkeypatch.setattr(segment_module, "get_image", lambda b, k: _png_bytes())
    monkeypatch.setattr(segment_module, "model", _FakeModel([_FakeMasks([])]))

    out = segment_module.segment(_request(segment_module, [([10, 10], "sign")]))
    assert out["results"][0]["found"] is False


def test_multiple_items_processed_in_order(segment_module, monkeypatch):
    filled = np.zeros((100, 100), dtype=np.uint8)
    filled[10:60, 10:60] = 1
    monkeypatch.setattr(segment_module, "get_image", lambda b, k: _png_bytes())
    # first point finds an object, second finds nothing
    monkeypatch.setattr(segment_module, "model", _FakeModel([_FakeMasks([filled]), None]))

    out = segment_module.segment(
        _request(segment_module, [([30, 30], "manhole"), ([90, 90], "sign")])
    )
    assert [r["found"] for r in out["results"]] == [True, False]
    assert [r["label"] for r in out["results"]] == ["manhole", "sign"]


def test_health_reports_model_state(segment_module, monkeypatch):
    monkeypatch.setattr(segment_module, "model", None)
    assert segment_module.health() == {"status": "ok", "model_loaded": False}
    monkeypatch.setattr(segment_module, "model", object())
    assert segment_module.health()["model_loaded"] is True
