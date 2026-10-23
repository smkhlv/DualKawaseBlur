# Path-level blocks v2 — prospective protocol (DRAFT)

Status: **DRAFT, not frozen.** Prepared 2026-10-22 for Suretare-u2z3.3 (Task 3 of
`docs/superpowers/plans/2026-10-22-blur-s-production.md`). The open choices (§9) are not confirmed
yet. No device run has happened under this protocol, so no result exists yet; Task 4 runs it.

Template: `CPU_ENCODE_PROTOCOL.md` (`cpu-encode-blocks-v1`) and its complete series
`Results/2026-10-22-cpu-encode/`. This is a **new series** (`path-level-v2`). It neither amends v1
nor pools data with it.

**Why a v2.** Task 2 (Suretare-u2z3.2) made the presenters composite straight from S's half-resolution
level 0, with no full-size final pass. The shipped blur is therefore no longer a full-size filter output,
and v1's filter-level comparison against MPS no longer measures what ships. v2 compares whole
paths: the blur **plus** the presentation composite, in one command buffer.

**Freezing.** `run_cpu_encode.py freeze --protocol path-level-v2` records the SHA-256 of this file and of
both host tools in the journal's first entry. Every later command reads the series' `protocolID`,
hashes this file (not the v1 document) and both tools, and refuses to run if any hash has changed. Any
edit after freeze needs a new series root, never an amendment of a consumed journal. Review the open
choices (§9) **before** freezing.

**v1 evidence after the v2 tool edit.** The host tools are one tool for both protocols: v2 extends
`cpu_encode.py` and `run_cpu_encode.py` in place, and every v1 constant and code path keeps its
behaviour. The v1 journal froze the v1 tool hashes, which the working tree no longer matches, so
`verify_frozen` refuses the v1 root at the current tip. That is expected. **The v1 series re-verifies at
its recorded `gitRevision` 60e61288** (`60e6128805193a505bb4d1e606a54cc73e36fc64`). The journal's freeze
entry froze exactly these SHA-256 values, which are the bytes at that revision:
- `cpu_encode.py`: `3b9d4b4a0c7e9640d2776b3444f7b2aac40c2e0610c66fe3fc73c5e94c23154f`;
- `run_cpu_encode.py`: `08a6801636af2581b0cf9b72434fe460bd42563f97886de4b9cdd9a8ecbb4248`;
- `CPU_ENCODE_PROTOCOL.md`: `2298119065608a9d0b45f578f95a94de8ca48855825603b5b728a8b87f55a753`.

`status` never calls `verify_frozen`, and `analyze` refuses because `analysis.json` exists, so neither
re-verifies. This recipe does, and it is read-only: it extracts the 60e61288 tools outside the repository
and only reads the committed journal (from the repository root):

```bash
V=$(mktemp -d); git archive 60e6128805193a505bb4d1e606a54cc73e36fc64 DualKawaseBlur/Benchmarks | tar -x -C "$V"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import cpu_encode as c, run_cpu_encode as d
s = c.Journal(sys.argv[2]).state(); d.verify_frozen(s); print("verified", s["stopped"], len(s["completed"]))' \
  "$V/DualKawaseBlur/Benchmarks/CPUEncode" "$PWD/DualKawaseBlur/Benchmarks/Results/2026-10-22-cpu-encode"
# prints: verified complete 8   (verify_frozen raises if any frozen hash differs)
```

At the tip, the host test
`test_v1_series_evidence_reproduces` (read-only) shows that the edited core still reproduces the v1
evidence exactly:
- it replays `Results/2026-10-22-cpu-encode/journal.jsonl` through `Journal.state()`: the chain is intact,
  the series stopped `complete`, with 8 blocks;
- `analyze` of those blocks equals the committed `analysis.json`, minus its `excludedAttempts` key;
- re-auditing the committed qualification report against the frozen build returns exactly the series'
  frozen `qualification` receipt.

`CPU_ENCODE_PROTOCOL.md` and everything in `Results/` are unchanged.

## 1. Questions and pre-declared screens

