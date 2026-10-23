"""Device-free core of CPU_ENCODE_PROTOCOL.md (v1) and PATH_LEVEL_PROTOCOL.md (v2): block design,
report audits, journal, analysis. v1 and v2 share every audit; each protocol only names its own
constants (arms, orders, methods, output contract, comparisons, screens).

No launch, copy or device query lives here (see `run_cpu_encode.py`). Stdlib only.
"""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
from pathlib import Path
import random
import statistics
import uuid

PROTOCOL = "cpu-encode-blocks-v1"
LEG_METHOD = "cpu-encode-leg-v1"
QUALIFICATION_METHOD = "cpu-encode-qualification-v1"
WIDTH, HEIGHT, SIGMA = 1179, 2556, 92.087890625
WARMUP, MEASURED = 1000, 3000
# Qualification's timing smoke: rows per arm through the timed legs' own row audit; never analyzed.
SMOKE_ROWS = 48
COOLING_CAP_SECONDS = 300  # the native settling cap; the devicectl launch timeout must exceed it
P95_INDEX = math.ceil(0.95 * MEASURED) - 1  # nearest rank: 2849
BOOTSTRAP_RESAMPLES, BOOTSTRAP_SEED = 10000, 443
OUTPUT_USAGE = {"O": 5, "S": 5, "S4": 5, "L": 3}
PRIVATE_STORAGE = 2  # MTLStorageMode.private

# Williams square for four arms (0=O, 1=S, 2=S4, 3=L), then the same four rows in reverse
# block order. Each arm sits in each position twice, precedes every other arm in exactly
# four of eight blocks and immediately follows every other arm exactly twice.
FOUR_ARM_ORDERS = (
    ("O", "S", "L", "S4"), ("S", "S4", "O", "L"), ("S4", "L", "S", "O"), ("L", "O", "S4", "S"),
    ("L", "O", "S4", "S"), ("S4", "L", "S", "O"), ("S", "S4", "O", "L"), ("O", "S", "L", "S4"),
)
# Pre-declared fallback when S4 cannot be built or fails its quality gate: all six orders once.
THREE_ARM_ORDERS = (
    ("O", "S", "L"), ("S", "L", "O"), ("L", "O", "S"), ("L", "S", "O"), ("O", "L", "S"), ("S", "O", "L"),
)

RETRYABLE = {"thermal", "locked", "background", "lowPower", "connection", "export", "timeout", "interrupted",
             "preflight"}
FATAL = {"quality", "provenance", "timestamps", "identity", "contract"}

# --- path-level-v2 (PATH_LEVEL_PROTOCOL.md). Same workload, row audit, cooling, retry and journal as v1;
# an arm is a whole path: blur, then the presenters' opaque composite into a full-size render target.
PATH_PROTOCOL = "path-level-v2"
PATH_LEG_METHOD = "path-level-leg-v2"
PATH_QUALIFICATION_METHOD = "path-level-qualification-v2"
# LC: MPS-L blur + composite. SC: S `encode` + composite. SH: S `encodeThroughLevelZero` + composite from level 0.
PATH_ARMS = ("LC", "SC", "SH")
PATH_REFERENCE_ARM = "SC"  # SH is gated against SC; LC's difference from SC is recorded, never gated
# Blocks 1-6 are all six orders once; blocks 7-8 repeat blocks 2 and 1, so the series ends mirror its
# start. Every arm holds every position 2 or 3 times (LC 3/3/2, SC 2/3/3, SH 3/2/3); SH precedes LC
# and SC in exactly 4 of 8 blocks; immediate follows LC>SC 4, SH>LC 3, SC>SH 3, the other three 2.
PATH_ORDERS = (
    ("LC", "SC", "SH"), ("SH", "LC", "SC"), ("SC", "SH", "LC"), ("LC", "SH", "SC"),
    ("SC", "LC", "SH"), ("SH", "SC", "LC"), ("SH", "LC", "SC"), ("LC", "SC", "SH"),
)
# The composite every arm ends with: `.unit` mapping, this fixed opaque base color (RGBA, exact in
# Float and JSON), into a private bgra8Unorm WIDTHxHEIGHT texture of usage [.renderTarget] = 4.
COMPOSITE_BASE_COLOR = [0.25, 0.5, 0.75, 1.0]
COMPOSITE_MAPPING = "unit"
COMPOSITE_USAGE = 4
# Private blur output per arm: LC [.shaderRead, .shaderWrite] = 3, SC [.shaderRead, .renderTarget] = 5,
# SH none (the composite samples S's half-size level 0 directly).
PATH_BLUR_USAGE = {"LC": 3, "SC": 5, "SH": None}
# The host transport is chosen at qualify/freeze (protocol §6), recorded, and checked by every preflight.
PATH_TRANSPORTS = ("wired", "localNetwork")

