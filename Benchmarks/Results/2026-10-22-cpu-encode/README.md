# CPU encode blocks v1 — complete series, 2026-10-22

Protocol: `DualKawaseBlur/Benchmarks/CPU_ENCODE_PROTOCOL.md`. It was frozen before any timed leg
(`seriesSHA256 e4904a36…abf7`). The branch was `feat/blur-cpu-encode` @ 60e61288, with a Release
build that included `CPU_ENCODE_S4`.

## Setup and conditions

- **Device:** iPhone 16 (A18), iOS 27.0.1, at 1179×2556 BGRA8 and sigma 92.087890625, over the eight
  changing prerecorded Sphere inputs.
- **Connection:** CoreDevice over **Wi‑Fi**. The USB cable failed before freeze.
- **Power:** battery, not charging.
- **Display and power settings:** brightness ~50%, auto-brightness off, Low Power off. The user
  attested these in `conditions.json`.
- **Run:** 8 balanced blocks (a Williams square plus its mirror), each with one fresh process per
  arm: 1000 warmup + 3000 measured blurs, one drained command buffer each.
- **Attempts:** all 8 blocks completed on attempt 1. There were 0 failures, 0 retries and 0
  exclusions.

## Quality

The qualification gate passed:
- S and S4 are within 1/255 of O on all 22 fixtures, photos included;
- the 48-row timing smoke per arm passed, and the launch exited 0.

The O and MPS-L Sphere outputs match the 2026-10-10 receipt in **8/8** cases for each arm.

## Pre-declared screens

| # | Screen | Result | Pass? |
|---|---|---|---|
| Q2a | S CPU vs MPS-L: median ≥ 0 **and** lower 95% bound > 0 | median **9.84%** lower, CI [5.38, 11.67]%, 7/8 | ✅ |
| Q2b | S GPU regression vs O ≤ 3% | median **−0.67%** (S slightly faster than O), CI [−0.94, −0.57]%, 8/8 | ✅ |
| Q3 | S4 CPU vs MPS-L: median > 0, lower bound > 0, ≥ 7/8 | median **32.19%** lower, CI [31.83, 33.36]%, 8/8 | ✅ |
| Q3 label | paired submit S4 vs L | median 23.21% lower, CI [22.86, 25.53]%, 8/8 → **`cpu_win`** | — |

## Descriptive comparisons (paired medians; not gated)

- O vs L GPU: 14.37% lower, CI [12.62, 16.17]%, 8/8. This replicates 2026-10-10 (14.28%).
- O vs L CPU: O 96.95% **higher**, 0/8 favourable. This replicates the known ~2× CPU cost of O.
- S vs O CPU: 54.40% lower.
- S4 vs S CPU: 24.74% lower.
- S4 vs O GPU: 0.81% lower. The timing mechanisms differ, so this is descriptive only.

## Marginal medians of per-process p95 (descriptive; not the paired estimate)

| Arm | CPU encode p95, ms | Submit p95, ms | GPU p95, ms |
|---|---:|---:|---:|
| O (all-render 4/4/1) | 0.2862 | 0.3075 | 1.2570 |
| S (3 render + 1 compute) | 0.1317 | 0.1533 | 1.2482 |
| S4 (Metal 4 split) | 0.0984 | 0.1265 | 1.2469 |
| L (MPS Gaussian, reduced precision) | 0.1453 | 0.1652 | 1.4681 |

CPU and GPU percentiles are never summed.

## Scope

- One A18 iPhone 16, this sigma, this corpus, n = 8 blocks.
- Drained single-buffer regime: not end-to-end, pipelined, presentation or energy evidence.
- Wi‑Fi and battery differ from the 2026-10-10 conditions (wired, charging). This weakens only
  the cross-series O-vs-L replication; the within-series pairs are unaffected.
- **Not covered here:**
  - S4 production adoption, which stays gated on Suretare-15ef.7 (the cross-buffer WAR check on
    the A18);
  - Q1, the main-thread effect of moving encode off the main thread. That is a separate run per
    `MAIN_THREAD_ENCODE_PROCEDURE.md`.

Raw data:
- `journal.jsonl`, hash-chained;
- `attempts/bNN-a01/<arm>/report.json`, all rows;
- `qualification/`;
- `analysis.json`.

## Raw-data archive

Kept out of git as loose files:
- the 32 per-leg `attempts/bNN-a01/<arm>/report.json` files (all rows, ~84 MB);
- the preflight device snapshots `processes.*` (device process lists) and `details.*` (device
  details, including the serial number and ECID).

All 164 files are packed in `raw-data.tar.xz` (6.0 MB, SHA-256 `57e0d3fe4b687774a002550ee27293c1e7c23bfcedb293ae26974df74fff5601`), with paths relative to this
directory. `raw-data.sha256` lists each file's SHA-256; an extract-and-verify pass returned 164/164 OK.
`raw-files.txt` is the archive's file list.

To restore: `tar -xJf raw-data.tar.xz && shasum -a 256 -c raw-data.sha256`

The archive contains device identifiers and process lists from the user's phone. Review it before
pushing anywhere public. The device UDID also appears in the committed journal and install record.
