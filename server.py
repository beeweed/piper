#!/usr/bin/env python3
"""Piper TTS Web Application - FastAPI Backend"""
import io
import json
import os
import subprocess
import tempfile
import wave
import struct
import math
import urllib.request
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

VOICES_DIR = Path(__file__).parent / "voices"
VOICES_JSON = VOICES_DIR / "voices.json"
HF_BASE = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/"

app = FastAPI(title="Piper TTS", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

voices_data = {}


def load_voices():
    global voices_data
    with open(VOICES_JSON) as f:
        voices_data = json.load(f)


load_voices()


def get_model_path(voice_key: str) -> Path:
    info = voices_data[voice_key]
    for fpath in info["files"]:
        if fpath.endswith(".onnx") and not fpath.endswith(".onnx.json"):
            return VOICES_DIR / fpath
    raise ValueError(f"No .onnx file for {voice_key}")


def get_config_path(voice_key: str) -> Path:
    info = voices_data[voice_key]
    for fpath in info["files"]:
        if fpath.endswith(".onnx.json"):
            return VOICES_DIR / fpath
    raise ValueError(f"No config for {voice_key}")


def is_voice_downloaded(voice_key: str) -> bool:
    try:
        mp = get_model_path(voice_key)
        cp = get_config_path(voice_key)
        return mp.exists() and mp.stat().st_size > 0 and cp.exists() and cp.stat().st_size > 0
    except (ValueError, KeyError):
        return False


def download_voice(voice_key: str):
    info = voices_data[voice_key]
    for fpath in info["files"]:
        if fpath.endswith(".onnx") or fpath.endswith(".onnx.json"):
            dest = VOICES_DIR / fpath
            if dest.exists() and dest.stat().st_size > 0:
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            url = HF_BASE + fpath
            urllib.request.urlretrieve(url, str(dest))


@app.get("/api/voices")
def list_voices():
    result = []
    for key, info in voices_data.items():
        result.append({
            "key": key,
            "name": info["name"],
            "language_code": info["language"]["code"],
            "language_english": info["language"]["name_english"],
            "language_native": info["language"]["name_native"],
            "country": info["language"]["country_english"],
            "quality": info["quality"],
            "num_speakers": info["num_speakers"],
            "speaker_id_map": info.get("speaker_id_map", {}),
            "downloaded": is_voice_downloaded(key),
        })
    result.sort(key=lambda x: (x["language_english"], x["name"], x["quality"]))
    return result


@app.post("/api/download/{voice_key}")
def download_voice_endpoint(voice_key: str):
    if voice_key not in voices_data:
        raise HTTPException(status_code=404, detail="Voice not found")
    if is_voice_downloaded(voice_key):
        return {"status": "already_downloaded"}
    try:
        download_voice(voice_key)
        return {"status": "downloaded"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class TTSRequest(BaseModel):
    text: str
    voice: str
    speaker_id: Optional[int] = None
    length_scale: Optional[float] = 1.0
    noise_scale: Optional[float] = 0.667
    noise_w: Optional[float] = 0.8


@app.post("/api/synthesize")
def synthesize(req: TTSRequest):
    if req.voice not in voices_data:
        raise HTTPException(status_code=404, detail="Voice not found")

    if not is_voice_downloaded(req.voice):
        try:
            download_voice(req.voice)
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Could not download voice: {e}")

    model_path = get_model_path(req.voice)
    config_path = get_config_path(req.voice)

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = tmp.name

    try:
        cmd = [
            "piper",
            "--model", str(model_path),
            "--config", str(config_path),
            "--output_file", tmp_path,
            "--length-scale", str(req.length_scale),
            "--noise-scale", str(req.noise_scale),
            "--noise-w-scale", str(req.noise_w),
        ]

        if req.speaker_id is not None:
            cmd.extend(["--speaker", str(req.speaker_id)])

        proc = subprocess.run(
            cmd,
            input=req.text.encode("utf-8"),
            capture_output=True,
            timeout=120,
        )

        if proc.returncode != 0:
            err = proc.stderr.decode("utf-8", errors="replace")
            raise HTTPException(status_code=500, detail=f"Piper error: {err}")

        with open(tmp_path, "rb") as f:
            wav_data = f.read()

        return Response(
            content=wav_data,
            media_type="audio/wav",
            headers={"Content-Disposition": f"attachment; filename=piper_tts.wav"},
        )
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


@app.post("/api/synthesize-waveform")
def synthesize_waveform(req: TTSRequest):
    if req.voice not in voices_data:
        raise HTTPException(status_code=404, detail="Voice not found")

    if not is_voice_downloaded(req.voice):
        try:
            download_voice(req.voice)
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Could not download voice: {e}")

    model_path = get_model_path(req.voice)
    config_path = get_config_path(req.voice)

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = tmp.name

    try:
        cmd = [
            "piper",
            "--model", str(model_path),
            "--config", str(config_path),
            "--output_file", tmp_path,
            "--length-scale", str(req.length_scale),
            "--noise-scale", str(req.noise_scale),
            "--noise-w-scale", str(req.noise_w),
        ]
        if req.speaker_id is not None:
            cmd.extend(["--speaker", str(req.speaker_id)])

        proc = subprocess.run(
            cmd,
            input=req.text.encode("utf-8"),
            capture_output=True,
            timeout=120,
        )

        if proc.returncode != 0:
            err = proc.stderr.decode("utf-8", errors="replace")
            raise HTTPException(status_code=500, detail=f"Piper error: {err}")

        with wave.open(tmp_path, "rb") as wf:
            n_channels = wf.getnchannels()
            sampwidth = wf.getsampwidth()
            framerate = wf.getframerate()
            n_frames = wf.getnframes()
            raw = wf.readframes(n_frames)

        if sampwidth == 2:
            samples = struct.unpack(f"<{n_frames * n_channels}h", raw)
        elif sampwidth == 1:
            samples = struct.unpack(f"<{n_frames * n_channels}B", raw)
            samples = [s - 128 for s in samples]
        else:
            samples = list(raw)

        if n_channels > 1:
            samples = samples[::n_channels]

        max_val = max(abs(s) for s in samples) if samples else 1
        if max_val == 0:
            max_val = 1
        normalized = [s / max_val for s in samples]

        num_bars = 512
        chunk_size = max(1, len(normalized) // num_bars)
        waveform = []
        for i in range(0, len(normalized), chunk_size):
            chunk = normalized[i:i + chunk_size]
            rms = math.sqrt(sum(x * x for x in chunk) / len(chunk))
            waveform.append(round(rms, 4))

        with open(tmp_path, "rb") as f:
            wav_data = f.read()

        import base64
        wav_b64 = base64.b64encode(wav_data).decode("ascii")

        return {
            "waveform": waveform[:num_bars],
            "sample_rate": framerate,
            "duration": n_frames / framerate,
            "num_samples": n_frames,
            "audio_base64": wav_b64,
        }
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


@app.get("/")
def serve_index():
    return FileResponse(Path(__file__).parent / "index.html")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)