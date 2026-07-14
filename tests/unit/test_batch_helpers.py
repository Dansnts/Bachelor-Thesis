"""Pure helpers of the batch driver (deploy/jobs/batch/main.py).

ray and torch are stubbed by conftest so the module imports without the ML
stack. We test the EXIF conversion, the acquisition-id extraction, the progress
file and the S3 listing helpers (with the in-memory fake S3).
"""

import json
import types

import pytest


class TestRelativeToPrefix:
    """Mirroring of the input sub-structure under the output prefix.

    The result must reproduce the folders below the input prefix (S001, ...)
    without repeating the whole source path (the old double-nesting bug).
    """

    def test_subfolder_is_kept(self, batch_module):
        rel = batch_module.relative_to_prefix(
            "data/acquisitions/Vevey/01_images/S001/foo.jpg",
            "data/acquisitions/Vevey/01_images/",
        )
        assert rel == "S001"

    def test_nested_subfolders_are_kept(self, batch_module):
        rel = batch_module.relative_to_prefix(
            "data/acquisitions/Vevey/01_images/S002/x/bar.jpg",
            "data/acquisitions/Vevey/01_images/",
        )
        assert rel == "S002/x"

    def test_image_directly_under_prefix_is_empty(self, batch_module):
        rel = batch_module.relative_to_prefix(
            "data/acquisitions/testValentin/foo.jpg",
            "data/acquisitions/testValentin/",
        )
        assert rel == ""

    def test_image_at_prefix_root_is_empty(self, batch_module):
        rel = batch_module.relative_to_prefix(
            "data/acquisitions/Vevey/01_images/top.jpg",
            "data/acquisitions/Vevey/01_images/",
        )
        assert rel == ""

    def test_prefix_without_trailing_slash(self, batch_module):
        rel = batch_module.relative_to_prefix(
            "data/acquisitions/Vevey/01_images/S001/foo.jpg",
            "data/acquisitions/Vevey/01_images",
        )
        assert rel == "S001"

    def test_key_not_under_prefix_falls_back_to_parent(self, batch_module):
        # defensive: key that does not sit under the prefix keeps its own parent
        rel = batch_module.relative_to_prefix("other/place/foo.jpg", "data/acquisitions/Vevey/")
        assert rel == "other/place"

    def test_empty_prefix_returns_full_parent(self, batch_module):
        rel = batch_module.relative_to_prefix("a/b/c.jpg", "")
        assert rel == "a/b"

    def test_no_prefix_substring_false_positive(self, batch_module):
        # "01_images_backup" must NOT be treated as under "01_images"
        rel = batch_module.relative_to_prefix(
            "data/acq/01_images_backup/foo.jpg", "data/acq/01_images"
        )
        assert rel == "data/acq/01_images_backup"


class TestParseS3Url:
    """Explicit image URLs must carry the s3:// scheme and a bucket + key."""

    def test_valid_url_splits_bucket_and_key(self, batch_module):
        bucket, key = batch_module.parse_s3_url(
            "s3://nearai/data/acquisitions/A/01_images/a.jpg"
        )
        assert bucket == "nearai"
        assert key == "data/acquisitions/A/01_images/a.jpg"

    def test_other_bucket_is_kept(self, batch_module):
        bucket, key = batch_module.parse_s3_url("s3://other/x/b.jpg")
        assert bucket == "other" and key == "x/b.jpg"

    def test_https_scheme_rejected(self, batch_module):
        with pytest.raises(ValueError):
            batch_module.parse_s3_url("https://ville.example/img.jpg")

    def test_bare_key_rejected(self, batch_module):
        with pytest.raises(ValueError):
            batch_module.parse_s3_url("data/acquisitions/A/01_images/a.jpg")

    def test_bucket_without_key_rejected(self, batch_module):
        with pytest.raises(ValueError):
            batch_module.parse_s3_url("s3://nearai")

    def test_empty_bucket_rejected(self, batch_module):
        with pytest.raises(ValueError):
            batch_module.parse_s3_url("s3:///a.jpg")


