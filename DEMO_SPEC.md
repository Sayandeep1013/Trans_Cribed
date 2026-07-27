# Picaku STT Demo — Spec

> **What this is:** the spec for a standalone spike app that validates the transcription stack chosen in `ON_DEVICE_TRANSCRIPTION.md` (in `global docs/`) before any of it touches the main Picaku repo. This corresponds to **milestones 1–4** of that spec's §17.
> **Build philosophy:** cloud-only per `FLUTTER_CLEAN_CLOUD_DEV.md` — no local Android SDK, no local Gradle, no signing secrets. Push → GitHub Actions builds → download APK → install on phone.
> **Date:** 2026-07-28

---

## 1. Locked decisions (inherited from ON_DEVICE_TRANSCRIPTION.md)

| Decision | Value | Spec ref |
|---|---|---|
| Engine | **sherpa-onnx** (`sherpa_onnx` Flutter package, ONNX Runtime + XNNPACK CPU), hosted in a dedicated background isolate | §6 |
| Models | **Catalog** (in-app download): Moonshine base/tiny INT8 (English) + **NVIDIA Parakeet TDT 0.6B v2 INT8** (max accuracy, flagship phones) | §6, §10b, §19 |
| VAD | **Silero VAD** via sherpa-onnx, utterance-gated | §6, §11 |
| Streaming granularity | **Per-utterance captions** (text appears at natural pauses, ~1–3 s) | §15 default |
| Decode | Greedy, 2 threads | §13 |
| Scope | English only, Android only, fully offline | locked scope |
| Load strategy | Prepare once (singleton) + warmup inference; never per session | §9 |

## 2. Goals

1. Prove live VAD-gated captions + final transcript work on real phones with this stack.
2. Measure the §18 acceptance metrics on real devices (the app displays them — no adb needed).
3. Produce the exact code modules the main app will absorb, behind the exact interface it will keep.

## 3. Non-goals (deliberately NOT in the demo)

- **No backend upload** — the demo ends at "final transcript + duration_seconds produced." The sync path exists in the main app.
- **No foreground service / background recording** — the demo must stay in the foreground (screen is kept awake via wakelock while recording). The service shell is main-app work (findings doc UI-1); the engine plugs into it at integration time.
- **No device tiering / cloud fallback / two-pass** — later milestones (§10, §14), decided after benchmark numbers exist.
- **No auth, no persistence, no settings.** One screen.

## 4. Architecture

```
lib/
├── main.dart                                  # demo UI: model catalog + record screen + metrics (throwaway)
├── models/
│   ├── model_catalog.dart                     # ★ downloadable-model registry (id, URLs, sizes)
│   └── model_store.dart                       # ★ download-once-and-cache store (progress, cancel, resume, delete)
├── transcriber/
│   ├── transcriber.dart                       # ★ THE INTERFACE — copied to the main app unchanged
│   └── sherpa_onnx_transcriber.dart           # ★ engine in a background isolate; Moonshine + NeMo transducer (Parakeet)
├── audio/
│   └── mic_capture.dart                       # ★ record pkg, 16 kHz mono PCM16 → Float32
└── util/
    └── pcm.dart                               # ★ PCM conversion (unit-tested)
```
★ = handoff modules. The UI (`main.dart`) is throwaway.

**Pipeline:** mic (16 kHz mono PCM16) → Float32 → 512-sample windows → Silero VAD → finalized utterance segments → Moonshine offline decode → `TranscriptSegment` stream (live captions) + accumulated buffer → on Stop: VAD flush + assembled `TranscriptResult { text, segments, audioDuration }`.

**Interface contract** (`Transcriber`): `prepare() → TranscriberStats` / `start()` / `Stream<TranscriptSegment> segments` / `stop() → TranscriptResult` / `dispose()`. `TranscriptResult.durationSeconds` exists specifically because the main app must send `duration_seconds` in `POST /api/notes/sync`.

**Responsiveness design:** the entire engine (load, warmup, VAD, decode) lives in a **long-lived background isolate** — the UI thread never blocks, so loaders animate during model load and Stop finalizes behind a live "Finalizing…" spinner instead of freezing. The UI additionally gets `audioLevel` (mic RMS pulse) and `speechActive` ("Transcribing…" pending bubble) streams from the interface so the screen reacts the instant the user speaks, before the first caption lands. Utterances are capped at 8 s (`maxSpeechDuration`) so captions arrive on a steady rhythm even in pause-free monologues. Accuracy levers on by default: platform voice processing (AGC + noise suppression + echo cancel) on capture — clean input beats a bigger model (§13) — and the Parakeet catalog entry for phones that can carry it.

## 5. Model delivery — in-app download-and-cache

Models are **not bundled in the APK** (the APK stays ~35 MB). The app ships a **model catalog** (`lib/models/model_catalog.dart`: Moonshine base + tiny, both English INT8) with an in-app download button per model — the download-once-and-cache strategy from the transcription spec §12/§20. Details:

