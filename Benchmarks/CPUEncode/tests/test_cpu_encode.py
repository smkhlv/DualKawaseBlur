"""Device-free tests for the CPU encode harness. Run:
python3 -m unittest discover -s DualKawaseBlur/Benchmarks/CPUEncode/tests -v
"""
from collections import Counter
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import cpu_encode as core  # noqa: E402
import prepare_corpus  # noqa: E402
import run_cpu_encode as driver  # noqa: E402

ARMS4 = ("O", "S", "S4", "L")
SPHERES = [f"sphere-{i:03d}.bgra" for i in range(0, 24, 3)]
# The frozen build: what `app_identity` returns for the fake app bundle in FreezeTests.
BUILD = dict(appExecutableSHA256=core.digest(b"exe"), metallibSHA256=core.digest(b"lib"))


def hashes(tag):
    return {name: core.digest(f"{tag}-{name}".encode()) for name in SPHERES}


def timed_rows(phases, cpu_ms=0.2, gpu_ms=1.3, t=1000.0):
    """Rows exactly as the app writes them; returns (rows, start, end)."""
    rows, start = [], t
    for i, phase in enumerate(phases):
        # Deterministic spread so p95 differs from the max: measured value grows with i % 100.
        jitter = (i % 100) / 1e5
        before = dict(time=t, thermal=0, foreground=True, lowPower=False)
        ss = t + 1e-5
        es = ss + 1e-5
        ee = es + cpu_ms / 1000 + jitter
        se = ee + 1e-5
        gs = se + 1e-5
        ge = gs + gpu_ms / 1000 + jitter
        t = ge + 1e-5
        rows.append(dict(index=i, inputIndex=i % 8, phase=phase,
            timing=dict(submitStart=ss, encodeStart=es, encodeEnd=ee, submitEnd=se, gpuStart=gs, gpuEnd=ge,
                        gpuSucceeded=True),
            before=before, after=dict(time=t, thermal=0, foreground=True, lowPower=False)))
    return rows, start, t + 1


def cooling():
    return dict(nominalContinuousSeconds=20.2, elapsedSeconds=20.7, pollSeconds=0.5, noEncodes=True, checkpoints=[])


def smoke_for(arms):
    smoke = {}
    for arm in arms:
        rows, start, end = timed_rows(["smoke"] * core.SMOKE_ROWS)
        smoke[arm] = dict(outputTextureUsage=core.OUTPUT_USAGE[arm], outputStorageMode=2, timingStart=start,
                          timingEnd=end, rows=rows)
    return smoke


def qualification_report(arms=("O", "S", "L", "S4"), worst=1, photos=True):
    names = SPHERES + ["photo-1.bgra", "photo-2.bgra", "gradient.bgra", "coarse-checker.bgra", "fine-detail.bgra",
                       "edge-x.bgra", "edge-y.bgra", "alpha-border.bgra"] + [f"calibration-{i}" for i in range(6)]
    checks = [dict(fixture=n, sourceSHA256=core.digest(n.encode()),
                   outputSHA256={a: core.digest(f"{a}{n}".encode()) for a in arms},
                   differenceVersusO={a: (worst if i == 3 else 0) for a in arms if a != "O"})
              for i, n in enumerate(names)]
    return dict(method=core.QUALIFICATION_METHOD, protocolID=core.PROTOCOL, width=1179, height=2556,
        pixelFormat="bgra8Unorm", iterations=5, offset=5, sigma=core.SIGMA, mpsOptions="allowReducedPrecision",
        endToEndMeasured=False, automaticPromotion=False, processSessionUUID=str(uuid.uuid4()),
        s4Compiled="S4" in arms, debugBuild=False, **BUILD, completed=True, failure=None, arms=list(arms),
        photoFixturesIncluded=photos, checks=checks, sQualityPassed=worst <= 1,
        s4QualityPassed=(worst <= 1) if "S4" in arms else None,
        expectedOutputSHA256={a: hashes(a) for a in arms}, corpusManifestSHA256="c" * 64,
        hardware="iPhone17,3", os="Version 27.0.1", gpu="Apple A18 GPU",
        timingSmokeCooling=cooling(), timingSmoke=smoke_for(arms))


def series_for(arms=ARMS4):
    receipt = core.audit_qualification(qualification_report(("O", "S", "L", "S4") if "S4" in arms else ("O", "S", "L")),
                                       "S4" in arms, BUILD)
    series = dict(protocolID=core.PROTOCOL, qualification=receipt, arms=list(arms),
                  orders=[list(o) for o in core.orders_for(arms)], device="DEVICE", **BUILD)
    series["seriesSHA256"] = core.digest(core.canonical(series))
    return series


def leg_report(series, block, attempt, arm, cpu_ms=0.2, gpu_ms=1.3, mutate=None):
    rows, start, end = timed_rows(["warmup"] * core.WARMUP + ["measured"] * core.MEASURED, cpu_ms, gpu_ms)
    receipt = series["qualification"]
    report = dict(method=core.LEG_METHOD, protocolID=core.PROTOCOL, width=1179, height=2556, pixelFormat="bgra8Unorm",
        iterations=5, offset=5, sigma=core.SIGMA, mpsOptions="allowReducedPrecision", endToEndMeasured=False,
        automaticPromotion=False, processSessionUUID=str(uuid.uuid4()), s4Compiled=True, debugBuild=False, **BUILD,
        arm=arm, block=block, attempt=attempt, seriesSHA256=series["seriesSHA256"],
        sessionLabel=f"b{block:02d}-a{attempt:02d}-{arm}", completed=True, failure=None, warmupCount=1000,
        measuredCount=3000, outputTextureUsage=core.OUTPUT_USAGE[arm], outputStorageMode=2,
        corpusManifestSHA256=receipt["corpusManifestSHA256"], hardware=receipt["hardware"], os=receipt["os"],
        gpu=receipt["gpu"], cooling=cooling(), outputSHA256Before=dict(receipt["expectedOutputSHA256"][arm]),
        outputSHA256After=dict(receipt["expectedOutputSHA256"][arm]), timingStart=start, timingEnd=end, rows=rows)
    if mutate:
        mutate(report)
    # Round-trip like a copied report so no test shares objects with the receipt.
    return json.loads(json.dumps(report))


