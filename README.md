# Smart Dictation

A fully local, privacy-first macOS dictation daemon that combines Apple's on-device speech recognition with a local LLM to fix accent-related transcription errors — and pastes the corrected text directly into whatever app you're using.

---

## The Problem It Solves

macOS built-in dictation gets a lot of words wrong for Indian-accented English. "Three" becomes "tree". "Very" becomes "wery". "The" becomes "W". The errors are phonetic and consistent, but macOS has no way to learn from them.

Smart Dictation solves this by running two layers:

1. **Apple SFSpeechRecognizer** — the same engine macOS uses, fully on-device, streams words live as you speak
2. **Local LLM (Qwen3.5-4B)** — when you stop dictating, the raw transcript goes through a single correction pass that fixes phonetic substitutions using context

The result: words appear on screen as you speak (same UX as macOS dictation), then the corrected version is pasted into the active app 1–2 seconds after you stop.

**Everything runs locally. No audio, transcript, or text ever leaves your machine.**

---

## How It Works

```
Press Cmd+D
    ↓
Floating pill overlay appears at bottom of screen
    ↓
SFSpeechRecognizer streams words live into the overlay as you speak
    ↓
Press Cmd+D again to stop
    ↓
Raw transcript → local LLM (Qwen3.5-4B on localhost:8080) → corrected text
    ↓
Corrected text pasted into whatever app was focused
    ↓
Overlay shows green check and fades out
```

Works in any app: terminal, Slack, Gmail, Sublime Text, VS Code, Notes, Messages — anything that accepts keyboard input.

---

## Requirements

- macOS 13 or later (Apple Silicon — M1/M2/M3/M4)
- Xcode Command Line Tools (`xcode-select --install`)
- macOS on-device dictation model downloaded (one-time setup — see below)
- `llama-server` binary and `Qwen3.5-4B.Q4_K_M.gguf` model — both bundled in `Resources/` (already included)

---

## First-Time Setup

### Step 1 — Download the on-device speech model (one-time only)

Smart Dictation uses Apple's on-device speech recognition, which requires the model to be downloaded first. If you've ever used macOS Dictation, this is already done.

