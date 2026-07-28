# Model & Device Optimization — Strategy

> **Status:** planning document. Nothing here is implemented yet. What *is*
> implemented is the measurement apparatus this plan depends on (Lab tab,
> Diagnostics tab, re-decode benchmark) — see `DEMO_SPEC.md`.
>
> **Purpose:** decide *how* we would optimize, before spending effort
> optimizing. Every item below is ranked by expected payoff against cost, and
> every one names the measurement that proves or kills it.
>
> **Date:** 2026-07-28

---

## 1. The governing principle

We have been tuning on impressions — "accuracy feels off", "the stream comes
late". Impressions are not wrong, but they cannot rank fixes, and they cannot
tell you when to stop. Two things make the difference:

1. **A fixed input.** Session audio is now retained, so one recording can be
   re-decoded by every model and every option set. Any difference in output is
   the change, not the way you happened to speak that time.
2. **A number.** WER against a known reference, RTF, caption latency, RSS,
   thermal state. All are now on screen and exportable as JSON.

**Rule for everything below: no change lands without a before/after on the same
recording.** Optimization without that is just churn that feels productive.

---

## 2. What is and is not on the table

| | |
|---|---|
| **Fixed** | Weights are read-only inference artifacts. Nothing is trained, fine-tuned or quantized on device — ever. INT8 quantization happened upstream before publication. |
| **Fixed** | Inference is CPU-only. sherpa-onnx ships ONNX Runtime with XNNPACK; the Flutter builds carry no NNAPI, GPU or NPU delegate. "Use the GPU" is not a setting we can flip (§6.4). |
| **Changeable** | Which model we ship, its decode configuration, everything we do to the audio before it reaches the model, and how we schedule work on the device. |

That boundary is the whole reason this is an *engineering* optimization problem
and not an ML one.

---

## 3. The optimization surface

Four layers, cheapest and safest first. **Work them in this order** — layer 1
costs nothing to try and layer 4 costs weeks.

```
L1  Audio & pipeline    padding, VAD tuning, capture DSP, level normalization
L2  Decode config       threads, beam vs greedy, hotwords, utterance length
L3  Model selection     which model per device tier; two-pass; swap entirely
L4  Platform            scheduling, thermal budget, foreground service, delegates
```

---

## 4. Ranked backlog

Payoff is a guess until measured; that is the point of the "verify" column.

### Tier A — do these first (cheap, high expected payoff)

| # | Change | Why it should help | Cost | Verify with |
|---|---|---|---|---|
| A1 | **VAD pre/post-roll padding** (now default 200/200 ms) | Silero returns segments clipped exactly at detection, shaving word onsets and trailing consonants. Prime suspect for the "accuracy is off" reports. | Done, needs measuring | Re-decode one recording at 0/0 vs 200/200 vs 400/400; compare WER |
| A2 | **Capture DSP A/B** (AGC / noise suppression / echo cancel) | These were turned on by assumption. They are tuned for telephony and suppression can smear speech. Might be *hurting*. | Toggle, but needs re-recording | Record the same passage twice, all-on vs all-off; compare WER |
| A3 | **Min-silence tuning** (350 ms) | Dominant term in caption lag. The Diagnostics latency breakdown now shows exactly how much of the lag it accounts for. | Slider | Latency p50/p95 before/after; watch for mid-sentence splits |
| A4 | **Hotwords for meeting vocabulary** | Contextual biasing is the single biggest lever for names, products and jargon — exactly what the "hard" passage exposes. Parakeet only. | Text box, needs beam search | WER on the names/jargon passage with and without |
| A5 | **Thread count sweep** | Defaults (2 / 4) were picked by intuition. Returns flatten fast and extra threads only add heat. | Slider | RTF at 1/2/4/6/8 threads, plus thermal state after 10 min |

### Tier B — real work, do after Tier A data exists

