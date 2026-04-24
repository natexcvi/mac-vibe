//! MacVibe ASR sidecar — whisper.cpp via whisper-rs, Metal-accelerated.
//!
//! Protocol matches the (now retired) Python sidecar so the Swift bridge is
//! unchanged: line-delimited JSON on stdin/stdout.
//!
//!   -> {"cmd": "transcribe", "id": "<uuid>", "audio_path": "/tmp/x.wav"}
//!   <- {"type": "status", "state": "loading" | "ready" | "error", ...}
//!   <- {"type": "transcription", "id": "<uuid>", "text": "..."}
//!   <- {"type": "error", "id": "<uuid>", "error": "..."}
//!   -> {"cmd": "shutdown"}

use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::env;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

#[derive(Debug, Deserialize)]
#[serde(tag = "cmd")]
enum Request {
    #[serde(rename = "transcribe")]
    Transcribe { id: String, audio_path: String },
    #[serde(rename = "shutdown")]
    Shutdown,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event<'a> {
    #[serde(rename = "status")]
    Status {
        state: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<&'a str>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<&'a str>,
    },
    #[serde(rename = "transcription")]
    Transcription { id: &'a str, text: &'a str },
    #[serde(rename = "error")]
    Error { id: &'a str, error: &'a str },
}

fn emit(event: &Event) {
    let mut stdout = io::stdout().lock();
    let _ = serde_json::to_writer(&mut stdout, event);
    let _ = stdout.write_all(b"\n");
    let _ = stdout.flush();
}

fn log(msg: impl AsRef<str>) {
    let mut stderr = io::stderr().lock();
    let _ = writeln!(stderr, "[sidecar] {}", msg.as_ref());
    let _ = stderr.flush();
}