If not:
1. Open **System Settings → Keyboard → Dictation**
2. Toggle Dictation **On**
3. Wait for the model to download (you'll see a progress indicator)
4. You can turn Dictation back Off after — the model stays downloaded

### Step 2 — Run setup

```bash
cd /Users/pravingayal/VibrentHealth/Playground/Workspace/smart-dictation
bash scripts/setup.sh
```

This script handles everything automatically:
- **Downloads `llama-server`** from llama.cpp releases if not present — detects your platform (Apple Silicon, Intel Mac, or Linux)
- **Downloads the Qwen3.5-4B model** (~2.7 GB) from HuggingFace if not present — asks for confirmation first
- Builds the release binary (`swift build -c release`)
- Creates the log directory at `~/Library/Logs/smart-dictation/`
- Installs the LaunchAgent so the daemon auto-starts at login
- Prints the one manual step (Accessibility permission)

All downloads are **idempotent** — re-running setup safely skips anything already present.

### Step 3 — Grant Accessibility permission

After setup completes, you'll see this instruction printed:

```
Add .build/release/SmartDictation to System Settings → Privacy & Security → Accessibility
```

Do this manually:
1. Open **System Settings → Privacy & Security → Accessibility**
2. Click the **+** button
3. Navigate to the project folder and select `.build/release/SmartDictation`
4. Toggle it **On**

> **Why is this needed?** The Accessibility permission lets Smart Dictation install a global keyboard listener (to detect Cmd+D in any app) and simulate Cmd+V to paste text.

### Step 4 — Grant Microphone and Speech Recognition

On the first dictation attempt, macOS will show permission dialogs for:
- **Microphone** — to capture your voice
- **Speech Recognition** — to run SFSpeechRecognizer

Click **Allow** for both.

---

## Running It

### Start the daemon manually (for testing)

```bash
cd /Users/pravingayal/VibrentHealth/Playground/Workspace/smart-dictation
.build/release/SmartDictation
```

You'll see in the terminal:
```
[SmartDictation] Ready. Press Cmd+D to start dictation.
```

Leave this terminal open. Now switch to any other app and press **Cmd+D**.

### Start/stop with LaunchAgent (normal use)

The setup script installs a LaunchAgent that starts the daemon automatically at login.

```bash
# Start manually (if not already running)
launchctl load ~/Library/LaunchAgents/com.pravingayal.smart-dictation.plist

# Stop
launchctl unload ~/Library/LaunchAgents/com.pravingayal.smart-dictation.plist

# Check if running
launchctl list | grep smart-dictation
```

### Logs

```bash
# Live log output
tail -f ~/Library/Logs/smart-dictation/daemon.log

# Error log
tail -f ~/Library/Logs/smart-dictation/daemon.error.log
```

---

## Using It

| Action | What happens |
|--------|-------------|
| Press **Cmd+D** | Overlay appears, recording starts — speak now |
| Words appear in overlay | Live transcription streaming as you speak |
| Press **Cmd+D** again | Recording stops, "Correcting…" shown briefly |
| ~1–2 seconds later | Corrected text pasted into active app |
| **Green dot + fade out** | Done |

### What the overlay shows

```
╭──────────────────────────────────────────────╮
│  ●  ▁▃▅▃▁  words appear here as you speak…   │
╰──────────────────────────────────────────────╯
```

| Dot color | Meaning |
|-----------|---------|
| Yellow (pulsing) | LLM is warming up at startup |
| Blue (pulsing) | Recording — speak now |
| Blue (static) | Correcting with LLM |
| Green | Done — text pasted |
| Orange | LLM offline — raw transcript pasted instead |

### If the LLM is offline

If `llama-server` isn't running or still loading the model, Smart Dictation **still works** — it just pastes the raw (uncorrected) transcript and shows an orange dot. No crash, no hang.

### Clipboard is preserved

Whatever was on your clipboard before dictating is restored after the paste. Your clipboard is not permanently overwritten.

---

## Troubleshooting

### Cmd+D doesn't do anything

1. Check Accessibility permission is granted for `.build/release/SmartDictation`
2. Check the daemon is running: `launchctl list | grep smart-dictation`
3. Check logs: `tail -f ~/Library/Logs/smart-dictation/daemon.log`
4. If you rebuilt the binary after initial setup, **re-add it to Accessibility** (macOS revokes trust when the binary changes)

### "LLM offline" orange dot on every dictation

The LLM model takes 30–60 seconds to load on first launch. Wait a minute and try again. If it persists:

```bash
# Check if llama-server is running
ps aux | grep llama-server

# Check the error log
tail -20 ~/Library/Logs/smart-dictation/daemon.error.log
```

### Microphone permission dialog never appeared

```bash
# Reset microphone permission for the binary
tccutil reset Microphone
```

Then relaunch the daemon.

### Speech recognition not working / empty transcripts

Make sure macOS on-device dictation model is downloaded (Step 1 of setup). Test by opening Notes and using built-in macOS Dictation (Fn key) — if that works, the model is present.

### Cmd+D conflicts with another app

`Cmd+D` is consumed by Smart Dictation globally, which means it stops working in Finder (Duplicate) and Safari (Bookmark) while the daemon is running.

To change the hotkey to `Cmd+Shift+D`, edit `Sources/SmartDictationLib/Config.swift`:

```swift
// Change this line:
static let hotkeyModifiers: CGEventFlags = .maskCommand
// To:
static let hotkeyModifiers: CGEventFlags = [.maskCommand, .maskShift]
```

Then rebuild: `swift build -c release` and re-add the new binary to Accessibility.

---

## Rebuilding After Code Changes

```bash
cd /Users/pravingayal/VibrentHealth/Playground/Workspace/smart-dictation

# Build
swift build -c release

# Stop the running daemon
launchctl unload ~/Library/LaunchAgents/com.pravingayal.smart-dictation.plist

# Reload with new binary
launchctl load ~/Library/LaunchAgents/com.pravingayal.smart-dictation.plist
```

> **Remember:** After each rebuild, re-add `.build/release/SmartDictation` to Accessibility in System Settings — macOS tracks binary identity and revokes trust on rebuild.

---

## Uninstalling

```bash
bash scripts/uninstall.sh
```

This unloads and removes the LaunchAgent. The binary, model, and source files are kept in the project folder.

---

## Project Structure

```
smart-dictation/
├── Sources/SmartDictationLib/
│   ├── main.swift                  # Entry point, boot sequence, component wiring
│   ├── Config.swift                # Constants: hotkey, LLM URL, timeouts
│   ├── DictationStateMachine.swift # State machine: booting→idle→recording→correcting→pasting
│   ├── HotkeyDaemon.swift          # CGEventTap — Cmd+D global hotkey
│   ├── SpeechRecognizer.swift      # AVAudioEngine + SFSpeechRecognizer streaming
│   ├── OverlayWindow.swift         # Floating pill NSPanel UI
│   ├── WaveformView.swift          # Animated waveform bars (CAShapeLayer)
│   ├── LLMClient.swift             # URLSession POST to llama-server /v1/chat/completions
│   ├── LlamaManager.swift          # Spawns and monitors llama-server child process
│   ├── PasteController.swift       # NSPasteboard + CGEvent Cmd+V simulation
│   └── PermissionManager.swift     # Accessibility, Microphone, Speech Recognition checks
├── Resources/
│   ├── bin/llama-server            # llama.cpp inference server binary (~10MB)
│   └── models/                     # Qwen3.5-4B.Q4_K_M.gguf lives here (not in git, ~2.7GB)
├── LaunchAgents/
│   └── com.pravingayal.smart-dictation.plist
├── scripts/
│   ├── setup.sh                    # One-time install script
│   └── uninstall.sh
└── docs/arch/
    └── 2026-04-22-smart-dictation.md  # Full architecture document
```

---

## Privacy Guarantee

| Data | Where it goes |
|------|--------------|
| Microphone audio | Processed by AVAudioEngine on-device only — never written to disk |
| Raw transcript | Sent to `localhost:8080` only (your local llama-server) |
| Corrected text | Placed on system pasteboard, pasted into active app |
| Nothing | Sent to any external server, ever |

The LLM system prompt is hardcoded in `LLMClient.swift`. It instructs the model to fix transcription errors only — it does not summarise, reformat, or store anything.

---

## Architecture

Full architecture document with component diagrams, sequence diagrams, and design decisions:
[`docs/arch/2026-04-22-smart-dictation.md`](docs/arch/2026-04-22-smart-dictation.md)
