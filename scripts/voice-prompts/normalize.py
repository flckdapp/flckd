"""Trim, loudness-normalise and encode rendered clips for the app bundle.

  python3 -I normalize.py <voice_id> <out_dir>

Each clip: leading/trailing silence trimmed, measured with EBU R128, gained to -16 LUFS integrated,
peaks limited to leave about 1.5 dB of true-peak headroom after AAC encoding, then AAC-LC mono 64 kbps 44.1 kHz .m4a.
"""
import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
WORK = HERE.parents[1] / "ai-docs" / "voice-prompts"
TRIM = ("silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.02,"
        "areverse,silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.06,areverse")
TARGET = "I=-16:TP=-1.5:LRA=11"


def run(args):
    return subprocess.run(["ffmpeg", "-hide_banner", "-nostats", *args], capture_output=True, text=True)


def main():
    src = WORK / "out" / sys.argv[1]
    dst = pathlib.Path(sys.argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    clips = sorted(src.glob("*.mp3"))
    for f in clips:
        probe = run(["-i", str(f), "-af", f"{TRIM},loudnorm={TARGET}:print_format=json", "-f", "null", "-"])
        text = probe.stderr
        m = json.loads(text[text.rindex("{"):text.rindex("}") + 1])
        # Plain gain to the target, then a brick-wall limiter for the peaks. loudnorm's
        # linear mode silently falls back to dynamic when the true-peak ceiling binds,
        # which left short clips up to 6 dB quiet.
        gain = -16.0 - float(m["input_i"])
        second = (f"{TRIM},volume={gain:.2f}dB,"
                  f"alimiter=limit=0.66:attack=1:release=50:level=false,aresample=44100")
        out = dst / (f.stem + ".m4a")
        r = run(["-loglevel", "error", "-y", "-i", str(f), "-af", second,
                 "-ac", "1", "-c:a", "aac", "-b:a", "64k", str(out)])
        if r.returncode != 0:
            sys.exit(f"{f.name}: {r.stderr[-400:]}")
    print(f"normalised {len(clips)} clips into {dst}")


if __name__ == "__main__":
    main()