/// Resolve the GGUF/GGML model path. Search order:
///   1. $MACVIBE_MODEL_PATH (explicit override)
///   2. <sidecar dir>/models/ggml-*.bin (bundled — preferred)
///   3. ~/.cache/macvibe/<filename> (downloaded by setup_model.sh)
fn resolve_model_path() -> Result<PathBuf> {
    if let Ok(p) = env::var("MACVIBE_MODEL_PATH") {
        let path = PathBuf::from(p);
        if path.exists() {
            return Ok(path);
        }
        bail!("MACVIBE_MODEL_PATH set but file not found: {}", path.display());
    }

    let exe_dir = env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf));

    let mut search_dirs: Vec<PathBuf> = Vec::new();
    if let Some(dir) = exe_dir {
        // Walk up a few levels: handles bundled app
        // (Resources/asr-sidecar/models) and dev cargo build
        // (target/release → ../../models).
        let mut cur: Option<&Path> = Some(&dir);
        for _ in 0..4 {
            if let Some(d) = cur {
                search_dirs.push(d.join("models"));
                search_dirs.push(d.join("Resources").join("models"));
                cur = d.parent();
            }
        }
    }
    if let Some(home) = env::var_os("HOME") {
        search_dirs.push(PathBuf::from(home).join(".cache/macvibe"));
    }

    let preferred = [
        "ggml-large-v3-turbo.bin",
        "ggml-large-v3-turbo-q8_0.bin",
        "ggml-large-v3.bin",
        "ggml-medium.en.bin",
        "ggml-base.en.bin",
    ];

    for dir in &search_dirs {
        for name in &preferred {
            let p = dir.join(name);
            if p.exists() {
                return Ok(p);
            }
        }
    }

    // Fall back to *any* ggml-*.bin in the search dirs.
    for dir in &search_dirs {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.extension().and_then(|e| e.to_str()) == Some("bin") {
                    if p.file_name()
                        .and_then(|n| n.to_str())
                        .map(|n| n.starts_with("ggml-"))
                        .unwrap_or(false)
                    {
                        return Ok(p);
                    }
                }
            }
        }
    }

    bail!(
        "no whisper model found. Searched: {}. Run setup_model.sh.",
        search_dirs
            .iter()
            .map(|p| p.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn load_audio_16k_mono(path: &str) -> Result<Vec<f32>> {
    let mut reader = hound::WavReader::open(path)
        .with_context(|| format!("opening WAV: {path}"))?;
    let spec = reader.spec();
    let channels = spec.channels as usize;
    let sample_rate = spec.sample_rate;

    // Read all samples normalized to [-1.0, 1.0] f32.
    let raw: Vec<f32> = match (spec.sample_format, spec.bits_per_sample) {
        (hound::SampleFormat::Float, _) => reader
            .samples::<f32>()
            .collect::<Result<Vec<_>, _>>()
            .context("reading float samples")?,
        (hound::SampleFormat::Int, 16) => reader
            .samples::<i16>()
            .map(|s| s.map(|v| v as f32 / 32768.0))
            .collect::<Result<Vec<_>, _>>()
            .context("reading 16-bit int samples")?,
        (hound::SampleFormat::Int, 32) => reader
            .samples::<i32>()
            .map(|s| s.map(|v| v as f32 / 2147483648.0))
            .collect::<Result<Vec<_>, _>>()
            .context("reading 32-bit int samples")?,
        (fmt, bits) => bail!("unsupported WAV format: {:?} @ {} bits", fmt, bits),
    };

    // Down-mix to mono.
    let mono: Vec<f32> = if channels == 1 {
        raw
    } else {
        raw.chunks(channels)
            .map(|frame| frame.iter().sum::<f32>() / channels as f32)
            .collect()
    };

    // Resample to 16 kHz with linear interpolation. Whisper requires 16 kHz;
    // for short dictation clips this is plenty good — full SOTA resamplers
    // would buy <0.1% WER and take a dependency.
    let resampled = if sample_rate == 16_000 {
        mono
    } else {
        let ratio = 16_000.0_f64 / sample_rate as f64;
        let out_len = ((mono.len() as f64) * ratio).round() as usize;
        let mut out = Vec::with_capacity(out_len);
        for i in 0..out_len {
            let src = i as f64 / ratio;
            let i0 = src.floor() as usize;
            let i1 = (i0 + 1).min(mono.len() - 1);
            let frac = (src - i0 as f64) as f32;
            let s0 = mono[i0.min(mono.len() - 1)];
            let s1 = mono[i1];
            out.push(s0 + (s1 - s0) * frac);
        }
        out
    };

    Ok(resampled)
}

fn transcribe(ctx: &WhisperContext, audio_path: &str) -> Result<String> {
    let started = Instant::now();
    let samples = load_audio_16k_mono(audio_path)?;
    log(format!(
        "loaded audio: {} samples ({:.2}s)",
        samples.len(),
        samples.len() as f32 / 16_000.0
    ));

    let mut state = ctx.create_state().context("creating whisper state")?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_n_threads(num_cpus().min(8) as i32);
    params.set_translate(false);
    params.set_language(Some("en"));
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    params.set_suppress_blank(true);
    params.set_suppress_non_speech_tokens(true);
    params.set_no_context(true);
    params.set_single_segment(false);

    state
        .full(params, &samples)
        .map_err(|e| anyhow!("whisper full() failed: {:?}", e))?;

    let n = state
        .full_n_segments()
        .map_err(|e| anyhow!("full_n_segments: {:?}", e))?;
    let mut text = String::new();
    for i in 0..n {
        let seg = state
            .full_get_segment_text(i)
            .map_err(|e| anyhow!("full_get_segment_text({}): {:?}", i, e))?;
        text.push_str(&seg);
    }

    log(format!(
        "transcribed in {:.2}s: {:?}",
        started.elapsed().as_secs_f32(),
        text.chars().take(80).collect::<String>()
    ));
    Ok(text.trim().to_string())
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
}

fn main() -> Result<()> {
    emit(&Event::Status {
        state: "loading",
        model: None,
        error: None,
    });

    let model_path = match resolve_model_path() {
        Ok(p) => p,
        Err(e) => {
            let msg = e.to_string();
            emit(&Event::Status {
                state: "error",
                model: None,
                error: Some(&msg),
            });
            std::thread::sleep(std::time::Duration::from_secs(5));
            return Err(e);
        }
    };
    log(format!("model: {}", model_path.display()));

    let ctx = match WhisperContext::new_with_params(
        model_path.to_string_lossy().as_ref(),
        WhisperContextParameters::default(),
    ) {
        Ok(c) => c,
        Err(e) => {
            let msg = format!("WhisperContext::new failed: {:?}", e);
            log(&msg);
            emit(&Event::Status {
                state: "error",
                model: None,
                error: Some(&msg),
            });
            std::thread::sleep(std::time::Duration::from_secs(5));
            return Err(anyhow!(msg));
        }
    };

    let model_name = model_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("?");
    emit(&Event::Status {
        state: "ready",
        model: Some(model_name),
        error: None,
    });

    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                log(format!("stdin read error: {e}"));
                break;
            }
        };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let req: Request = match serde_json::from_str(line) {
            Ok(r) => r,
            Err(e) => {
                emit(&Event::Error {
                    id: "",
                    error: &format!("bad json: {e}"),
                });
                continue;
            }
        };

        match req {
            Request::Shutdown => {
                log("shutdown requested");
                break;
            }
            Request::Transcribe { id, audio_path } => {
                if !Path::new(&audio_path).exists() {
                    emit(&Event::Error {
                        id: &id,
                        error: &format!("audio missing: {audio_path}"),
                    });
                    continue;
                }
                match transcribe(&ctx, &audio_path) {
                    Ok(text) => emit(&Event::Transcription { id: &id, text: &text }),
                    Err(e) => {
                        log(format!("TRANSCRIBE FAILED: {e:?}"));
                        emit(&Event::Error {
                            id: &id,
                            error: &format!("{e}"),
                        });
                    }
                }
            }
        }
    }

    Ok(())
}
