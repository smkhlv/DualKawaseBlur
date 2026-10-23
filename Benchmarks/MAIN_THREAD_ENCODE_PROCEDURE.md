# Q1 — main-thread encode cost in the production app (procedure, DRAFT)

Task 5, question 1 of `docs/superpowers/plans/2026-10-21-blur-cpu-encode.md`: did Task 1 move the
blur encode off the main thread without hurting frame cadence? This is a production-app
profile. It is separate from the `CPU_ENCODE_PROTOCOL.md` series and is never pooled with it.
No result exists yet. Confirm the thresholds in §4 with the user **before** the first recording.

## 1. What differs between the builds

- **Before** — `main`: `SharedMetalBlurSession.renderLatest()` encodes the blur synchronously.
  The call chain runs on the main thread:
  `AnimatedBackgroundSession.tick(at:)` → `AnimatedBackgroundPipeline.renderLatest()` →
  `DualKawaseBlurRenderer` encode.
- **After** — `feat/blur-cpu-encode`: `renderLatest()` only schedules a job: it calls
  `SharedBlurEncodeWorker.requestRender()` (a mutex lock plus `queue.async`, a few µs), which still
  runs synchronously on main every tick. The encode itself, `SharedBlurEncodeWorker.encode(_:pinnedRevision:)`, runs on the serial queue `DualKawaseBlur.encode`
  (QoS user-interactive). Each encode is wrapped in an `OSSignposter` interval named
  **`blur.encode`**, with subsystem `DualKawaseBlur` and category Points of Interest.
  `main` has no such signpost.

The app consumes the package by local path, so build each variant from a checkout of that branch.

## 2. Builds and setup

1. Build both variants in **Release**, signed for the same device, from `SuretareiOS/`, with the
   recipe in `SuretareiOS/CLAUDE.md` and `-configuration Release -destination 'generic/platform=iOS'`.
   The bundle ID is `smkhlv.SuretareiOS` in both. Record each commit SHA and the app executable's SHA-256.
2. Use one physical iPhone 16 under the conditions of `CPU_ENCODE_PROTOCOL.md` §6:
   - wired, unlocked, foreground;
   - brightness about 50% manual, Low Power off;
   - nominal thermal state before each recording.
3. Use the same screen every time: the root screen with the animated Sphere background
   (`RootView`). Same account state, no interaction during recording.

## 3. Recording (balanced order, 4 recordings)

Use the order **main, feat, feat, main** (ABBA). Before each recording:
- install that build: `xcrun devicectl device install app --device <udid> <path>.app`;
- launch it by hand, open the root screen, and wait 10 s;
- let the phone settle for 60 s.

Then record 30 s:

```bash
xcrun xctrace record --device <udid> --template 'Time Profiler' \
  --instrument 'Points of Interest' --instrument 'Hitches' \
  --attach SuretareiOS --time-limit 30s --output <dir>/<n>-<main|feat>.trace
```

Keep every trace, including failed ones. A recording is retried, and the retry noted, only if
the app left the foreground or the thermal state was not nominal. Never retry because of a value.

## 4. Endpoints and pass screen (confirm thresholds before recording)

Read these in Instruments for the steady 30 s window, filtered to the main thread
(`com.apple.main-thread`), call tree not inverted.

| Endpoint | How | Screen |
|---|---|---|
| E1. Blur-encode main-thread time | Sampled weight of main-thread stacks that contain `SharedBlurEncodeWorker.encodeLatest()`, `SharedBlurEncodeWorker.encode(_:pinnedRevision:)`, or `DualKawaseBlurRenderer.encode(source:destination:workspace:configuration:into:)`, in ms per second. On `main` the synchronous encode lands under `DualKawaseBlurRenderer.encode`, so the comparison stays valid. Stacks under `SphereFrameProducer.render` are **excluded**, and so is scheduling (see below) | **feat: 0 such samples in both feat recordings**; main is reported for contrast |
| E1s. Blur scheduling main-thread time | Sampled weight of main-thread stacks under `SharedMetalBlurSession.renderLatest()` / `SharedBlurEncodeWorker.requestRender()`, in ms per second. On feat this is the mutex lock plus `queue.async`; on main it contains the whole synchronous encode, so it is not comparable with E1 | Descriptive only, **never gates** |
| E1p. Sphere producer main-thread time | Sampled weight of main-thread stacks under `SphereFrameProducer.render` (reached via `AnimatedBackgroundPipeline.renderSource`), in ms per second | Descriptive only, never screened |
| E2. `tick(at:)` inclusive main-thread time | Weight of `AnimatedBackgroundSession.tick(at:)`, in ms per second; per tick = ms/s ÷ tick rate. It includes E1p | Descriptive (before vs after) |
| E3. Encode placement (feat only) | Points of Interest: `blur.encode` count per second, duration median/p95, and its thread | Intervals on the `DualKawaseBlur.encode` queue thread, never on main |
| E4. Frame cadence | Hitches: hitch count and hitch-time ratio (ms/s) | **No regression:** feat median hitch-time ratio ≤ main median + 0.5 ms/s, and no feat hitch longer than the longest main hitch + 1 frame |

**Why E1 excludes scheduling.** On feat, `renderLatest()` → `worker.requestRender()` still runs on main
every tick. A "0 samples under `renderLatest()`" screen would therefore fail by construction. E1 counts
only the encode work named in the table; the scheduling cost is reported on its own line (E1s) and
never gates.

**Why E1 excludes the producer.** `tick(at:)` also calls `AnimatedBackgroundPipeline.renderSource`
→ `SphereFrameProducer.render`, which still encodes its own render pass on the main actor after
Task 1 (`SphereAnimation/Sources/SphereAnimation/SphereFrameProducer.swift`). That is the Sphere
source frame, not the blur. Counting every `renderCommandEncoder` under `tick(at:)` would therefore
fail feat by construction. E1 counts only stacks that contain one of the three encode symbols named in the table; in Instruments,
focus on each of those symbols in turn (Call Tree → Focus on Subtree) on the main thread and sum
their weights, counting a sample once if several of them are on its stack. Any
`renderCommandEncoder`/`computeCommandEncoder` sample counts toward E1 only when one of those
symbols is on its stack. The producer's time is E1p; the scheduling time is E1s.

Tick rate: the session caps rendering at 30 Hz. On feat, use the `blur.encode` count per second
as the measured rate. On main there is no signpost: report ms per second, and give ms per tick
only against the nominal 30 Hz, labelled as nominal.

## 5. Reporting

For each recording, report:
- the build, commit and order position;
- E1–E4 (E1 is the only gate besides E4), and E1p and E1s as separate descriptive lines;
- the trace file name.

Also report the medians per build. Time Profiler values are sampled estimates, not exact CPU
time, and no microbenchmark number from `CPU_ENCODE_PROTOCOL.md` is added to them. The scope
is this device and this screen, at idle animation. Nothing here measures energy or presentation
latency.