# (label, metric, baseline arm, candidate arm, direction). Reduction = 100*(base-cand)/base.
# Regression = 100*(cand-base)/base. CPU and GPU percentiles are never combined.
COMPARISONS = (
    ("S_vs_L_cpu", "cpuEncodeP95Ms", "L", "S", "reduction"),
    ("S_vs_O_gpu", "gpuP95Ms", "O", "S", "regression"),
    ("S4_vs_L_cpu", "cpuEncodeP95Ms", "L", "S4", "reduction"),
    # Q3 qualifier: the submit interval also covers begin/end/commit, where Metal 4 may move CPU work.
    ("S4_vs_L_submit", "submitP95Ms", "L", "S4", "reduction"),
    ("O_vs_L_gpu", "gpuP95Ms", "L", "O", "reduction"),
    ("O_vs_L_cpu", "cpuEncodeP95Ms", "L", "O", "reduction"),
    ("S_vs_O_cpu", "cpuEncodeP95Ms", "O", "S", "reduction"),
    ("S4_vs_S_cpu", "cpuEncodeP95Ms", "S", "S4", "reduction"),
    ("S4_vs_O_gpu", "gpuP95Ms", "O", "S4", "regression"),
)
# v2: P1 and P2 are the screens; P3 (SH_vs_SC_gpu) and the rest are descriptive only.
PATH_COMPARISONS = (
    ("SH_vs_LC_gpu", "gpuP95Ms", "LC", "SH", "reduction"),
    ("SH_vs_LC_cpu", "cpuEncodeP95Ms", "LC", "SH", "reduction"),
    ("SH_vs_SC_gpu", "gpuP95Ms", "SC", "SH", "reduction"),
    ("SC_vs_LC_gpu", "gpuP95Ms", "LC", "SC", "reduction"),
    ("SC_vs_LC_cpu", "cpuEncodeP95Ms", "LC", "SC", "reduction"),
    ("SH_vs_SC_cpu", "cpuEncodeP95Ms", "SC", "SH", "reduction"),
    ("SH_vs_LC_submit", "submitP95Ms", "LC", "SH", "reduction"),
)
PATH_SCREENS = {"P1_SH_gpu_below_LC": "SH_vs_LC_gpu", "P2_SH_cpu_below_LC": "SH_vs_LC_cpu"}


