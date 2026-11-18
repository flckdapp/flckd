"""Render the guidance phrase set with ElevenLabs.

Development tool. Sends only the generic lines in phrases.json.

  python3 -I generate.py --plan                    # list clips and character cost, no network
  python3 -I generate.py --voices                  # list voices on the account
  python3 -I generate.py --voice ID --sample       # render a handful to audition
  python3 -I generate.py --voice ID                # render everything (skips existing files)

The API key comes from $ELEVENLABS_API_KEY, ~/development/.env, or the macOS keychain item
"elevenlabs-api-key" (security add-generic-password -s elevenlabs-api-key -a "$USER" -w).
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
WORK = HERE.parents[1] / "ai-docs" / "voice-prompts"
API = "https://api.elevenlabs.io"
SIGNAL_ACTIONS = ["turn_left", "turn_right", "slight_left", "slight_right", "uturn", "continue"]
SAMPLE = ["turn_left", "500ft.turn_right", "half_mi.exit_right", "at_light.turn_left",
          "lane_right2", "roundabout_2", "arrive_right", "rerouting"]


def sentence(text):
    text = text[0].upper() + text[1:]
    return text if text.endswith((".", ",")) else text + "."


def clips():
    p = json.loads((HERE / "phrases.json").read_text())
    out = {}
    for k, a in p["actions"].items():
        out[k] = sentence(a)
        for dk, d in p["distances_imperial"].items():
            out[f"{dk}.{k}"] = sentence(f"{d}, {a}")
    for k, t in p["lanes"].items():
        out[k] = sentence(t)
    for sk, s in p["signals"].items():
        for k in SIGNAL_ACTIONS:
            out[f"{sk}.{k}"] = sentence(f"{s} {p['actions'][k]}")
    for k, t in p["standalone"].items():
        out[k] = sentence(t) if k != "then" else "then"
    c = p.get("cameras", {})
    for tk, tname in c.get("types", {}).items():
        for group in ("where", "distance"):
            for wk, tmpl in c[group].items():
                out[f"cam.{tk}.{wk}"] = sentence(tmpl.replace("{T}", tname))
        out[f"cam.{tk}.passing"] = sentence(c["passing"].replace("{T}", tname))
        out[f"cam.{tk}.in_view"] = sentence(c["in_view"].replace("{T}", tname))
    for k, t in c.get("standalone", {}).items():
        out[f"cam.{k}"] = sentence(t)
    return out


def api_key():
    key = os.environ.get("ELEVENLABS_API_KEY")
    if key:
        return key
    env = pathlib.Path.home() / "development" / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            name, _, value = line.strip().removeprefix("export ").partition("=")
            if name.strip() == "ELEVENLABS_API_KEY" and value.strip():
                return value.strip().strip("'\"")
    try:
        return subprocess.run(
            ["security", "find-generic-password", "-s", "elevenlabs-api-key", "-w"],
            check=True, capture_output=True, text=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        sys.exit("No API key: set ELEVENLABS_API_KEY or add keychain item 'elevenlabs-api-key'.")


def request(method, path, key, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"xi-api-key": key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path.split('?')[0]}: HTTP {e.code} {e.read()[:300]!r}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--voices", action="store_true")
    ap.add_argument("--voice")
    ap.add_argument("--model", default="eleven_multilingual_v2")
    ap.add_argument("--sample", action="store_true")
    ap.add_argument("--keys", help="comma-separated clip keys to render")
    a = ap.parse_args()

    all_clips = clips()
    if a.plan:
        for k, t in all_clips.items():
            print(f"{k:28} {t}")
        print(f"\n{len(all_clips)} clips, {sum(len(t) for t in all_clips.values())} characters")
        return

    key = api_key()
    if a.voices:
        data = json.loads(request("GET", "/v2/voices?page_size=100", key))
        for v in data.get("voices", []):
            lab = v.get("labels") or {}
            print(f"{v['voice_id']}  {v['name']:24} {lab.get('accent', ''):12} {lab.get('gender', ''):8} {v.get('category', '')}")
        return

    if not a.voice:
        sys.exit("--voice is required")
    if a.keys:
        wanted = {k: all_clips[k] for k in a.keys.split(",")}
    elif a.sample:
        wanted = {k: all_clips[k] for k in SAMPLE}
    else:
        wanted = all_clips
    out = WORK / "out" / a.voice
    out.mkdir(parents=True, exist_ok=True)
    for k, text in wanted.items():
        f = out / f"{k}.mp3"
        if f.exists():
            continue
        audio = request("POST", f"/v1/text-to-speech/{a.voice}?output_format=mp3_44100_128", key,
                        {"text": text, "model_id": a.model, "seed": 1})
        f.write_bytes(audio)
        print(f"{k:28} {len(audio):7d} B  {text}")
    print(f"done: {out}")


if __name__ == "__main__":
    main()
