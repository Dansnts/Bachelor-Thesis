"""Input validation of the API — "everything a user can do wrong".

TestRequiredFields / TestWrongTypes / TestAccepted document the baseline
Pydantic behaviour; TestValueRanges pins the hardening pass of mid-July
(negative tile size, downsample out of range, stride larger than tile,
empty labels, zero workers all get a 422).

The Kubernetes and S3 layers are mocked (see conftest), so a request that
passes validation returns 200 without touching a real cluster.
"""

import pytest

VALID_BATCH = {
    "s3Uri": "in/",
    "s3OutputUri": "out/",
    "s3Bucket": "nearai",
    "labels": ["sign"],
    "numWorkers": 1,
    "batchSize": 4,
}

VALID_SOLO = {
    "imageUri": "img.jpg",
    "s3Bucket": "nearai",
    "labels": ["sign"],
}


def _batch(**over):
    return {**VALID_BATCH, **over}


def _solo(**over):
    return {**VALID_SOLO, **over}


class TestRequiredFields:
    """A missing required field must be rejected by Pydantic (HTTP 422)."""

    @pytest.mark.parametrize(
        "field",
        ["s3Uri", "s3Bucket", "labels", "numWorkers", "batchSize"],
    )
    def test_batch_missing_field_is_422(self, client, field):
        body = _batch()
        body.pop(field)
        assert client.post("/jobs/batch", json=body).status_code == 422

    @pytest.mark.parametrize("field", ["imageUri", "s3Bucket", "labels"])
    def test_solo_missing_field_is_422(self, client, field):
        body = _solo()
        body.pop(field)
        assert client.post("/jobs/solo", json=body).status_code == 422

    def test_empty_body_is_422(self, client):
        assert client.post("/jobs/batch", json={}).status_code == 422

    def test_not_json_is_422(self, client):
        r = client.post(
            "/jobs/batch",
            content=b"this is not json",
            headers={"Content-Type": "application/json"},
        )
        assert r.status_code == 422


class TestWrongTypes:
    """Wrong JSON types must be rejected before reaching the pipeline."""

    def test_tile_size_not_a_number(self, client):
        assert client.post("/jobs/batch", json=_batch(tileSize="huge")).status_code == 422

    def test_num_workers_string(self, client):
        assert client.post("/jobs/batch", json=_batch(numWorkers="three")).status_code == 422

    def test_labels_not_a_list(self, client):
        assert client.post("/jobs/batch", json=_batch(labels="sign")).status_code == 422

    def test_downsample_not_a_number(self, client):
        assert client.post("/jobs/batch", json=_batch(downsample="half")).status_code == 422

    def test_tile_size_fractional_is_422(self, client):
        # an int field must not silently accept 512.5
        assert client.post("/jobs/batch", json=_batch(tileSize=512.5)).status_code == 422


class TestAccepted:
    """Well-formed requests pass validation (k8s is mocked -> 200)."""

    def test_minimal_batch_ok(self, client):
        assert client.post("/jobs/batch", json=_batch()).status_code == 200

    def test_minimal_solo_ok(self, client):
        assert client.post("/jobs/solo", json=_solo()).status_code == 200

    def test_defaults_applied(self, client, fake_k8s):
        client.post("/jobs/batch", json=_batch())
        job = next(iter(fake_k8s.batch.jobs.values()))
        args = job.spec.template.spec.containers[0].args
        # tileSize/tileStride/downsample defaults reach the driver command line
        assert "--tile_size" in args and "1008" in args
        assert "--tile_stride" in args and "768" in args


class TestExplicitUrlList:
    """s3Uris: an explicit list of full s3:// image URLs instead of a prefix.

    The scheme is mandatory (a future https:// source must be added
    explicitly, not guessed), and the list is exclusive with s3Uri.
    """

    URLS = [
        "s3://nearai/data/acquisitions/A/01_images/a.jpg",
        "s3://other-bucket/somewhere/else/b.jpg",
    ]

    def _list_batch(self, **over):
        body = _batch(s3Uris=self.URLS)
        body.pop("s3Uri")
        return {**body, **over}

    def test_valid_url_list_ok(self, client):
        assert client.post("/jobs/batch", json=self._list_batch()).status_code == 200

    def test_urls_reach_driver_as_s3_uris(self, client, fake_k8s):
        client.post("/jobs/batch", json=self._list_batch())
        job = next(iter(fake_k8s.batch.jobs.values()))
        args = job.spec.template.spec.containers[0].args
        assert "--s3_uris" in args
        assert args[args.index("--s3_uris") + 1] == ",".join(self.URLS)
        assert "--s3_uri" not in args

    def test_both_uri_and_urls_rejected(self, client):
        body = self._list_batch(s3Uri="in/")
        assert client.post("/jobs/batch", json=body).status_code == 422

    def test_neither_uri_nor_urls_rejected(self, client):
        body = _batch()
        body.pop("s3Uri")
        assert client.post("/jobs/batch", json=body).status_code == 422

    def test_https_url_rejected(self, client):
        body = self._list_batch(s3Uris=["https://ville.example/img.jpg"])
        assert client.post("/jobs/batch", json=body).status_code == 422

    def test_bare_key_rejected(self, client):
        body = self._list_batch(s3Uris=["data/acquisitions/A/01_images/a.jpg"])
        assert client.post("/jobs/batch", json=body).status_code == 422

    def test_bucket_only_url_rejected(self, client):
        body = self._list_batch(s3Uris=["s3://nearai"])
        assert client.post("/jobs/batch", json=body).status_code == 422


class TestValueRanges:
    """Values the pipeline cannot honour must get a 422, not a job.

    Enforced by the Field constraints and the stride_must_fit_tile
    validator on BatchRequest/SoloRequest.
    """

    def test_negative_tile_size_rejected(self, client):
        assert client.post("/jobs/batch", json=_batch(tileSize=-512)).status_code == 422

    def test_zero_tile_size_rejected(self, client):
        assert client.post("/jobs/batch", json=_batch(tileSize=0)).status_code == 422

    def test_downsample_above_one_rejected(self, client):
        assert client.post("/jobs/batch", json=_batch(downsample=5.0)).status_code == 422

    def test_downsample_negative_rejected(self, client):
        assert client.post("/jobs/batch", json=_batch(downsample=-0.5)).status_code == 422

    def test_stride_larger_than_tile_rejected(self, client):
        # stride > tile leaves uncovered gaps between tiles (see test_tiling)
        assert client.post(
            "/jobs/batch", json=_batch(tileSize=1008, tileStride=2000)
        ).status_code == 422

    def test_zero_workers_rejected(self, client):
        assert client.post("/jobs/batch", json=_batch(numWorkers=0)).status_code == 422

    def test_empty_labels_rejected(self, client):
        assert client.post("/jobs/batch", json=_batch(labels=[])).status_code == 422

    def test_full_resolution_downsample_accepted(self, client):
        # 1.0 is the upper bound and must stay valid (no off-by-one on le=1.0)
        assert client.post("/jobs/batch", json=_batch(downsample=1.0)).status_code == 200

    def test_solo_negative_tile_size_rejected(self, client):
        assert client.post("/jobs/solo", json=_solo(tileSize=-512)).status_code == 422

    def test_solo_empty_labels_rejected(self, client):
        assert client.post("/jobs/solo", json=_solo(labels=[])).status_code == 422

    def test_solo_stride_larger_than_tile_rejected(self, client):
        assert client.post(
            "/jobs/solo", json=_solo(tileSize=1008, tileStride=2000)
        ).status_code == 422
