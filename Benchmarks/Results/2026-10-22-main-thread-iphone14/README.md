# Q1 — main-thread profile in the production app, 2026-10-22, iPhone 14

Procedure: `DualKawaseBlur/Benchmarks/MAIN_THREAD_ENCODE_PROCEDURE.md`, using the E4 thresholds the
user confirmed before the first recording: feat median hitch-time ratio ≤ main + 0.5 ms/s, and no
feat hitch longer than main's longest + 1 frame.

## Builds

| | Commit | What the background does | Executable SHA-256 |
|---|---|---|---|
| before | `c214da81` (main before any blur merge) | original renderer, encoded synchronously on the main thread | `6a05102b…` |
| after | `bad70bb9` (main right after the blur-S merge) | off-main encode queue + S + composite from half-res level 0 | `2da2c2e7…` |

Both builds are Release with `CODE_SIGN_ENTITLEMENTS=SuretareiOS/SuretareiOS.Debug.entitlements`,
because the free Personal Team cannot sign Associated Domains. `main` had already moved on to
`627defa8`; `bad70bb9` keeps the only difference between the builds equal to the blur work.

## Setup

- **Device:** iPhone 14 (A15), iOS 27.0.1, wired, charging, signed in.
- **Screen:** the root screen with the animated Sphere background.
- **Order:** before, after, after, before (ABBA). Each build was installed fresh, launched by hand
  and settled for ≥ 70 s, then recorded for 30 s with
  `xctrace record --template 'Time Profiler' --instrument 'Points of Interest' --instrument 'Hitches'`.
- **Attaching by name failed:** xctrace could not find the process by its executable name. Each
  recording attached instead by PID or by display name `Suretare`, retrying until the attach
  succeeded. See `attempts.log`.
  - Recording 3's first attempt never attached, and a "before" build was installed by mistake
    before the failure was noticed.
  - The "after" build was then reinstalled, and recording 3 was redone from a fresh launch.
  - No values were looked at before any retry.
- **Trace lengths:** all four traces are 30.9–31.0 s and ended on the time limit.

## Results

Main-thread sampled weight, in ms per second of trace. Computed by `analyze_q1.py`; raw lines in
`q1-results.jsonl`.

| Endpoint | before #1 | after #2 | after #3 | before #4 | Median before → after |
|---|---:|---:|---:|---:|---|
| **E1** blur encode on main (`DualKawaseBlurRenderer.encode` / worker encode) | 7.06 | **0.00** | **0.00** | 13.52 | 10.29 → **0** |
| E1s scheduling (`renderLatest` / `requestRender`) | 20.16* | 0.52 | 0.65 | 26.84* | — |
| E1p Sphere producer (`SphereFrameProducer.render`) | 17.16 | 16.50 | 15.70 | 16.85 | 17.00 → 16.10 |
| E2 `AnimatedBackgroundSession.tick` inclusive | 26.19 | 17.27 | 16.38 | 33.50 | 29.84 → 16.82 |
| Main thread, total | 51.66 | 40.55 | 39.81 | 57.82 | 54.74 → 40.18 |

\* On "before", `renderLatest()` contains the whole synchronous encode, so E1s is not comparable
across builds. That is why the procedure keeps it descriptive.

**E3, encode placement (after only):**
- recording #2: 921 `blur.encode` intervals, 29.7/s, median 0.284 ms, p95 0.333 ms;
- recording #3: 916 intervals, 29.7/s, median 0.273 ms, p95 0.312 ms;
- every interval ran on a worker thread; none on the main thread.

**E4, frame cadence:** the Hitches instrument recorded **0 hitches** in all four traces.

## Screens

- **E1: PASS.** 0 main-thread samples with blur encode in both "after" recordings. "Before" spent
  7–14 ms/s on it.
- **E4: PASS.** The hitch-time ratio is 0 = 0 and there are no hitches at all, so there is no
  regression.

Scope: one device, this screen, idle animation, sampled estimates. This is not energy or
presentation-latency evidence, and it is never combined with the microbenchmark series.

## Visual acceptance (user, on device)

**Accepted.** The user watched the background on the iPhone 14 in both builds: "before" in
recordings 1 and 4, "after" in 2 and 3. Verdict, verbatim: «разницы не заметил» (2026-10-22). It
covers the production change as a whole: the moment-matched S approximation, off-main encode and
the half-res publish, against the original faithful renderer.

## Raw data

The four `.trace` bundles (~92 MB) are packed in `traces.tar.xz`:
- 9.1 MB, SHA-256 `cbae9cd574139299bc135d93fa6a164b58e5110b4346d458ef0625a99589a12d`;
- the file list is in `raw-files.txt`.

To restore: `tar -xJf traces.tar.xz`.
