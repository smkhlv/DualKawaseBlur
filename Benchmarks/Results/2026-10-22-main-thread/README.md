# Q1 main-thread run — 2026-10-22 (pre-recording record)

Procedure: `DualKawaseBlur/Benchmarks/MAIN_THREAD_ENCODE_PROCEDURE.md`.

## Confirmed before the first recording

- E4 thresholds as drafted. The user confirmed them before any trace: feat median hitch-time
  ratio ≤ main median + 0.5 ms/s, and no feat hitch longer than the longest main hitch + 1 frame.
- **Builds (deviation from §2, decided before recording):**
  - **before** = `main` tip `c214da81`;
  - **after** = `c214da81` merged with `feat/blur-cpu-encode` (merge commit `3e10fe3c`, no conflicts).

  The procedure said "from a checkout of each branch". The feature branch is 37 commits behind
  `main`, and installing it over the user's current app could downgrade the app's local store.
  The merge keeps the only difference between builds equal to the branch's own diff. Both builds
  are Release, from temporary worktrees.
- **Connection:** Wi‑Fi (CoreDevice localNetwork), on battery. The USB cable failed earlier today,
  so the wired condition of §2.2 cannot be met. Recording happens on-device; the transport only
  installs apps and collects traces.
- **Order:** before, after, after, before (ABBA). Each recording is 30 s, preceded by a manual launch
  onto the root screen, 10 s wait and 60 s settle. Retry only for a foreground or thermal
  violation, never for a value.
- **Signing (deviation, before recording):** the Release config's entitlements carry Associated
  Domains, which the free Personal Team cannot provision. Both builds therefore use
  `-configuration Release` with `CODE_SIGN_ENTITLEMENTS=SuretareiOS/SuretareiOS.Debug.entitlements`,
  the empty set Debug already uses. Release optimization is unchanged, and the two builds stay
  identical in this respect. Universal links do not affect the blur path.

## Recording attempts (no trace obtained; Q1 postponed)

The "before" build was installed. Its executable SHA-256 is `6a05102b…f212a`; the "after" build
compiled too. Every recording attempt over Wi‑Fi failed, and none reached a 30 s trace:

1. `--attach SuretareiOS`: "Timed out waiting for device to boot". xctrace listed the iPhone as
   offline. That cleared after the user opened Xcode's Devices window.
2. `--attach SuretareiOS`: "Cannot find process matching name" (`1-before.log`), although
   devicectl showed the process running as PID 558.
3. `--attach 558`: "Cannot find process for provided pid".
4. A probe with `--all-processes` and a 3 s limit stopped after 1.34 s with end-reason "Device
   disconnected". It was a scratch probe and was not kept.

Conclusion: wireless Instruments recording is not reliable on this setup. Q1 needs a wired data
cable; rerun the procedure from §3 with the builds above, or rebuild them identically. No values
were seen, so nothing here biases a later run.