def orders_for(arms):
    arms = tuple(arms)
    if arms == ("O", "S", "S4", "L"):
        return FOUR_ARM_ORDERS
    if arms == ("O", "S", "L"):
        return THREE_ARM_ORDERS
    if arms == PATH_ARMS:
        return PATH_ORDERS
    raise ValueError("arms must be O,S,S4,L, the declared O,S,L fallback or the path-level LC,SC,SH")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def is_hash(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def number(value):
    return type(value) in (float, int) and math.isfinite(value)


class AuditFailure(ValueError):
    def __init__(self, reason, detail):
        super().__init__(f"{reason}: {detail}")
        self.reason = reason


def _common(report, method, protocol=PROTOCOL):
    expected = dict(method=method, protocolID=protocol, width=WIDTH, height=HEIGHT, pixelFormat="bgra8Unorm",
                    iterations=5, offset=5, sigma=SIGMA, mpsOptions="allowReducedPrecision",
                    endToEndMeasured=False, automaticPromotion=False)
    for key, value in expected.items():
        if report.get(key) != value or type(report.get(key)) is not type(value):
            raise AuditFailure("contract", f"{key}={report.get(key)!r}")
    session = report.get("processSessionUUID")
    try:
        if str(uuid.UUID(session)) != session:
            raise ValueError
    except (ValueError, TypeError, AttributeError):
        raise AuditFailure("contract", "noncanonical process session") from None


def _path_common(report, method):
    """v2 adds the composite every path ends with: the fixed base color and the `.unit` mapping."""
    _common(report, method, PATH_PROTOCOL)
    color = report.get("compositeBaseColor")
    if (type(color) is not list or not all(number(v) for v in color) or color != COMPOSITE_BASE_COLOR
            or report.get("compositeMapping") != COMPOSITE_MAPPING):
        raise AuditFailure("contract", f"composite {color!r} {report.get('compositeMapping')!r}")


def path_output(arm):
    """What a v2 report records about one arm's textures (protocol §2). SH has no blur output: its
    composite source is S's half-size level 0."""
    blur = {} if PATH_BLUR_USAGE[arm] is None else dict(blurOutputTextureUsage=PATH_BLUR_USAGE[arm],
                                                         blurOutputStorageMode=PRIVATE_STORAGE)
    width, height = (WIDTH // 2, HEIGHT // 2) if arm == "SH" else (WIDTH, HEIGHT)
    return dict(blur, compositeSourceWidth=width, compositeSourceHeight=height,
                compositeTextureUsage=COMPOSITE_USAGE, compositeStorageMode=PRIVATE_STORAGE)


BUILD_KEYS = ("appExecutableSHA256", "metallibSHA256")


def _build(report, build):
    """The process must be the frozen Release build: its own executable and metallib hashes."""
    if report.get("debugBuild") is not False:
        raise AuditFailure("identity", f"debugBuild={report.get('debugBuild')!r}; Release required")
    for key in BUILD_KEYS:
        if not is_hash(build.get(key)) or report.get(key) != build[key]:
            raise AuditFailure("identity", f"{key}={report.get(key)!r} is not the frozen build")


def _cooling(cooling):
    cooling = cooling or {}
    if (not number(cooling.get("nominalContinuousSeconds")) or cooling["nominalContinuousSeconds"] < 20
            or not number(cooling.get("elapsedSeconds")) or not 20 <= cooling["elapsedSeconds"] <= COOLING_CAP_SECONDS
            or cooling["nominalContinuousSeconds"] > cooling["elapsedSeconds"]
            or cooling.get("pollSeconds") != 0.5 or cooling.get("noEncodes") is not True):
        raise AuditFailure("contract", "cooling guard")


def _rows(rows, start, end, phases):
    """The one row audit for timed legs and the qualification smoke: exact count and order, every
    environment check, and monotonic, finite, correctly nested timestamps. Returns ms per row."""
    if not number(start) or not number(end) or not 0 < start < end:
        raise AuditFailure("timestamps", "timing window")
    rows = rows or []
    if len(rows) != len(phases):
        raise AuditFailure("contract", f"{len(rows)} rows; partial legs are never filtered")
    measured = []
    last = start
    for i, (row, phase) in enumerate(zip(rows, phases)):
        t, before, after = row.get("timing", {}), row.get("before", {}), row.get("after", {})
        if (row.get("index") != i or row.get("inputIndex") != i % 8
                or row.get("phase") != phase or t.get("gpuSucceeded") is not True):
            raise AuditFailure("contract", f"row {i}")
        for env in (before, after):
            if env.get("thermal") != 0 or env.get("foreground") is not True or env.get("lowPower") is not False:
                raise AuditFailure("contract", f"row {i} environment")
        stamps = [t.get(k) for k in ("submitStart", "encodeStart", "encodeEnd", "submitEnd", "gpuStart", "gpuEnd")]
        if not all(number(v) for v in stamps):
            raise AuditFailure("timestamps", f"row {i} nonfinite")
        ss, es, ee, se, gs, ge = stamps
        if not (last <= ss <= es < ee <= se and 0 < gs < ge and ss <= gs and ge <= after.get("time", -1) <= end):
            raise AuditFailure("timestamps", f"row {i} order")
        last = after["time"]
        measured.append((phase, 1000 * (ee - es), 1000 * (ge - gs), 1000 * (se - ss)))
    return measured


def _qualification(report, build, common, expected_arms, reference, gated, native_flags, smoke_output):
    """The one qualification audit. Gates: every fixture's max per-channel |arm - reference| <= 1/255
    for each `gated` arm (other differences are recorded only), the frozen Release build, and every
    arm's timing smoke through the timed legs' row audit. Returns the receipt the series freezes."""
    common(report)
    _build(report, build)
    if report.get("completed") is not True or report.get("failure") is not None:
        raise AuditFailure("quality", f"qualification incomplete: {report.get('failure')}")
    if report.get("photoFixturesIncluded") is not True:
        raise AuditFailure("quality", "photos not staged; 22 fixtures required")
    checks = report.get("checks", [])
    names = [c.get("fixture") for c in checks]
    if len(checks) != 22 or len(set(names)) != 22:
        raise AuditFailure("quality", f"expected 22 distinct fixtures, got {len(checks)}")
    arms = report.get("arms")
    if arms != expected_arms:
        raise AuditFailure("identity", f"arms {arms} != {expected_arms}")
    for check in checks:
        diff = check.get(f"differenceVersus{reference}", {})
        for arm in arms:
            # A max absolute difference is a non-negative int; a negative one would pass any `> 1` gate.
            if arm != reference and (type(diff.get(arm)) is not int or diff[arm] < 0):
                raise AuditFailure("contract", f"missing or negative difference: {arm}={diff.get(arm)!r}")
        if any(diff[arm] > 1 for arm in gated):
            raise AuditFailure("quality", f"{check['fixture']} differs from {reference} by more than 1/255: {diff}")
        if set(check.get("outputSHA256", {})) != set(arms) or not all(map(is_hash, check["outputSHA256"].values())):
            raise AuditFailure("contract", "missing output hash")
    if any(report.get(flag) is not True for flag in native_flags):
        raise AuditFailure("quality", "native gate disagrees with audit")
    expected = report.get("expectedOutputSHA256", {})
    if set(expected) != set(arms) or any(len(v) != 8 or not all(map(is_hash, v.values())) for v in expected.values()):
        raise AuditFailure("contract", "expected Sphere output hashes")
    # The timing route (both clock domains, the cooling path) runs once before freeze. Its rows
    # pass the same audit as a timed leg and are excluded from every analysis.
    _cooling(report.get("timingSmokeCooling"))
    smoke = report.get("timingSmoke") or {}
    if set(smoke) != set(arms):
        raise AuditFailure("contract", f"timing smoke arms {sorted(smoke)} != {sorted(arms)}")
    for arm in arms:
        leg = smoke[arm] or {}
        if any(leg.get(key) != value for key, value in smoke_output(arm).items()):
            raise AuditFailure("contract", f"{arm} smoke output texture")
        _rows(leg.get("rows"), leg.get("timingStart"), leg.get("timingEnd"), ["smoke"] * SMOKE_ROWS)
    return dict(arms=arms, expectedOutputSHA256=expected, corpusManifestSHA256=report["corpusManifestSHA256"],
                hardware=report["hardware"], os=report["os"], gpu=report["gpu"], timingSmokeRows=SMOKE_ROWS)


def audit_qualification(report, require_s4, build):
    """v1. Gates: every fixture |S-O| and |S4-O| <= 1/255, the frozen Release build, and every arm's
    timing smoke through the timed legs' row audit."""
    return _qualification(report, build, lambda r: _common(r, QUALIFICATION_METHOD),
                          ["O", "S", "L", "S4"] if require_s4 else ["O", "S", "L"], "O",
                          ["S", "S4"] if require_s4 else ["S"],
                          ["sQualityPassed", "s4QualityPassed"] if require_s4 else ["sQualityPassed"],
                          lambda arm: dict(outputTextureUsage=OUTPUT_USAGE[arm], outputStorageMode=PRIVATE_STORAGE))


def audit_path_qualification(report, build):
    """v2. Gates: every fixture's composite |SH-SC| <= 1/255 (LC-SC is recorded in the receipt, never
    gated), the frozen Release build, and every arm's timing smoke through the timed legs' row audit."""
    receipt = _qualification(report, build, lambda r: _path_common(r, PATH_QUALIFICATION_METHOD),
                             list(PATH_ARMS), PATH_REFERENCE_ARM, ["SH"], ["shQualityPassed"],
                             lambda arm: dict(pathOutput=path_output(arm)))
    key = f"differenceVersus{PATH_REFERENCE_ARM}"
    receipt["maxDifferenceVersusSC"] = {arm: max(c[key][arm] for c in report["checks"])
                                        for arm in PATH_ARMS if arm != PATH_REFERENCE_ARM}
    return receipt


def _leg(report, series, block, attempt, arm, common, output):
    """The one leg audit: rejects partial, legacy or guard-violating legs; returns per-process summaries in ms."""
    common(report)
    receipt = series["qualification"]
    expected = dict(arm=arm, block=block, attempt=attempt, seriesSHA256=series["seriesSHA256"],
                    sessionLabel=f"b{block:02d}-a{attempt:02d}-{arm}", completed=True, failure=None,
                    warmupCount=WARMUP, measuredCount=MEASURED, **output,
                    corpusManifestSHA256=receipt["corpusManifestSHA256"],
                    hardware=receipt["hardware"], os=receipt["os"], gpu=receipt["gpu"])
    for key, value in expected.items():
        if report.get(key) != value:
            raise AuditFailure("identity" if key in ("seriesSHA256", "hardware", "os", "gpu",
                "corpusManifestSHA256") else "contract", f"{key}={report.get(key)!r}")
    _build(report, series)
    outputs = receipt["expectedOutputSHA256"][arm]
    if report.get("outputSHA256Before") != outputs or report.get("outputSHA256After") != outputs:
        raise AuditFailure("quality", "output guard differs from qualification receipt")
    _cooling(report.get("cooling"))
    rows = _rows(report.get("rows"), report.get("timingStart"), report.get("timingEnd"),
                 ["warmup"] * WARMUP + ["measured"] * MEASURED)
    measured = [r for r in rows if r[0] == "measured"]
    cpu, gpu, submit = ([r[k] for r in measured] for k in (1, 2, 3))
    return dict(cpuEncodeP95Ms=sorted(cpu)[P95_INDEX], gpuP95Ms=sorted(gpu)[P95_INDEX],
                submitP95Ms=sorted(submit)[P95_INDEX], cpuEncodeMedianMs=statistics.median(cpu),
                gpuMedianMs=statistics.median(gpu))


def audit_leg(report, series, block, attempt, arm):
    """v1 leg: the arm's own private full-size output texture."""
    return _leg(report, series, block, attempt, arm, lambda r: _common(r, LEG_METHOD),
                dict(outputTextureUsage=OUTPUT_USAGE[arm], outputStorageMode=PRIVATE_STORAGE))


def audit_path_leg(report, series, block, attempt, arm):
    """v2 leg: one drained buffer per row holds blur + composite; the CPU endpoint is both encoder calls."""
    return _leg(report, series, block, attempt, arm, lambda r: _path_common(r, PATH_LEG_METHOD),
                dict(pathOutput=path_output(arm)))


def bootstrap(values, seed=BOOTSTRAP_SEED, resamples=BOOTSTRAP_RESAMPLES):
    """Paired-median percentile bootstrap, identical to the 2026-10-10 confirmation."""
    rng = random.Random(seed)
    samples = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(resamples))
    return [samples[int(0.025 * resamples) - 1], samples[int(0.975 * resamples) - 1]]


def paired(blocks, metric, base, candidate, direction):
    values = []
    for b in blocks:
        x, y = b["summaries"][base][metric], b["summaries"][candidate][metric]
        values.append(100 * (x - y) / x if direction == "reduction" else 100 * (y - x) / x)
    return values


def _comparisons(blocks, arms, comparisons):
    result = {}
    for label, metric, base, candidate, direction in comparisons:
        if base not in arms or candidate not in arms:
            continue
        values = paired(blocks, metric, base, candidate, direction)
        favorable = [v > 0 for v in values] if direction == "reduction" else [v <= 3 for v in values]
        result[label] = dict(metric=metric, baseline=base, candidate=candidate, direction=direction,
            values=values, median=statistics.median(values), favorablePairs=sum(favorable),
            bootstrap95CI=bootstrap(values),
            positionMedians={pos: statistics.median(v for b, v in zip(blocks, values)
                if (b["order"].index(candidate) < b["order"].index(base)) == (pos == "candidateFirst"))
                for pos in ("candidateFirst", "baselineFirst")})
    return result


def _screen(comparison):
    """The strict screen: median > 0, lower 95% bootstrap bound > 0 and >= 7/8 favourable blocks."""
    return comparison["median"] > 0 and comparison["bootstrap95CI"][0] > 0 and comparison["favorablePairs"] >= 7


def _marginal_medians(blocks, arms):
    return {arm: {m: statistics.median(b["summaries"][arm][m] for b in blocks)
            for m in ("cpuEncodeP95Ms", "gpuP95Ms", "submitP95Ms")} for arm in arms}


def analyze(blocks, arms):
    """Only the complete fixed-count series may be analyzed; no optional stopping."""
    orders = orders_for(arms)
    if len(blocks) != len(orders) or [tuple(b["order"]) for b in blocks] != list(orders):
        raise ValueError("incomplete series; no confirmatory analysis")
    if tuple(arms) == PATH_ARMS:
        return _analyze_path(blocks)
    result = dict(protocolID=PROTOCOL, independentBlocks=len(blocks), arms=list(arms),
                  comparisons=_comparisons(blocks, arms, COMPARISONS),
                  endToEndMeasured=False, automaticPromotion=False, cpuGpuSummed=False)
    c = result["comparisons"]
    screens = dict(
        # User decision 2026-10-22 (before freeze): Q2a also needs a positive lower bootstrap bound.
        S_cpu_parity=c["S_vs_L_cpu"]["median"] >= 0 and c["S_vs_L_cpu"]["bootstrap95CI"][0] > 0,
        S_gpu_regression_within_3pct=c["S_vs_O_gpu"]["median"] <= 3)
    if "S4" in arms:
        s4 = c["S4_vs_L_cpu"]
        screens["S4_cpu_below_L"] = _screen(s4)
        # Pre-declared Q3 qualifier (protocol §1): "below L" is the PAIRED median submit p95 reduction
        # S4_vs_L_submit > 0, never the descriptive marginal medians.
        if not screens["S4_cpu_below_L"]:
            result["S4_q3_label"] = "fail"
        elif c["S4_vs_L_submit"]["median"] > 0:
            result["S4_q3_label"] = "cpu_win"
        else:
            result["S4_q3_label"] = "encode_call_win_only"
    else:
        result["S4_q3_label"] = "not_run"
    result["screens"] = screens
    result["marginalMediansMs"] = _marginal_medians(blocks, arms)
    result["limitation"] = (f"A18 iPhone 16 only, sigma {SIGMA}, eight prerecorded Sphere inputs, "
                            f"n={len(blocks)} blocks; one drained command buffer per blur (drained "
                            f"single-buffer regime), so not end-to-end, pipelined, presentation or energy evidence")
    return result


def _analyze_path(blocks):
    """v2 (PATH_LEVEL_PROTOCOL.md §1): P1/P2 are the strict screens; P3 and the rest are descriptive."""
    comparisons = _comparisons(blocks, PATH_ARMS, PATH_COMPARISONS)
    return dict(protocolID=PATH_PROTOCOL, independentBlocks=len(blocks), arms=list(PATH_ARMS),
                comparisons=comparisons, endToEndMeasured=False, automaticPromotion=False, cpuGpuSummed=False,
                screens={name: _screen(comparisons[label]) for name, label in PATH_SCREENS.items()},
                descriptiveOnly=[label for label, *_ in PATH_COMPARISONS if label not in PATH_SCREENS.values()],
                marginalMediansMs=_marginal_medians(blocks, PATH_ARMS),
                limitation=(f"the single device fixed at freeze only (series hardware/gpu), sigma {SIGMA}, "
                            f"eight prerecorded Sphere inputs, "
                            f"n={len(blocks)} blocks; one drained command buffer per path (blur + opaque "
                            f"composite into an offscreen render target, no drawable), so not end-to-end, "
                            f"pipelined, presentation, frame-latency or energy evidence"))


class Journal:
    """Append-only, hash-chained JSONL. Replay derives all state; nothing is ever rewritten."""

    def __init__(self, root):
        self.root = Path(root).resolve()
        self.path = self.root / "journal.jsonl"

    @contextmanager
    def locked(self):
        with (self.root / "journal.lock").open("a") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError("another writer holds the journal") from None
            yield

    def entries(self):
        if not self.path.exists():
            return []
        entries, previous = [], None
        for seq, line in enumerate(self.path.read_text().splitlines()):
            entry = json.loads(line)
            body = {k: v for k, v in entry.items() if k != "sha256"}
            if entry.get("seq") != seq or entry.get("previous") != previous or digest(canonical(body)) != entry.get("sha256"):
                raise ValueError(f"journal chain broken at entry {seq}")
            entries.append(entry)
            previous = entry["sha256"]
        return entries

    def append(self, kind, **payload):
        entries = self.entries()
        body = dict(seq=len(entries), previous=entries[-1]["sha256"] if entries else None, kind=kind, **payload)
        entry = dict(body, sha256=digest(canonical(body)))
        with self.path.open("a") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")
        return entry

    def state(self):
        entries = self.entries()
        if not entries or entries[0]["kind"] != "freeze":
            raise ValueError("series not frozen")
        series = entries[0]["series"]
        orders = [tuple(o) for o in series["orders"]]
        state = dict(series=series, block=1, attempt=1, active=None, completed=[], failures=[], stopped=None)
        for entry in entries[1:]:
            kind = entry["kind"]
            if state["stopped"]:
                raise ValueError("entry after stop")
            if kind == "begin":
                if state["active"] or (entry["block"], entry["attempt"]) != (state["block"], state["attempt"]):
                    raise ValueError("out-of-order begin")
                state["active"] = dict(block=entry["block"], attempt=entry["attempt"],
                                       order=orders[entry["block"] - 1], legs={})
            elif kind == "leg":
                active = state["active"]
                if not active or entry["block"] != active["block"] or entry["arm"] in active["legs"]:
                    raise ValueError("unexpected leg")
                if entry["arm"] != active["order"][len(active["legs"])]:
                    raise ValueError("leg out of order")
                active["legs"][entry["arm"]] = entry["summary"]
            elif kind == "complete":
                active = state["active"]
                if not active or len(active["legs"]) != len(active["order"]):
                    raise ValueError("complete without every leg")
                state["completed"].append(dict(block=active["block"], attempt=active["attempt"],
                                               order=list(active["order"]), summaries=active["legs"]))
                state["active"] = None
                state["block"], state["attempt"] = active["block"] + 1, 1
                if state["block"] > len(orders):
                    state["stopped"] = "complete"
            elif kind == "fail":
                if not state["active"]:
                    raise ValueError("failure without attempt")
                state["failures"].append(dict(block=entry["block"], attempt=entry["attempt"],
                                              reason=entry["reason"], detail=entry["detail"]))
                state["active"] = None
                if entry["reason"] not in RETRYABLE:
                    state["stopped"] = "fatal"
                elif state["attempt"] == 2:
                    state["stopped"] = "retry budget exhausted"
                else:
                    state["attempt"] = 2
            else:
                raise ValueError(f"unknown entry {kind}")
        return state
