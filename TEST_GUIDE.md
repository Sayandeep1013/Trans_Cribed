# Picaku STT Demo — Tester Guide

> **What you are testing:** a standalone spike app that transcribes speech
> **entirely on your phone** — no internet, no server, no account. It exists to
> answer whether this engine is good enough to put inside the real Picaku app.
>
> **What you are NOT testing:** visual design, polish, or the flow between
> screens. The UI is throwaway scaffolding. Ugly is fine; wrong is not.
>
> **How long:** 20 minutes for the basics (Parts 1–3). 60+ minutes if you also
> do accuracy and endurance (Parts 4–6).

---

## 0. Before you start

### Install

1. Uninstall any older "Picaku STT Demo" first — **required** if you were given
   a build before 28 July 2026, because the app's signing key changed and
   Android will refuse the update otherwise. Settings → Apps → Picaku STT Demo
   → Uninstall.
2. Install the APK (`...-arm64-v8a.apk` for any phone from the last ~8 years).
3. Android will warn about **"unknown apps"** and Play Protect may call it
   unsafe. Both are expected — this is an unsigned internal test build. Choose
   **Install anyway**.
4. Open it and grant **microphone** permission when asked.

### Download a model

The app ships with no model — the download button is inside the app. On the
**Record** tab pick one and tap **Download** (Wi-Fi strongly recommended):

| Model | Size | Use it for |
|---|---|---|
| **Moonshine Base** | ~170 MB | **Start here.** The default candidate. |
| Moonshine Tiny | ~75 MB | Speed/accuracy trade-off comparison |
| Whisper Base.en | ~161 MB | The engine the current app uses — the baseline |
| Whisper Tiny.en | ~104 MB | Same family, smaller |
| NVIDIA Parakeet TDT 0.6B | ~640 MB | **Only on phones with 8 GB+ RAM.** Skip on budget devices. |

Download at least **two** models — most of the interesting tests compare them.

### What to send back

For every issue: **what you did → what you expected → what happened**, plus
your phone model and Android version. Screenshots help; a screen recording
helps more.

For anything performance-related, also send the diagnostics:
**Diagnostics tab → Copy full log JSON** → paste into a note/message. It
contains timings, memory, thermals and your transcripts. **It contains what you
said**, so do not record anything confidential during testing.

---

## 1. Basic functionality

Tick each one. If any fails, stop and report it — later tests depend on these.

| # | Do this | Expect |
|---|---|---|
| 1.1 | Open the app with no model installed | Model list, each with size and source. No crash. |
| 1.2 | Tap **Download** on Moonshine Base | Progress bar with MB counter and file 1/6, 2/6… |
| 1.3 | Tap **Cancel** mid-download | Returns to the list promptly, no freeze |
| 1.4 | Tap **Download** again | **Resumes** — already-finished files are skipped, not re-fetched |
| 1.5 | Let it finish | Loads automatically, shows "Engine ready" with **model load** and **warmup** times |
| 1.6 | Tap the big mic button | Recording screen: timer counting, red dot **pulsing with your voice** |
| 1.7 | Say a sentence, pause | Caption appears within ~1–2 s of the pause |
| 1.8 | Say two more sentences | Each becomes its own caption, newest at the top |
| 1.9 | Tap **Stop** | "Finalizing…" briefly, then the full transcript + session metrics |
| 1.10 | Toggle **Plain / Timestamped** | Timestamped shows a time range and decode time per line |
| 1.11 | Tap **Copy** | "Copied to clipboard" — paste somewhere to confirm the text is real |
| 1.12 | Tap **New session**, record again | Starts immediately — **no model reload**, no waiting |
| 1.13 | Download a second model | Both show "Installed" |
| 1.14 | Tap the mic button now | **A "Transcribe with" sheet appears** listing both, loaded one marked |
| 1.15 | Pick the *other* model | Loads it, then starts recording by itself |
| 1.16 | Go to the model list, **Delete** one | Disappears, storage freed, app still works |

