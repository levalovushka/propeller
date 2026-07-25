# Fixture: `ru-short-2spk`

Short synthetic Russian dialogue (~27 s, 16 kHz mono WAV) for batch metrics / golden E2E.

| File | Role |
|------|------|
| `final.wav` | Mixed meeting audio |
| `final.mic.wav` | Mic stem (speaker A loud) |
| `final.sys.wav` | System stem (speaker B loud) |
| `reference-transcript.txt` | Ground-truth text (WER/CER, Q1) |
| `reference-speakers.json` | Speaker turns / stem hints (DER, Q1) |

Regenerate (needs macOS `say` + `afconvert`):

```bash
../../../../tools/generate-fixture-ru-short.sh
```
