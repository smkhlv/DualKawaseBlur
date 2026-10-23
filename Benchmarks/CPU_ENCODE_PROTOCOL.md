# CPU encode blocks v1 — prospective protocol (DRAFT)

Status: **final, ready to freeze** (open choices confirmed 2026-10-22). Prepared 2026-10-21 for Suretare-15ef.5 (Task 5 of
`docs/superpowers/plans/2026-10-21-blur-cpu-encode.md`), in prep issue Suretare-15ef.6.
No device run has happened under this protocol, so no result exists yet.

Template: `RESUMABLE_PAIRS_PROTOCOL.md` and the 2026-10-10 eight-pair confirmation
(read-only worktree `.worktrees/dual-kawase-matched-quality`, `Benchmarks/Results/2026-10-10-resumable-confirmation/`).
This is a **new series**. It neither amends that series nor pools data with it.

**Freezing.** `run_cpu_encode.py freeze` records the SHA-256 of this file and of both host tools in
the journal's first entry. Every later command refuses to run if either hash has changed. Any
edit after freeze needs a new series root, never an amendment of a consumed journal. Review
the open choices (§9) **before** freezing.

## 1. Questions and pre-declared screens

All runs are on the physical iPhone 16 (A18), at 1179×2556 BGRA8 and sigma 92.087890625, over
the eight changing prerecorded Sphere inputs.

| # | Question | Endpoint | Pass screen (fixed now) |
|---|---|---|---|
| Q1 | Did Task 1 unload the main thread? | Production-app main-thread time, `main` vs `feat/blur-cpu-encode` | See `MAIN_THREAD_ENCODE_PROCEDURE.md`. This is a separate run, not part of this series |
| Q2a | Does S reach CPU parity with MPS-L? | Paired CPU encode p95 reduction `100×(L−S)/L` | **Median ≥ 0 and lower 95% bootstrap bound > 0** (S CPU reliably below MPS-L CPU; user decision 2026-10-22, before freeze) |
| Q2b | Does S keep O's GPU win? | Paired GPU p95 regression `100×(S−O)/O` | **Median ≤ 3%** |
| Q3 | Does S4 beat Apple on CPU? | Paired CPU encode p95 reduction `100×(L−S4)/L` | **Median > 0, lower 95% bootstrap bound > 0, and ≥ 7/8 favourable blocks** |

A pair value is computed inside one block, from the two legs being compared. "Favourable"
means a reduction > 0. For Q2b it means a regression ≤ 3%.