**Key number to report from 1.5:** model load and warmup in ms, per model.

---

## 2. The specific fixes — please be harsh here

These are bugs that were reported and fixed. Confirm they are actually gone.

### 2.1 Talking without pausing ⭐ most important

Previously, speaking fluently produced **nothing on screen** until you stopped.

- Talk continuously for **45 seconds** with no real pause. Read from something
  if that's easier.
- **Expect:** a caption appears roughly **every 6 seconds** while you're still
  talking, updating as you go, then firming into final text.
- **Report if:** the screen stays empty for more than ~10 seconds while you are
  clearly speaking.

### 2.2 Stop should not freeze

- Record 2 minutes, then tap **Stop**.
- **Expect:** the "Finalizing…" spinner **animates** — the screen is never
  frozen. Under ~2 s to the transcript.
- **Report if:** the UI locks up, or the spinner is stuck for more than ~5 s.

### 2.3 Captions should start promptly

- Tap the mic and start talking immediately.
- **Expect:** the red dot reacts to your voice **instantly**, first caption
  within a couple of seconds of your first pause.
- **Report if:** the first caption takes noticeably longer than later ones.

### 2.4 Timestamps should line up

- Record, deliberately pausing 3 seconds between three sentences.
- Switch to **Timestamped**.
- **Expect:** time ranges match when you actually spoke, in order, no overlaps.

---

## 3. Accuracy — the part that actually decides things

Casual impressions here are worthless, because you never say a sentence the
same way twice. The app is built to remove that problem: **record once, then
replay that same audio through every model.**

### 3.1 Scored passage (no typing needed)

1. On the ready screen tap **"Read a scored passage instead"**.
2. Pick one — **Harvard sentences** (neutral), **Meeting-style** (realistic),
   or **Names, numbers and jargon** (the hard one).
3. Record yourself reading it at a natural pace, then Stop.
4. The app knows the text, so **WER appears automatically**.

**WER = word error rate**, the standard ASR metric. 10% ≈ one word in ten
wrong. Lower is better.

### 3.2 Compare models on identical audio ⭐

1. **Lab** tab → find your recording.
2. **Re-decode with other models** → select all installed → **Run**.
3. Each model loads, decodes the *same* audio, unloads. Big models take a while.
4. Read the table: **RTF**, load time, RAM, **WER** per model.

**Report the whole table.** This is the single most valuable thing you can send
back.

> **RTF** = decode time ÷ audio length. 0.1 means a 10-second utterance decoded
> in 1 second. Below 0.3 is the target; lower is better.

### 3.3 Your own speech, your own words

1. Record yourself talking normally for a minute — real speech, not a script.
2. Lab → that recording → **Add reference text** → type what you actually said.
3. Re-decode with all models.

This matters more than the passages: it is the register the app must handle.

### 3.4 Accent testing — needs several people

**This only works if everyone reads the same passage.**

- Have 3–5 people with **different accents** each read the **same** passage on
  the **same** phone.
- Record each, note who is who, re-decode all with the same models.
- Send the WER per speaker per model.

The spread between speakers is the accent measurement. One person is one data
point and proves nothing about accents.

### 3.5 Does padding help? (Lab)

1. Record the jargon passage.
2. Re-decode → note WER.
3. Lab → set **Pre-roll** and **Post-roll** both to **0 ms**.
4. Re-decode the **same** recording → note WER again.

**Expect:** 0/0 is worse, especially on first words. Report both numbers even
if you see no difference — a null result is a real result.

### 3.6 Does the mic processing help or hurt?

**This one needs two recordings** — Android applies these before the app sees
any audio, so re-decoding cannot test them.

1. Record the Harvard passage with defaults. Note WER.
2. Lab → turn **off** auto-gain, noise suppression, echo cancel.
3. Record the **same passage again**. Note WER.

