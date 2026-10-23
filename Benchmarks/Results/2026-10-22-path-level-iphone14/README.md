# Path-level blocks v2 — complete series, 2026-10-22, iPhone 14

Protocol: `DualKawaseBlur/Benchmarks/PATH_LEVEL_PROTOCOL.md`. It was frozen before any timed leg:
- `seriesSHA256 c0bd50e4…2415`;
- branch `feat/blur-v2-series` @ 8d22dc5b;
- Release demo build.

## Setup and conditions

- **Device:** iPhone 14 (iPhone14,7, A15), iOS 27.0.1. It was chosen before freeze because the
  iPhone 16's cable had failed.
- **Transport:** wired USB, charging. Brightness ~50%; auto-brightness and Low Power were off.
  The user attested this in `conditions.json`.
- **Workload:**
  - 1179×2556 BGRA8, sigma 92.087890625, the eight prerecorded Sphere inputs;
  - each row is one drained command buffer: the arm's blur, then the presenters' opaque composite
    (`.unit`, base color 0.25/0.5/0.75) into an offscreen full-size render target.
- **Arms:**
  - LC = MPS-L + composite;
  - SC = S `encode` (full-size final pass) + composite;
  - SH = S `encodeThroughLevelZero` + composite from half-size level 0. This is the production
    path since Suretare-u2z3.2.
- **Block outcomes:** all 8 blocks are complete.
  - Blocks 5 and 7 each failed once, on attempt 1. The reason was `thermal`
    (`thermalDeadline` before the SH leg: no 20 s continuous nominal window within 300 s).
  - Each was retried once with the user's explicit authorization, which is recorded verbatim in
    the journal. Both attempt-1 folders are retained and excluded.
  - The host inserted 10–20 min cooling pauses between invocations. The protocol allows this,
    and it is arm-symmetric.

## Qualification

The first qualification attempt (`0c76a421…`) failed its timing smoke with `thermalDeadline`. It is
retained and was not used.

The second attempt (`65dee9aa…`) passed:
- SH vs SC composite output ≤ 1/255 on all 22 fixtures, photos included;
- the 48-row timing smoke per arm;
- launch exit 0.

LC vs SC differ by up to 122/255. That is informational: MPS is a true Gaussian, while Dual Kawase
approximates it.

## Pre-declared screens

| # | Screen | Result | Pass? |
|---|---|---|---|
| P1 | SH vs LC GPU: median > 0, lower 95% bound > 0, ≥ 7/8 | **36.998%** lower, CI [36.668, 37.219]%, 8/8 | ✅ |
| P2 | SH vs LC CPU encode: same rule | **31.856%** lower, CI [29.889, 32.118]%, 8/8 | ✅ |

## Descriptive (paired medians; never gated)

- **P3** SH vs SC GPU: 22.95% lower, CI [22.50, 23.47]%, 8/8. This is the saving from the half-res
  publish, i.e. from dropping the final pass.
- SH vs SC CPU: 18.42% lower.
- SC vs LC GPU: 18.38% lower, 8/8. SC vs LC CPU: 15.93% lower, 8/8. This is the v1-style S-vs-MPS
  comparison, now with the composite. On A15 the margin is larger than v1 measured on A18
  (−15% GPU, −10% CPU, without the composite); different device and endpoint, so not directly
  comparable.
- SH vs LC submit (buffer creation through commit): 29.83% lower, 8/8.

## Marginal medians of per-process p95 (descriptive; not the paired estimate)

| Arm | CPU encode p95, ms | Submit p95, ms | GPU p95, ms |
|---|---:|---:|---:|
| LC (MPS + composite) | 0.3325 | 0.3720 | 2.2994 |
| SC (S + composite) | 0.2809 | 0.3164 | 1.8787 |
| SH (production: S to level 0 + composite) | 0.2282 | 0.2626 | 1.4499 |

CPU and GPU percentiles are never summed.

## Scope

- One iPhone 14 / A15, this sigma, this corpus and composite target, n = 8 blocks.
- Drained single-buffer regime with an offscreen composite (no drawable or present): this is not
  end-to-end, presentation, frame-latency or energy evidence.
- Not covered:
  - Q1, the main-thread profile;
  - on-device visual acceptance.

  Both are separate Suretare-u2z3.4 steps.

## Raw-data archive

Kept out of git as loose files:
- the per-leg `attempts/*/<arm>/report.json` files;
- the device snapshots `processes.*` (process lists) and `details.*` (serial number and ECID).

All 148 files are packed in `raw-data.tar.xz` (5.2 MB, SHA-256
`1adae52519ba778d4f8496f1af2051d2da2c53e9d9e67b85cfe60781f52e575a`). `raw-data.sha256` lists each
file's SHA-256; an extract-and-verify pass returned 148/148 OK.

To restore: `tar -xJf raw-data.tar.xz && shasum -a 256 -c raw-data.sha256`.

The archive contains device identifiers from the iPhone 14. Review it before pushing anywhere public.