class TestWriteRunParams:
    def _args(self):
        return types.SimpleNamespace(
            s3_uri="s3://nearai/data/acquisitions/Vevey/01_images/",
            s3_output_uri="s3://nearai/data/acquisitions/Vevey/09_Pipeline_result/sam3-batch-abcd/",
            num_workers=3,
            batch_size=4,
            tile_size=1008,
            tile_stride=768,
            downsample=0.75,
        )

    def test_writes_params_json_with_run_and_counts(self, batch_module, fake_s3):
        prefix = "data/acquisitions/Vevey/09_Pipeline_result/sam3-batch-abcd/"
        batch_module.write_run_params(
            fake_s3, "nearai", prefix, self._args(), ["sign", "road_marking"], 10, 177
        )
        stored = json.loads(fake_s3.store[("nearai", prefix + "params.json")])
        assert stored["run"] == "sam3-batch-abcd"          # last path component
        assert stored["labels"] == ["sign", "road_marking"]
        assert stored["num_workers"] == 3 and stored["batch_size"] == 4
        assert stored["tile_size"] == 1008 and stored["tile_stride"] == 768
        assert stored["downsample"] == 0.75
        assert stored["images_processed"] == 10
        assert stored["total_detections"] == 177
        assert stored["input_uri"].endswith("/01_images/")

    def test_run_name_survives_prefix_without_trailing_slash(self, batch_module, fake_s3):
        prefix = "data/acquisitions/Vevey/09_Pipeline_result/sam3-batch-abcd"
        batch_module.write_run_params(fake_s3, "nearai", prefix, self._args(), ["sign"], 1, 2)
        stored = json.loads(fake_s3.store[("nearai", prefix + "/params.json")])
        assert stored["run"] == "sam3-batch-abcd"


class TestDmsToDecimal:
    def test_north_is_positive(self, batch_module):
        # 46°30'00" N -> 46.5
        assert batch_module.dms_to_decimal((46, 30, 0), "N") == 46.5

    def test_east_is_positive(self, batch_module):
        assert batch_module.dms_to_decimal((6, 0, 0), "E") == 6.0

    def test_south_is_negative(self, batch_module):
        assert batch_module.dms_to_decimal((46, 30, 0), "S") == -46.5

    def test_west_is_negative(self, batch_module):
        assert batch_module.dms_to_decimal((6, 30, 0), "W") == -6.5

    def test_seconds_contribute(self, batch_module):
        # 0°0'36" -> 36/3600 = 0.01
        assert abs(batch_module.dms_to_decimal((0, 0, 36), "N") - 0.01) < 1e-9


class TestGetAcquisitionId:
    def test_extracts_folder_after_acquisitions(self, batch_module):
        key = "data/acquisitions/Vevey/01_images/S001/img.jpg"
        assert batch_module.get_acquisition_id(key) == "Vevey"

    def test_fallback_when_no_acquisitions_segment(self, batch_module):
        # no "acquisitions" in the path -> grandparent of the file, i.e. the
        # folder holding 01_images (the usual acquisition folder position)
        key = "some/other/Vevey/01_images/img.jpg"
        assert batch_module.get_acquisition_id(key) == "Vevey"

    def test_acquisitions_is_last_segment(self, batch_module):
        # "acquisitions" present but nothing after it -> fallback, no IndexError
        key = "data/acquisitions"
        assert isinstance(batch_module.get_acquisition_id(key), str)


class TestPoseCsvKey:
    """Deriving a session's trajectory CSV key from an image key."""

    def test_derives_trajectory_csv_from_image(self, batch_module):
        key = "data/acquisitions/20241003-Nyon/01_images/S003/20241003-Nyon_S003_ladybug5plus_000001.jpg"
        assert (
            batch_module.pose_csv_key(key)
            == "data/acquisitions/20241003-Nyon/02_poses/S003_trajectory.csv"
        )

    def test_flat_layout_reads_session_from_filename(self, batch_module):
        # no session folder: session comes from the _S001_ token in the name
        key = "data/acquisitions/Samples/01_images/20251210-NeoCapture-bis_S001_Trimblemx50_000001.jpg"
        assert (
            batch_module.pose_csv_key(key)
            == "data/acquisitions/Samples/02_poses/S001_trajectory.csv"
        )

    def test_none_when_flat_and_no_session_token(self, batch_module):
        # flat layout and no S<NNN> token -> no session to key on
        key = "data/acquisitions/Vevey/01_images/img.jpg"
        assert batch_module.pose_csv_key(key) is None

    def test_none_when_no_01_images(self, batch_module):
        assert batch_module.pose_csv_key("other/place/img.jpg") is None


