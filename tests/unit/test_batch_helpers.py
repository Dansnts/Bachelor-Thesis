"""Pure helpers of the batch driver (deploy/jobs/batch/main.py).

ray and torch are stubbed by conftest so the module imports without the ML
stack. We test the EXIF conversion, the acquisition-id extraction, the progress
file and the S3 listing helpers (with the in-memory fake S3).
"""

import json


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
