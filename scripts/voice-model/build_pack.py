# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["sherpa-onnx==2.0.1"]
# ///
"""Build the Kokoro voice pack: model files plus every fixed prompt pre-rendered
in six presets, with no eSpeak data.

Development tool. It downloads the public Kokoro model from the sherpa-onnx
release, renders the generic sentences in PromptText.json on this Mac, and
writes content-addressed files for the tile server. It never uploads.

  uv run scripts/voice-model/build_pack.py                     # int8, full build
  uv run scripts/voice-model/build_pack.py --check-only        # word-list check only
  uv run scripts/voice-model/build_pack.py --variant fp32 --no-descriptor   # bench model only

Outputs (all gitignored, under ai-docs/kokoro/):
  inputs/   upstream tarballs, kept so a replaced upstream file is noticed
  pack/<variant>/  the five model files
  out/<preset>/    raw 24 kHz renders
  clips/<preset>/  levelled AAC clips, as in the app bundle
  site/v1/voice/kokoro/blobs/<sha256>   what is uploaded
and ios/YoureFlocked/Resources/KokoroPack.json, the descriptor the app trusts.
"""
import argparse
import hashlib
import io
import json
import pathlib
import re
import statistics
import subprocess
import sys
import tarfile
import time
import unicodedata
import urllib.request
import wave

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORK = ROOT / "ai-docs" / "kokoro"
PROMPT_TEXT = ROOT / "ios" / "YoureFlocked" / "Resources" / "PromptText.json"
DESCRIPTOR = ROOT / "ios" / "YoureFlocked" / "Resources" / "KokoroPack.json"
FIXTURE = ROOT / "ios" / "YoureFlockedTests" / "Navigation" / "Fixtures" / "spoken-road-names.json"
NORMALIZE = ROOT / "scripts" / "voice-prompts" / "normalize.py"
RELEASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/"

# Upstream archives, pinned. A mismatch means upstream replaced the file: stop and look.
VARIANTS = {
    "int8": {"archive": "kokoro-int8-multi-lang-v1_0.tar.bz2", "model": "model.int8.onnx",
             "sha256": "72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653"},
    "fp32": {"archive": "kokoro-multi-lang-v1_0.tar.bz2", "model": "model.onnx",
             "sha256": "60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4"},
}
KEEP = ["voices.bin", "tokens.txt", "lexicon-us-en.txt", "LICENSE"]

# Speaker ids from sherpa-onnx scripts/kokoro/v1.0/generate_voices_bin.py at v2.0.1.
PRESETS = [
    {"id": "heart", "name": "Heart", "upstream": "af_heart", "sid": 3},
    {"id": "bella", "name": "Bella", "upstream": "af_bella", "sid": 2},
    {"id": "nicole", "name": "Nicole", "upstream": "af_nicole", "sid": 6},
    {"id": "fenrir", "name": "Fenrir", "upstream": "am_fenrir", "sid": 14},
    {"id": "michael", "name": "Michael", "upstream": "am_michael", "sid": 16},
    {"id": "puck", "name": "Puck", "upstream": "am_puck", "sid": 18},
]

# The upstream list has no inflected forms (misaki derives them at run time; the
# engine does not). These prompt words are added, built from their stems with
# misaki's own suffix rule, so Kokoro says exactly what the recordings say.
EXTRA_LEXICON = {
    "arrived": "əɹˈIvd",       # arrive + d
    "cameras": "kˈæməɹəz",     # camera + z
    "kilometers": "kəlˈɑməɾəɹz",  # kilometer + z
}

PART = 128 * 1024 * 1024
ALLOWED = set(" '-,.!?;:")


def words(text):
    """P12: None if any character is outside letters, ', -, space and , . ! ? ; :
    Otherwise the maximal runs of letters and apostrophes, lowercased."""
    text = unicodedata.normalize("NFC", text).lower()
    if any(not (c.isalpha() or c in ALLOWED) for c in text):
        return None
    return "".join(c if c.isalpha() or c == "'" else " " for c in text).split()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(variant):
    v = VARIANTS[variant]
    dst = WORK / "inputs" / v["archive"]
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not dst.exists():
        print(f"downloading {v['archive']}")
        urllib.request.urlretrieve(RELEASE + v["archive"], dst)
    digest = sha256(dst)
    if v["sha256"] is None:
        sys.exit(f"{v['archive']} is not pinned. sha256 {digest}: check it, then set it in VARIANTS.")
    if digest != v["sha256"]:
        sys.exit(f"{v['archive']}: sha256 {digest} does not match the pinned {v['sha256']}")
    return dst