class TestLoadPoses:
    """Reading a trajectory CSV into {image_name: (lat, lon, heading)}."""

    CSV = (
        "frame_index,image_name,timestamp,gps_latitude,gps_longitude,"
        "gps_altitude_m,heading_deg,pitch_deg,roll_deg\n"
        "1,a.jpg,2024-10-03T11:09:31,46.3819,6.2308,409.5,33.07,-1.6,1.6\n"
        "2,b.jpg,2025-06-18T06:13:53Z,47.6220,6.1511,270.3,,,\n"  # empty heading
    )

    def test_maps_image_name_to_coordinates(self, batch_module, fake_s3):
        fake_s3.store[("nearai", "poses.csv")] = self.CSV.encode()
        poses = batch_module.load_poses(fake_s3, "nearai", "poses.csv")
        assert poses["a.jpg"] == (46.3819, 6.2308, 33.07)

    def test_empty_cells_become_none(self, batch_module, fake_s3):
        fake_s3.store[("nearai", "poses.csv")] = self.CSV.encode()
        poses = batch_module.load_poses(fake_s3, "nearai", "poses.csv")
        assert poses["b.jpg"] == (47.6220, 6.1511, None)  # heading absent -> None

    def test_missing_file_gives_empty_map(self, batch_module, fake_s3):
        # NoSuchKey (or any read error) must not raise: callers fall back to EXIF
        assert batch_module.load_poses(fake_s3, "nearai", "nope.csv") == {}


class TestWriteStatus:
    def test_writes_progress_json(self, batch_module, fake_s3):
        batch_module.write_status(fake_s3, "nearai", "results/j.status.json", 42, 100, 1_000_000_000)
        stored = json.loads(fake_s3.store[("nearai", "results/j.status.json")])
        assert stored["percent"] == 42
        assert stored["processed"] == 42 and stored["total"] == 100
        assert stored["done"] is False
        assert "elapsed_seconds" not in stored          # only frozen when done

    def test_done_freezes_elapsed(self, batch_module, fake_s3):
        batch_module.write_status(fake_s3, "nearai", "k", 10, 10, 1_000_000_000, done=True)
        stored = json.loads(fake_s3.store[("nearai", "k")])
        assert stored["done"] is True
        assert stored["percent"] == 100
        assert "elapsed_seconds" in stored

    def test_zero_total_does_not_divide_by_zero(self, batch_module, fake_s3):
        batch_module.write_status(fake_s3, "nearai", "k", 0, 0, 1_000_000_000)
        assert json.loads(fake_s3.store[("nearai", "k")])["percent"] == 0


class TestListImages:
    def test_keeps_only_supported_extensions_sorted(self, batch_module, fake_s3):
        for key in [
            "in/b.jpg", "in/a.png", "in/c.tiff",
            "in/notes.txt",          # ignored: not an image
            "in/thumb.gif",          # ignored: unsupported extension
        ]:
            fake_s3.put_object(Bucket="nearai", Key=key, Body=b"x")
        keys = batch_module.list_images(fake_s3, "nearai", "in/")
        assert keys == ["in/a.png", "in/b.jpg", "in/c.tiff"]   # sorted, filtered

    def test_case_insensitive_extension(self, batch_module, fake_s3):
        fake_s3.put_object(Bucket="nearai", Key="in/UPPER.JPG", Body=b"x")
        assert batch_module.list_images(fake_s3, "nearai", "in/") == ["in/UPPER.JPG"]


class TestAlreadyProcessed:
    def test_returns_stems_of_existing_parquet(self, batch_module, fake_s3):
        fake_s3.put_object(Bucket="nearai", Key="out/S001/a.parquet", Body=b"x")
        fake_s3.put_object(Bucket="nearai", Key="out/S001/b.parquet", Body=b"x")
        fake_s3.put_object(Bucket="nearai", Key="out/dataset_info.txt", Body=b"x")
        done = batch_module.already_processed(fake_s3, "nearai", "out/")
        assert done == {"a", "b"}          # stems only, non-parquet ignored

    def test_empty_prefix_gives_empty_set(self, batch_module, fake_s3):
        assert batch_module.already_processed(fake_s3, "nearai", "out/") == set()


class TestConnectRay:
    def test_retries_the_flaky_first_contact(self, batch_module, monkeypatch):
        # the proxier dies twice (gRPC fork race), the third attempt connects
        calls = []

        def flaky_init(address):
            calls.append(address)
            if len(calls) < 3:
                raise ConnectionAbortedError("Initialization failure from server")
            return "ctx"

        monkeypatch.setattr(batch_module.ray, "init", flaky_init)
        monkeypatch.setattr(batch_module.time, "sleep", lambda s: None)
        assert batch_module.connect_ray("ray://head:10001", attempts=5, delay=0) == "ctx"
        assert len(calls) == 3

    def test_gives_up_after_the_last_attempt(self, batch_module, monkeypatch):
        def dead_init(address):
            raise ConnectionAbortedError("Initialization failure from server")

        monkeypatch.setattr(batch_module.ray, "init", dead_init)
        monkeypatch.setattr(batch_module.time, "sleep", lambda s: None)
        with pytest.raises(ConnectionAbortedError):
            batch_module.connect_ray("ray://head:10001", attempts=3, delay=0)
