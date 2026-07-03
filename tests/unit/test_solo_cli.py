"""Solo driver output format and the CLI client.

solo_module.to_label_studio is pure. For the CLI we capture the request bodies
sent to the API (api_get/api_post are monkeypatched) so we check the argument
plumbing without any network.
"""

import types


# --- solo: to_label_studio -------------------------------------------------
class TestToLabelStudio:
    def test_one_task_per_image_with_prediction(self, solo_module):
        polygons = [
            ("sign", [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]], 0.9),
            ("manhole", [[7.0, 8.0], [9.0, 10.0], [11.0, 12.0]], 0.7),
        ]
        out = solo_module.to_label_studio("s3://nearai/img.jpg", polygons, 8000, 4000)
        assert len(out) == 1
        task = out[0]
        assert task["data"]["image"] == "s3://nearai/img.jpg"
        pred = task["predictions"][0]
        assert pred["model_version"] == "SAM3"
        assert len(pred["result"]) == 2
        # prediction-level score = mean of detection scores
        assert abs(pred["score"] - 0.8) < 1e-6

    def test_result_fields_match_label_studio_contract(self, solo_module):
        polygons = [("sign", [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]], 0.5)]
        r0 = solo_module.to_label_studio("img", polygons, 100, 50)[0]["predictions"][0]["result"][0]
        assert r0["from_name"] == "label" and r0["to_name"] == "image"
        assert r0["type"] == "polygonlabels"
        assert r0["original_width"] == 100 and r0["original_height"] == 50
        assert r0["value"]["polygonlabels"] == ["sign"]
        assert r0["value"]["closed"] is True

    def test_no_polygons_has_no_prediction_score(self, solo_module):
        out = solo_module.to_label_studio("img", [], 100, 50)
        pred = out[0]["predictions"][0]
        assert pred["result"] == []
        assert "score" not in pred          # no detections -> no mean score


# --- cli: prefixes ---------------------------------------------------------
class TestCliPrefixes:
    def test_images_prefix(self, cli_module):
        assert cli_module.images_prefix("Vevey") == "data/acquisitions/Vevey/01_images/"

    def test_parquet_prefix(self, cli_module):
        assert cli_module.parquet_prefix("Vevey") == "data/acquisitions/Vevey/09_parquet/"


# --- cli: command bodies ---------------------------------------------------
class TestCliBatch:
    def test_batch_body_maps_flags_to_api_contract(self, cli_module, monkeypatch, capsys):
        captured = {}

        def fake_post(path, body=None):
            captured["path"] = path
            captured["body"] = body
            return {"job_name": "sam3-batch-1234", "status": "submitted"}

        monkeypatch.setattr(cli_module, "api_post", fake_post)
        args = types.SimpleNamespace(
            acquisition="Vevey", bucket="nearai",
            labels="sign,road_mark", workers=3, batch_size=4, downsample=0.75,
        )
        cli_module.cmd_batch(args)
        assert captured["path"] == "/jobs/batch"
        body = captured["body"]
        assert body["s3Uri"] == "data/acquisitions/Vevey/01_images/"
        assert body["s3OutputUri"] == "data/acquisitions/Vevey/09_parquet/"
        assert body["labels"] == ["sign", "road_mark"]     # split on comma
        assert body["numWorkers"] == 3 and body["downsample"] == 0.75
        # user gets the submitted job name back
        assert "sam3-batch-1234" in capsys.readouterr().out


class TestCliSolo:
    def test_solo_body(self, cli_module, monkeypatch):
        captured = {}
        monkeypatch.setattr(cli_module, "api_post",
                            lambda path, body=None: captured.update(path=path, body=body) or {})
        args = types.SimpleNamespace(
            image="data/in/x.jpg", bucket="nearai", labels="sign", downsample=1.0
        )
        cli_module.cmd_solo(args)
        assert captured["path"] == "/jobs/solo"
        assert captured["body"]["imageUri"] == "data/in/x.jpg"
        assert captured["body"]["labels"] == ["sign"]


class TestCliStatus:
    def test_status_once_queries_the_right_path(self, cli_module, monkeypatch, capsys):
        seen = {}

        def fake_get(path, params=None):
            seen["path"] = path
            return {"percent": 50, "processed": 5, "total": 10, "elapsed_seconds": 12, "done": False}

        monkeypatch.setattr(cli_module, "api_get", fake_get)
        args = types.SimpleNamespace(job="sam3-batch-1234", watch=False)
        cli_module.cmd_status(args)
        assert seen["path"] == "/jobs/sam3-batch-1234/status"
        assert "50%" in capsys.readouterr().out


class TestCliJobs:
    def test_jobs_kind_filter_forwarded(self, cli_module, monkeypatch):
        seen = {}

        def fake_get(path, params=None):
            seen["path"] = path
            seen["params"] = params
            return {"jobs": []}

        monkeypatch.setattr(cli_module, "api_get", fake_get)
        cli_module.cmd_jobs(types.SimpleNamespace(kind="batch"))
        assert seen["path"] == "/jobs/"
        assert seen["params"] == {"kind": "batch"}
