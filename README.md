# Picaku STT Demo

Standalone spike app: **on-device English transcription** with sherpa-onnx + Silero VAD. Live captions while you speak, final transcript when you stop — and, more importantly, the measurements needed to decide what to ship.

The APK stays small (~42 MB): models are **downloaded in-app** from a catalog, with progress, cancel, resume, switch, and delete. Internet is used **only** for that one-time download — transcription runs fully offline, and no weights are ever trained or modified on device.

Validates the engine from `ON_DEVICE_TRANSCRIPTION.md` before it is integrated into the main Picaku app. See **DEMO_SPEC.md** for scope and architecture, and **MODEL_OPTIMIZATION_STRATEGY.md** for the optimization plan the measurements feed.

## Model catalog

| Model | Download | Languages | Notes |
|---|---|---|---|
| Moonshine Base | ~287 MB | English | Recommended default |
| Moonshine Tiny | ~124 MB | English | Fastest, lowest RAM |
| NVIDIA Parakeet TDT 0.6B v2 | ~661 MB | English | Highest accuracy; the only model supporting hotwords. Needs 8 GB+ RAM |
| Whisper Base | ~161 MB | **99** | Pick this for non-English meetings. Can also translate any of them to English |
| Whisper Tiny | ~104 MB | **99** | Same, smaller and less accurate |
| Whisper Base.en | ~161 MB | English | The incumbent (main app uses whisper.cpp), here as the baseline to beat |
| Whisper Tiny.en | ~104 MB | English | Same, smaller |

Plus a shared ~2 MB Silero VAD, fetched once with the first model.

All files come from the official k2-fsa distribution: per-model Hugging Face repos under [`csukuangfj`](https://huggingface.co/csukuangfj) (the sherpa-onnx maintainer), and the `asr-models` GitHub release for the VAD. The browsable index of everything available is <https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html>. URLs are pinned at compile time — each model card in the app shows its source.

> **Whisper is slower here than its size suggests.** Its encoder is fixed at 30 seconds, so every utterance is zero-padded to 30 s before inference — a 2-second reply costs the same as a 30-second one. Moonshine takes variable-length input and exists specifically to avoid that. Judge by measured RTF, not file size.

> **Language is a property of the weights, not a setting.** Only the multilingual Whisper builds understand anything but English. The `.en` builds do not fail on other languages — sherpa-onnx skips the language step for them entirely, so they emit confident English-shaped nonsense instead. Moonshine and Parakeet are English-only across the board. The Lab tab shows the language controls only when the loaded model can actually use them.

## Build it (no local SDK needed — cloud-only)

Push to `main` and the **Build Demo APK** workflow runs `flutter analyze` + `flutter test`, then builds. Download the `picaku-stt-demo` artifact and install `app-arm64-v8a-release.apk`. It is debug-signed on purpose — no keystore, installs anywhere. The debug keystore is cached in CI, so updates install in place and downloaded models survive.

## Use it

**Record tab** — download a model, tap the mic (with 2+ models installed you are asked which to use), speak, stop. Captions appear at natural pauses *and* on a fixed clock while you keep talking, so fluent speech still updates the screen. Each caption shows its decode time and true end-of-speech-to-screen lag.

**Lab tab** — every tunable that affects quality or speed, and the recordings list. Session audio is retained (~2 MB/min), which is what makes real comparison possible: **re-decode one recording with every installed model** and read WER, RTF and RAM side by side. Supply reference text by typing what you said, or read one of the built-in scored passages the app already knows.

**Diagnostics tab** — RAM, CPU, threads, thermal throttle state, battery draw; an endurance card (RAM trend, drain rate, throttling) answering how long a session can run; and a latency breakdown splitting caption lag into VAD wait, decode, and the rest. Exports everything as JSON.

> Two things that will otherwise mislead you: the capture DSP switches (auto-gain, noise suppression, echo cancel) are applied by Android *before* the app sees audio, so comparing them needs two recordings, not a re-decode. And one speaker is one data point — accent conclusions need the same passage read by several people.

Test on at least one budget phone (3–4 GB RAM) and one good phone, and keep the exported numbers. They become the regression baseline in the integration doc.

## Local development (optional)

Only the Flutter SDK is required (no Android Studio / Android SDK, per `FLUTTER_CLEAN_CLOUD_DEV.md`):

```powershell
flutter pub get
flutter analyze
flutter test
```

## Layout

```
lib/models/        model catalog + download-once-and-cache store   ← handoff
lib/engine/        tunables + the sherpa-onnx pipeline             ← handoff
lib/transcriber/   Transcriber interface + live capture isolate    ← handoff
lib/audio/         mic capture (record pkg, 16 kHz mono PCM16)     ← handoff
lib/util/          PCM, DSP, WAV                                   ← handoff
lib/bench/         re-decode runner, WER/CER, scored passages      (demo-only)
lib/diag/          resource monitor, device channel, event log     (demo-only)
lib/ui/            throwaway demo screens
android/           shell copied from the main Picaku app (same toolchain)
.github/workflows/ cloud build: analyze + test + APK artifact
```
