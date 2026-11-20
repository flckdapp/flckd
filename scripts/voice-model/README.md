# Bundled Phonon model

Before building, run from the repository root:

```sh
uv run scripts/voice-model/fetch_phonon.py
```

The script downloads xn-ptts 0.7.1's Core ML archive, verifies its pinned
SHA-256, extracts into a fresh directory, and keeps only Easton and Harper.
The model stays in gitignored `ios/_phonon/Models`; the Xcode build copies the
folder intact for every configuration and fails clearly if it is absent.
Run the same command in CI before xcodegen/build/archive. No model download
exists in the app. The source archive and the runtime's checksum are pinned
in the script and project.yml respectively. Retained model files are unmodified.

The bundle is about 154 MiB uncompressed. Keeping it out of ordinary git avoids
large binary history; builds need a network-enabled preparation step or a
verified cached copy of the directory. No Git LFS configuration is required.
