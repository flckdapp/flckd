# Kokoro voice pack

`build_pack.py` builds the optional Kokoro voice the app can download from the
tile server. It is a development tool. It never runs on a phone and never
uploads anything.

It needs [uv](https://docs.astral.sh/uv/) and `ffmpeg` with Apple's AAC
encoder (`aac_at`, macOS). uv installs the pinned `sherpa-onnx` 2.0.1 Python
package for the script; nothing else is installed.

From the repository root:

```sh
uv run scripts/voice-model/build_pack.py                   # int8, the variant the app uses
uv run scripts/voice-model/build_pack.py --check-only      # word-list check only
uv run scripts/voice-model/build_pack.py --variant fp32 --no-descriptor   # model files for the DEBUG bench
```

## What it does

1. Downloads the sherpa-onnx `kokoro-int8-multi-lang-v1_0` (or
   `kokoro-multi-lang-v1_0`) archive and checks it against the sha256 pinned in
   the script. A mismatch means upstream replaced the file; check it before
   changing the pin. Archives are kept in `ai-docs/kokoro/inputs/`.
2. Extracts five files: the model (renamed to `model.onnx`), `voices.bin`,
   `tokens.txt`, `lexicon-us-en.txt` and `LICENSE`. It appends three inflected
   words the prompts use (`arrived`, `cameras`, `kilometers`) to the word list,
   built from their stems, because the engine does no suffix handling.
3. Checks every sentence in `ios/YoureFlocked/Resources/PromptText.json`, and
   the vocabulary list of the road-name test fixture, against the word list.
   The engine silently skips unknown words, so every word must be known. Fix a
   failure with `kokoro_overrides` in `scripts/voice-prompts/generate.py`.
4. Renders all 435 fixed prompts in six presets (Heart, Bella, Nicole, Fenrir,
   Michael, Puck) and levels them with `scripts/voice-prompts/normalize.py`,
   exactly like Eric and Jessica: -16 LUFS, AAC 128 kbps, 44.1 kHz mono.
5. Measures the gain each preset needed (the median over the approach prompts)
   so the phone can apply the same gain to street names it renders live.
6. Writes one uncompressed tar of clips per preset, splits model files over
   128 MB, and names every object by its sha256 under
   `ai-docs/kokoro/site/v1/voice/kokoro/blobs/`.
7. Writes `ios/YoureFlocked/Resources/KokoroPack.json`. The app trusts only the
   hashes in this bundled file, never anything the server says.

## Uploading

The script prints an `rclone copy` command for the `v1/voice/` prefix with
immutable caching, using the same credentials as
`server/builder/bin/push-r2.sh`. That script never touches `v1/voice/`, so the
pack survives its pruning. Commit the new `KokoroPack.json` with the upload; a
build whose descriptor names files the server lacks cannot download the voice.

A self-hosted tile server needs the same `site/` tree to offer the voice.

## No eSpeak

The upstream archives carry an `espeak-ng-data/` folder, which is GPL. It is
never extracted, and the script fails if any output path mentions eSpeak.
sherpa-onnx 2.0.0 removed eSpeak from its code; the pack must never bring it
back as data.

## Licence

The model, voices and word list are Apache-2.0 (the `LICENSE` in the upstream
archive, shipped in the pack).
