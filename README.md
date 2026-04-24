# MacVibe

Global dictation for macOS. Tap right `⌥`, talk, tap right `⌥` again. The text
is transcribed with Microsoft VibeVoice-ASR, cleaned up by Apple Intelligence
(fillers and self-corrections removed), and pasted into the focused field.

- Menubar-only app (no Dock icon).
- Hotkey: *right* Option key, clean tap (press + release with nothing else in
  between). Holding `⌥` to type special characters is unaffected.
- Popup: a small floating HUD shows recording → transcribing → refining → done.
- ASR: `microsoft/VibeVoice-ASR-7B` via a Python sidecar. The JSON bridge is
  intentionally small so swapping in a Rust / whisper.cpp sidecar is a one-file
  change.
- Refinement: `FoundationModels` framework (macOS 26+). On older systems the
  raw transcription is used.

## Requirements

- macOS 14+ to build, macOS 26+ to get Apple Intelligence refinement.
- Xcode command-line tools (`xcode-select --install`).
- Python 3.11+ and either `uv` or `pip`.
- Apple Silicon strongly recommended — the sidecar runs VibeVoice on MPS.

## Build

```sh
./build.sh
```

This produces `build/MacVibe.app`.

## Install the Python sidecar

The app bundle ships the sidecar script but not its Python environment (the
weights and deps are several GB). After building, run:

```sh
./build/MacVibe.app/Contents/Resources/python-sidecar/setup_venv.sh
```

This creates a `.venv` alongside `transcribe.py`, installs PyTorch +
transformers, and attempts to install the official `vibevoice` package from
GitHub. First run will download the VibeVoice-ASR-7B weights from HuggingFace.

Set `MACVIBE_MODEL` to override the model ID, or `MACVIBE_PYTHON` to point at
a specific Python interpreter.

## Run

```sh
open build/MacVibe.app
```

On first launch, macOS will prompt for:

1. **Microphone access** — required to record your voice.
2. **Accessibility access** — required to observe the right ⌥ tap globally and
   to synthesise ⌘V for paste.

If the paste step fails, it means Accessibility isn't granted yet — the text
is still on your clipboard.

## Architecture

```
 ┌──────────────┐        ┌─────────────────┐        ┌────────────────┐
 │ HotkeyMonitor│──tap──▶│ DictationCoord. │──wav──▶│ Python sidecar │
 │  (CGEventTap)│        │                 │◀─text──│ (VibeVoice ASR)│
 └──────────────┘        │                 │        └────────────────┘
                         │                 │
                         │                 │──raw──▶┌────────────────┐
                         │                 │        │ RefinementSvc  │
                         │                 │◀final──│ (FoundationMdl)│
                         │                 │        └────────────────┘
                         │                 │
                         │                 │──⌘V──▶ focused app
                         └─────────────────┘
                                │
                                └──▶ PopupController (NSPanel + SwiftUI)
```

## Swapping the ASR backend

`TranscriptionService.swift` speaks line-delimited JSON over stdin/stdout.
Any process that implements the same protocol works:

```
-> {"cmd":"transcribe","id":"<uuid>","audio_path":"/tmp/x.wav"}
<- {"type":"status","state":"ready"}
<- {"type":"transcription","id":"<uuid>","text":"hello world"}
```

For a Rust alternative, `whisper-rs` on top of whisper.cpp gives you a single
binary with Metal acceleration and no Python environment.

## Layout

```
mac-vibe/
├── Package.swift
├── Sources/MacVibe/
│   ├── MacVibeApp.swift          # @main + menubar + delegate
│   ├── DictationCoordinator.swift # State machine: idle → rec → proc
│   ├── HotkeyMonitor.swift       # CGEventTap on right ⌥
│   ├── AudioRecorder.swift       # AVAudioEngine → 16 kHz mono WAV
│   ├── TranscriptionService.swift # JSON bridge to the sidecar
│   ├── RefinementService.swift   # FoundationModels streaming refine
│   ├── PopupController.swift     # NSPanel lifecycle
│   └── PopupView.swift           # SwiftUI HUD
├── PythonSidecar/
│   ├── transcribe.py
│   ├── requirements.txt
│   └── setup_venv.sh
├── Resources/
│   ├── Info.plist
│   └── MacVibe.entitlements
├── build.sh
└── README.md
```

## Troubleshooting

- **Hotkey doesn't fire.** Grant MacVibe Accessibility access in System
  Settings → Privacy & Security → Accessibility, then restart the app.
- **Status stays "loading model…".** First run downloads ~14 GB; check
  `stderr` (run from Terminal: `./build/MacVibe.app/Contents/MacOS/MacVibe`).
- **"Pasted" but nothing appears.** The frontmost app doesn't accept ⌘V.
  The text is still on your clipboard.
- **Refinement does nothing.** Apple Intelligence requires macOS 26+ on an
  Apple-Intelligence-capable Mac, and must be enabled in System Settings.
