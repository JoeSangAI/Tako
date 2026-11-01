"""Turns pieces of a class's sound into words on this Mac, in whatever language is being spoken.

Reads one path per line on stdin and answers with one JSON line each. Runs in the Python that has Whisper,
which is not the one the server runs in. Each piece is deleted once read: the words stay, the sound does not.
"""
import json
import os
import sys
from pathlib import Path

import numpy as np
import whisper

MODELS = ("small", "base", "tiny")  # the best one already on this Mac


def choose():
    folder = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "whisper"
    return next((name for name in MODELS if (folder / f"{name}.pt").exists()), "tiny")


def main():
    name = choose()
    model = whisper.load_model(name, device="cpu")
    print(json.dumps({"ready": name}), flush=True)
    previous = ""
    for line in sys.stdin:
        path = Path(line.strip())
        try:
            audio = np.fromfile(path, dtype=np.float32)
        finally:
            path.unlink(missing_ok=True)
        if audio.size == 0 or np.sqrt(np.mean(audio ** 2)) < 0.002:  # silence: Whisper makes things up when given nothing
            print(json.dumps({"text": "", "language": ""}), flush=True)
            continue
        # The end of the last piece helps with names and terms, and keeps it in the same language.
        result = model.transcribe(audio, fp16=False, initial_prompt=previous[-200:] or None, condition_on_previous_text=False, no_speech_threshold=0.5)
        text = " ".join(s["text"].strip() for s in result["segments"] if s.get("no_speech_prob", 0) < 0.8).strip()
        previous = text or previous
        print(json.dumps({"text": text, "language": result.get("language", "")}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
