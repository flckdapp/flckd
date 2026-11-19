# The Kokoro voice pack

The optional Kokoro voice is one download that every platform shares. This
document is for whoever builds it into the Android app: it describes the files,
how they are checked, how the engine is configured, and the rules the iOS app
follows so both apps say the same thing.

## What is in it

The pack has two halves:

- **Prompt clips.** All 435 fixed prompts the recorded voices cover (turn
  prompts, distances, lanes, traffic lights, camera alerts) rendered in six
  Kokoro presets: Heart, Bella, Nicole, Fenrir, Michael and Puck. They are
  AAC-LC, mono, 44.1 kHz, 128 kbps, levelled to -16 LUFS, the same format as
  the bundled Eric and Jessica clips, and keyed the same way
  (`500ft.turn_right.m4a`). They play with no model loaded.
- **The street-name engine.** The Kokoro-82M v1.0 model (int8) for
  [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 2.0.1: `model.onnx`,
  `voices.bin`, `tokens.txt`, `lexicon-us-en.txt` and the model's `LICENSE`.
  It is used during a trip, only to say street names, and briefly for a
  live preview on the settings page.

The pack contains no eSpeak-NG code or data. sherpa-onnx 2.0.0 removed eSpeak
from the library; the upstream model archives still carry an
`espeak-ng-data/` folder, which the build script never extracts.

## Layout

On the tile server every object is immutable and named by its sha256:

```
v1/voice/kokoro/blobs/<sha256>
```

Each preset's clips are one uncompressed ustar archive whose members are
`<key>.m4a` at the top level. A model file larger than 128 MB is split into
128 MB parts; smaller files are one part.

The iOS app installs into Application Support, excluded from backup:

```
voice/kokoro/<packId>/clips/<preset>/<key>.m4a
voice/kokoro/<packId>/model/{model.onnx,voices.bin,tokens.txt,lexicon-us-en.txt,LICENSE}
```

## The descriptor

`ios/YoureFlocked/Resources/KokoroPack.json` is compiled into the app and is
the only thing the app trusts. The server is never asked which files to fetch
or what their hashes are; a file whose sha256 differs from the descriptor is
deleted and the download fails. Android should bundle the same file.

```json
{
  "schema": 1,
  "id": "kokoro-v1_0-int8-<yyyymmdd>",
  "engine": "sherpa-onnx 2.0.1",
  "presets": [
    { "id": "heart", "name": "Heart", "upstream": "af_heart", "sid": 3, "gain_db": 9.84,
      "clips": { "path": "v1/voice/kokoro/blobs/<sha256>", "bytes": 0, "sha256": "<sha256>", "count": 435 } }
  ],
  "model": { "files": [
    { "name": "model.onnx", "bytes": 0, "sha256": "<sha256>",
      "parts": [ { "path": "v1/voice/kokoro/blobs/<sha256>", "bytes": 0, "sha256": "<sha256>" } ] }
  ] }
}
```

- `sid` is the speaker id in `voices.bin`.
- `gain_db` is the gain the preset's clips needed to reach -16 LUFS. Apply it
  to live renders so street names match the clips' loudness, then limit peaks
  to 0.66 (1 ms attack, 50 ms release, as the clips were limited).
- A descriptor with a new `id` makes any older installed pack obsolete; delete it.

Download only when the user taps a download button. Fetch each object from
`<tile server>/<path>`, hash it while streaming, and install only on a match.
A 404 means the configured server doesn't offer the voice; never fall back to
another server.

## Building it

`scripts/voice-model/build_pack.py` (see its README) downloads the pinned
upstream archive, extracts the five files, adds three inflected words the
prompts need (`arrived`, `cameras`, `kilometers`), checks every prompt against
the word list, renders and levels the clips, measures each preset's gain,
writes the blobs and the descriptor. It never uploads.

## Engine settings

sherpa-onnx offline TTS, Kokoro model config with `model`, `voices`, `tokens`
and `lexicon` only (`dataDir`, `dictDir` and `lang` are ignored since 2.0.0).
Provider `cpu`, two threads, `debug` 0, speed 1.0. Output is 24 kHz mono
float; resample to the playback rate and trim leading and trailing silence
before measuring or playing.

## What text may reach the engine

The engine skips words it doesn't know, and it logs them whatever its debug
setting says. So the app sends only text it has checked, and a road name never
reaches a log:

- NFC-normalise and lowercase.
- Any character other than a letter, an ASCII apostrophe, a hyphen, a space or
  `, . ! ? ; :` fails the whole text.
- A word is a maximal run of letters and apostrophes. Every other character,
  punctuation included, is a boundary, exactly as in the engine.
- Every word must be in the first column of `lexicon-us-en.txt`.

Text that fails is not rendered, and the prompt plays without the name.

## Turning a road name into words

The name comes from the turn card's primary text, so the voice and the screen
agree. The rules, in order, are in `ios/YoureFlocked/Services/Navigation/SpokenRoadName.swift`,
and every case is pinned by the shared fixture
`ios/YoureFlockedTests/Navigation/Fixtures/spoken-road-names.json`, which the
Android tests should read too:

1. **Candidate.** None if the text is empty or ends with a full stop (it is a
   sentence). Keep what precedes the first `:`, the first item of a `,` `;` or
   `/` list, and drop a trailing `( … )`. Reject anything left with characters
   other than letters, digits, `'`, `-`, `.` and spaces.
2. **Route prefixes**, only before a number of 1 to 4 digits: `I` → Interstate,
   `US` → U S, `CR` → County Road, `SR` → State Route, any other two capital
   letters → Highway.
3. **Numbers** as road numbers are said: 412 → "four twelve", 905 → "nine oh
   five", 9920 → "ninety nine twenty". Ordinals 1st–999th: "thirty ninth",
   "one hundred second".
4. **Rejection.** Any remaining single letter, token with a full stop or a
   digit, or all-capital token of two to four letters drops the whole name.
5. The sentence is the prompt's own wording without its full stop, then
   "onto" (or "to take" after keep), the name, and a full stop:
   "In a quarter mile, turn left onto Main Street."

A name is never spoken in part.

## When names are spoken

- Approach prompts only (the ones with a distance), never the final "Turn
  left." or traffic-light prompts.
- Rendered ahead for the current step and the next two, nearest step first,
  one render at a time, and only while the app is in the foreground and the
  phone is not at a serious thermal state. A render already running when the
  app goes to the background may finish; no new one starts.
- Audio stays in memory only, for the steps in the window, and is dropped when
  they pass or the trip ends. The engine is unloaded at trip end and after a
  memory warning (for the rest of that trip).
- Playback never waits for a render. A named first clip is used only if it is
  at most 2.5 s longer than the name-free clip and the whole utterance, joins
  included, is at most 5.0 s, so a camera alert waiting behind it still plays.
- Phones under 5 GB of memory don't get names. A measured render speed slower
  than real time (render time over audio length above 1.0) switches names off
  until a new measurement says otherwise; the settings page offers "Test again".

## Lookup order and fallbacks

For each utterance, in order:

1. Kokoro audio with the street name, if rendered and within the limits above.
2. Kokoro prompt clips, if every clip of the utterance exists.
3. The recorded voice (Eric or Jessica), for the whole utterance.

An utterance never mixes voices. Previews of a Kokoro preset never fall back
to another voice: if the preset's files are missing or a live render fails,
the page says so, and if playback itself fails nothing plays.
