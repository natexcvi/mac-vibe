#!/usr/bin/env python3
"""
VibeVoice ASR sidecar.

Protocol (line-delimited JSON on stdin/stdout):

    -> {"cmd": "transcribe", "id": "<uuid>", "audio_path": "/tmp/x.wav"}
    <- {"type": "status", "state": "loading" | "ready" | "error", ...}
    <- {"type": "transcription", "id": "<uuid>", "text": "..."}
    <- {"type": "error", "id": "<uuid>", "error": "..."}

    -> {"cmd": "shutdown"}

The model (microsoft/VibeVoice-ASR-7B) is loaded once at startup, then held in
memory for the life of the process. On Apple Silicon we use the MPS backend.
"""
from __future__ import annotations

import json
import os
import sys
import time
import traceback
from typing import Any

MODEL_ID = os.environ.get("MACVIBE_MODEL", "microsoft/VibeVoice-ASR-HF")


def emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False))
    sys.stdout.write("\n")
    sys.stdout.flush()


def log(msg: str) -> None:
    sys.stderr.write(f"[sidecar] {msg}\n")
    sys.stderr.flush()


def load_model():
    emit({"type": "status", "state": "loading", "model": MODEL_ID})

    import torch  # noqa: WPS433

    if torch.backends.mps.is_available():
        device = "mps"
        dtype = torch.float16
    elif torch.cuda.is_available():
        device = "cuda"
        dtype = torch.float16
    else:
        device = "cpu"
        dtype = torch.float32
    log(f"device={device} dtype={dtype} model={MODEL_ID}")

    # VibeVoice ASR shipped natively in transformers>=5.3. That's the canonical
    # loader — don't use the third-party vibevoice package (different class,
    # different weight layout, incompatible config mapping).
    from transformers import AutoProcessor, VibeVoiceAsrForConditionalGeneration  # type: ignore

    log("loading VibeVoiceAsrForConditionalGeneration from transformers")
    processor = AutoProcessor.from_pretrained(MODEL_ID)
    model = VibeVoiceAsrForConditionalGeneration.from_pretrained(
        MODEL_ID,
        dtype=dtype,
        low_cpu_mem_usage=True,
    )

    model = model.to(device)
    model.eval()
    return processor, model, device, dtype


def load_audio(path: str):
    import soundfile as sf  # noqa: WPS433

    audio, sr = sf.read(path, dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != 16_000:
        try:
            import librosa  # noqa: WPS433

            audio = librosa.resample(audio, orig_sr=sr, target_sr=16_000)
            sr = 16_000
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(
                f"audio is {sr} Hz and librosa is unavailable for resample: {exc}"
            ) from exc
    return audio, sr


_TRANSCRIBE_PROMPT = "Transcribe the audio."


def _extract_plain_text(raw: str) -> str:
    """VibeVoice-ASR emits a JSON array of segments with Speaker/Start/End/Content.
    For dictation we only want the concatenated Content field, stripped."""
    import json  # local — avoid polluting top-level imports

    candidate = raw.strip()
    # The model sometimes wraps output in code fences or prose; find a [ ... ].
    start = candidate.find("[")
    end = candidate.rfind("]")
    if start != -1 and end > start:
        candidate = candidate[start : end + 1]
    try:
        segments = json.loads(candidate)
    except Exception:  # noqa: BLE001
        return raw.strip()

    if not isinstance(segments, list):
        return raw.strip()

    parts: list[str] = []
    for seg in segments:
        if isinstance(seg, dict):
            content = seg.get("Content") or seg.get("content") or seg.get("text")
            if isinstance(content, str) and content.strip():
                parts.append(content.strip())
    if not parts:
        return raw.strip()
    return " ".join(parts)


def transcribe(processor, model, device, audio_path: str) -> str:
    import torch  # noqa: WPS433

    audio, sr = load_audio(audio_path)
    log(f"loaded audio: {len(audio)} samples @ {sr} Hz ({len(audio)/sr:.2f}s)")

    # VibeVoice-ASR is conversational: we feed it a chat-templated prompt with
    # an audio placeholder and ask it to transcribe.
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "audio"},
                {"type": "text", "text": _TRANSCRIBE_PROMPT},
            ],
        }
    ]
    text_prompt = processor.apply_chat_template(
        messages, add_generation_prompt=True, tokenize=False
    )
    inputs = processor(text=text_prompt, audio=[audio], return_tensors="pt")

    # The feature extractor emits float32, but we loaded the model in fp16 on
    # MPS. Cast any floating-point tensors to match the model's dtype; leave
    # integer tensors (input_ids, masks) alone.
    model_dtype = next(model.parameters()).dtype
    casted = {}
    for k, v in inputs.items():
        if hasattr(v, "to"):
            if hasattr(v, "dtype") and v.dtype in (torch.float16, torch.float32, torch.bfloat16):
                casted[k] = v.to(device=device, dtype=model_dtype)
            else:
                casted[k] = v.to(device)
        else:
            casted[k] = v
    inputs = casted

    with torch.no_grad():
        output_ids = model.generate(
            **inputs,
            max_new_tokens=2048,
            do_sample=False,
        )

    # Strip prompt tokens; only decode the newly-generated suffix.
    input_len = inputs["input_ids"].shape[1]
    new_tokens = output_ids[:, input_len:]
    raw = processor.batch_decode(new_tokens, skip_special_tokens=True)[0]
    log(f"raw model output: {raw[:160]!r}")
    return _extract_plain_text(raw)


def main() -> int:
    try:
        processor, model, device, _dtype = load_model()
    except Exception as exc:  # noqa: BLE001
        emit({
            "type": "status",
            "state": "error",
            "error": f"{type(exc).__name__}: {exc}",
            "trace": traceback.format_exc(),
        })
        # Keep the process alive so the Swift side can read the error; it will
        # terminate us when it gives up.
        time.sleep(5)
        return 1

    emit({"type": "status", "state": "ready", "model": MODEL_ID, "device": device})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            emit({"type": "error", "error": f"bad json: {exc}"})
            continue

        cmd = req.get("cmd")
        req_id = req.get("id", "")

        if cmd == "shutdown":
            log("shutdown requested")
            return 0

        if cmd != "transcribe":
            emit({"type": "error", "id": req_id, "error": f"unknown cmd: {cmd}"})
            continue

        audio_path = req.get("audio_path")
        if not audio_path or not os.path.exists(audio_path):
            emit({"type": "error", "id": req_id, "error": f"missing audio: {audio_path!r}"})
            continue

        try:
            started = time.time()
            text = transcribe(processor, model, device, audio_path)
            log(f"transcribed in {time.time() - started:.2f}s: {text[:80]!r}")
            emit({"type": "transcription", "id": req_id, "text": text})
        except Exception as exc:  # noqa: BLE001
            # Log the full traceback to stderr so it reaches MacVibe.log, not
            # just the Swift popup. Otherwise silent transcribe failures look
            # the same as the sidecar hanging.
            log(f"TRANSCRIBE FAILED ({type(exc).__name__}): {exc}")
            log(traceback.format_exc())
            emit({
                "type": "error",
                "id": req_id,
                "error": f"{type(exc).__name__}: {exc}",
                "trace": traceback.format_exc(),
            })

    return 0


if __name__ == "__main__":
    sys.exit(main())
