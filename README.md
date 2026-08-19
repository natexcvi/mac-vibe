# MacVibe

Global dictation for macOS. Tap right `⌥`, talk, tap right `⌥` again — the text
is transcribed locally and pasted straight into whatever you were typing in.

- **Menubar-only.** No Dock icon, no window in your way.
- **Local.** Transcription runs on-device via whisper.cpp with Metal
  acceleration. Your audio never leaves the machine.
- **Hotkey.** A clean tap of the *right* Option key — press and release with
  nothing in between. Holding `⌥` for special characters still works normally.
- **Optional cleanup.** On macOS 26+ Apple Intelligence strips fillers and
  self-corrections. Off by default, and entirely on-device.
- **Auto-updating.** Signed, notarized, and updated in place via Sparkle.

## Install

Download the latest `.dmg` from
[Releases](https://github.com/natexcvi/mac-vibe/releases/latest), drag MacVibe
to Applications, and launch it.

Requirements: **Apple Silicon** Mac running **macOS 14 or later**. (Apple
Intelligence refinement additionally needs macOS 26+ on a supported Mac.)

### First launch

1. MacVibe downloads its speech model — `ggml-large-v3-turbo`, about 1.6 GB —
   into `~/Library/Application Support/MacVibe/models`. Progress shows in the
   menubar and a HUD. This happens once; updates don't re-download it.
2. macOS asks for **Microphone** access — needed to hear you.
3. macOS asks for **Accessibility** access — needed to watch for the right `⌥`
   tap globally and to synthesise ⌘V.

If the paste step fails, Accessibility isn't granted yet. The transcribed text
is still on your clipboard either way.

### Updates

MacVibe checks for updates once a day, after asking your permission on first
launch. You can also trigger a check, or turn automatic checks off, from the
menubar. Updates are EdDSA-signed and verified against a key baked into the
app, so a compromised release page can't push code to you.

## Usage

| | |
| --- | --- |
| **Right `⌥`** | start / stop dictation |
| **Language** | pin a language, or leave on Automatic for per-utterance detection |
| **Custom Words** | names and jargon whisper keeps mishearing — one per line |
| **Refine with Apple Intelligence** | strip fillers and self-corrections |

When you pin a language but MacVibe acoustically hears a different one, the HUD
says so — whisper treats a pinned language as a hint, not a constraint, so this
is otherwise a confusing way to get output in the wrong language.

## Build from source

```bash
git clone https://github.com/natexcvi/mac-vibe.git
cd mac-vibe
./build.sh
open build/MacVibe.app
```

You need the Xcode command-line tools (`xcode-select --install`), a Rust
toolchain, and CMake (`brew install cmake`) for whisper.cpp.

`./build.sh` produces an ad-hoc signed bundle. That's fine for development, but
the signature changes on every build, so macOS treats each one as a new app and
asks for Accessibility again. Release builds are signed with a stable Developer
ID, so permissions survive updates.

Useful knobs:

```bash
VERSION=1.2.3 ./build.sh      # stamp a marketing version
EMBED_MODEL=1 ./build.sh      # embed weights from RustSidecar/models
CONFIG=debug ./build.sh       # debug build
```

To install to `/Applications` with the model embedded (skipping the first-run
download), use `./install.sh`.

Releasing is documented in [docs/RELEASING.md](docs/RELEASING.md).

## Architecture

```
 ┌──────────────┐        ┌─────────────────┐        ┌────────────────┐
 │ HotkeyMonitor│──tap──▶│ DictationCoord. │──wav──▶│  ASR sidecar   │
 │  (CGEventTap)│        │                 │◀─text──│ (whisper.cpp)  │
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

The sidecar is a separate process speaking line-delimited JSON over
stdin/stdout, so the ASR backend can be swapped without touching the app:

```
-> {"cmd":"transcribe","id":"<uuid>","audio_path":"/tmp/x.wav","language":"auto"}
<- {"type":"status","state":"ready"}
<- {"type":"transcription","id":"<uuid>","text":"hello world","detected_language":"en"}
```

## Layout

```
mac-vibe/
├── Package.swift
├── Sources/MacVibe/
│   ├── MacVibeApp.swift           # @main + menubar + delegate
│   ├── DictationCoordinator.swift # State machine: idle → rec → proc
│   ├── HotkeyMonitor.swift        # CGEventTap on right ⌥
│   ├── AudioRecorder.swift        # AVAudioEngine → 16 kHz mono WAV
│   ├── TranscriptionService.swift # JSON bridge to the sidecar
│   ├── RefinementService.swift    # FoundationModels streaming refine
│   ├── ModelManager.swift         # First-launch weights download
│   ├── UpdaterController.swift    # Sparkle
│   ├── PopupController.swift      # NSPanel lifecycle
│   └── PopupView.swift            # SwiftUI HUD
├── RustSidecar/                   # whisper.cpp ASR sidecar
├── PythonSidecar/                 # retired VibeVoice sidecar, kept for reference
├── Resources/                     # Info.plist, entitlements, icon
├── scripts/                       # release + appcast tooling
├── build.sh
└── docs/RELEASING.md
```

## Troubleshooting

- **Hotkey doesn't fire.** Grant MacVibe Accessibility access in System
  Settings → Privacy & Security → Accessibility, then restart the app.
- **Stuck on "downloading speech model".** Check your connection; MacVibe
  retries and resumes automatically. Logs are in `~/Library/Logs/MacVibe.log`.
- **"Pasted" but nothing appeared.** The frontmost app doesn't accept ⌘V. The
  text is on your clipboard.
- **Refinement does nothing.** It needs macOS 26+ on an Apple-Intelligence
  capable Mac, with Apple Intelligence enabled in System Settings.

## License

MIT — see [LICENSE](LICENSE).
