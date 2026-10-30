"""Speed-camera extraction and publishing.

Run from server/:  python3 -m unittest discover -s builder/tests

Every coordinate here is a synthetic grid point, not a place.
"""
import hashlib
import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin"
sys.path.insert(0, str(BIN))

import extract_cameras as ex  # noqa: E402


def node(lat, lon, **tags):
    return (lat, lon, tags)


class ExtractTests(unittest.TestCase):

    def test_speed_camera_node_is_kept_with_its_own_id(self):
        cams = ex.build_cameras({7: node(40.25, -75.5, highway="speed_camera")}, [])

        self.assertEqual(cams, [{"id": 7, "lat": 40.25, "lon": -75.5,
                                 "tags": {"highway": "speed_camera"}}])

    def test_enforcement_relation_is_placed_on_its_device_with_a_negative_id(self):
        nodes = {1: node(40.0, -75.0), 2: node(40.5, -75.5)}
        rel = (9, {"type": "enforcement", "enforcement": "maxspeed", "maxspeed": "50"},
               [("n", 1, "from"), ("n", 2, "device")])

        cams = ex.build_cameras(nodes, [rel])

        self.assertEqual([(c["id"], c["lat"], c["lon"]) for c in cams], [(-9, 40.5, -75.5)])
        self.assertEqual(cams[0]["tags"]["maxspeed"], "50")

    def test_relation_without_a_device_falls_back_to_from(self):
        nodes = {1: node(40.0, -75.0)}
        rel = (9, {"type": "enforcement", "enforcement": "traffic_signals"}, [("n", 1, "from")])

        self.assertEqual([c["lat"] for c in ex.build_cameras(nodes, [rel])], [40.0])

    def test_relation_whose_device_is_already_a_camera_node_is_not_duplicated(self):
        nodes = {2: node(40.5, -75.5, highway="speed_camera")}
        rel = (9, {"type": "enforcement", "enforcement": "maxspeed"}, [("n", 2, "device")])

        self.assertEqual([c["id"] for c in ex.build_cameras(nodes, [rel])], [2])

    def test_only_speed_and_red_light_enforcement_counts(self):
        nodes = {
            1: node(40.0, -75.0, enforcement="toll"),
            2: node(40.1, -75.0, enforcement="maxspeed;traffic_signals"),
            3: node(40.2, -75.0),
        }
        rels = [
            (8, {"type": "enforcement", "enforcement": "check"}, [("n", 3, "device")]),
            (9, {"type": "enforcement", "enforcement": "average_speed"}, [("n", 3, "device")]),
        ]

        self.assertEqual([c["id"] for c in ex.build_cameras(nodes, rels)], [-9, 2])

    def test_relation_with_no_located_node_is_dropped(self):
        rel = (9, {"type": "enforcement", "enforcement": "maxspeed"}, [("w", 5, "device")])

        self.assertEqual(ex.build_cameras({}, [rel]), [])

    def test_identical_data_renders_identical_bytes(self):
        nodes_a = {1: node(40.0, -75.0, highway="speed_camera", b="2", a="1"),
                   2: node(40.1, -75.0, highway="speed_camera")}
        nodes_b = dict(reversed(list(nodes_a.items())))

        a = ex.render(ex.build_cameras(nodes_a, []), "2026-10-28")
        b = ex.render(ex.build_cameras(nodes_b, []), "2026-10-28")

        self.assertEqual(a, b)
        doc = json.loads(a)
        self.assertEqual(doc["license"], "ODbL-1.0")
        self.assertEqual(doc["count"], 2)
        self.assertNotIn("generated_at", doc)


class PublishTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.docroot = root / "site"
        self.staging = root / "staging"
        self.staging.mkdir()
        self.regions = root / "regions.json"
        self.regions.write_text(json.dumps({"packs": [{"id": "test", "name": "Test"}]}))
        with tarfile.open(self.staging / "test.tar", "w") as tf:
            info = tarfile.TarInfo("index.bin")
            info.size = 4
            tf.addfile(info, io.BytesIO(b"\0\0\0\0"))
        self.version = 0

    def tearDown(self):
        self.tmp.cleanup()

    def camera_file(self, count):
        self.version += 1
        path = Path(self.tmp.name) / ("cams-%d.json" % self.version)
        cams = [{"id": i, "lat": 40.0, "lon": -75.0, "tags": {}} for i in range(1, count + 1)]
        path.write_bytes(ex.render(cams, "2026-10-28"))
        return path

    def publish(self, *args):
        return subprocess.run([sys.executable, str(BIN / "publish.py"),
                               "--docroot", str(self.docroot), *args],
                              capture_output=True, text=True)

    def release(self, cameras):
        result = self.publish("--staging", str(self.staging), "--regions", str(self.regions),
                              "--build-id", "r1", "--cameras", str(cameras))
        self.assertEqual(result.returncode, 0, result.stderr)

    def refresh(self, cameras, job="c1"):
        result = self.publish("--build-id", job, "--cameras", str(cameras), "--cameras-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def pointer(self):
        return json.loads((self.docroot / "v1" / "manifest.json").read_text())

    def camera_files(self):
        return sorted(p.name for p in (self.docroot / "v1" / "cameras").iterdir())

    def test_release_publishes_the_file_at_its_own_hash(self):
        cams = self.camera_file(3)

        self.release(cams)

        entry = self.pointer()["speed_cameras"]
        digest = hashlib.sha256(cams.read_bytes()).hexdigest()
        self.assertEqual(entry["path"], "/v1/cameras/%s.json" % digest)
        self.assertEqual((entry["count"], entry["sha256"]), (3, digest))
        self.assertEqual((self.docroot / entry["path"].lstrip("/")).read_bytes(), cams.read_bytes())
        release = json.loads((self.docroot / "v1" / "releases" / "r1" / "manifest.json").read_text())
        self.assertEqual(release["speed_cameras"]["path"], entry["path"])

    def test_cameras_only_updates_the_pointer_and_nothing_else(self):
        self.release(self.camera_file(1))
        packs = self.pointer()["packs"]
        release_before = (self.docroot / "v1" / "releases" / "r1" / "manifest.json").read_bytes()

        self.refresh(self.camera_file(2), job="cam-job")

        pointer = self.pointer()
        self.assertEqual(pointer["packs"], packs)
        self.assertEqual(pointer["build_id"], "r1")
        self.assertEqual((pointer["speed_cameras"]["count"], pointer["speed_cameras"]["build_id"]),
                         (2, "cam-job"))
        self.assertEqual((self.docroot / "v1" / "releases" / "r1" / "manifest.json").read_bytes(),
                         release_before)

    def test_unchanged_cameras_keep_their_url(self):
        same = self.camera_file(2)
        self.release(same)

        result = self.refresh(same)

        self.assertTrue(result["unchanged"])
        self.assertEqual(len(self.camera_files()), 1)

    def test_old_files_are_pruned_but_the_previous_and_release_files_stay(self):
        self.release(self.camera_file(1))
        second = self.refresh(self.camera_file(2))["speed_cameras"]["path"]
        third = self.refresh(self.camera_file(3))["speed_cameras"]["path"]

        self.refresh(self.camera_file(4))

        names = self.camera_files()
        self.assertEqual(len(names), 3)
        self.assertNotIn(second.rsplit("/", 1)[1], names)
        self.assertIn(third.rsplit("/", 1)[1], names)

    def test_cameras_only_without_a_release_fails(self):
        result = self.publish("--build-id", "c1", "--cameras", str(self.camera_file(1)),
                              "--cameras-only")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("run a full build first", result.stderr)


if __name__ == "__main__":
    unittest.main()