All runs are on one physical device, fixed at freeze and audited on every leg (`hardware`/`os`/`gpu`).
This series runs on **iPhone 14 (iPhone14,7, A15), iOS 27.0.1, wired**. The user chose it on 2026-10-22,
before freeze, because the iPhone 16's cable had failed. The workload is offscreen and device-independent,
at 1179×2556 BGRA8 and sigma 92.087890625, over
the eight changing prerecorded Sphere inputs. One row is one drained command buffer holding the arm's
blur and the opaque composite.

| # | Question | Endpoint | Pass screen (fixed now) |
|---|---|---|---|
| P1 | Does the production path SH cost less GPU than the MPS path LC? | Paired GPU p95 reduction `100×(LC−SH)/LC` | **Median > 0, lower 95% bootstrap bound > 0, and ≥ 7/8 favourable blocks** |
| P2 | Does SH cost less CPU encode than LC? | Paired CPU encode p95 reduction `100×(LC−SH)/LC` | **Median > 0, lower 95% bootstrap bound > 0, and ≥ 7/8 favourable blocks** |
| P3 | How much GPU does the half-resolution publish save over S with its full-size final pass? | Paired GPU p95 reduction `100×(SC−SH)/SC` | **None: descriptive only, never gated** |

A pair value is computed inside one block, from the two legs being compared. "Favourable" means
a reduction > 0. `analyze` writes the screens `P1_SH_gpu_below_LC` and `P2_SH_cpu_below_LC`, and lists
every other comparison in `descriptiveOnly`:
- `SH_vs_SC_gpu` (P3);
- `SC_vs_LC_gpu` and `SC_vs_LC_cpu`, the v1-style S-vs-MPS comparison, now with the composite;
- `SH_vs_SC_cpu`;
- `SH_vs_LC_submit`, the descriptive submit interval (buffer creation through commit).

There is no S4 arm and no Q3 label: Metal 4 is not on the production path. Production adoption is a
separate decision; nothing here promotes anything.

## 2. Arms and fixed workload

