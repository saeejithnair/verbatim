# Verbatim

Push-to-talk dictation for macOS that types **exactly what you say** — fillers,
false starts, backtracking and all.

Every dictation app cleans up your speech. Some run an LLM "enhancement" pass;
even raw Whisper quietly drops your "um"s and collapses your self-corrections,
because its training data was normalized. If you dictate prompts to AI agents,
think out loud, or just want your words to stay yours, that cleanup destroys
exactly the signal you wanted to keep.

Verbatim doesn't clean anything. Hold a key, talk, release — your words appear
in whatever app has focus, as spoken.

## How it works

While you hold the hotkey, microphone audio streams to OpenAI's
`gpt-live-transcribe` realtime model over a WebSocket, with a prompt that
demands strict verbatim output and a keyword list that biases recognition
toward your jargon. Transcription happens *while* you speak, so when you
release the key there's almost nothing left to wait for — the final transcript
pastes immediately, with a trailing space so back-to-back dictations don't run
together.

There is no live preview, no floating overlay, no post-processing. The app is
invisible while you talk.

- **Bring your own OpenAI API key.** No subscription, no accounts, no servers
  of ours. `gpt-live-transcribe` costs about **$0.017 per minute of audio** —
  roughly $2 a month for 20 minutes of dictation a day.
- **Everything stays on your Mac.** History and stats are local JSON files.
  Audio is streamed for transcription and never stored anywhere.
- The main window shows your dictation history (with per-turn duration, cost,
  and key-release-to-paste latency), a lifetime word count, and a 12-week
  contribution heatmap. Clearing history keeps the stats.

## Install

Requires an Apple Silicon Mac on macOS 14+, and Xcode command line tools.

```sh
git clone https://github.com/saeejithnair/verbatim.git
cd verbatim
./build.sh
open dist/Verbatim.app
```

Then:

1. **API key** — open Settings (⌘, from the app) and paste your OpenAI API
   key. Alternatively put `OPENAI_API_KEY=sk-...` in `~/.config/verbatim/.env`
   or export it in your environment.
2. **Microphone** — approve the prompt on first dictation.
3. **Accessibility** — the app shows a banner with a button to System
   Settings; enable Verbatim. This is needed to watch the hotkey and to paste.
   The app detects the grant within seconds — no relaunch needed. (If the
   hotkey still doesn't register, also grant Input Monitoring.)

`build.sh` signs with whatever Developer ID or Apple Development identity is
in your keychain, falling back to ad-hoc. A stable identity matters: macOS
ties permission grants to the code signature, so ad-hoc builds lose
Accessibility on every rebuild.

## Use

Hold **Right ⌥ Option** (configurable), speak, release. A soft tick marks the
start, a pop marks the paste.

- **Double-tap** the hotkey to latch hands-free recording — no finger stamina
  required for long takes. Tap once more to finish and paste.
- **⌘ + the hotkey** pastes the most recent transcript again — instant
  recovery when a paste landed in the wrong window.
- A stray tap, or a dictation that produced no text, answers with a soft
  "nevermind" sound rather than silence. If the microphone delivered nothing
  at all (a Bluetooth device stealing the input mid-sentence, say), the app
  says so instead of failing quietly.

Your words can't be lost: every turn's audio is buffered locally while it
streams. If the connection dies mid-sentence you hear a low warning but keep
talking — on release the buffered audio is transcribed through the batch API
instead. If even that fails, the audio is saved and recovered into your
history the next time the app launches. Back-to-back dictations queue cleanly;
starting a new turn while the previous one is still finalizing loses nothing.

Settings:

- **Hotkey** — any single modifier key, left or right variant, or Fn.
- **Latency** — `minimal` → `xhigh`. Lower emits text sooner; higher gives the
  model more context per word. Each history entry records the felt latency
  (release → paste) so you can tune this on data.
- **Keywords** — a token field of names and jargon you actually say. These are
  sent with every request and stop technical terms from being mangled.
- **Languages** — ISO codes (`en`, or `en, fr`); empty auto-detects. Locking a
  language stops mid-sentence drift into other scripts, via both the API's
  language constraint and a generated prompt clause.
- **Microphone** — pin an input device. The built-in mic starts instantly;
  Bluetooth mics (AirPods) take 1–2 s to wake into headset mode, and words
  spoken before the wake never reach the Mac. Pinning the built-in mic keeps
  output on your headphones while dictation starts immediately.
- **Prompt** — the transcription instruction. The default demands strict
  verbatim output; make it yours (one click resets it).
- **Sounds** — the start and paste cues are individually mutable. (On idle
  Bluetooth headphones cues can arrive seconds late — the *output* link also
  sleeps — so silencing them is honest, not reckless: capture doesn't wait
  for the sound.)
- **Launch at login** — so the hotkey is always live.

If a finalize ever times out, the transcript still pastes but its history
card is marked **partial** — suspect output is never passed off as complete.

## Test without a mic

```sh
swift run Verbatim --transcribe path/to/clip.wav
```

streams a file through the same engine and prints the transcript.

## Design decisions

- **Streaming, but paste-on-release.** Live transcription for speed, a single
  paste for sanity. No text appears until you finish — nothing to watch, no
  un-typing of interim corrections.
- **Push-to-talk, no VAD.** Your key release is the commit. The model never
  decides you're "done".
- **Verbatim is the product.** If you want cleanup, every other dictation app
  already does that.

## Credits

The hotkey monitor and clipboard-paste logic are adapted from
[OpenSuperWhisper](https://github.com/starmel/OpenSuperWhisper) (MIT).

MIT licensed.
