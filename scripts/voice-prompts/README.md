# Recorded voice prompts

These development tools generate the audio bundled with the app. They are not
part of the app and never run on a user's phone. `phrases.json` must contain
generic lines only: every line is sent to ElevenLabs. Never add user data,
coordinates, street names, place names, or route-derived text.

The generator reads `ELEVENLABS_API_KEY` from the environment, then
`~/development/.env`, then the optional `elevenlabs-api-key` macOS Keychain
item. Never commit a key. Rendering uses the standard library; normalization
requires `ffmpeg` with AAC support.

From the repository root:

```sh
python3 -I scripts/voice-prompts/generate.py --plan
python3 -I scripts/voice-prompts/generate.py --voice cjVigY5qzO86Huf0OWal
python3 -I scripts/voice-prompts/normalize.py cjVigY5qzO86Huf0OWal ios/YoureFlocked/Resources/VoicePrompts/male
python3 -I scripts/voice-prompts/generate.py --voice r1KmysJdVYZjJCm4mL3b
python3 -I scripts/voice-prompts/normalize.py r1KmysJdVYZjJCm4mL3b ios/YoureFlocked/Resources/VoicePrompts/female
```

Eric (`cjVigY5qzO86Huf0OWal`) is Male; Jessica (`r1KmysJdVYZjJCm4mL3b`)
is Female. Eric is an ElevenLabs default voice. Jessica comes from the
ElevenLabs Voice Library, where its owner can withdraw it after a 730-day
notice period; that would only stop future re-renders, not the shipped files. Raw MP3 output stays in gitignored `ai-docs/voice-prompts/out/`.
Existing MP3 files are skipped; remove only the clips you intend to regenerate.
Normalization trims silence, targets -16 LUFS, limits peaks and writes mono
44.1 kHz AAC at 128 kbps with Apple's encoder (`aac_at`), so normalization needs
ffmpeg on macOS; ffmpeg's built-in AAC at 64 kbps audibly degraded bright voices. Both voice directories must keep identical clip keys.
Xcode copies `VoicePrompts` as a folder reference so the voices cannot flatten
onto each other. Run the voice manifest tests after regeneration.

`continue_distances` contains forty generic quarter-mile phrases, keyed
`continue_mi.0_25` through `continue_mi.10_00`. The original `continue_long`
recording handles distances over ten miles. Both tools accept `--keys` to
process a comma-separated subset and `--work-dir` to keep intermediates in a
different gitignored checkout. Generation keeps the existing
`eleven_multilingual_v2` model and seed 1; existing raw files are skipped.
Use the same key subset for normalization to leave older bundle files intact.

Metric adds 157 recordings per voice: five approach distances for each of the
23 actions (`2km`, `1km`, `500m`, `200m`, `100m`), thirty half-kilometer continue
phrases (`continue_km.0_50` through `continue_km.15_00`), and `200m`/`300m`/`400m`
distance alerts for each camera type. The phrases use US spelling, "kilometers"
and "meters". Lane and traffic-light phrases are shared by both unit systems.
Each voice folder contains 435 recordings in total.
