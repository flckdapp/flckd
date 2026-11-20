#!/usr/bin/env python3
"""Prepare the bundled offline speech model. Run with uv run this-file.py."""

import hashlib
import json
from pathlib import Path
import shutil
import stat
import urllib.request
import uuid
import zipfile

VERSION = "0.7.1"
SHA256 = "058cde756a5e67bcdb986e7c45fe431d41a1a9073e68aabae314c80631a34b76"
URL = f"https://github.com/gradium-ai/xn-ptts/releases/download/v{VERSION}/phonon-31m-en-coreml.zip"
ROOT = Path(__file__).resolve().parents[2] / "ios" / "_phonon"
VOICES = ["Easton", "Harper"]


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    archive = ROOT / f"phonon-{VERSION}.zip"
    if not archive.exists():
        request = urllib.request.Request(URL, headers={"User-Agent": "FLCKD/1.0 (iOS; +https://flckd.app)"})
        partial = archive.with_suffix(".partial")
        with urllib.request.urlopen(request) as response, partial.open("wb") as out:
            shutil.copyfileobj(response, out)
        partial.replace(archive)
    with archive.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != SHA256:
        raise ValueError("Phonon archive SHA-256 mismatch; remove it and retry")
    # A new empty directory for every extraction; never follow archive links.
    staging = ROOT / f"extract-{uuid.uuid4()}"
    staging.mkdir()
    try:
        with zipfile.ZipFile(archive) as z:
            for item in z.infolist():
                path = Path(item.filename)
                mode = item.external_attr >> 16
                if path.is_absolute() or ".." in path.parts or stat.S_ISLNK(mode):
                    raise ValueError("Unsafe archive member")
            z.extractall(staging)
        bundles = list(staging.glob("*/bundle.json"))
        if len(bundles) != 1:
            raise ValueError("Expected one model bundle")
        bundle = bundles[0].parent
        manifest = json.loads(bundles[0].read_text())
        original_bytes = sum(p.stat().st_size for p in bundle.rglob("*") if p.is_file())
        for voice in (bundle / "voices").glob("*.safetensors"):
            if voice.stem not in VOICES:
                voice.unlink()
        manifest["voices"] = VOICES
        manifest["files"] = [item for item in manifest["files"]
                             if not item["path"].startswith("voices/")
                             or Path(item["path"]).stem in VOICES]
        # A distinct install identity replaces a previously installed full catalog.
        # PhononModels.install uses `built`, not the manifest hash, as its identity.
        manifest["built"] += 1
        bundles[0].write_text(json.dumps(manifest, indent=2) + "\n")
        saved = original_bytes - sum(p.stat().st_size for p in bundle.rglob("*") if p.is_file())
        target = ROOT / "Models"
        if target.exists():
            shutil.rmtree(target)
        bundles[0].parent.replace(target)
    finally:
        shutil.rmtree(staging)
    print(f"Phonon {VERSION}: verified {SHA256}; installed {ROOT / 'Models'}")
    print(f"Easton + Harper only: saved {saved:,} bytes versus the full catalog")


if __name__ == "__main__":
    main()