def extract(variant, archive):
    out = WORK / "pack" / variant
    out.mkdir(parents=True, exist_ok=True)
    wanted = {VARIANTS[variant]["model"]: "model.onnx", **{k: k for k in KEEP}}
    with tarfile.open(archive, "r:bz2") as tar:
        for member in tar.getmembers():
            name = pathlib.PurePosixPath(member.name).name
            parts = pathlib.PurePosixPath(member.name).parts
            if len(parts) != 2 or name not in wanted or not member.isfile():
                continue
            data = tar.extractfile(member).read()
            (out / wanted[name]).write_bytes(data)
    missing = [n for n in wanted.values() if not (out / n).exists()]
    if missing:
        sys.exit(f"missing from archive: {missing}")
    lexicon = out / "lexicon-us-en.txt"
    known = {line.split(" ", 1)[0] for line in lexicon.read_text(encoding="utf-8").splitlines()}
    extra = [f"{w} {' '.join(p)}" for w, p in EXTRA_LEXICON.items() if w not in known]
    if extra:
        with open(lexicon, "a", encoding="utf-8") as f:
            f.write("\n".join(extra) + "\n")
    for p in WORK.rglob("*"):
        if "espeak" in str(p.relative_to(WORK)).lower() and "inputs" not in p.parts:
            sys.exit(f"eSpeak data found in output: {p}")
    return out


def check(pack):
    known = {line.split(" ", 1)[0] for line in (pack / "lexicon-us-en.txt").read_text(encoding="utf-8").splitlines()}
    sentences = json.loads(PROMPT_TEXT.read_text())
    bad = 0
    for key, text in sorted(sentences.items()):
        ws = words(text)
        if ws is None:
            print(f"bad characters  {key}: {text}")
            bad += 1
            continue
        missing = [w for w in ws if w not in known]
        if missing:
            print(f"missing {missing}  {key}: {text}")
            bad += 1
    vocab_missing = []
    if FIXTURE.exists():
        vocab = json.loads(FIXTURE.read_text()).get("vocabulary", [])
        vocab_missing = sorted(w for w in vocab if w.lower() not in known)
        if vocab_missing:
            print(f"vocabulary words missing from the word list: {vocab_missing}")
        else:
            print(f"all {len(vocab)} vocabulary words covered")
    if bad or vocab_missing:
        sys.exit(1)
    print(f"all {len(sentences)} sentences covered")
    return sentences


def engine(pack, threads):
    import sherpa_onnx
    config = sherpa_onnx.OfflineTtsConfig(
        model=sherpa_onnx.OfflineTtsModelConfig(
            kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(
                model=str(pack / "model.onnx"), voices=str(pack / "voices.bin"),
                tokens=str(pack / "tokens.txt"), lexicon=str(pack / "lexicon-us-en.txt")),
            num_threads=threads, debug=False, provider="cpu"))
    return sherpa_onnx, sherpa_onnx.OfflineTts(config)