- Files come from the official sherpa-onnx mirrors (HuggingFace `csukuangfj/sherpa-onnx-moonshine-*-en-int8` per-file, Silero VAD from the k2-fsa GitHub release). Filenames are normalized on disk (`encode.int8.onnx → encode.onnx`) so **every Moonshine variant runs through identical engine code — only paths differ**.
- Download has live progress, cancel, and file-level resume (finished files are kept; retry skips them). Silero VAD (~2 MB) is a shared component fetched once with the first model.
- Users can install several models, switch between them (engine re-`prepare`s with the new paths), and delete them.
- **Nothing is trained or modified on device.** Weights are read-only inference artifacts; the INT8 quantization was applied upstream before publication. Model updates = publishing a new catalog entry, never touching weights locally.
- Trade-off: the app now requires the INTERNET permission (for the download only). Transcription remains fully offline; audio and transcripts never leave the device.

## 6. Build & distribution (cloud-only)

- `flutter build` happens **only** in GitHub Actions (`.github/workflows/build-apk.yml`): JDK 17 + Flutter **3.41.2** (pinned to the main app's `.fvmrc`) on ubuntu-latest, with `flutter analyze` + `flutter test` as gates before the build.
- Release APK is **debug-signed on purpose**: installable on any phone, zero keystore/secrets. This app never goes to a store.
- `--split-per-abi`; the arm64-v8a APK is what modern phones need.
- Trigger: push to `main`, or Actions → "Build Demo APK" → Run workflow. (Models are no longer part of the build — they're downloaded in-app.)
- The Android shell (`android/`) is copied from the main Picaku repo — same AGP 8.11.1 / Kotlin 2.2.20 / Gradle 8.14 / JDK 17 — with its two known defects fixed (guarded/debug signing; sane Gradle JVM args). Toolchain parity is deliberate: whatever builds here builds in the main app.

## 7. Acceptance criteria (from ON_DEVICE_TRANSCRIPTION.md §18)

Measured with the in-app metrics panel, on real meeting-style speech:

| Metric | Target | Where shown |
|---|---|---|
| Avg RTF (decode time / audio time) | **< 0.3** (expect ≈ 0.05–0.15) | Session metrics card |
| Caption latency after a pause | **< ~2 s** (≈ VAD min-silence 0.4 s + decode) | observed live |
| Time-to-ready (load + warmup, warm start) | **no visible wait** (~1–3 s, shown on Ready card) | Engine-ready card |
| Accuracy vs current Whisper flow | subjectively better on the same speech | manual A/B vs main app |
| Stability | 30–60 min session, no crash/OOM, phone doesn't cook | manual |

Test matrix (minimum): one budget Android (3–4 GB RAM) + one mid/flagship. **Record the numbers per device** — they go into the integration doc and drive the tiering decisions.

## 8. Handoff → "Model Integration doc" (after validation)

When the demo passes §7, the integration doc for the main-app dev will contain:

1. **Modules to copy verbatim:** `lib/transcriber/*`, `lib/audio/mic_capture.dart`, `lib/util/pcm.dart`, plus the tests.
2. **Dependency changes:** add `sherpa_onnx`; `record`/`path_provider` already present.
3. **Wiring:** one `Transcriber` instance provided app-wide; `prepare()` in the background *after* first frame (never blocking `runApp` — findings CORE-3); record page consumes `segments` for live captions; `stop()` result feeds the existing note-save flow **including `durationSeconds`** (findings SYNC-10).
4. **Feature flag:** wrap the legacy `WhisperService` in the same `Transcriber` interface; flag chooses the engine; remove whisper.cpp + the 181 MB bundled model only after the new path wins in production (§17.10).
5. **Foreground service:** engine hooks into the main app's recording service (findings UI-1) — start/stop tied to service lifecycle, transcript segments persisted incrementally (§16).
6. **Engine isolate:** already implemented in the demo — carries over as-is.
7. **Model distribution decision:** bundle-tiny vs download-base per device tier (§12/§20), replacing `model_assets.dart` internals only.
8. **Proguard/R8:** keep rules for sherpa-onnx JNI if minification is enabled (findings AND-4).
9. **Benchmark numbers per device** from §7 as the regression baseline.

## 9. Risks / notes

- `sherpa_onnx` Dart API signatures were written against the official flutter examples but could not be compiled locally (no local SDK — by design). The CI `flutter analyze` step is the verification gate; expect possibly one round of small API fixes on the first workflow run. This is exactly the "verify exact package APIs against the official examples" caveat from the transcription spec's preamble.
- Moonshine v1 is not a frame-streamer: captions appear per utterance, at pauses. That is the accepted §15 default; word-by-word would be the Zipformer route.
- Silence in → nothing out is **correct** (VAD gating). The UI says "captions appear at natural pauses" to set expectations.