Report both. Do it in a quiet room *and* a noisy one if you can.

### 3.7 Hotwords — Parakeet only

Only if you have Parakeet installed.

1. Lab → Advanced → turn on **Beam search**, and enter hotwords one per line:
   `Picaku`, `Supabase`, `sherpa-onnx`, plus names of people you'll mention.
2. Record the jargon passage, compare WER with and without.

---

## 4. Resources and endurance

**Diagnostics** tab.

| # | Do this | Report |
|---|---|---|
| 4.1 | Sit on Diagnostics with a model loaded, idle | RAM (RSS), CPU %, threads |
| 4.2 | Record for 2 minutes, watch it live | Peak RAM, CPU during decode |
| 4.3 | Compare across models | RAM per model — especially Parakeet |
| 4.4 | **Record continuously for 30–45 minutes** ⭐ | See below |

### The long session (4.4) — the most valuable endurance test

Play a podcast or talk radio near the phone and let it run. Screen must stay on
(the app keeps it awake).

Report from the **Endurance** card:
- **RAM trend (MB/hour)** — should be roughly flat. A steady climb is a leak.
- **Throttled samples** and **worst thermal state** — when did throttling start?
- **Battery drain %/hour**
- Whether **RTF got worse** over time (compare early vs late segments in the log)
- Did the phone get uncomfortably hot?
- Did it crash, or did captions stop arriving?

Then **Copy full log JSON** and send it.

---

## 5. Edge cases — please try to break it

Grouped by kind. Note the ones that misbehave; some already have known answers,
marked ✔ *expected*.

### Audio

| Try | Expect |
|---|---|
| Record 30 s of **pure silence** | No captions at all. ✔ *expected — that's the voice detector working, not a bug* |
| **Whisper very quietly** | Should still transcribe; if not, note it |
| **Shout** into the mic | No crash, no garbage output |
| Say one short word (**"yes"**) and stop | The word should survive, not get dropped |
| Talk for **5 straight minutes** with no pause | Captions keep arriving throughout |
| Hold the phone **3–4 metres away** | Degrades gracefully, no crash |
| **Cover the mic** mid-sentence | Recovers when uncovered |
| Play **music** with no speech | Little or no output; no crash |
| **Two people talking over each other** | Garbled is acceptable; crashing is not |
| Speak **another language** | Nonsense English out. ✔ *expected — English-only build* |
| **Very fast** speech, then very slow | Both handled |
| Say lots of **numbers and acronyms** | Note how badly — this is known-hard |
| **Cough / laugh / clear throat** | No crash, no absurd output |

### Interruptions while recording ⭐ high value

| Try | Expect |
|---|---|
| **Incoming phone call** | Recording stops or pauses cleanly. **No crash, no lost transcript.** |
| **Alarm** goes off | Same |
| Switch to another app and come back | Note exactly what happens |
| **Lock the screen** | Capture will stop. ✔ *expected — no background service in this demo* |
| Let the screen time out on its own | Should NOT sleep — the app holds it awake. Report if it does. |
| **Plug in / unplug headphones** mid-recording | No crash |
| **Connect / disconnect Bluetooth** headset mid-recording | No crash — note if audio dies silently |
| Open **WhatsApp voice note** or another recorder while recording | No crash; note whether the app notices losing the mic |
| **Battery saver** on, then record | Note any slowdown |

### Permissions

| Try | Expect |
|---|---|
| **Deny** mic permission at the prompt | Clear message explaining it's needed, with a retry — not a crash |
| Deny, then grant in Settings, return | Works without reinstalling |
| **Revoke** mic in Settings while the app is open | Graceful error, no crash |

### Downloads and network

| Try | Expect |
|---|---|
| **Airplane mode** mid-download | Clear failure message, not a hang |
| Retry after re-enabling | **Resumes** — finished files kept |
| Switch **Wi-Fi → mobile data** mid-download | Either continues or fails clearly |
| **Force-close** the app mid-download, reopen | No corruption; retry resumes |
| Download with **very low storage** | Clear error, not a corrupted model |
| Start a download and immediately **background** the app | Note the behaviour |

