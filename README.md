# Verbatim

Push-to-talk dictation for macOS that transcribes **exactly what you say** —
fillers, false starts, backtracking and all — using OpenAI's
`gpt-live-transcribe` realtime model. No cleanup, no "AI enhancement", no
subscription: bring your own API key (~$0.017 per audio minute).

Hold a modifier key, talk, release. The audio streams to the realtime API
*while* you speak, so the final transcript arrives almost immediately after
you let go and is pasted into whatever app has focus. Nothing is shown while
you talk; nothing is stored.

## Install

```sh
./build.sh
open dist/Verbatim.app
```

Apple Silicon, macOS 14+. On first run:

1. Set your OpenAI API key in Settings (menu bar icon → Settings…).
2. Grant Microphone access when prompted.
3. Grant Accessibility access (System Settings → Privacy & Security →
   Accessibility) — needed to watch the hotkey and synthesize the paste.
   If the hotkey still doesn't register, also grant Input Monitoring.

Default hotkey: hold **Right ⌥ Option**. Configurable in Settings, along with
the latency/quality trade-off (`minimal` → `xhigh`), a keywords list for
jargon, and the transcription prompt (defaults to a strict-verbatim
instruction).

## Design decisions

- **Streaming, but paste-on-release.** Transcription happens live so there's
  nothing left to wait for when you release the key, but text is only pasted
  once, when you finish. No live preview, no un-typing corrections.
- **Push-to-talk, no VAD.** `turn_detection` is disabled; your key release is
  the commit.
- **Verbatim is the whole point.** The prompt demands it and there is no
  post-processing step of any kind.

## Testing without a mic

```sh
swift run Verbatim --transcribe path/to/clip.wav
```

streams a file through the same engine and prints the transcript.

## Credits

The hotkey monitor and clipboard-paste logic are adapted from
[OpenSuperWhisper](https://github.com/starmel/OpenSuperWhisper)
(MIT, © 2024 OpenSuperWhisper). MIT licensed.
