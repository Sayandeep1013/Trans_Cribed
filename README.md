# Picaku STT Demo

Standalone spike app: **on-device English transcription** with sherpa-onnx + Moonshine INT8 + Silero VAD. Live captions while you speak, final transcript + performance metrics when you stop. Fully offline — the release build has no internet permission at all.

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
2. The **Build Demo APK** workflow runs automatically (or trigger it from the Actions tab — there you can pick Moonshine **base** or **tiny**). It downloads the models, runs `flutter analyze` + `flutter test`, and builds the APK. First run ≈ 10–15 min; cached runs are faster.
3. Download the `picaku-stt-demo-base` artifact from the run page, copy **`app-arm64-v8a-release.apk`** to your phone, and install it (allow "install unknown apps" once). It's debug-signed on purpose — no keystore setup, installs anywhere.

> If the very first run fails on `flutter analyze` with sherpa_onnx API mismatches, that's the expected verification gate (see DEMO_SPEC.md §9) — paste the log to Claude and it's a small fix + push.

## Use it

Open the app → it loads + warms up the model once (timings shown) → tap the mic → speak → captions appear at natural pauses with per-segment RTF → tap **Stop** → full transcript + session metrics (avg RTF target **< 0.3**) → **Copy** to export.

Test on at least one budget phone (3–4 GB RAM) and one good phone, and note the numbers — they feed the integration doc.

## Local development (optional)

Only the Flutter SDK is required (no Android Studio / Android SDK, per `FLUTTER_CLEAN_CLOUD_DEV.md`):

```powershell
pwsh ./scripts/get_models.ps1        # fetch models into assets/ (CI does this itself)
flutter pub get
flutter analyze
flutter test
```

## Layout

```
lib/transcriber/   Transcriber interface + sherpa-onnx/Moonshine engine  ← the handoff modules
lib/audio/         mic capture (record pkg, 16 kHz mono PCM16)
lib/util/          PCM conversion
lib/main.dart      throwaway demo UI + metrics
android/           shell copied from the main Picaku app (same toolchain), signing fixed
.github/workflows/ cloud build: models + analyze + test + APK artifact
```