### Storage and models

| Try | Expect |
|---|---|
| **Delete the model currently loaded** | App stays usable, prompts for a model |
| Install all 5 models | Roughly 1.1 GB total; all switchable |
| Record 10 sessions | ~2 MB per minute of audio kept. Delete some in Lab and confirm space returns |
| Lab → turn **Keep session audio off**, record | Works, but re-decode is unavailable for it ✔ *expected* |

### App lifecycle

| Try | Expect |
|---|---|
| **Rotate** the phone on every screen | No crash, no lost state |
| **Force stop** while recording, reopen | No crash; partial data loss is acceptable |
| **Reboot** the phone, reopen | **Models and past recordings survive** |
| Leave it in the background an hour, return | No crash |
| Switch to **light mode** (if your phone has it) | Text still readable — report anything invisible |

### Rapid / concurrent actions

| Try | Expect |
|---|---|
| Tap **Stop** twice quickly | No double-finalize, no crash |
| Tap the mic twice quickly | Only one recording starts |
| Start a **re-decode**, then hit the Record tab and record | Either blocked cleanly or works — must not crash |
| Drag a Lab slider back and forth fast | Engine reloads once when you let go, not continuously |
| Change a setting **during** recording | Should not disrupt the recording in progress |
| Re-decode with **all 5 models** at once | Slow but completes; watch RAM |

---

## 6. Known limitations — do NOT report these

These are deliberate. Reporting them is fine but they're already understood.

- **The screen must stay on.** Lock the screen and capture stops. The demo has
  no background recording service on purpose — that lives in the real app.
- **Captions appear at pauses**, plus a provisional one every ~6 seconds during
  continuous speech. It is not word-by-word live captioning.
- **English only.**
- **Whisper models are slow.** Their design pads every utterance to 30 seconds.
  That's expected; it's why they're the baseline rather than the recommendation.
- **Play Protect warns about the app.** It's an internal debug-signed build.
- **No sync, no upload, no login.** The demo ends at "here is your transcript".
- **Diagnostics shows no GPU.** Nothing to show — inference is CPU-only here.
- **Changing a Lab setting reloads the engine** (a few seconds). Expected.

---

## 7. Severity — how urgent is what you found

| Level | Means | Examples |
|---|---|---|
| **Blocker** | Can't use the app | Crash on launch, model won't download, no captions ever |
| **Major** | Core feature broken | Crash during recording, transcript lost on Stop, freeze >5 s, phone overheats |
| **Minor** | Works, but wrong | Bad timestamps, wrong metric, occasional caption drop |
| **Note** | Observation | "Accuracy poor on my accent", "battery drains fast" |

Accuracy complaints are most useful as **Note + numbers** (WER from Part 3),
not as "it's bad".

---

## 8. Report template

```
DEVICE:   e.g. Samsung Galaxy A06, Android 16, 6 GB RAM
MODEL(S): e.g. Moonshine Base, Whisper Base.en
BUILD:    (Diagnostics → the version at the bottom, or the APK filename)

WHAT I DID:
WHAT I EXPECTED:
WHAT HAPPENED:
SEVERITY:  Blocker / Major / Minor / Note

NUMBERS (if performance or accuracy):
  Model load / warmup:
  Avg RTF:
  Caption latency p50 / p95:
  WER per model:
  Peak RAM:

Attached: diagnostics JSON / screenshot / screen recording
```

---

## 9. Priorities, if you're short on time

1. **§2.1** — talking without pausing (the headline fix)
2. **§3.2** — re-decode comparison table
3. **§4.4** — the 30-minute endurance run
4. **§5 Interruptions** — phone call and screen lock during recording
5. **§3.4** — accent spread, if you can find several speakers

Everything else is a bonus.
