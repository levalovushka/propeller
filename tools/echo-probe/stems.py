"""Расшифровать оба стема записи через сайдкар — так же, как это делает приложение.

Куда писать — `STEMS_OUT` (по умолчанию /tmp/attrib). Сайдкар должен быть поднят:
`gigastt serve --offline -p 9891 --model-dir "$HOME/Library/Application Support/Meeting Recorder/gigastt-models"`.

Куски по 20 минут (`GigasttChunking.chunkSeconds`), времена сдвигаются на начало
куска, сегменты и слова приходят одним ответом (`?segments=true`) — ровно те
данные, которые получит `TranscriptionService`.

Запуск: stems-http.py <id> [порт]
"""
import json
import os
import pathlib
import subprocess
import sys
import urllib.request

ID = sys.argv[1]
PORT = sys.argv[2] if len(sys.argv) > 2 else "9891"
CHUNK = 20 * 60
R = pathlib.Path.home() / ".meeting-recorder/recordings"
W = pathlib.Path(os.environ.get("STEMS_OUT", "/tmp/attrib"))


def duration(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", str(path)],
        capture_output=True, text=True, check=True)
    return float(out.stdout.strip())


def transcribe(path):
    with open(path, "rb") as f:
        body = f.read()
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/v1/transcribe?segments=true",
        data=body, headers={"Content-Type": "audio/wav"}, method="POST")
    with urllib.request.urlopen(req, timeout=1800) as r:
        return json.loads(r.read())


def stamp(t):
    ms = int(round(t * 1000))
    return f"{ms // 3600000:02d}:{(ms // 60000) % 60:02d}:{(ms // 1000) % 60:02d},{ms % 1000:03d}"


for stem in ("mic", "sys"):
    srt_path, json_path = W / f"{ID}.{stem}.srt", W / f"{ID}.{stem}.json"
    if srt_path.exists() and json_path.exists():
        print(f"уже есть: {ID}.{stem}")
        continue
    src = R / f"{ID}.{stem}.wav"
    total = duration(src)
    segments, words = [], []
    offset = 0.0
    while offset < total:
        piece = W / f"piece-{ID}-{stem}-{int(offset)}.wav"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
                        "-ss", str(offset), "-t", str(CHUNK),
                        "-ac", "1", "-ar", "16000", str(piece)], check=True)
        d = transcribe(piece)
        piece.unlink()
        for s in d.get("segments") or []:
            segments.append({"start": s["start"] + offset, "end": s["end"] + offset,
                             "text": s["text"]})
            for w in s.get("words") or []:
                words.append({"word": w["word"], "start": w["start"] + offset,
                              "end": w["end"] + offset})
        print(f"  {ID}.{stem} {int(offset)}с → сегментов {len(segments)}, слов {len(words)}")
        offset += CHUNK

    srt_path.write_text("\n".join(
        f"{i + 1}\n{stamp(s['start'])} --> {stamp(s['end'])}\n{s['text']}\n"
        for i, s in enumerate(segments)), encoding="utf-8")
    json_path.write_text(json.dumps({"words": words}, ensure_ascii=False), encoding="utf-8")
    print(f"готово: {ID}.{stem} — {len(segments)} сегментов, {len(words)} слов")