| # | Change | Why | Cost | Risk |
|---|---|---|---|---|
| B1 | **Device tiering** — pick the default model from RAM / core count | A 3 GB phone and a flagship should not run the same model. Diagnostics already reports device RAM. | Medium | Wrong thresholds ship a bad default |
| B2 | **Remote model manifest** — fetch the catalog as JSON instead of compiling URLs in | Lets us add or repoint a model without an app release, and roll back a bad one. | Medium | Needs hosting + signature/pinning, or it becomes an attack surface |
| B3 | **Adaptive interim interval** — widen when RTF is high or thermals rise | Interim captions cost one extra decode each. On a throttling phone that is the first thing worth dropping. | Medium | Captions get less responsive exactly when the user notices |
| B4 | **Incremental segment persistence** | A 60-minute session currently lives in RAM until Stop. Also the prerequisite for crash-safety in the main app. | Medium | None significant |
| B5 | **Two-pass decode** — fast model live, accurate model on the full audio at Stop | Best of both: instant captions, high-quality final transcript. Needs retained audio, which we now have. | High | Stop becomes slow; needs a background job + progress UI |

### Tier C — only if the numbers demand it

| # | Change | Notes |
|---|---|---|
| C1 | **Different model family entirely** | The catalog is one `switch` branch per architecture. SenseVoice, FireRedASR, Dolphin, Zipformer CTC and Canary are all already supported by the package. Cheap to *try*, so gate it on a measured deficiency, not curiosity. |
| C2 | **Custom ONNX export / graph optimization** | Re-exporting with fused ops or a different opset can win 10–20%. Requires an offline toolchain and re-validation of every model. |
| C3 | **Streaming (Zipformer) model for word-by-word captions** | Truly incremental output instead of utterance-gated. Architecturally different: a streaming recognizer, not an offline one. Only if per-utterance captions are judged insufficient after B3. |
| C4 | **Vendor NPU delegates (QNN / NNAPI)** | Would need a different sherpa-onnx build with the delegate compiled in, and per-vendor validation. Large effort, fragile, high ceiling. |

---

## 5. Model-side specifics

### 5.1 The Whisper trap

Whisper's encoder is **fixed at 30 seconds**. Every utterance — a two-second
"yes, agreed" included — is zero-padded to 30 s before inference. Our pipeline
is VAD-gated short utterances, which is the worst possible shape for it. This
is precisely the inefficiency Moonshine was built to remove: the Moonshine
paper measures **~5× less compute than Whisper tiny.en on a 10-second segment
at equal WER**.

Whisper is in the catalog as **the baseline to beat**, because it is what the
main app runs today via whisper.cpp. If Moonshine beats it on both RTF and WER
on your own speech, that is the evidence that justifies the migration. Do not
treat a Whisper win on one passage as a reason to switch to it without also
looking at RTF.