class DesignTests(unittest.TestCase):
    def check_balance(self, orders, precedence):
        arms = orders[0]
        for position in range(len(arms)):
            self.assertEqual(Counter(o[position] for o in orders), Counter({a: len(orders) // len(arms) for a in arms}))
        for x in arms:
            for y in arms:
                if x != y:
                    self.assertEqual(sum(o.index(x) < o.index(y) for o in orders), precedence, (x, y))
        carry = Counter((o[i], o[i + 1]) for o in orders for i in range(len(arms) - 1))
        self.assertEqual(set(carry.values()), {2})
        self.assertEqual(len(carry), len(arms) * (len(arms) - 1))

    def test_four_arm_williams_design_is_balanced(self):
        self.check_balance(core.FOUR_ARM_ORDERS, 4)
        # Mirrored second half: drift that is linear in block number cancels.
        self.assertEqual(core.FOUR_ARM_ORDERS[4:], tuple(reversed(core.FOUR_ARM_ORDERS[:4])))

    def test_three_arm_fallback_is_balanced(self):
        self.check_balance(core.THREE_ARM_ORDERS, 3)
        self.assertEqual(len(set(core.THREE_ARM_ORDERS)), 6)

    def test_undeclared_arm_sets_are_refused(self):
        with self.assertRaises(ValueError):
            core.orders_for(("O", "L"))

    def test_p95_is_nearest_rank_2849(self):
        self.assertEqual(core.P95_INDEX, 2849)


class BootstrapTests(unittest.TestCase):
    def test_reproduces_2026_10_10_confirmation_exactly(self):
        # analysis.json of Results/2026-10-10-resumable-confirmation (read-only worktree).
        values = [14.56979923910331, 18.237635296564264, 14.08126941668497, 14.477860875821365,
                  13.48256595394256, 13.331040871699324, 13.34231502116217, 16.31683956626867]
        self.assertEqual(core.bootstrap(values), [13.34231502116217, 16.31683956626867])

    def test_screens(self):
        series = series_for()
        blocks = []
        for block, order in enumerate(core.FOUR_ARM_ORDERS, 1):
            cpu = dict(O=0.29, S=0.145, S4=0.12, L=0.149)
            gpu = dict(O=1.26, S=1.28, S4=1.28, L=1.47)
            summaries = {a: dict(cpuEncodeP95Ms=cpu[a] + block * 1e-4, gpuP95Ms=gpu[a], submitP95Ms=0.3)
                         for a in order}
            blocks.append(dict(block=block, attempt=1, order=list(order), summaries=summaries))
        result = core.analyze(blocks, series["arms"])
        self.assertEqual(result["screens"], dict(S_cpu_parity=True, S_gpu_regression_within_3pct=True,
                                                 S4_cpu_below_L=True))
        self.assertFalse(result["cpuGpuSummed"])
        self.assertAlmostEqual(result["comparisons"]["S_vs_O_gpu"]["median"], 100 * (1.28 - 1.26) / 1.26)
        blocks[0]["summaries"]["S"]["gpuP95Ms"] = 2.0
        for b in blocks[1:5]:
            b["summaries"]["S"]["gpuP95Ms"] = 1.31
        self.assertFalse(core.analyze(blocks, series["arms"])["screens"]["S_gpu_regression_within_3pct"])

    def test_q2a_needs_a_positive_lower_bound_not_just_a_nonnegative_median(self):
        series = series_for()
        blocks = []
        # S beats L in half the blocks and loses in the rest: median >= 0, lower bound <= 0.
        for block, order in enumerate(core.FOUR_ARM_ORDERS, 1):
            cpu = dict(O=0.29, S=0.140 if block % 2 else 0.150, S4=0.12, L=0.149)
            summaries = {a: dict(cpuEncodeP95Ms=cpu[a], gpuP95Ms=1.3, submitP95Ms=0.3) for a in order}
            blocks.append(dict(block=block, attempt=1, order=list(order), summaries=summaries))
        result = core.analyze(blocks, series["arms"])
        self.assertGreaterEqual(result["comparisons"]["S_vs_L_cpu"]["median"], 0)
        self.assertLessEqual(result["comparisons"]["S_vs_L_cpu"]["bootstrap95CI"][0], 0)
        self.assertFalse(result["screens"]["S_cpu_parity"])

    def q3_blocks(self, cpu, submit):
        blocks = []
        for block, order in enumerate(core.FOUR_ARM_ORDERS, 1):
            summaries = {a: dict(cpuEncodeP95Ms=cpu[a] + block * 1e-4, gpuP95Ms=1.3, submitP95Ms=submit[a])
                         for a in order}
            blocks.append(dict(block=block, attempt=1, order=list(order), summaries=summaries))
        return blocks

    def test_q3_label_requires_a_paired_submit_win(self):
        cpu = dict(O=0.29, S=0.145, S4=0.12, L=0.149)
        win = core.analyze(self.q3_blocks(cpu, dict(O=0.4, S=0.3, S4=0.2, L=0.25)), ARMS4)
        self.assertTrue(win["screens"]["S4_cpu_below_L"])
        self.assertEqual(win["comparisons"]["S4_vs_L_submit"]["metric"], "submitP95Ms")
        self.assertAlmostEqual(win["comparisons"]["S4_vs_L_submit"]["median"], 100 * (0.25 - 0.2) / 0.25)
        self.assertEqual(win["S4_q3_label"], "cpu_win")
        # Encode call below L, but begin/end/commit moved the work: never a CPU win.
        moved = core.analyze(self.q3_blocks(cpu, dict(O=0.4, S=0.3, S4=0.3, L=0.25)), ARMS4)
        self.assertTrue(moved["screens"]["S4_cpu_below_L"])
        self.assertEqual(moved["S4_q3_label"], "encode_call_win_only")
        tie = core.analyze(self.q3_blocks(cpu, dict(O=0.4, S=0.3, S4=0.25, L=0.25)), ARMS4)
        self.assertEqual(tie["S4_q3_label"], "encode_call_win_only")
        failed = core.analyze(self.q3_blocks(dict(cpu, S4=0.2), dict(O=0.4, S=0.3, S4=0.1, L=0.25)), ARMS4)
        self.assertFalse(failed["screens"]["S4_cpu_below_L"])
        self.assertEqual(failed["S4_q3_label"], "fail")

    def test_q3_label_uses_paired_values_not_marginal_medians(self):
        # Paired submit reductions are 4 x +50% and 4 x -20%: median +15% > 0, although the marginal
        # median of S4's submit p95 (0.625) is above L's (0.55). The label follows the paired estimate.
        cpu = dict(O=0.29, S=0.145, S4=0.12, L=0.149)
        blocks = self.q3_blocks(cpu, dict(O=0.4, S=0.3, S4=0.2, L=0.25))
        for b in blocks[:4]:
            b["summaries"]["L"]["submitP95Ms"], b["summaries"]["S4"]["submitP95Ms"] = 0.1, 0.05
        for b in blocks[4:]:
            b["summaries"]["L"]["submitP95Ms"], b["summaries"]["S4"]["submitP95Ms"] = 1.0, 1.2
        result = core.analyze(blocks, ARMS4)
        self.assertGreater(result["comparisons"]["S4_vs_L_submit"]["median"], 0)
        self.assertGreater(result["marginalMediansMs"]["S4"]["submitP95Ms"],
                           result["marginalMediansMs"]["L"]["submitP95Ms"])
        self.assertEqual(result["S4_q3_label"], "cpu_win")

    def test_three_arm_fallback_reports_q3_not_run(self):
        blocks = [dict(block=i, attempt=1, order=list(o),
                       summaries={a: dict(cpuEncodeP95Ms=dict(O=0.29, S=0.145, L=0.149)[a], gpuP95Ms=1.3,
                                          submitP95Ms=0.3) for a in o})
                  for i, o in enumerate(core.THREE_ARM_ORDERS, 1)]
        result = core.analyze(blocks, ("O", "S", "L"))
        self.assertEqual(result["S4_q3_label"], "not_run")
        self.assertNotIn("S4_vs_L_submit", result["comparisons"])
        self.assertIn("drained single-buffer regime", result["limitation"])

    def test_incomplete_series_is_not_analyzed(self):
        with self.assertRaises(ValueError):
            core.analyze([], ARMS4)


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.series = series_for()

    def test_valid_leg_summarizes_measured_rows_only(self):
        summary = core.audit_leg(leg_report(self.series, 1, 1, "S"), self.series, 1, 1, "S")
        # Measured jitter is (i % 100)/1e5 s; nearest-rank p95 of 3000 rows lands on jitter 0.94 ms*1e-2.
        self.assertAlmostEqual(summary["cpuEncodeP95Ms"], 0.2 + 0.94, places=6)
        self.assertGreater(summary["gpuP95Ms"], summary["cpuEncodeP95Ms"])

    def assert_rejected(self, reason, mutate, arm="S"):
        with self.assertRaises(core.AuditFailure) as caught:
            core.audit_leg(leg_report(self.series, 1, 1, arm, mutate=mutate), self.series, 1, 1, arm)
        self.assertEqual(caught.exception.reason, reason)

    def test_partial_rows_are_never_filtered(self):
        self.assert_rejected("contract", lambda r: r["rows"].pop())

    def test_environment_violation_anywhere(self):
        self.assert_rejected("contract", lambda r: r["rows"][2500]["after"].update(thermal=1))

    def test_output_guard_mismatch_is_quality(self):
        self.assert_rejected("quality", lambda r: r["outputSHA256After"].update({SPHERES[0]: "0" * 64}))

    def test_wrong_series_is_identity(self):
        self.assert_rejected("identity", lambda r: r.update(seriesSHA256="f" * 64))

    def test_other_build_is_identity(self):
        self.assert_rejected("identity", lambda r: r.update(appExecutableSHA256="e" * 64))
        self.assert_rejected("identity", lambda r: r.update(metallibSHA256="e" * 64))
        self.assert_rejected("identity", lambda r: r.pop("metallibSHA256"))

    def test_debug_build_is_identity(self):
        self.assert_rejected("identity", lambda r: r.update(debugBuild=True))
        self.assert_rejected("identity", lambda r: r.pop("debugBuild"))

    def test_overlapping_rows_are_timestamps(self):
        def overlap(r):
            r["rows"][10]["timing"]["submitStart"] = r["rows"][9]["timing"]["gpuStart"]
        self.assert_rejected("timestamps", overlap)

    def test_mps_must_use_usage_3(self):
        self.assert_rejected("contract", lambda r: r.update(outputTextureUsage=5), arm="L")

    def test_short_cooling(self):
        self.assert_rejected("contract", lambda r: r["cooling"].update(nominalContinuousSeconds=19.9))

    def test_qualification_gate(self):
        self.assertEqual(core.audit_qualification(qualification_report(), True, BUILD)["arms"], ["O", "S", "L", "S4"])
        with self.assertRaises(core.AuditFailure):
            core.audit_qualification(qualification_report(worst=2), True, BUILD)
        with self.assertRaises(core.AuditFailure):
            core.audit_qualification(qualification_report(photos=False), True, BUILD)
        with self.assertRaises(core.AuditFailure):
            core.audit_qualification(qualification_report(arms=("O", "S", "L")), True, BUILD)
        core.audit_qualification(qualification_report(arms=("O", "S", "L")), False, BUILD)

    def assert_qualification_rejected(self, reason, mutate):
        report = json.loads(json.dumps(qualification_report()))
        mutate(report)
        with self.assertRaises(core.AuditFailure) as caught:
            core.audit_qualification(report, True, BUILD)
        self.assertEqual(caught.exception.reason, reason)

    def test_qualification_requires_the_frozen_release_build(self):
        self.assert_qualification_rejected("identity", lambda r: r.update(appExecutableSHA256="e" * 64))
        self.assert_qualification_rejected("identity", lambda r: r.update(metallibSHA256="e" * 64))
        self.assert_qualification_rejected("identity", lambda r: r.update(debugBuild=True))
        with self.assertRaises(core.AuditFailure) as caught:
            core.audit_qualification(qualification_report(), True, dict(BUILD, metallibSHA256="e" * 64))
        self.assertEqual(caught.exception.reason, "identity")

    def test_qualification_timing_smoke_uses_the_leg_row_audit(self):
        def misordered(r):  # e.g. a commit-feedback clock in another domain than CACurrentMediaTime
            r["timingSmoke"]["S4"]["rows"][5]["timing"]["gpuStart"] = 1e9
        self.assert_qualification_rejected("timestamps", misordered)
        self.assert_qualification_rejected("contract", lambda r: r["timingSmoke"]["S4"]["rows"].pop())
        self.assert_qualification_rejected("contract", lambda r: r["timingSmoke"].pop("S4"))
        self.assert_qualification_rejected("contract", lambda r: r["timingSmoke"]["L"]["rows"][3]["after"].update(
            foreground=False))
        self.assert_qualification_rejected("contract", lambda r: r["timingSmoke"]["L"].update(outputTextureUsage=5))
        self.assert_qualification_rejected("contract", lambda r: r["timingSmoke"]["O"]["rows"][0].update(
            phase="measured"))
        self.assert_qualification_rejected("contract", lambda r: r["timingSmokeCooling"].update(noEncodes=False))
        self.assert_qualification_rejected("contract", lambda r: r.pop("timingSmokeCooling"))

    def test_qualification_smoke_is_excluded_from_the_receipt(self):
        receipt = core.audit_qualification(qualification_report(), True, BUILD)
        self.assertNotIn("timingSmoke", receipt)
        self.assertEqual(receipt["timingSmokeRows"], core.SMOKE_ROWS)


class FakeDevice:
    """Stands in for devicectl at the `Device` method level; never launches anything."""

    def __init__(self, series, root, failures=None):
        self.series, self.root, self.failures, self.calls = series, Path(root), failures or {}, []

    def preflight(self, folder):
        self.calls.append(("preflight", str(folder)))
        reason = self.failures.pop(("preflight", Path(folder).parent.name, Path(folder).name), None)
        if reason:
            raise core.AuditFailure(reason, "fake")

    def launch(self, arguments, folder):
        self.calls.append(("launch", arguments))
        values = dict(zip(arguments[1::2], arguments[2::2]))
        self.pending = (int(values["--cpu-encode-block"]), int(values["--cpu-encode-attempt"]), values["--cpu-encode-arm"])
        return 0, f"CPUEncodeBenchmark-{str(uuid.uuid4()).upper()}"

    def copy_report(self, remote, destination):
        block, attempt, arm = self.pending
        cpu = dict(O=0.29, S=0.145, S4=0.12, L=0.149)[arm]
        gpu = dict(O=1.26, S=1.27, S4=1.27, L=1.47)[arm]
        mutate = self.failures.pop(("report", block, attempt, arm), None)
        report = leg_report(self.series, block, attempt, arm, cpu, gpu, mutate)
        Path(destination).write_text(json.dumps(report))
        return report


class JournalAndDriverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.series = series_for()
        self.journal = core.Journal(self.root)
        self.journal.append("freeze", series=self.series)
        driver.verify_frozen = lambda state: None  # tool/protocol hashes are covered by freeze tests

    def tearDown(self):
        self.temp.cleanup()

    def test_full_series_then_analysis(self):
        device = FakeDevice(self.series, self.root)
        for _ in range(8):
            self.assertTrue(driver.run_block(self.root, device)["completed"])
        state = self.journal.state()
        self.assertEqual(state["stopped"], "complete")
        result = driver.analyze(self.root)
        self.assertTrue(all(result["screens"].values()))
        self.assertTrue((self.root / "analysis.json").exists())
        self.assertFalse(any("terminate" in " ".join(map(str, c[1])) for c in device.calls if c[0] == "launch"))
        with self.assertRaises(ValueError):
            driver.run_block(self.root, device)

    def test_preflight_failure_is_an_excluded_attempt_and_retry_needs_authorization(self):
        device = FakeDevice(self.series, self.root, {("preflight", "b01-a01", "O"): "preflight"})
        result = driver.run_block(self.root, device)
        self.assertEqual((result["completed"], result["reason"]), (False, "preflight"))
        self.assertTrue((self.root / "attempts/b01-a01/O").is_dir())
        with self.assertRaises(ValueError):
            driver.run_block(self.root, device)
        self.assertTrue(driver.run_block(self.root, device, authorization="да, повтори блок 1")["completed"])
        state = self.journal.state()
        self.assertEqual(len(state["failures"]), 1)
        self.assertEqual(state["completed"][0]["attempt"], 2)

    def test_second_retryable_failure_stops_series(self):
        failures = {("preflight", "b01-a01", "O"): "thermal", ("preflight", "b01-a02", "O"): "thermal"}
        device = FakeDevice(self.series, self.root, failures)
        driver.run_block(self.root, device)
        driver.run_block(self.root, device, authorization="да")
        self.assertEqual(self.journal.state()["stopped"], "retry budget exhausted")
        with self.assertRaises(ValueError):
            driver.analyze(self.root)

    def test_quality_failure_is_fatal(self):
        def bad(r):
            r["outputSHA256After"] = {k: "0" * 64 for k in r["outputSHA256After"]}
        device = FakeDevice(self.series, self.root, {("report", 1, 1, "S"): bad})
        self.assertEqual(driver.run_block(self.root, device)["reason"], "quality")
        self.assertEqual(self.journal.state()["stopped"], "fatal")

    def test_native_environment_failure_is_retryable(self):
        def background(r):
            r.update(completed=False, failure="environment(background)", failureReason="background")
        device = FakeDevice(self.series, self.root, {("report", 1, 1, "O"): background})
        self.assertEqual(driver.run_block(self.root, device)["reason"], "background")
        self.assertEqual(self.journal.state()["attempt"], 2)

    def test_native_thermal_rise_during_a_leg_is_thermal(self):
        def thermal(r):
            r.update(completed=False, failure="environment(thermal)", failureReason="thermal")
        device = FakeDevice(self.series, self.root, {("report", 1, 1, "O"): thermal})
        self.assertEqual(driver.run_block(self.root, device)["reason"], "thermal")
        self.assertEqual(self.journal.state()["attempt"], 2)

    def test_native_failure_reasons_map_faithfully(self):
        cases = dict(thermal="thermal", thermalDeadline="thermal", background="background", lowPower="lowPower",
                     timestamp="timestamps", metal="contract", other="contract")
        for native, reason in cases.items():
            self.assertEqual(driver.native_failure_reason(dict(failureReason=native)), reason, native)
        self.assertEqual(driver.native_failure_reason(dict(failure="environment")), "contract")
        self.assertIn("lowPower", core.RETRYABLE)
        self.assertIn("timestamps", core.FATAL)

    def test_crash_mid_attempt_needs_explicit_recovery(self):
        self.journal.append("begin", block=1, attempt=1, order=list(core.FOUR_ARM_ORDERS[0]), authorization=None)
        with self.assertRaises(ValueError):
            driver.run_block(self.root, FakeDevice(self.series, self.root))
        driver.recover(self.root, "host crashed")
        self.assertEqual(self.journal.state()["failures"][0]["reason"], "interrupted")

    def test_tampering_breaks_the_chain(self):
        driver.run_block(self.root, FakeDevice(self.series, self.root))
        lines = self.journal.path.read_text().splitlines()
        entry = json.loads(lines[2])
        entry["summary"]["cpuEncodeP95Ms"] = 0.001
        lines[2] = json.dumps(entry, sort_keys=True)
        self.journal.path.write_text("\n".join(lines) + "\n")
        with self.assertRaises(ValueError):
            self.journal.state()

    def test_out_of_order_leg_is_rejected(self):
        self.journal.append("begin", block=1, attempt=1, order=list(core.FOUR_ARM_ORDERS[0]), authorization=None)
        self.journal.append("leg", block=1, attempt=1, arm="L", reportSHA256="0" * 64, summary={})
        with self.assertRaises(ValueError):
            self.journal.state()


class FreezeTests(unittest.TestCase):
    def test_freeze_requires_installed_build_conditions_and_clean_tree(self):
        with tempfile.TemporaryDirectory() as temp:
            root, app = Path(temp) / "series", Path(temp) / "DualKawaseBlurDemo.app"
            (app / "DualKawaseBlur_DualKawaseBlur.bundle").mkdir(parents=True)
            (app / "DualKawaseBlurDemo").write_bytes(b"exe")
            (app / "DualKawaseBlur_DualKawaseBlur.bundle/default.metallib").write_bytes(b"lib")
            root.mkdir()
            qualification = Path(temp) / "q.json"
            qualification.write_text(json.dumps(qualification_report()))
            driver.save_new(Path(temp) / "launch-result.json",
                            dict(exitCode=0, remoteFolder="x", reportSHA256=driver.sha_file(qualification)))
            conditions = Path(temp) / "c.json"
            conditions.write_text(json.dumps(dict(userQuote="да", brightnessApproxPercent=50, autoBrightness=False,
                lowPower=False, deviceConnection="wired USB", chargingPolicy="same USB throughout",
                foregroundMaintained=True, settingsHeldConstant=True)))
            with self.assertRaises(ValueError):  # not installed through `install`
                driver.freeze(root, "DEVICE", app, qualification, conditions, True, revision=("abc", False))
            driver.save_new(root / "install-x.json", dict(driver.app_identity(app), device="DEVICE"))
            with self.assertRaises(ValueError):
                driver.freeze(root, "DEVICE", app, qualification, conditions, True, revision=("abc", True))
            series = driver.freeze(root, "DEVICE", app, qualification, conditions, True, revision=("abc", False))
            self.assertEqual(series["orders"], [list(o) for o in core.FOUR_ARM_ORDERS])
            self.assertEqual({k: series[k] for k in BUILD}, BUILD)
            self.assertEqual(series["qualificationExitCode"], 0)
            self.assertEqual(series["referenceComparison"], dict(available=False, path="None"))
            body = {k: v for k, v in series.items() if k != "seriesSHA256"}
            self.assertEqual(series["seriesSHA256"], core.digest(core.canonical(body)))
            with self.assertRaises(ValueError):
                driver.freeze(root, "DEVICE", app, qualification, conditions, True, revision=("abc", False))


class FreezeGuardTests(unittest.TestCase):
    """freeze refuses a qualification whose launch did not exit 0, or whose build is not this app."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        temp = Path(self.temp.name)
        self.root, self.app = temp / "series", temp / "DualKawaseBlurDemo.app"
        (self.app / "DualKawaseBlur_DualKawaseBlur.bundle").mkdir(parents=True)
        (self.app / "DualKawaseBlurDemo").write_bytes(b"exe")
        (self.app / "DualKawaseBlur_DualKawaseBlur.bundle/default.metallib").write_bytes(b"lib")
        self.root.mkdir()
        driver.save_new(self.root / "install-x.json", dict(driver.app_identity(self.app), device="DEVICE"))
        self.folder = self.root / "qualification" / "q1"
        self.folder.mkdir(parents=True)
        self.qualification = self.folder / "report.json"
        self.conditions = temp / "c.json"
        self.conditions.write_text(json.dumps(dict(userQuote="да", brightnessApproxPercent=50, autoBrightness=False,
            lowPower=False, deviceConnection="wired USB", chargingPolicy="same USB throughout",
            foregroundMaintained=True, settingsHeldConstant=True)))

    def tearDown(self):
        self.temp.cleanup()

    def write(self, report, exit_code=0, sha=None):
        self.qualification.write_text(json.dumps(report))
        (self.folder / "launch-result.json").unlink(missing_ok=True)
        driver.save_new(self.folder / "launch-result.json", dict(exitCode=exit_code, remoteFolder="x",
                        reportSHA256=sha or driver.sha_file(self.qualification)))

    def freeze(self, **kwargs):
        return driver.freeze(self.root, "DEVICE", self.app, self.qualification, self.conditions, True,
                             revision=("abc", False), **kwargs)

    def test_nonzero_qualification_exit_is_refused(self):
        self.write(qualification_report(), exit_code=2)
        with self.assertRaisesRegex(ValueError, "exited 2"):
            self.freeze()
        self.assertFalse(core.Journal(self.root).entries())

    def test_missing_or_foreign_launch_record_is_refused(self):
        self.qualification.write_text(json.dumps(qualification_report()))
        with self.assertRaisesRegex(ValueError, "launch-result"):
            self.freeze()
        self.write(qualification_report(), sha="0" * 64)
        with self.assertRaisesRegex(ValueError, "different report"):
            self.freeze()

    def test_qualification_from_another_build_is_refused(self):
        self.write(dict(qualification_report(), appExecutableSHA256="e" * 64))
        with self.assertRaises(core.AuditFailure) as caught:
            self.freeze()
        self.assertEqual(caught.exception.reason, "identity")

    def test_failed_timing_smoke_is_refused(self):
        report = qualification_report()
        report["timingSmoke"]["S4"]["rows"][7]["timing"]["gpuEnd"] = -1.0
        self.write(report)
        with self.assertRaises(core.AuditFailure) as caught:
            self.freeze()
        self.assertEqual(caught.exception.reason, "timestamps")

    def test_reference_hashes_are_disclosed_never_gating(self):
        report = qualification_report()
        self.write(report)
        reference = Path(self.temp.name) / "reference.json"
        o = dict(report["expectedOutputSHA256"]["O"])
        m = dict(report["expectedOutputSHA256"]["L"], **{SPHERES[2]: "0" * 64})
        reference.write_text(json.dumps(dict(expectedOutputSHA256=dict(O=o, M=m))))
        series = self.freeze(reference=reference)
        comparison = series["referenceComparison"]
        self.assertTrue(comparison["available"])
        self.assertEqual(comparison["referenceSHA256"], driver.sha_file(reference))
        self.assertEqual(comparison["arms"]["O"], dict(referenceArm="O", matching=8, compared=8, mismatched=[]))
        self.assertEqual(comparison["arms"]["L"], dict(referenceArm="M", matching=7, compared=8,
                                                       mismatched=[SPHERES[2]]))

    def test_reference_receipt_shape_matches_2026_10_10(self):
        # The real receipt (read-only worktree) keys MPS as "M"; skipped where that worktree is absent.
        if not driver.REFERENCE_QUALIFICATION.is_file():
            self.skipTest("2026-10-10 receipt not present")
        expected = json.loads(driver.REFERENCE_QUALIFICATION.read_text())["expectedOutputSHA256"]
        for ref_arm in driver.REFERENCE_ARMS.values():
            self.assertEqual(sorted(expected[ref_arm]), SPHERES)


class LaunchTimeoutTests(unittest.TestCase):
    def test_devicectl_outlasts_the_cooling_cap_and_the_host_outlasts_devicectl(self):
        seen = []

        def runner(arguments, timeout):
            seen.append((arguments, timeout))
            return 0, "CPU_ENCODE_REPORT CPUEncodeBenchmark-" + str(uuid.uuid4()).upper() + "\n"

        with tempfile.TemporaryDirectory() as temp:
            driver.Device("DEVICE", runner).launch([], temp)
        arguments, host_timeout = seen[0]
        devicectl_timeout = int(arguments[arguments.index("--timeout") + 1])
        self.assertGreaterEqual(devicectl_timeout, 600)
        self.assertGreaterEqual(devicectl_timeout, 2 * core.COOLING_CAP_SECONDS)
        self.assertGreaterEqual(host_timeout, devicectl_timeout + 30)


class QualifyTests(unittest.TestCase):
    def test_qualify_keeps_the_exit_code_beside_the_report(self):
        class Fake:
            def preflight(self, folder):
                pass

            def launch(self, arguments, folder):
                return 2, "CPUEncodeBenchmark-X"

            def copy_report(self, remote, destination):
                Path(destination).write_text(json.dumps(qualification_report()))
                return qualification_report()

        with tempfile.TemporaryDirectory() as temp:
            path, code, _ = driver.qualify(Fake(), temp)
            launch = json.loads((path.parent / "launch-result.json").read_text())
            self.assertEqual((code, launch["exitCode"], launch["reportSHA256"]), (2, 2, driver.sha_file(path)))
            with self.assertRaisesRegex(ValueError, "exited 2"):
                driver.qualification_launch(path)


class GitStateTests(unittest.TestCase):
    def test_series_root_is_ignored_but_untracked_sources_are_dirty(self):
        import subprocess
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp).resolve()
            run = lambda *a: subprocess.run(["git", "-C", str(repo)] + list(a), check=True, capture_output=True)
            run("init", "-q")
            (repo / "DualKawaseBlur").mkdir()
            (repo / "DualKawaseBlur/a.swift").write_text("let a = 1\n")
            run("add", ".")
            run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")
            saved = driver.WORKSPACE
            driver.WORKSPACE = repo
            try:
                root = repo / "DualKawaseBlur/Benchmarks/Results/series"
                root.mkdir(parents=True)
                (root / "install-x.json").write_text("{}")
                self.assertFalse(driver.git_revision(root)[1])
                (repo / "DualKawaseBlur/b.swift").write_text("let b = 2\n")
                self.assertTrue(driver.git_revision(root)[1])
            finally:
                driver.WORKSPACE = saved


class DeviceWrapperTests(unittest.TestCase):
    def test_preflight_refuses_a_transport_other_than_the_series_transport(self):
        def runner(arguments, timeout):
            output = Path(arguments[arguments.index("--json-output") + 1])
            result = dict(connectionProperties=dict(transportType="wired", tunnelState="connected"),
                          hardwareProperties=dict(reality="physical"))
            output.write_text(json.dumps(dict(info=dict(outcome="success"), result=result)))
            return 0, ""

        self.assertEqual(driver.SERIES_TRANSPORT, "localNetwork")
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(core.AuditFailure) as caught:
                driver.Device("DEVICE", runner).preflight(temp)
        self.assertEqual(caught.exception.reason, "connection")

    def test_preflight_refuses_running_demo_and_never_terminates(self):
        calls = []

        def runner(arguments, timeout):
            calls.append(arguments)
            output = Path(arguments[arguments.index("--json-output") + 1])
            result = dict(connectionProperties=dict(transportType=driver.SERIES_TRANSPORT, tunnelState="connected"),
                          hardwareProperties=dict(reality="physical"), passcodeRequired=False,
                          runningProcesses=[dict(executable="file:///private/var/containers/Bundle/Application/X/"
                                                            "DualKawaseBlurDemo.app/DualKawaseBlurDemo")])
            output.write_text(json.dumps(dict(info=dict(outcome="success"), result=result)))
            return 0, ""

        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(core.AuditFailure) as caught:
                driver.Device("DEVICE", runner).preflight(temp)
        self.assertEqual(caught.exception.reason, "preflight")
        self.assertFalse(any("terminate" in a for call in calls for a in call))

    def test_launch_parses_exactly_one_marker(self):
        folder = "CPUEncodeBenchmark-" + str(uuid.uuid4()).upper()
        with tempfile.TemporaryDirectory() as temp:
            device = driver.Device("DEVICE", lambda a, t: (0, f"noise\nCPU_ENCODE_REPORT {folder}\n"))
            self.assertEqual(device.launch([], temp), (0, folder))
            twice = driver.Device("DEVICE", lambda a, t: (0, f"CPU_ENCODE_REPORT {folder}\nCPU_ENCODE_REPORT {folder}\n"))
            with self.assertRaises(core.AuditFailure):
                twice.launch([], temp)
            timeout = driver.Device("DEVICE", lambda a, t: (124, ""))
            with self.assertRaises(core.AuditFailure) as caught:
                timeout.launch([], temp)
            self.assertEqual(caught.exception.reason, "timeout")


class CorpusTests(unittest.TestCase):
    def test_raw_deflate_round_trip(self):
        data = bytes(range(256)) * 1000
        self.assertEqual(prepare_corpus.inflate(prepare_corpus.deflate(data)), data)

    def test_bundled_manifest_matches_bundled_resources(self):
        folder = prepare_corpus.APP_RESOURCES
        manifest = json.loads((folder / prepare_corpus.MANIFEST_NAME).read_text())
        self.assertEqual(manifest["sourceManifestSHA256"], prepare_corpus.SOURCE_MANIFEST_SHA256)
        self.assertEqual(manifest["primarySequence"], SPHERES)
        bundled = [r for r in manifest["records"] if r["bundled"]]
        self.assertEqual(len(bundled), 14)
        self.assertEqual({r["kind"] for r in manifest["records"] if not r["bundled"]}, {"photo"})
        for record in bundled:
            packed = (folder / record["resource"]).read_bytes()
            self.assertEqual(core.digest(packed), record["resourceSHA256"])
            raw = prepare_corpus.inflate(packed)
            self.assertEqual((len(raw), core.digest(raw)), (record["bytes"], record["sha256"]))



# ---------------------------------------------------------------------------------------------
# path-level-v2 (PATH_LEVEL_PROTOCOL.md). Everything above is v1 and stays as frozen.

from itertools import permutations  # noqa: E402

PATH_ARMS = ("LC", "SC", "SH")


def path_blocks(cpu, gpu, submit=None, scale=None):
    """Synthetic complete v2 blocks in the fixed orders; `scale(block, arm)` perturbs a block."""
    blocks = []
    for block, order in enumerate(core.PATH_ORDERS, 1):
        summaries = {}
        for arm in order:
            factor = scale(block, arm) if scale else 1.0
            summaries[arm] = dict(cpuEncodeP95Ms=cpu[arm] * factor + block * 1e-4, gpuP95Ms=gpu[arm] * factor,
                                  submitP95Ms=(submit or dict(LC=0.6, SC=0.5, SH=0.45))[arm])
        blocks.append(dict(block=block, attempt=1, order=list(order), summaries=summaries))
    return blocks


class PathLevelDesignTests(unittest.TestCase):
    def test_path_level_orders_are_balanced(self):
        orders = core.PATH_ORDERS
        self.assertEqual(core.orders_for(PATH_ARMS), orders)
        self.assertEqual(len(orders), 8)
        # Blocks 1-6 are all six orders of three arms once; blocks 7-8 mirror blocks 1-2.
        self.assertEqual(set(orders[:6]), set(permutations(PATH_ARMS)))
        self.assertEqual((orders[6], orders[7]), (orders[1], orders[0]))
        self.assertEqual(orders[0], ("LC", "SC", "SH"))
        # Positions 1/2/3: every arm holds every position 2 or 3 times.
        positions = {arm: tuple(sum(o[p] == arm for o in orders) for p in range(3)) for arm in PATH_ARMS}
        self.assertEqual(positions, dict(LC=(3, 3, 2), SC=(2, 3, 3), SH=(3, 2, 3)))
        precedes = lambda x, y: sum(o.index(x) < o.index(y) for o in orders)
        self.assertEqual((precedes("SH", "LC"), precedes("SH", "SC"), precedes("LC", "SC")), (4, 4, 5))
        follows = Counter((o[i], o[i + 1]) for o in orders for i in range(2))
        self.assertEqual(follows, Counter({("LC", "SC"): 4, ("SH", "LC"): 3, ("SC", "SH"): 3,
                                           ("SC", "LC"): 2, ("LC", "SH"): 2, ("SH", "SC"): 2}))


class PathLevelScreenTests(unittest.TestCase):
    def test_path_level_screens(self):
        cpu, gpu = dict(LC=0.5, SC=0.42, SH=0.4), dict(LC=2.0, SC=1.6, SH=1.4)
        # SH beats LC by 30% GPU and 20% CPU in every block: P1 and P2 pass.
        result = core.analyze(path_blocks(cpu, gpu), PATH_ARMS)
        self.assertEqual(result["protocolID"], core.PATH_PROTOCOL)
        c = result["comparisons"]
        self.assertAlmostEqual(c["SH_vs_LC_gpu"]["median"], 30.0)
        self.assertAlmostEqual(c["SH_vs_LC_cpu"]["median"], 20.0, delta=0.1)
        self.assertEqual(result["screens"], dict(P1_SH_gpu_below_LC=True, P2_SH_cpu_below_LC=True))
        # P3 and the rest are descriptive only: computed, never a screen.
        self.assertEqual(set(c), {"SH_vs_LC_gpu", "SH_vs_LC_cpu", "SH_vs_SC_gpu", "SC_vs_LC_gpu", "SC_vs_LC_cpu",
                                  "SH_vs_SC_cpu", "SH_vs_LC_submit"})
        self.assertEqual(result["descriptiveOnly"], ["SH_vs_SC_gpu", "SC_vs_LC_gpu", "SC_vs_LC_cpu", "SH_vs_SC_cpu",
                                                     "SH_vs_LC_submit"])
        self.assertFalse(result["cpuGpuSummed"])
        # SH wins 30% in four blocks and loses 10% in four: median > 0 but the lower bound is not > 0.
        lose = lambda block, arm: (1.0 if block % 2 else 2.2 / 1.4) if arm == "SH" else 1.0
        mixed = core.analyze(path_blocks(cpu, gpu, scale=lose), PATH_ARMS)
        p1 = mixed["comparisons"]["SH_vs_LC_gpu"]
        self.assertGreater(p1["median"], 0)
        self.assertLessEqual(p1["bootstrap95CI"][0], 0)
        self.assertFalse(mixed["screens"]["P1_SH_gpu_below_LC"])



# The real v1 `verify_frozen`, captured at import: JournalAndDriverTests.setUp stubs the module attribute.
REAL_VERIFY_FROZEN = driver.verify_frozen
V1_SERIES_ROOT = HERE.parents[1] / "Results/2026-10-22-cpu-encode"


def path_common(method):
    """The fields every v2 report carries, as the app's JSONEncoder writes them (1.0 encodes as 1)."""
    return dict(method=method, protocolID=core.PATH_PROTOCOL, width=1179, height=2556, pixelFormat="bgra8Unorm",
        iterations=5, offset=5, sigma=core.SIGMA, mpsOptions="allowReducedPrecision", endToEndMeasured=False,
        automaticPromotion=False, processSessionUUID=str(uuid.uuid4()), s4Compiled=False, debugBuild=False, **BUILD,
        compositeBaseColor=[0.25, 0.5, 0.75, 1], compositeMapping="unit")


def path_qualification_report(worst_sh=1, worst_lc=9, photos=True):
    names = [c["fixture"] for c in qualification_report()["checks"]]
    checks = [dict(fixture=n, sourceSHA256=core.digest(n.encode()),
                   outputSHA256={a: core.digest(f"{a}{n}".encode()) for a in PATH_ARMS},
                   differenceVersusSC=dict(LC=worst_lc if i == 3 else 0, SH=worst_sh if i == 3 else 0))
              for i, n in enumerate(names)]
    smoke = {}
    for arm in PATH_ARMS:
        rows, start, end = timed_rows(["smoke"] * core.SMOKE_ROWS)
        smoke[arm] = dict(pathOutput=core.path_output(arm), timingStart=start, timingEnd=end, rows=rows)
    return json.loads(json.dumps(dict(path_common(core.PATH_QUALIFICATION_METHOD), sessionLabel="qualification",
        completed=True, failure=None, arms=list(PATH_ARMS), photoFixturesIncluded=photos, checks=checks,
        shQualityPassed=worst_sh <= 1, expectedOutputSHA256={a: hashes(a) for a in PATH_ARMS},
        corpusManifestSHA256="c" * 64, hardware="iPhone17,3", os="Version 27.0.1", gpu="Apple A18 GPU",
        timingSmokeCooling=cooling(), timingSmoke=smoke)))


def path_series_for(transport="wired"):
    receipt = core.audit_path_qualification(path_qualification_report(), BUILD)
    series = dict(protocolID=core.PATH_PROTOCOL, qualification=receipt, arms=list(PATH_ARMS),
                  orders=[list(o) for o in core.PATH_ORDERS], device="DEVICE", transport=transport, **BUILD)
    series["seriesSHA256"] = core.digest(core.canonical(series))
    return series


def path_leg_report(series, block, attempt, arm, cpu_ms=0.4, gpu_ms=1.4, mutate=None):
    rows, start, end = timed_rows(["warmup"] * core.WARMUP + ["measured"] * core.MEASURED, cpu_ms, gpu_ms)
    receipt = series["qualification"]
    report = dict(path_common(core.PATH_LEG_METHOD), arm=arm, block=block, attempt=attempt,
        seriesSHA256=series["seriesSHA256"], sessionLabel=f"b{block:02d}-a{attempt:02d}-{arm}", completed=True,
        failure=None, warmupCount=1000, measuredCount=3000, pathOutput=core.path_output(arm),
        corpusManifestSHA256=receipt["corpusManifestSHA256"], hardware=receipt["hardware"], os=receipt["os"],
        gpu=receipt["gpu"], cooling=cooling(), outputSHA256Before=dict(receipt["expectedOutputSHA256"][arm]),
        outputSHA256After=dict(receipt["expectedOutputSHA256"][arm]), timingStart=start, timingEnd=end, rows=rows)
    report = json.loads(json.dumps(report))
    if mutate:
        mutate(report)
    return report


class PathLevelAuditTests(unittest.TestCase):
    def setUp(self):
        self.series = path_series_for()

    def test_path_output_contract_constants(self):
        self.assertEqual(core.path_output("LC"), dict(blurOutputTextureUsage=3, blurOutputStorageMode=2,
            compositeSourceWidth=1179, compositeSourceHeight=2556, compositeTextureUsage=4, compositeStorageMode=2))
        self.assertEqual(core.path_output("SC")["blurOutputTextureUsage"], 5)
        # SH has no blur output: its composite samples S's half-size level 0.
        self.assertEqual(core.path_output("SH"), dict(compositeSourceWidth=589, compositeSourceHeight=1278,
                                                      compositeTextureUsage=4, compositeStorageMode=2))

    def test_valid_path_leg_summarizes_measured_rows_only(self):
        summary = core.audit_path_leg(path_leg_report(self.series, 1, 1, "SH"), self.series, 1, 1, "SH")
        self.assertAlmostEqual(summary["cpuEncodeP95Ms"], 0.4 + 0.94, places=6)
        self.assertEqual(set(summary), {"cpuEncodeP95Ms", "gpuP95Ms", "submitP95Ms", "cpuEncodeMedianMs",
                                        "gpuMedianMs"})

    def assert_rejected(self, reason, mutate, arm="SH"):
        with self.assertRaises(core.AuditFailure) as caught:
            core.audit_path_leg(path_leg_report(self.series, 1, 1, arm, mutate=mutate), self.series, 1, 1, arm)
        self.assertEqual(caught.exception.reason, reason)

    def test_path_leg_textures_and_composite_are_audited(self):
        self.assert_rejected("contract", lambda r: r["pathOutput"].update(blurOutputTextureUsage=5))
        self.assert_rejected("contract", lambda r: r["pathOutput"].update(compositeSourceWidth=1179))
        self.assert_rejected("contract", lambda r: r["pathOutput"].update(blurOutputTextureUsage=5), arm="LC")
        self.assert_rejected("contract", lambda r: r["pathOutput"].update(compositeTextureUsage=5), arm="SC")
        self.assert_rejected("contract", lambda r: r["pathOutput"].update(compositeStorageMode=0), arm="SC")
        self.assert_rejected("contract", lambda r: r.pop("pathOutput"), arm="LC")
        self.assert_rejected("contract", lambda r: r.update(compositeBaseColor=[0.25, 0.5, 0.75, 0.5]))
        self.assert_rejected("contract", lambda r: r.update(compositeBaseColor=[0.25, 0.5, 0.75, True]))
        self.assert_rejected("contract", lambda r: r.pop("compositeBaseColor"))
        self.assert_rejected("contract", lambda r: r.update(compositeMapping="offset"))
        # A v1 report is never a v2 leg.
        self.assert_rejected("contract", lambda r: r.update(protocolID=core.PROTOCOL))
        self.assert_rejected("contract", lambda r: r.update(method=core.LEG_METHOD))

    def test_path_leg_reuses_the_v1_guards(self):
        self.assert_rejected("contract", lambda r: r["rows"].pop())
        self.assert_rejected("contract", lambda r: r["rows"][2500]["after"].update(thermal=1))
        self.assert_rejected("quality", lambda r: r["outputSHA256After"].update({SPHERES[0]: "0" * 64}))
        self.assert_rejected("identity", lambda r: r.update(seriesSHA256="f" * 64))
        self.assert_rejected("identity", lambda r: r.update(debugBuild=True))
        self.assert_rejected("contract", lambda r: r["cooling"].update(nominalContinuousSeconds=19.9))

        def overlap(r):
            r["rows"][10]["timing"]["submitStart"] = r["rows"][9]["timing"]["gpuStart"]
        self.assert_rejected("timestamps", overlap)

    def test_path_qualification_gates_sh_against_sc_only(self):
        receipt = core.audit_path_qualification(path_qualification_report(worst_sh=1, worst_lc=9), BUILD)
        self.assertEqual(receipt["arms"], ["LC", "SC", "SH"])
        # LC's difference from SC is recorded, never gated.
        self.assertEqual(receipt["maxDifferenceVersusSC"], dict(LC=9, SH=1))
        self.assertNotIn("timingSmoke", receipt)
        self.assertEqual(receipt["timingSmokeRows"], core.SMOKE_ROWS)
        with self.assertRaises(core.AuditFailure) as caught:
            core.audit_path_qualification(path_qualification_report(worst_sh=2), BUILD)
        self.assertEqual(caught.exception.reason, "quality")
        with self.assertRaises(core.AuditFailure) as caught:
            core.audit_path_qualification(path_qualification_report(photos=False), BUILD)
        self.assertEqual(caught.exception.reason, "quality")

    def assert_qualification_rejected(self, reason, mutate):
        report = path_qualification_report()
        mutate(report)
        with self.assertRaises(core.AuditFailure) as caught:
            core.audit_path_qualification(report, BUILD)
        self.assertEqual(caught.exception.reason, reason)

    def test_path_qualification_contract(self):
        self.assert_qualification_rejected("quality", lambda r: r.update(shQualityPassed=False))
        self.assert_qualification_rejected("identity", lambda r: r.update(arms=["SC", "LC", "SH"]))
        self.assert_qualification_rejected("identity", lambda r: r.update(metallibSHA256="e" * 64))
        self.assert_qualification_rejected("contract", lambda r: r["checks"][4]["differenceVersusSC"].pop("LC"))
        # Negative "max differences" are impossible and must not slip under the <= 1 gate.
        self.assert_qualification_rejected("contract", lambda r: r["checks"][4]["differenceVersusSC"].update(SH=-1))
        self.assert_qualification_rejected("contract", lambda r: r["checks"][4]["differenceVersusSC"].update(LC=-3))
        self.assert_qualification_rejected("contract", lambda r: r.update(compositeMapping="offset"))
        self.assert_qualification_rejected("contract", lambda r: r.update(method=core.QUALIFICATION_METHOD))
        self.assert_qualification_rejected("contract", lambda r: r["timingSmoke"]["SH"]["pathOutput"].update(
            blurOutputTextureUsage=5, blurOutputStorageMode=2))
        self.assert_qualification_rejected("contract", lambda r: r["timingSmoke"].pop("LC"))
        self.assert_qualification_rejected("contract", lambda r: r["timingSmoke"]["SC"]["rows"].pop())
        self.assert_qualification_rejected("contract", lambda r: r.pop("timingSmokeCooling"))

        def misordered(r):
            r["timingSmoke"]["LC"]["rows"][5]["timing"]["gpuStart"] = 1e9
        self.assert_qualification_rejected("timestamps", misordered)
        # Neither audit accepts the other protocol's report.
        with self.assertRaises(core.AuditFailure):
            core.audit_qualification(path_qualification_report(), True, BUILD)
        with self.assertRaises(core.AuditFailure):
            core.audit_path_qualification(qualification_report(), BUILD)


class FakePathDevice:
    """A v2 device at the `Device` method level. `preflight` takes the transport (v2 always passes it)."""

    def __init__(self, series):
        self.series, self.calls = series, []

    def preflight(self, folder, transport):
        self.calls.append(("preflight", transport))

    def launch(self, arguments, folder):
        self.calls.append(("launch", arguments))
        values = dict(zip(arguments[1::2], arguments[2::2]))
        self.pending = (int(values["--cpu-encode-block"]), int(values["--cpu-encode-attempt"]), values["--cpu-encode-arm"])
        return 0, f"CPUEncodeBenchmark-{str(uuid.uuid4()).upper()}"

    def copy_report(self, remote, destination):
        block, attempt, arm = self.pending
        report = path_leg_report(self.series, block, attempt, arm, dict(LC=0.5, SC=0.42, SH=0.4)[arm],
                                 dict(LC=2.0, SC=1.6, SH=1.4)[arm])
        Path(destination).write_text(json.dumps(report))
        return report


class PathLevelDriverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_v1_route_is_unchanged_and_v2_adds_its_selector(self):
        self.assertEqual(driver.route(core.PROTOCOL), ["--cpu-encode-benchmark"])
        self.assertEqual(driver.route(core.PATH_PROTOCOL),
                         ["--cpu-encode-benchmark", "--cpu-encode-protocol", "path-level-v2"])
        with self.assertRaises(ValueError):
            driver.route("cpu-encode-blocks-v3")

    def test_qualify_records_protocol_and_transport(self):
        calls = []

        class Fake:
            def preflight(self, folder, transport):
                calls.append(("preflight", transport))

            def launch(self, arguments, folder):
                calls.append(("launch", arguments))
                return 0, "CPUEncodeBenchmark-X"

            def copy_report(self, remote, destination):
                Path(destination).write_text(json.dumps(path_qualification_report()))
                return path_qualification_report()

        path, code, _ = driver.qualify(Fake(), self.root, core.PATH_PROTOCOL, "wired")
        self.assertEqual(calls[0], ("preflight", "wired"))
        self.assertEqual(calls[1], ("launch", ["--cpu-encode-benchmark", "--cpu-encode-protocol", "path-level-v2",
                                               "--cpu-encode-mode", "qualification"]))
        launch = driver.qualification_launch(path)
        self.assertEqual((launch["protocolID"], launch["transport"]), (core.PATH_PROTOCOL, "wired"))
        with self.assertRaises(ValueError):  # v2 needs an explicit transport
            driver.qualify(Fake(), self.root, core.PATH_PROTOCOL)
        with self.assertRaises(ValueError):
            driver.qualify(Fake(), self.root, core.PATH_PROTOCOL, "usb")
        with self.assertRaises(ValueError):  # the v1 transport stays fixed
            driver.qualify(Fake(), self.root, core.PROTOCOL, "wired")

    def freeze_setup(self, transport="wired", protocol=core.PATH_PROTOCOL):
        root, app = self.root / "series", self.root / "DualKawaseBlurDemo.app"
        (app / "DualKawaseBlur_DualKawaseBlur.bundle").mkdir(parents=True)
        (app / "DualKawaseBlurDemo").write_bytes(b"exe")
        (app / "DualKawaseBlur_DualKawaseBlur.bundle/default.metallib").write_bytes(b"lib")
        folder = root / "qualification" / "q1"
        folder.mkdir(parents=True)
        driver.save_new(root / "install-x.json", dict(driver.app_identity(app), device="DEVICE"))
        qualification = folder / "report.json"
        qualification.write_text(json.dumps(path_qualification_report()))
        record = dict(exitCode=0, remoteFolder="x", reportSHA256=driver.sha_file(qualification))
        if protocol:
            record.update(protocolID=protocol, transport=transport)
        driver.save_new(folder / "launch-result.json", record)
        conditions = self.root / "c.json"
        conditions.write_text(json.dumps(dict(userQuote="да", brightnessApproxPercent=50, autoBrightness=False,
            lowPower=False, deviceConnection="wired USB", chargingPolicy="charging over USB throughout",
            foregroundMaintained=True, settingsHeldConstant=True)))
        return lambda transport: driver.freeze(root, "DEVICE", app, qualification, conditions, True,
                                               revision=("abc", False), protocol=core.PATH_PROTOCOL,
                                               transport=transport), root

    def test_freeze_records_the_transport_and_refuses_a_mismatch(self):
        freeze, root = self.freeze_setup(transport="wired")
        with self.assertRaisesRegex(ValueError, "over 'wired'"):
            freeze("localNetwork")
        with self.assertRaises(ValueError):
            freeze(None)
        self.assertFalse(core.Journal(root).entries())
        series = freeze("wired")
        self.assertEqual((series["protocolID"], series["transport"]), (core.PATH_PROTOCOL, "wired"))
        self.assertEqual(series["protocolSHA256"], driver.sha_file(driver.PATH_PROTOCOL_FILE))
        self.assertEqual(series["arms"], ["LC", "SC", "SH"])
        self.assertEqual(series["orders"], [list(o) for o in core.PATH_ORDERS])
        self.assertEqual(series["qualification"]["maxDifferenceVersusSC"], dict(LC=9, SH=1))
        self.assertNotIn("referenceComparison", series)
        body = {k: v for k, v in series.items() if k != "seriesSHA256"}
        self.assertEqual(series["seriesSHA256"], core.digest(core.canonical(body)))

    def test_freeze_refuses_a_qualification_without_a_recorded_transport(self):
        freeze, _ = self.freeze_setup(protocol=None)  # a v1-style launch record
        with self.assertRaisesRegex(ValueError, "qualification ran None"):
            freeze("wired")

    def test_full_path_series_checks_the_frozen_transport_every_leg(self):
        series = path_series_for("localNetwork")
        core.Journal(self.root).append("freeze", series=series)
        self.addCleanup(setattr, driver, "verify_frozen", driver.verify_frozen)
        driver.verify_frozen = lambda state: None  # covered by test_verify_frozen_hashes_the_series_own_protocol
        device = FakePathDevice(series)
        for _ in range(8):
            self.assertTrue(driver.run_block(self.root, device)["completed"])
        preflights = [c[1] for c in device.calls if c[0] == "preflight"]
        self.assertEqual(preflights, ["localNetwork"] * 24)
        launches = [c[1] for c in device.calls if c[0] == "launch"]
        self.assertTrue(all(a[:3] == ["--cpu-encode-benchmark", "--cpu-encode-protocol", "path-level-v2"]
                            for a in launches))
        arms = [a[a.index("--cpu-encode-arm") + 1] for a in launches]
        self.assertEqual(arms, [arm for order in core.PATH_ORDERS for arm in order])
        result = driver.analyze(self.root)
        self.assertEqual(result["screens"], dict(P1_SH_gpu_below_LC=True, P2_SH_cpu_below_LC=True))
        self.assertEqual(result["excludedAttempts"], [])

    def test_preflight_checks_the_given_transport(self):
        def runner(transport):
            def run(arguments, timeout):
                output = Path(arguments[arguments.index("--json-output") + 1])
                result = dict(connectionProperties=dict(transportType=transport, tunnelState="connected"),
                              hardwareProperties=dict(reality="physical"), passcodeRequired=False, runningProcesses=[])
                output.write_text(json.dumps(dict(info=dict(outcome="success"), result=result)))
                return 0, ""
            return run

        driver.Device("DEVICE", runner("wired")).preflight(self.root, "wired")
        with self.assertRaises(core.AuditFailure) as caught:
            driver.Device("DEVICE", runner("localNetwork")).preflight(self.root, "wired")
        self.assertEqual(caught.exception.reason, "connection")
        # v1 keeps its fixed transport when none is given.
        driver.Device("DEVICE", runner("localNetwork")).preflight(self.root)

    def test_verify_frozen_hashes_the_series_own_protocol(self):
        tools = {p.name: driver.sha_file(p) for p in driver.TOOL_FILES}
        v1 = dict(protocolID=core.PROTOCOL, protocolSHA256=driver.sha_file(driver.PROTOCOL_FILE), toolSHA256=tools)
        v2 = dict(v1, protocolID=core.PATH_PROTOCOL, protocolSHA256=driver.sha_file(driver.PATH_PROTOCOL_FILE))
        REAL_VERIFY_FROZEN(dict(series=v1))
        REAL_VERIFY_FROZEN(dict(series=v2))
        for series in (dict(v2, protocolSHA256=v1["protocolSHA256"]), dict(v1, protocolSHA256=v2["protocolSHA256"]),
                       dict(v2, toolSHA256=dict(tools, **{"cpu_encode.py": "0" * 64})),
                       dict(v1, protocolID="cpu-encode-blocks-v3")):
            with self.assertRaises(ValueError):
                REAL_VERIFY_FROZEN(dict(series=series))


class V1EvidenceTests(unittest.TestCase):
    """The edited core reproduces the committed v1 series exactly. Read-only: nothing is written there.
    (The v1 journal froze the v1 tool hashes; it re-verifies with `verify_frozen` at gitRevision 60e61288.)"""

    def test_v1_series_evidence_reproduces(self):
        state = core.Journal(V1_SERIES_ROOT).state()  # replays and checks the whole hash chain
        series = state["series"]
        self.assertEqual((state["stopped"], len(state["completed"]), state["failures"]), ("complete", 8, []))
        self.assertEqual(series["protocolID"], core.PROTOCOL)
        self.assertTrue(series["gitRevision"].startswith("60e61288"))
        self.assertNotIn("transport", series)  # a v1 series: SERIES_TRANSPORT
        analysis = json.loads((V1_SERIES_ROOT / "analysis.json").read_text())
        analysis.pop("excludedAttempts")
        # Canonical bytes, not parsed dicts: key order aside, every value and type must be identical.
        self.assertEqual(core.canonical(core.analyze(state["completed"], series["arms"])), core.canonical(analysis))
        [report] = list(V1_SERIES_ROOT.glob("qualification/*/report.json"))
        self.assertEqual(driver.sha_file(report), series["qualificationReportSHA256"])
        build = {k: series[k] for k in core.BUILD_KEYS}
        self.assertEqual(core.canonical(core.audit_qualification(json.loads(report.read_text()), True, build)),
                         core.canonical(series["qualification"]))



class NegativeDifferenceTests(unittest.TestCase):
    def test_negative_differences_are_contract_failures_in_both_protocols(self):
        for arm in ("S", "S4", "L"):
            report = json.loads(json.dumps(qualification_report()))
            report["checks"][2]["differenceVersusO"][arm] = -1
            with self.assertRaises(core.AuditFailure) as caught:
                core.audit_qualification(report, True, BUILD)
            self.assertEqual(caught.exception.reason, "contract", arm)
        report = path_qualification_report()
        report["checks"][0]["differenceVersusSC"]["SH"] = -2
        with self.assertRaises(core.AuditFailure) as caught:
            core.audit_path_qualification(report, BUILD)
        self.assertEqual(caught.exception.reason, "contract")
        # Valid reports (zero differences included) still pass in both protocols.
        core.audit_qualification(qualification_report(worst=0), True, BUILD)
        core.audit_path_qualification(path_qualification_report(worst_sh=0, worst_lc=0), BUILD)


if __name__ == "__main__":
    unittest.main()