| Arm | Blur | Blur output (private) | Composite source |
|---|---|---|---|
| LC | `MPSImageGaussianBlur(sigma: 92.087890625)`, `.allowReducedPrecision`, reused kernel, `.clamp` (v1's L exactly) | full size, `[.shaderRead, .shaderWrite]` = usage 3 | the LC output, 1179×2556 |
| SC | `SplitRoleBlurEncoder.encode` (v1's S, with its full-size final pass) | full size, `[.shaderRead, .renderTarget]` = usage 5 | the SC output, 1179×2556 |
| SH | `SplitRoleBlurEncoder.encodeThroughLevelZero` (the production blur since Task 2) | **none** | S's own half-size level 0, 589×1278 |

**Composite (every arm, after its blur, in the same buffer).** `BenchmarkOpaqueCompositeEncoder`
(`@_spi(Benchmark)`) owns a `DualKawaseBlurRenderer` and calls the presenters' own
`encodeOpaqueComposite` with the `.unit` mapping and the fixed opaque base color
**(0.25, 0.5, 0.75, 1)** (RGBA; exact in Float and JSON). Its target is a private `.bgra8Unorm`
1179×2556 texture of usage `[.renderTarget]` = 4. A package test pins its bytes to a direct internal
`encodeOpaqueComposite(.unit)` call. The target is offscreen: there is no `CAMetalLayer`, no drawable
acquisition and no present.

Every report records, and the host audits against these constants:
- `compositeBaseColor` and `compositeMapping` (`"unit"`);
- per arm, `pathOutput`: the blur output's usage and storage (absent for SH), the composite source's
  size, and the composite target's usage and storage (`cpu_encode.path_output`).

- Common settings: 5 levels, offset 5, `.bgra8Unorm`. Sources are private `shaderRead` textures,
  uploaded before timing.
- Inputs: the eight Sphere frames, indices 0,3,…,21 of the original capture. Each process walks
  them in the fixed order `index % 8` from zero. This is changing prerecorded content, not live
  animation.
- The corpus is v1's: the qualified 2026-10-10 corpus (source manifest SHA `693cfeb2…10bd`),
  bundled raw-deflate in `Examples/DualKawaseBlurDemo/DualKawaseBlurDemo/Resources/CPUEncodeCorpus/`, with
  the two photo fixtures staged by SHA with `stage-photos`. The app verifies every input's SHA-256 after
  decompression.
- **CPU encode endpoint:** host time around the arm's encoder calls only: the blur encode **and** the
  composite encode (`encodeStart`…`encodeEnd`). These are excluded symmetrically for every arm:
  - command-buffer creation;
  - commit and drain;
  - upload and readback.
- **GPU endpoint:** `MTLCommandBuffer.gpuEndTime − gpuStartTime` of the one buffer that holds blur and
  composite. All three arms use the same classic queue and clock, so every GPU comparison is like for like.
- **Submit interval (descriptive):** buffer creation through commit, as in v1.
- **Per-process statistic:** nearest-rank p95 of the 3000 measured rows, at sorted index
  `ceil(0.95×3000)−1 = 2849`.

## 3. Qualification (once, before freeze; not timed)

1. Build the demo app, signed, in **Release**, with Metal API validation and GPU frame capture off.
   `CPU_ENCODE_S4` is not needed (S4 is not an arm). Then `install` it. That records the executable and
   metallib SHA-256 that `freeze` later requires. One binary serves both protocols, so `install` takes
   no protocol.

   **Build identity** is v1's: every process reports its own executable and
   `DualKawaseBlur_DualKawaseBlur.bundle/default.metallib` SHA-256 and `debugBuild`; the qualification
   report and every leg must carry exactly the frozen hashes and `debugBuild: false`. Anything else is a
   fatal `identity` failure.
2. Run `stage-photos`, then `qualify --protocol path-level-v2 --transport <wired|localNetwork>`. One
   process runs all 22 fixtures through every arm from the same source texture and reads back each
   arm's **composite target**:
   - the 8 Sphere frames;
   - the 2 photos;
   - the 6 diagnostic fixtures (gradient, coarse checker, fine detail, edge-x, edge-y, alpha border);
   - the 6 generated edge-phase fixtures.
3. **Gate:** on every fixture, max per-channel |SH − SC| ≤ 1/255 on the composite output, alpha
   included (`differenceVersusSC.SH`). SC's composite is the Task 1 production path (S's full-size
   output, then the composite); Task 2's package test bounds the two by 1/255 at this size. This keeps
   the human visual acceptance of that path valid for SH.

   LC is not gated: MPS Gaussian and Dual Kawase are different filters. Its difference from SC is
   recorded per fixture (`differenceVersusSC.LC`) and frozen in the receipt as `maxDifferenceVersusSC`,
   for information only. There is no reference comparison with 2026-10-10: composite hashes have no
   precedent, so a v2 series has no `referenceComparison`.
4. The qualification receipt also freezes each arm's 8 Sphere **composite** output hashes. Every timing
   leg reproduces them before and after its timed loop. A mismatch is a fatal quality failure.
5. If SH fails the gate, nothing is timed. There is no fallback arm set.
6. **Timing smoke (not timed, never analyzed)**, exactly as v1 §3.6: after the fixtures, the same
   process settles once with the §5.1 cooling procedure and runs 48 rows per arm over the eight Sphere
   sources through the timed legs' own row loop. The host runs these rows through the same row audit as a
   timed leg (`cpu_encode._rows`) and the cooling record through the same cooling audit; each arm's
   smoke entry also carries its `pathOutput`. Any failure there fails the qualification.

   `qualify` keeps the devicectl exit code beside the report in `launch-result.json`, with the report's
   SHA-256, the `protocolID` and the `transport`. `freeze` accepts only a report whose launch exited 0,
   whose smoke passed, and whose recorded transport equals the one `freeze` is given.

All qualification attempts are retained. `freeze` names exactly one passing report.

## 4. Design: balanced blocks of fresh processes

The series has 8 blocks. Each block has one fresh process per arm, in this order:

| Block | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| Order | LC SC SH | SH LC SC | SC SH LC | LC SH SC | SC LC SH | SH SC LC | SH LC SC | LC SC SH |

Blocks 1–6 are all six orders of three arms once. Within them every arm holds every position twice,
precedes every other arm in 3 of 6 blocks, and each of the six ordered pairs is an immediate follow in
exactly 2 of the 6 blocks. Blocks 7–8 repeat blocks 2 and 1, so the two duplicated orders sit symmetrically about the
series midpoint (1, 2 … 7, 8: the ends mirror, ABBA). Eight blocks cannot balance three positions
exactly (8 is not a multiple of 3); the properties of the full series, which the test
`test_path_level_orders_are_balanced` checks exactly, are:
- every arm holds every position 2 or 3 times:

  | Arm | Position 1 | Position 2 | Position 3 |
  |---|---|---|---|
  | LC | 3 | 3 | 2 |
  | SC | 2 | 3 | 3 |
  | SH | 3 | 2 | 3 |

- SH precedes LC in exactly 4 of 8 blocks and precedes SC in exactly 4 of 8, so both SH comparisons
  (P1–P3) are order-balanced; LC precedes SC in 5 of 8 (only the descriptive SC-vs-LC pair is off);
- immediate follows: LC→SC 4, SH→LC 3, SC→SH 3, SC→LC 2, LC→SH 2, SH→SC 2.

`analyze` also reports position medians (candidate first vs baseline first) for every comparison.
The independent units are the 8 blocks, not the 24 000 rows per arm.

One host invocation (`run-block`) runs one block. The user may cool the phone or pause between
invocations, and completed blocks survive.

## 5. Per-leg procedure (native route `--cpu-encode-benchmark --cpu-encode-protocol path-level-v2`)

1. **Settling:** before every leg, a continuous 20 s of nominal thermal state, foreground and
   Low Power off, polled every 0.5 s, with a 300 s maximum. No blur, composite or upload work runs
   during settling. The devicectl launch timeout is 600 s, and the host waits 660 s, so the
   300 s cap plus the leg's work fits inside it.
2. Prepare the textures, the arm's path (blur and composite) and the eight sources. Then run the output
   guard: 8 paths, whose composite hashes must match the receipt.
3. Run 1000 warmup + 3000 measured paths, one drained command buffer each (blur + composite). Thermal,
   foreground and Low Power are checked before **and** after every row. Any violation stops the whole
   leg; individual rows are never removed. Any non-finite or misordered timestamp stops the leg.
   The app names the first failed condition in `failureReason`, and the host maps it
   faithfully: `background` → background, `thermal` (a rise during the leg) and
   `thermalDeadline` (the settling cap) → thermal, `lowPower` → lowPower, `timestamp` →
   timestamps. Anything else is contract.
4. Run the output guard again, then write `report.json`, print `CPU_ENCODE_REPORT <folder>` and exit.

The host checks every row again during the audit (`cpu_encode.audit_path_leg`, which runs v1's leg
audit with the v2 contract). Partial legs are never filtered into usable data.

## 6. Conditions (recorded, not sensor-measured)

Hold these constant for the whole series:
- the same Mac over the **same CoreDevice transport throughout, fixed at freeze**. **Wired (USB) is
  preferred**; the user confirms the transport before freeze (§9). `qualify` and `freeze` take the
  required `--transport wired|localNetwork`. It is recorded in the qualification's `launch-result.json`
  and in the frozen series (`transport`); the two must agree, or `freeze` refuses. Every preflight
  (qualification and every leg) checks devicectl's `connectionProperties.transportType` against the
  series value; any other transport is a retryable `connection` failure (§7). All timing is on-device,
  so the transport only launches processes and copies reports. (v1 ran over `localNetwork` because the
  cable had failed; a series without `transport` is a v1 series.);
- device unlocked and the app in the foreground;
- brightness about 50%, auto-brightness off, Low Power off;
- the same charging policy throughout.

The user confirms them in their own words in `conditions.json`, which `freeze` hashes.
Brightness, battery level and charge current are human-attested, not measured.

## 7. Failure, retry and exclusion policy (fixed before results)

v1's policy, unchanged:
- Each attempt is journalled (`begin`) **before** any device contact, so a preflight failure is
  still an auditable, excluded attempt. Each attempt has its own immutable folder.
- **Retryable:**
  - environment: thermal, locked, background, lowPower, preflight (for example the demo app was
    already running — the tool never terminates it; the user closes it);
  - transport: connection (including a transport other than the series'), export, timeout;
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
  pooling of qualification, smoke, v1 or 2026-10-10 data.

## 8. Analysis (only after every block is complete)

`run_cpu_encode.py analyze` computes, for each comparison of §1, exactly as v1:
- the per-block reduction;
- the median;
- the favourable count;
- a paired-median percentile bootstrap: 10 000 resamples, a fresh `random.Random(443)` per
  comparison, bounds at sorted indices 249 and 9749;
- position medians (candidate first vs baseline first).

**Never summed or combined:**
- CPU p95 + GPU p95;
- submit + GPU;
- p95s across arms or processes.

Every row is one drained command buffer (the drained single-buffer regime) that ends in an offscreen
composite. Nothing in this series is end-to-end, pipelined, frame-latency, presentation (no drawable)
or energy evidence. Marginal medians of per-process p95 are descriptive and are not the paired estimate.

The scope is this one device (iPhone 14 / A15 for this series), this sigma, this corpus, this composite target and n = 8 blocks. Claims
beyond that need a new prospective series.

## 9. Open choices to confirm before freeze

- **The transport** (§6): wired preferred; `localNetwork` if no working cable. Recorded at freeze.
- **The base color** (0.25, 0.5, 0.75, 1): a fixed opaque color. The composite's *timing* does not depend
  on its value (production passes the presenter's resolved color), but its *output* does, and so does the
  margin of the SH vs SC ≤ 1/255 gate. The composite writes `rgb + base·(1 − a)`. SC samples its full-size
  output, which is already rounded to 8 bits (up to ½ LSB per channel, alpha included); SH samples the
  unrounded level-0 filter value. So before the final rounding the two differ by up to
  `½ + base·½` LSB per channel. A base channel near 1.0 brings that to 1 LSB and leaves no rounding margin.
  The drafted maximum channel, 0.75, keeps the worst-case pre-rounding error at 0.875 LSB, below 1 LSB.
- **The composite target** (§2): private, usage `[.renderTarget]` only, like a drawable's role but
  readable by blit for the output guard.
- **The descriptive set** (§1): `SH_vs_SC_gpu`, `SC_vs_LC_gpu`, `SC_vs_LC_cpu`, `SH_vs_SC_cpu`,
  `SH_vs_LC_submit`.
- **P3 descriptive only** (§1): the half-resolution saving is reported, never gated.
- **P1 and P2 use v1's strict Q3 screen** (median, lower bound and ≥ 7/8), for both GPU and CPU.
- The 48-row timing smoke inside qualification (§3.6), as in v1.

## 10. Runbook (user present; placeholders in `<>`)

```bash
# Build (from DualKawaseBlur/Examples/DualKawaseBlurDemo), signed Release:
xcodebuild -project DualKawaseBlurDemo.xcodeproj -scheme DualKawaseBlurDemo -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath <dd> -allowProvisioningUpdates build
T=DualKawaseBlur/Benchmarks/CPUEncode/run_cpu_encode.py
R=DualKawaseBlur/Benchmarks/Results/<date>-path-level
APP=<dd>/Build/Products/Release-iphoneos/DualKawaseBlurDemo.app
X=<wired|localNetwork>   # the transport confirmed in §9
# Before qualify, over the transport you will use: read what devicectl reports for it.
xcrun devicectl device info details --device <udid> --json-output <details.json>
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["connectionProperties"]["transportType"])' <details.json>
#   It must print exactly $X. Only "localNetwork" has been observed in this repo; the cable's string is
#   unverified. The tool fails safe (any other string is a retryable `connection` failure at preflight), but if
#   the cable reports another string than "wired", cpu_encode.PATH_TRANSPORTS needs a tool edit (and a re-run of
#   the host tests) BEFORE freeze, because freeze hashes the tools.
python3 -I $T install --root $R --device <udid> --app $APP
python3 -I $T stage-photos --device <udid>
python3 -I $T qualify --protocol path-level-v2 --transport $X --root $R --device <udid>
python3 -I $T freeze --protocol path-level-v2 --transport $X --root $R --device <udid> --app $APP \
  --qualification $R/qualification/<uuid>/report.json --conditions <conditions.json>
# freeze prints seriesSHA256, transport and maxDifferenceVersusSC (LC vs SC, informational)
python3 -I $T run-block --root $R      # repeat; one block per invocation; follows series.protocolID
python3 -I $T status --root $R
python3 -I $T analyze --root $R        # only after all blocks
```

`conditions.json` has exactly v1's keys: `userQuote`, `brightnessApproxPercent`, `autoBrightness`,
`lowPower`, `deviceConnection`, `chargingPolicy`, `foregroundMaintained`, `settingsHeldConstant`.

Commit the series directory as evidence when it ends, whether complete or not.