Also note: [sherpa-onnx issue #2900](https://github.com/k2-fsa/sherpa-onnx/issues/2900)
reports Whisper tiny producing higher CER in sherpa-onnx than in faster-whisper.
If Whisper scores unexpectedly badly here, that is a candidate explanation and
not necessarily a fact about Whisper itself.

### 5.2 Size is not the useful axis

| Model | Download | Family | Variable length? | Hotwords? |
|---|---|---|---|---|
| Moonshine Tiny | 75 MB | Moonshine | Yes | No |
| Moonshine Base | 170 MB | Moonshine | Yes | No |
| Whisper Tiny.en | 104 MB | Whisper | **No** (30 s) | No |
| Whisper Base.en | 161 MB | Whisper | **No** (30 s) | No |
| Parakeet TDT 0.6B | 640 MB | NeMo transducer | Yes | **Yes** |

Whisper Tiny.en is *larger* than Moonshine Tiny and slower per utterance. Rank
by measured RTF and WER, never by parameter count or file size.

### 5.3 Quantization

All catalog entries are INT8. FP32 variants exist upstream (roughly 3× the
download) and would be the accuracy ceiling for a given architecture. Worth one
measurement on Moonshine Base to find out what INT8 actually costs us in WER —
if it is under half a point, the question is permanently closed.

---

## 6. Device-side specifics

### 6.1 Thermal is the real session limit

Not RAM, not battery. The CPU governor starts clawing back clocks once Android
reports `MODERATE`, and RTF drifts upward from there. Diagnostics now records
thermal status per sample and flags throttled samples, so the shape of a long
session is observable rather than theoretical.

**Test to run:** 45-minute continuous session, Moonshine Base, watch RTF at
minute 1 vs minute 40. If it degrades materially, the fix is a lower thread
count or a smaller model — not a faster one.

### 6.2 The interruption we will hit first is not thermal

The demo has **no foreground service** by design. With the screen off, Android
suspends audio capture regardless of how healthy the thermal and memory numbers
look. This is already tracked as UI-1 in `CODEBASE_REVIEW_FINDINGS.md` and is
main-app work. Any endurance number measured here assumes the screen stays on
via wakelock.

### 6.3 Memory

RSS and its trend over time are now sampled. What matters:

- **Steady state** — a model's resident cost, visible as the RSS delta in a
  benchmark row.
- **Trend** — a rising MB/hour figure is a leak, and the endurance card reports
  it directly. Native handles (recognizer, VAD, streams) are the likely
  culprits if it ever appears.
- **Headroom** — Android's own `lowMemory` flag is reported. Parakeet at 640 MB
  on a 4 GB phone is the case to watch.

### 6.4 On "using the GPU"

There is no GPU path to enable. sherpa-onnx runs `provider: 'cpu'` with
XNNPACK, and these builds contain no GPU, NNAPI or NPU delegate. Changing that
means a different native build of the library (C4 above), not a config flag.
The Diagnostics page says so explicitly rather than showing an empty gauge —
a metric that always reads zero teaches the reader nothing.

---

## 7. How to run an experiment

1. Record **once**, with a scored passage if you want a WER number without
   typing a reference.
2. Change exactly **one** thing.
3. **Re-decode the same recording** (Lab → Re-decode with other models).
4. Compare WER, RTF and RAM in the results table.
5. Export the diagnostics JSON and keep it. These become the regression
   baseline in the integration doc.

Two caveats that will otherwise waste your time:

- **Capture DSP settings cannot be A/B'd on stored audio.** Android applies AGC,
  noise suppression and echo cancellation before the app receives any samples.
  Those three require recording the passage twice.
- **One speaker is one data point.** Accent conclusions need the same passage
  read by several people. That is the entire reason the scored passages exist.

---

## 8. Decision gates

Optimization stops when these hold on the target device, or continues on
whichever one fails:

| Gate | Threshold | Source |
|---|---|---|
| Avg RTF | < 0.3 | ON_DEVICE_TRANSCRIPTION.md §18 |
| Caption latency p95 | < 2 s | §18 |
| Time to ready (warm) | no visible wait | §18 |
| WER vs the main app's Whisper flow | better on the same audio | §18 |
| 45-minute session | no crash, no OOM, RTF drift < 25% | §18 + §6.1 |
| RAM trend | flat | §6.3 |

---

## 9. Dead ends — deliberately not doing these

- **Spectral denoising before the model.** Reliably hurts ASR. The models were
  trained on noisy audio; scrubbing it removes information they use.
- **Manual MFCC / feature extraction.** sherpa-onnx does its own log-mel
  internally, and Moonshine takes raw waveform. Any hand-rolled front end is
  redundant at best and mismatched at worst.
- **Resampling.** Capture is already 16 kHz mono, which is what every model
  here expects.
- **On-device fine-tuning to an accent.** No training happens on device, and
  the runtime has no path for it. Accent handling is model selection plus
  hotwords, full stop.
- **Chasing leaderboard WER.** Published numbers are American read speech.
  Yours is Indian-accented spontaneous meeting speech through a phone mic. Only
  your own measurements decide anything.

---

## 10. Open questions the device data should close

1. Does padding (A1) measurably reduce WER, and where do returns flatten?
2. Do the capture DSP toggles (A2) help or hurt on this hardware?
3. Moonshine Base vs Parakeet: is the 640 MB and the RTF worth the WER delta?
4. Does Whisper Base.en beat Moonshine Base on accuracy? At what RTF cost?
5. How far does WER spread across speakers with different accents on the same
   passage — and does the ranking of models change between them?
6. What thread count is the actual knee for each model on this phone?
7. Does RTF degrade over 45 minutes, and at what minute does throttling start?
8. What is the INT8 accuracy cost versus FP32 on Moonshine Base?

Each of these is now answerable in the app without a code change. That was the
point of this round.
