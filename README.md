# Picaku STT Demo

Standalone spike app: **on-device English transcription** with sherpa-onnx + Moonshine INT8 + Silero VAD. Live captions while you speak, final transcript + performance metrics when you stop.

The APK is small (~35 MB): models are **downloaded in-app** from a catalog (Moonshine base ~170 MB / tiny ~75 MB, plus a shared 2 MB Silero VAD) with progress, cancel, resume, switch, and delete. Internet is used **only** for that one-time download — transcription runs fully offline and no weights are ever trained or modified on device.

Validates the engine from `ON_DEVICE_TRANSCRIPTION.md` before it is integrated into the main Picaku app. See **DEMO_SPEC.md** for scope, architecture, and acceptance criteria.

## Build it (no local SDK needed — cloud-only)

1. Create a **new GitHub repo** and push this folder to `main`:
   ```powershell
   git init
   git add .
   git commit -m "Picaku STT demo: sherpa-onnx + Moonshine + Silero VAD spike"
   git branch -M main
   git remote add origin https://github.com/<you>/picaku-stt-demo.git
   git push -u origin main
   ```
2. The **Build Demo APK** workflow runs automatically (or trigger it from the Actions tab). It runs `flutter analyze` + `flutter test` and builds the APK. First run ≈ 10–15 min; cached runs are faster.
3. Download the `picaku-stt-demo` artifact from the run page, copy **`app-arm64-v8a-release.apk`** to your phone, and install it (allow "install unknown apps" once). It's debug-signed on purpose — no keystore setup, installs anywhere.

> If the very first run fails on `flutter analyze` with sherpa_onnx API mismatches, that's the expected verification gate (see DEMO_SPEC.md §9) — paste the log to Claude and it's a small fix + push.

## Use it

Open the app → pick a model in the catalog and **Download** it (Wi-Fi recommended; progress shown, cancel/resume supported) → it loads + warms up (timings shown) → tap the mic → speak → captions appear at natural pauses with per-segment RTF → tap **Stop** → full transcript + session metrics (avg RTF target **< 0.3**) → **Copy** to export. Use **Switch model** to A/B base vs tiny on the same speech.

Test on at least one budget phone (3–4 GB RAM) and one good phone, and note the numbers — they feed the integration doc.

## Local development (optional)

Only the Flutter SDK is required (no Android Studio / Android SDK, per `FLUTTER_CLEAN_CLOUD_DEV.md`):

```powershell
flutter pub get
flutter analyze
flutter test
```

## Layout

```
lib/models/        model catalog + download-once-and-cache store  ← handoff modules
lib/transcriber/   Transcriber interface + sherpa-onnx/Moonshine engine  ← handoff modules
lib/audio/         mic capture (record pkg, 16 kHz mono PCM16)
lib/util/          PCM conversion
lib/main.dart      throwaway demo UI (catalog + record + metrics)
android/           shell copied from the main Picaku app (same toolchain), signing fixed
.github/workflows/ cloud build: analyze + test + APK artifact (no models in the build)
```