def render_preset(pack, sentences, threads, preset):
    import array
    sherpa_onnx, tts = engine(pack, threads)
    out = WORK / "out" / preset["id"]
    out.mkdir(parents=True, exist_ok=True)
    start = time.time()
    made = 0
    for key, text in sentences.items():
        path = out / f"{key}.wav"
        if path.exists():
            continue
        gen = sherpa_onnx.GenerationConfig()
        gen.sid = preset["sid"]
        gen.speed = 1.0
        audio = tts.generate(text, gen)
        if len(audio.samples) == 0:
            raise RuntimeError(f"{preset['id']}/{key}: no audio")
        pcm = array.array("h", (int(max(-1.0, min(1.0, s)) * 32767) for s in audio.samples))
        tmp = path.with_suffix(".tmp")
        with wave.open(str(tmp), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(audio.sample_rate)
            w.writeframes(pcm.tobytes())
        tmp.rename(path)
        made += 1
    return f"{preset['id']}: rendered {made} clips in {time.time() - start:.0f} s"


def render(pack, sentences, threads, jobs):
    from concurrent.futures import ProcessPoolExecutor
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        for line in pool.map(render_preset, [pack] * len(PRESETS), [sentences] * len(PRESETS),
                             [threads] * len(PRESETS), PRESETS):
            print(line, flush=True)


TRIM = ("silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.02,"
        "areverse,silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.06,areverse")


def loudness(path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af",
                        f"{TRIM},loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
                       capture_output=True, text=True)
    t = r.stderr
    return float(json.loads(t[t.rindex("{"):t.rindex("}") + 1])["input_i"])


APPROACH = re.compile(r"^(500ft|1000ft|quarter_mi|half_mi|1mi|2mi|100m|200m|500m|1km|2km)\.[a-z0-9_]+$")


def level(sentences):
    gains = {}
    for preset in PRESETS:
        dst = WORK / "clips" / preset["id"]
        if len(list(dst.glob("*.m4a"))) != len(sentences):
            subprocess.run([sys.executable, "-I", str(NORMALIZE), preset["id"], str(dst),
                            "--work-dir", str(WORK), "--ext", "wav"], check=True)
        values = [-16.0 - loudness(WORK / "out" / preset["id"] / f"{k}.wav")
                  for k in sorted(sentences) if APPROACH.match(k)]
        gains[preset["id"]] = round(statistics.median(values), 2)
        print(f"{preset['id']}: gain_db {gains[preset['id']]}")
    return gains


def blob(data_or_path, site):
    blobs = site / "v1" / "voice" / "kokoro" / "blobs"
    blobs.mkdir(parents=True, exist_ok=True)
    data = data_or_path.read_bytes() if isinstance(data_or_path, pathlib.Path) else data_or_path
    digest = hashlib.sha256(data).hexdigest()
    (blobs / digest).write_bytes(data)
    return {"path": f"v1/voice/kokoro/blobs/{digest}", "bytes": len(data), "sha256": digest}


def archive(preset_id):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for f in sorted((WORK / "clips" / preset_id).glob("*.m4a")):
            info = tarfile.TarInfo(f.name)
            info.size = f.stat().st_size
            info.mtime = 0
            info.mode = 0o644
            info.uname = info.gname = ""
            with open(f, "rb") as fh:
                tar.addfile(info, fh)
    return buf.getvalue()


def publish(variant, pack, sentences, gains):
    site = WORK / "site"
    presets = []
    for preset in PRESETS:
        entry = blob(archive(preset["id"]), site)
        entry["count"] = len(list((WORK / "clips" / preset["id"]).glob("*.m4a")))
        presets.append({**preset, "gain_db": gains[preset["id"]], "clips": entry})
    files = []
    for name in ["model.onnx", *KEEP]:
        data = (pack / name).read_bytes()
        parts = [blob(data[i:i + PART], site) for i in range(0, len(data), PART)]
        files.append({"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "parts": parts})
    descriptor = {
        "schema": 1,
        "id": f"kokoro-v1_0-{variant}-{time.strftime('%Y%m%d')}",
        "engine": "sherpa-onnx 2.0.1",
        "presets": presets,
        "model": {"files": files},
    }
    DESCRIPTOR.write_text(json.dumps(descriptor, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {DESCRIPTOR.relative_to(ROOT)} ({descriptor['id']})")
    print("upload with (credentials as for server/builder/bin/push-r2.sh):")
    print(f"  rclone copy {site}/v1/voice S3:<bucket>/v1/voice --transfers 8 \\\n"
          "    --header-upload 'Cache-Control: public, max-age=31536000, immutable' \\\n"
          "    --header-upload 'Content-Type: application/octet-stream'")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", choices=VARIANTS, default="int8")
    ap.add_argument("--check-only", action="store_true", help="extract and check the word list, nothing else")
    ap.add_argument("--no-descriptor", action="store_true",
                    help="extract the model files only (for the DEBUG bench); leave clips and descriptor alone")
    ap.add_argument("--threads", type=int, default=2, help="engine threads per preset")
    ap.add_argument("--jobs", type=int, default=6, help="presets rendered at once")
    a = ap.parse_args()
    pack = extract(a.variant, fetch(a.variant))
    sentences = check(pack)
    if a.check_only or a.no_descriptor:
        print(f"model files in {pack.relative_to(ROOT)}")
        return
    render(pack, sentences, a.threads, a.jobs)
    gains = level(sentences)
    publish(a.variant, pack, sentences, gains)


if __name__ == "__main__":
    main()
