#!/usr/bin/env python3
"""Download all Piper TTS voice models."""
import json
import os
import sys
import urllib.request
import concurrent.futures
from pathlib import Path

VOICES_DIR = Path(__file__).parent / "voices"
VOICES_JSON = VOICES_DIR / "voices.json"
HF_BASE = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/"

def download_file(url, dest):
    dest = Path(dest)
    if dest.exists() and dest.stat().st_size > 0:
        return f"SKIP {dest.name}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        urllib.request.urlretrieve(url, str(dest))
        return f"OK   {dest.name}"
    except Exception as e:
        return f"FAIL {dest.name}: {e}"

def main():
    with open(VOICES_JSON) as f:
        voices = json.load(f)

    tasks = []
    for voice_key, voice_info in voices.items():
        for file_path in voice_info["files"]:
            if file_path.endswith(".onnx") or file_path.endswith(".onnx.json"):
                url = HF_BASE + file_path + ("" if not file_path.endswith(".onnx") else "?download=true")
                dest = VOICES_DIR / file_path
                tasks.append((url, dest, voice_key, file_path))

    print(f"Total files to download: {len(tasks)}")
    completed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        future_map = {}
        for url, dest, vk, fp in tasks:
            future = executor.submit(download_file, url, dest)
            future_map[future] = (vk, fp)
        for future in concurrent.futures.as_completed(future_map):
            completed += 1
            vk, fp = future_map[future]
            result = future.result()
            print(f"[{completed}/{len(tasks)}] {result}")

    print("Done!")

if __name__ == "__main__":
    main()