Q2b is a point screen on the median. Q2a gates on the median **and** the lower bootstrap bound
(stricter than the plan's table, chosen by the user before freeze). Their favourable counts, and
Q2b's interval, are reported but not gated. Every other comparison
`analyze` prints is descriptive only:
- O vs L GPU, which replicates 2026-10-10;
- O vs L CPU;
- S vs O CPU;
- S4 vs S CPU;
- S4 vs O GPU;
- S4 vs L submit (`S4_vs_L_submit`), which only qualifies Q3 as below.

**Interpretation rule for Q3 (pre-declared).** Metal 4 can move CPU work out of the encoder
call into `beginCommandBuffer`, `endCommandBuffer` and `commit`. Every leg therefore also
records a descriptive *submit* interval: buffer creation or allocator reset and begin, through
encode and end, to commit. Its paired comparison `S4_vs_L_submit` is the per-block submit p95
reduction `100×(L−S4)/L`, computed inside each block like every other pair value.

"S4's submit is below L's" means **the paired median of `S4_vs_L_submit` is > 0**. It is the
same paired estimate the screens use. The marginal medians of per-process p95 (§8) are
descriptive and never decide it. `analyze` writes the label `S4_q3_label`:
- `cpu_win`: Q3 passes and the paired median submit reduction is > 0;
- `encode_call_win_only`: Q3 passes but that median is ≤ 0. This is reported as an
  "encode-call win only", never as a CPU win;
- `fail`: Q3 fails;
- `not_run`: the three-arm fallback (§3.5).

Production adoption of O, S or S4 is a separate decision; nothing here promotes anything.

## 2. Arms and fixed workload

| Arm | Path | Output (private, full size) |
|---|---|---|
| O | `RedistributedAllRenderBlurEncoder`: all-render, redistributed, moment-matched 4/4/1 | `[.shaderRead, .renderTarget]` = usage 5 |
| S | `SplitRoleBlurEncoder`: 3 render passes + 1 compute encoder | usage 5 |
| S4 | `Metal4SplitRoleBlurEncoder` (Task 4): MTL4 queue + allocator, residency set built once | usage 5 |
| L | `MPSImageGaussianBlur(sigma: 92.087890625)`, `.allowReducedPrecision`, reused kernel, `.clamp` | `[.shaderRead, .shaderWrite]` = usage 3 |

Arm L uses exactly the MPS configuration that the 2026-10-10 pilots selected.

- Common settings: 5 levels, offset 5, `.bgra8Unorm`. Sources are private `shaderRead` textures,
  uploaded before timing.
- Inputs: the eight Sphere frames, indices 0,3,…,21 of the original capture. Each process walks
  them in the fixed order `index % 8` from zero. This is changing prerecorded content, not live
  animation.
- The corpus is the qualified 2026-10-10 corpus (source manifest SHA
  `693cfeb2…10bd`). The Sphere and diagnostic files are committed raw-deflate in
  `Examples/DualKawaseBlurDemo/DualKawaseBlurDemo/Resources/CPUEncodeCorpus/` and bundled into
  the app. The two photo fixtures (5.3 MB) are not committed. They stay at
  `.worktrees/dual-kawase-matched-quality/DualKawaseBlur/Benchmarks/Results/2026-10-10-resumable-preparation/corpus/`
  and are staged by SHA with `stage-photos`. The app verifies every input's SHA-256 after
  decompression.
- **CPU encode endpoint:** host time around the encoder call only, `encode(source:destination:into:)`.
  These are excluded symmetrically for every arm:
  - command-buffer creation, or MTL4 allocator reset and begin;
  - end, commit and drain;
  - upload and readback.
- **GPU endpoint:**
  - classic arms: `MTLCommandBuffer.gpuEndTime − gpuStartTime`;
  - S4: `MTL4CommitFeedback.GPUEndTime − GPUStartTime`.

  The mechanisms differ, so S4-vs-O GPU stays descriptive.
- **Per-process statistic:** nearest-rank p95 of the 3000 measured rows, at sorted index
  `ceil(0.95×3000)−1 = 2849`.

## 3. Qualification (once, before freeze; not timed)

1. Build the demo app, signed, in **Release**:
   - Metal API validation and GPU frame capture off;
   - `SWIFT_ACTIVE_COMPILATION_CONDITIONS` including `CPU_ENCODE_S4`.

   Then `install` it. That records the executable and metallib SHA-256 that `freeze` later requires.

   **Build identity.** Every process hashes its own executable (`Bundle.main.executableURL`) and
   `DualKawaseBlur_DualKawaseBlur.bundle/default.metallib`, and reports `debugBuild` (`#if DEBUG`).
   The qualification report and every leg must carry exactly the frozen
   `appExecutableSHA256` / `metallibSHA256` and `debugBuild: false`. Anything else is a fatal
   `identity` failure (`cpu_encode._build`). If the hashes the app reports differ from the
   built bundle's, `freeze` refuses the qualification, before any series exists.
2. Run `stage-photos`, then `qualify`. One process runs all 22 fixtures through every arm from the
   same source texture:
   - the 8 Sphere frames;
   - the 2 photos;
   - the 6 diagnostic fixtures (gradient, coarse checker, fine detail, edge-x, edge-y, alpha border);
   - the 6 generated edge-phase fixtures.
3. **Gate:** on every fixture, max per-channel |S − O| ≤ 1/255 and |S4 − O| ≤ 1/255, alpha
   included. This keeps the existing human visual acceptance of O valid for S and S4, so no
   new visual review is needed.

   L is not gated: it is the configuration already qualified on 2026-10-10. The O and L Sphere
   output hashes are compared with the 2026-10-10 receipt for information only. `freeze` does the
   comparison:
   - it reads `expectedOutputSHA256.O` and `expectedOutputSHA256.M` (M is that series' name for L)
     of `.worktrees/dual-kawase-matched-quality/DualKawaseBlur/Benchmarks/Results/2026-10-10-resumable-confirmation/qualification.json`,
     or the file passed as `--reference-qualification`;
   - it records the per-arm matching count and the mismatched Sphere names, plus the receipt's
     SHA-256, as `referenceComparison` in the series, and prints them.

   A mismatch, or a missing receipt (`available: false`), is disclosed, not a stop, because iOS
   and shader-compiler changes can alter bits.
4. The qualification receipt also freezes each arm's 8 Sphere output hashes. Every timing leg
   reproduces them before and after its timed loop. A mismatch is a fatal quality failure.
5. If S fails the gate, nothing is timed. If S4 cannot be built, is unsupported, or fails the
   gate, the **declared fallback** applies: a three-arm series (O, S, L), `freeze --three-arm-fallback`,
   with Q3 reported as *not run*. No other arm set is allowed.

   A `CPU_ENCODE_S4` build always qualifies S4. If S4 is unsupported at run time (no Metal 4
   family, or an OS below 26), the whole qualification fails. A 4-arm receipt also cannot freeze
   `--three-arm-fallback`. The fallback therefore needs:
   - a new Release build **without** `CPU_ENCODE_S4`;
   - its own `install`, which records its new hashes;
   - a new `qualify`, whose report has arms O, S, L;
   - then `freeze --three-arm-fallback`, naming that report.
6. **Timing smoke (not timed, never analyzed).** After the fixtures, the same process runs the
   timing route once, so it is exercised before any series exists:
   - it settles once with the §5.1 cooling procedure (same 20 s, 0.5 s poll, 300 s cap);
   - then, for every arm, it runs 48 rows over the eight Sphere sources (`index % 8`). It uses
     the timed legs' own row loop: environment checks before and after every row, one drained
     command buffer each, and the stop on the first violation or bad timestamp.

   The host runs these rows through the same row audit as a timed leg (`cpu_encode._rows`), and
   the cooling record through the same cooling audit. Any failure there fails the qualification.
   The smoke rows are excluded from every analysis and never pooled.

   `qualify` keeps the devicectl exit code beside the report (`launch-result.json`, with the
   report's SHA-256). `freeze` accepts only a report whose launch exited 0 and whose smoke passed.
   The route thus runs S4's `MTL4CommitFeedback` clock domain, the cooling path and the
   exit-code propagation before freeze.

All qualification attempts are retained. `freeze` names exactly one passing report.

## 4. Design: balanced blocks of fresh processes

The series has 8 blocks. Each block has one fresh process per arm, in this order:

| Block | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| Order | O S L S4 | S S4 O L | S4 L S O | L O S4 S | L O S4 S | S4 L S O | S S4 O L | O S L S4 |

Blocks 1–4 are a Williams square, and blocks 5–8 mirror them (ABBA), so linear drift over the
series cancels. Properties, which the tests check:
- every arm holds every position twice;
- every arm precedes every other arm in exactly 4 of 8 blocks;
- every arm immediately follows every other arm exactly twice.

The independent units are the 8 blocks, not the 24 000 rows per arm.

The fallback uses all six orders of (O, S, L) once, giving 6 blocks with the same balance properties.

One host invocation (`run-block`) runs one block. The user may cool the phone or pause between
invocations, and completed blocks survive.

## 5. Per-leg procedure (native route `--cpu-encode-benchmark`)

1. **Settling:** before every leg, a continuous 20 s of nominal thermal state, foreground and
   Low Power off, polled every 0.5 s, with a 300 s maximum. No blur or upload work runs
   during settling. The devicectl launch timeout is 600 s, and the host waits 660 s, so the
   300 s cap plus the leg's work fits inside it.
2. Prepare the textures, the arm and the eight sources. Then run the output guard: 8 blurs,
   whose hashes must match the receipt.
3. Run 1000 warmup + 3000 measured blurs, one drained command buffer each. Thermal, foreground
   and Low Power are checked before **and** after every row. Any violation stops the whole leg;
   individual rows are never removed. Any non-finite or misordered timestamp stops the leg.
   The app names the first failed condition in `failureReason`, and the host maps it
   faithfully: `background` → background, `thermal` (a rise during the leg) and
   `thermalDeadline` (the settling cap) → thermal, `lowPower` → lowPower, `timestamp` →
   timestamps. Anything else is contract.
4. Run the output guard again, then write `report.json`, print `CPU_ENCODE_REPORT <folder>` and exit.

The host checks every row again during the audit (`cpu_encode.audit_leg`). Partial legs are
never filtered into usable data.

## 6. Conditions (recorded, not sensor-measured)

Hold these constant for the whole series:
- the same Mac over the CoreDevice **local-network (Wi‑Fi) connection**, throughout. The USB cable
  failed on 2026-10-22, before freeze, and the user chose to measure over Wi‑Fi. All timing is
  on-device, so the transport only launches processes and copies reports; transport errors are
  retryable `connection`/`export`/`timeout` failures (§7). This differs from 2026-10-10 (wired,
  charging), which weakens the O-vs-L replication comparison but not the within-series pairs;
- device unlocked and the app in the foreground;
- brightness about 50%, auto-brightness off, Low Power off;
- the same charging policy (on 2026-10-22: battery, not charging, because no cable is connected).

The user confirms them in their own words in `conditions.json`, which `freeze` hashes.
Brightness, battery level and charge current are human-attested, not measured.

## 7. Failure, retry and exclusion policy (fixed before results)

- Each attempt is journalled (`begin`) **before** any device contact, so a preflight failure is
  still an auditable, excluded attempt. Each attempt has its own immutable folder.
- **Retryable:**
  - environment: thermal, locked, background, lowPower, preflight (for example the demo app was
    already running — the tool never terminates it; the user closes it);
  - transport: connection, export, timeout;
  - host: interrupted (host crash, recorded with `recover`).

  At most **one** retry of the **whole block**, in the same order. It needs new explicit user
  authorization, passed as `--authorize-retry "<the user's words>"`. Nothing retries automatically.
- Both attempts are kept, and a failed attempt is excluded entirely. A leg is never carried
  into another attempt.
- A second failure of the same block stops the series as **incomplete**. Completed blocks are
  then reported descriptively, with no screen and no confirmatory CI.
- **Fatal** (stops the series at once, with no retry under this identity): quality (output
  guard), provenance, identity (series, device, OS, build: executable and metallib SHA-256 and
  a Release build), contract, timestamps.
- **No exclusion for speed.** No optional stopping, no restarting until a preferred result, no
  pooling of qualification, pilot or 2026-10-10 data.

## 8. Analysis (only after every block is complete)

`run_cpu_encode.py analyze` computes the following for each comparison:
- the per-block reduction or regression;
- the median;
- the favourable count;
- a paired-median percentile bootstrap: 10 000 resamples, a fresh `random.Random(443)` per
  comparison, bounds at sorted indices 249 and 9749, the same method as 2026-10-10;
- position medians (candidate first vs baseline first).

A unit test reproduces the 2026-10-10 interval bit for bit.

**Never summed or combined:**
- CPU p95 + GPU p95;
- submit + GPU;
- p95s across arms or processes.

Every blur is one drained command buffer (the drained single-buffer regime). Nothing in this
series is end-to-end, pipelined, frame-latency, presentation or energy evidence. Marginal
medians of per-process p95 are descriptive and are not the paired estimate.

The scope is one A18 iPhone 16, this sigma, this corpus and n = 8 blocks. Claims beyond that
need a new prospective series.

## 9. Open choices to confirm before freeze

- The descriptive submit interval and the Q3 interpretation rule (§1).
- The 48-row timing smoke inside qualification (§3.6), chosen over a separate throwaway
  smoke leg per arm.
- The three-arm fallback design (§3.5, §4).
- Q2a's positive lower bound: **decided 2026-10-22 by the user — required** (§1).

The user accepted the other three choices as drafted on 2026-10-22.

## 10. Runbook (user present; placeholders in `<>`)

```bash
# Build (from DualKawaseBlur/Examples/DualKawaseBlurDemo), signed Release with S4 enabled:
xcodebuild -project DualKawaseBlurDemo.xcodeproj -scheme DualKawaseBlurDemo -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath <dd> -allowProvisioningUpdates \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CPU_ENCODE_S4' build
T=DualKawaseBlur/Benchmarks/CPUEncode/run_cpu_encode.py
R=DualKawaseBlur/Benchmarks/Results/<date>-cpu-encode
APP=<dd>/Build/Products/Release-iphoneos/DualKawaseBlurDemo.app
python3 -I $T install --root $R --device <udid> --app $APP
python3 -I $T stage-photos --device <udid>
python3 -I $T qualify --root $R --device <udid>
python3 -I $T freeze --root $R --device <udid> --app $APP \
  --qualification $R/qualification/<uuid>/report.json --conditions <conditions.json>
# freeze prints seriesSHA256 and referenceComparison (O/L vs 2026-10-10, informational)
python3 -I $T run-block --root $R      # repeat; one block per invocation
python3 -I $T status --root $R
python3 -I $T analyze --root $R        # only after all blocks
```

`conditions.json` has exactly these keys: `userQuote`, `brightnessApproxPercent`,
`autoBrightness`, `lowPower`, `deviceConnection`, `chargingPolicy`, `foregroundMaintained`,
`settingsHeldConstant`.

Commit the series directory as evidence when it ends, whether complete or not.
