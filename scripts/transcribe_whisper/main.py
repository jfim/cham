# /// script
# requires-python = ">=3.11"
# dependencies = ["faster-whisper>=1.0"]
# ///

import json
import sys
from pathlib import Path

from faster_whisper import WhisperModel


def main():
    if len(sys.argv) < 3:
        print("Usage: main.py <media_file> <output_dir> [--model MODEL] [--language LANG] [--device DEVICE]", file=sys.stderr)
        sys.exit(1)

    media_file = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])

    model_name = "turbo"
    language = None
    device = "auto"

    args = sys.argv[3:]
    i = 0
    while i < len(args):
        if args[i] == "--model" and i + 1 < len(args):
            model_name = args[i + 1]
            i += 2
        elif args[i] == "--language" and i + 1 < len(args):
            language = args[i + 1]
            i += 2
        elif args[i] == "--device" and i + 1 < len(args):
            device = args[i + 1]
            i += 2
        else:
            i += 1

    model = WhisperModel(model_name, device=device)

    segments, info = model.transcribe(
        str(media_file),
        language=language,
        beam_size=5,
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    transcript_path = output_dir / "transcript.md"

    total_duration = info.duration

    with open(transcript_path, "w", encoding="utf-8") as f:
        for segment in segments:
            start_ts = format_timestamp(segment.start)
            line = f"[{start_ts}] {segment.text.strip()}"
            f.write(line + "\n")

            if total_duration > 0:
                progress = min(segment.end / total_duration, 1.0)
                print(json.dumps({"progress": round(progress, 3), "message": "Transcribing..."}), flush=True)

    metadata = {
        "language": info.language,
        "duration": int(total_duration),
    }
    print(json.dumps(metadata), flush=True)


def format_timestamp(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    if h > 0:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


if __name__ == "__main__":
    main()
