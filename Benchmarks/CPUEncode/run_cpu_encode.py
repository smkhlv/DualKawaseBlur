"""Host driver for CPU_ENCODE_PROTOCOL.md (v1) and PATH_LEVEL_PROTOCOL.md (v2, `--protocol path-level-v2`
on qualify/freeze; later commands follow the frozen series' protocolID). One block (one fresh
process per arm) per invocation.

Never terminates a process: a running demo app is a preflight failure, not something to kill.
No automatic retry: attempt 2 of a block needs `--authorize-retry` with the user's words.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cpu_encode as core  # noqa: E402

BUNDLE = "smkhlv.DualKawaseBlurDemo"
APP_NAME = "DualKawaseBlurDemo"
HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[2]
PROTOCOL_FILE = HERE.parent / "CPU_ENCODE_PROTOCOL.md"
PATH_PROTOCOL_FILE = HERE.parent / "PATH_LEVEL_PROTOCOL.md"
TOOL_FILES = (HERE / "cpu_encode.py", Path(__file__).resolve())
REPORT_MARKER = re.compile(r"^CPU_ENCODE_REPORT (CPUEncodeBenchmark-[0-9A-F-]{36})\s*$", re.M)
# devicectl's own launch timeout covers the app's 300 s settling cap with room for the work after it;
# the host kills only its devicectl client, never the app, and waits comfortably longer than devicectl.
# Protocol §6: the USB cable failed before freeze (2026-10-22); the series runs on the CoreDevice
# local-network transport throughout. A transport change mid-series is a retryable connection failure.
# This is the v1 value (a series without `transport`); a v2 series records the transport chosen at
# qualify/freeze (PATH_LEVEL_PROTOCOL.md §6) and every preflight checks that value instead.
SERIES_TRANSPORT = "localNetwork"
DEVICECTL_LAUNCH_TIMEOUT, HOST_LAUNCH_TIMEOUT, COPY_TIMEOUT = 600, 660, 30
# The 2026-10-10 confirmation's qualification receipt (read-only worktree). Its O and M (= L) Sphere
# output hashes are compared at freeze for information only (protocol §3.3).
REFERENCE_QUALIFICATION = Path("/Users/sergeimikhailov/Documents/Suretare/.worktrees/dual-kawase-matched-quality/"
                               "DualKawaseBlur/Benchmarks/Results/2026-10-10-resumable-confirmation/qualification.json")
REFERENCE_ARMS = {"O": "O", "L": "M"}
CONDITION_KEYS = {"userQuote", "brightnessApproxPercent", "autoBrightness", "lowPower", "deviceConnection",
                  "chargingPolicy", "foregroundMaintained", "settingsHeldConstant"}


def sha_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save_new(path, value):
    with Path(path).open("x") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


def subprocess_runner(arguments, timeout):
    try:
        done = subprocess.run(["xcrun", "devicectl"] + arguments, capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired as error:
        return 124, (error.stdout or "") if isinstance(error.stdout, str) else ""


class Device:
    def __init__(self, identifier, runner=subprocess_runner):
        self.identifier, self.runner = identifier, runner

    def _json(self, arguments, folder, name, timeout=25):
        output = Path(folder) / f"{name}.json"
        code, text = self.runner(arguments + ["--device", self.identifier, "--json-output", str(output)], timeout)
        (Path(folder) / f"{name}.stdout").write_text(text)
        if code != 0 or not output.exists():
            raise core.AuditFailure("connection", f"{name} query failed ({code})")
        data = json.loads(output.read_text())
        if data.get("info", {}).get("outcome") != "success":
            raise core.AuditFailure("connection", f"{name} outcome")
        return data.get("result", {})

    def preflight(self, folder, transport=SERIES_TRANSPORT):
        """Physical device on the series' fixed transport, unlocked, and no demo process already running."""
        details = self._json(["device", "info", "details"], folder, "details")
        connection = details.get("connectionProperties", {})
        if (connection.get("transportType") != transport or connection.get("tunnelState") != "connected"
                or details.get("hardwareProperties", {}).get("reality") != "physical"):
            raise core.AuditFailure("connection", f"exact {transport} physical connection not established")
        lock = self._json(["device", "info", "lockState"], folder, "lock")
        if lock.get("passcodeRequired") is not False:
            raise core.AuditFailure("locked", "device locked or lock state unknown")
        processes = self._json(["device", "info", "processes"], folder, "processes")
        running = [p for p in processes.get("runningProcesses", [])
                   if f"/{APP_NAME}.app/" in p.get("executable", "")]
        if running:
            raise core.AuditFailure("preflight", "demo app already running; it is never terminated by this tool")

    def launch(self, arguments, folder):
        folder = Path(folder)
        code, text = self.runner(["device", "process", "launch", "--device", self.identifier, "--console",
            "--timeout", str(DEVICECTL_LAUNCH_TIMEOUT), "--json-output", str(folder / "launch.json"),
            "--log-output", str(folder / "launch.log"), BUNDLE] + arguments, HOST_LAUNCH_TIMEOUT)
        (folder / "launch.stdout").write_text(text)
        if code == 124 or "timed out" in text.lower():
            raise core.AuditFailure("timeout", "launch timed out; the process was left alone")
        found = REPORT_MARKER.findall(text)
        if len(found) != 1:
            raise core.AuditFailure("export", f"missing/ambiguous report marker (exit {code})")
        return code, found[0]

    def copy_report(self, remote_folder, destination):
        code, text = self.runner(["device", "copy", "from", "--device", self.identifier,
            "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
            "--source", f"Documents/{remote_folder}/report.json", "--destination", str(destination),
            "--timeout", str(COPY_TIMEOUT)], COPY_TIMEOUT + 10)
        if code != 0 or not Path(destination).exists():
            raise core.AuditFailure("export", f"report copy failed ({code}): {text[-200:]}")
        return json.loads(Path(destination).read_text())

    def copy_to(self, local, remote):
        code, text = self.runner(["device", "copy", "to", "--device", self.identifier,
            "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
            "--source", str(local), "--destination", remote, "--timeout", "120"], 130)
        if code != 0:
            raise core.AuditFailure("export", f"copy to device failed ({code}): {text[-200:]}")

    def install(self, app):
        code, text = self.runner(["device", "install", "app", "--device", self.identifier, str(app)], 300)
        if code != 0:
            raise core.AuditFailure("connection", f"install failed ({code}): {text[-200:]}")


# The app's own `failureReason` -> journal reason. Anything else (metal, corpus, cancellation) is contract.
NATIVE_REASONS = {"thermal": "thermal", "thermalDeadline": "thermal", "background": "background",
                  "lowPower": "lowPower", "timestamp": "timestamps"}


def native_failure_reason(report):
    return NATIVE_REASONS.get(report.get("failureReason"), "contract")


def app_identity(app):
    app = Path(app)
    executable, library = app / APP_NAME, app / "DualKawaseBlur_DualKawaseBlur.bundle/default.metallib"
    if not executable.is_file() or not library.is_file():
        raise ValueError("not a built DualKawaseBlurDemo.app")
    return dict(appExecutableSHA256=sha_file(executable), metallibSHA256=sha_file(library))


def git_revision(root):
    """HEAD plus whether DualKawaseBlur/ differs from it, ignoring only the series root itself.
    Untracked sources count: the demo's synchronized group would compile them."""
    revision = subprocess.run(["git", "-C", str(WORKSPACE), "rev-parse", "HEAD"], capture_output=True, text=True)
    pathspec = ["--", "DualKawaseBlur"]
    resolved = Path(root).resolve()
    if resolved.is_relative_to(WORKSPACE):
        pathspec.append(f":(exclude){resolved.relative_to(WORKSPACE)}")
    dirty = subprocess.run(["git", "-C", str(WORKSPACE), "status", "--porcelain"] + pathspec,
                           capture_output=True, text=True)
    if revision.returncode or dirty.returncode:
        raise ValueError("git state unavailable")
    return revision.stdout.strip(), bool(dirty.stdout.strip())


def install(device, app, root):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    identity = app_identity(app)
    device.install(app)
    record = dict(identity, device=device.identifier, app=str(Path(app).resolve()), id=str(uuid.uuid4()))
    save_new(root / f"install-{record['id']}.json", record)
    return record


def stage_photos(device, corpus):
    manifest = json.loads((HERE.parents[1] / "Examples/DualKawaseBlurDemo/DualKawaseBlurDemo/Resources/"
                           "CPUEncodeCorpus/cpu-encode-corpus.json").read_text())
    for record in (r for r in manifest["records"] if not r["bundled"]):
        local = Path(corpus) / record["file"]
        if sha_file(local) != record["sha256"]:
            raise ValueError(f"{local} does not match the qualified corpus")
        device.copy_to(local, f"Documents/CPUEncodeInputs/{record['stagedName']}")


def protocol_file(protocol):
    """The protocol document a series of `protocol` freezes and re-verifies."""
    files = {core.PROTOCOL: PROTOCOL_FILE, core.PATH_PROTOCOL: PATH_PROTOCOL_FILE}
    if protocol not in files:
        raise ValueError(f"unknown protocol {protocol!r}")
    return files[protocol]


def route(protocol):
    """The native route's leading arguments. v1 is the bare flag, exactly as frozen; v2 adds its selector."""
    protocol_file(protocol)
    return ["--cpu-encode-benchmark"] + ([] if protocol == core.PROTOCOL else ["--cpu-encode-protocol", protocol])


def path_transport(transport):
    if transport not in core.PATH_TRANSPORTS:
        raise ValueError(f"{core.PATH_PROTOCOL} needs --transport {'|'.join(core.PATH_TRANSPORTS)}, got {transport!r}")
    return transport


def preflight(device, folder, transport):
    """`transport` None is v1: the fixed SERIES_TRANSPORT, called exactly as v1 calls it."""
    if transport is None:
        device.preflight(folder)
    else:
        device.preflight(folder, transport)


def qualify(device, root, protocol=core.PROTOCOL, transport=None):
    """One qualification attempt. Its devicectl exit code is kept next to the copied report, because
    `freeze` accepts only a launch that exited 0 (exit-code propagation is part of the route).
    v2 also records its protocol and the host transport there; `freeze` requires the same transport."""
    path = protocol == core.PATH_PROTOCOL
    if path:
        path_transport(transport)
    elif transport is not None:
        raise ValueError(f"the v1 transport is fixed ({SERIES_TRANSPORT}); --transport is a v2 argument")
    arguments = route(protocol) + ["--cpu-encode-mode", "qualification"]
    folder = Path(root) / "qualification" / str(uuid.uuid4())
    folder.mkdir(parents=True)
    preflight(device, folder, transport)
    code, remote = device.launch(arguments, folder)
    report = device.copy_report(remote, folder / "report.json")
    record = dict(exitCode=code, remoteFolder=remote, reportSHA256=sha_file(folder / "report.json"))
    if path:
        record.update(protocolID=protocol, transport=transport)
    save_new(folder / "launch-result.json", record)
    return folder / "report.json", code, report


def qualification_launch(qualification):
    """The exit record `qualify` wrote beside this exact report; freeze needs exit 0."""
    path = Path(qualification).parent / "launch-result.json"
    if not path.is_file():
        raise ValueError("no launch-result.json beside the qualification report; run `qualify`")
    launch = json.loads(path.read_text())
    if launch.get("reportSHA256") != sha_file(qualification):
        raise ValueError("launch-result.json belongs to a different report")
    if launch.get("exitCode") != 0:
        raise ValueError(f"qualification launch exited {launch.get('exitCode')!r}, not 0")
    return launch


def reference_comparison(receipt, reference):
    """Informational only: O and L Sphere output hashes against the 2026-10-10 receipt. A mismatch is
    disclosed in the series, never a stop (iOS and shader-compiler updates can change bits)."""
    if reference is None or not Path(reference).is_file():
        return dict(available=False, path=str(reference))
    ref = json.loads(Path(reference).read_text()).get("expectedOutputSHA256", {})
    result = dict(available=True, path=str(reference), referenceSHA256=sha_file(reference), arms={})
    for arm, ref_arm in REFERENCE_ARMS.items():
        ours, theirs = receipt["expectedOutputSHA256"].get(arm, {}), ref.get(ref_arm, {})
        names = sorted(set(ours) | set(theirs))
        result["arms"][arm] = dict(referenceArm=ref_arm, matching=sum(ours.get(n) == theirs.get(n) for n in names),
                                   compared=len(names), mismatched=[n for n in names if ours.get(n) != theirs.get(n)])
    return result


def freeze(root, device_id, app, qualification, conditions, require_s4=True, revision=None, reference=None,
           protocol=core.PROTOCOL, transport=None):
    """`require_s4` and `reference` are v1 only (a v2 freeze never reads them); `transport` is v2 only and
    must be the qualification's."""
    root = Path(root)
    protocol_file(protocol)
    if protocol == core.PATH_PROTOCOL:
        path_transport(transport)
    elif transport is not None:
        raise ValueError(f"the v1 transport is fixed ({SERIES_TRANSPORT}); --transport is a v2 argument")
    journal = core.Journal(root)
    if journal.entries():
        raise ValueError("series already frozen; a change needs a new series root")
    conditions = json.loads(Path(conditions).read_text())
    if set(conditions) != CONDITION_KEYS or not conditions["userQuote"] or conditions["lowPower"] is not False:
        raise ValueError("user-confirmed constant conditions required")
    revision, dirty = revision or git_revision(root)
    if dirty:
        raise ValueError("DualKawaseBlur has uncommitted changes; freeze only a committed build")
    identity = app_identity(app)
    installs = [json.loads(p.read_text()) for p in root.glob("install-*.json")]
    if not any(i["device"] == device_id and {k: i[k] for k in identity} == identity for i in installs):
        raise ValueError("this exact build was not installed on this device by `install`")
    launch = qualification_launch(qualification)
    report = json.loads(Path(qualification).read_text())
    if protocol == core.PATH_PROTOCOL:
        if launch.get("protocolID") != protocol or launch.get("transport") != transport:
            raise ValueError(f"qualification ran {launch.get('protocolID')!r} over {launch.get('transport')!r}; "
                             f"freeze names {protocol} over {transport!r}")
        receipt = core.audit_path_qualification(report, identity)
        arms, extra = core.PATH_ARMS, dict(transport=transport)
    else:
        receipt = core.audit_qualification(report, require_s4, identity)
        arms = ("O", "S", "S4", "L") if require_s4 else ("O", "S", "L")
        extra = dict(referenceComparison=reference_comparison(receipt, reference))
    series = dict(protocolID=protocol, protocolSHA256=sha_file(protocol_file(protocol)),
        toolSHA256={p.name: sha_file(p) for p in TOOL_FILES}, gitRevision=revision, device=device_id,
        conditions=conditions, qualificationReportSHA256=sha_file(qualification), qualification=receipt,
        qualificationExitCode=launch["exitCode"], **extra,
        arms=list(arms), orders=[list(o) for o in core.orders_for(arms)], **identity)
    series["seriesSHA256"] = core.digest(core.canonical(series))
    root.mkdir(parents=True, exist_ok=True)
    with journal.locked():
        journal.append("freeze", series=series)
    return series


def verify_frozen(state):
    """Hashes the protocol document of the series' own protocol, and both tools."""
    series = state["series"]
    if (series["protocolSHA256"] != sha_file(protocol_file(series["protocolID"]))
            or series["toolSHA256"] != {p.name: sha_file(p) for p in TOOL_FILES}):
        raise ValueError("protocol or tool changed since freeze; start a new series")


def run_block(root, device, authorization=None):
    journal = core.Journal(root)
    with journal.locked():
        state = journal.state()
        verify_frozen(state)
        if state["stopped"]:
            raise ValueError(f"series stopped: {state['stopped']}")
        if state["active"]:
            raise ValueError("an attempt is in flight; record it with `recover` first")
        block, attempt, series = state["block"], state["attempt"], state["series"]
        if attempt == 2 and not authorization:
            raise ValueError("attempt 2 needs --authorize-retry with the user's words")
        order = series["orders"][block - 1]
        path = series["protocolID"] == core.PATH_PROTOCOL
        # v1 series carry no `transport` (fixed SERIES_TRANSPORT); v2 checks its frozen transport.
        transport = path_transport(series.get("transport")) if path else None
        audit = core.audit_path_leg if path else core.audit_leg
        folder = Path(root) / "attempts" / f"b{block:02d}-a{attempt:02d}"
        folder.mkdir(parents=True)
        # Recorded before any device contact: a preflight failure is still an auditable attempt.
        journal.append("begin", block=block, attempt=attempt, order=order, authorization=authorization)
        try:
            for arm in order:
                leg = folder / arm
                leg.mkdir()
                preflight(device, leg, transport)
                code, remote = device.launch(route(series["protocolID"]) + ["--cpu-encode-mode", "timing",
                    "--cpu-encode-arm", arm, "--cpu-encode-block", str(block), "--cpu-encode-attempt", str(attempt),
                    "--cpu-encode-series", series["seriesSHA256"]], leg)
                report = device.copy_report(remote, leg / "report.json")
                if report.get("completed") is not True:
                    raise core.AuditFailure(native_failure_reason(report), f"{arm}: {report.get('failure')}")
                if code != 0:
                    raise core.AuditFailure("contract", f"{arm}: completed report but exit {code}")
                summary = audit(report, series, block, attempt, arm)
                journal.append("leg", block=block, attempt=attempt, arm=arm,
                               reportSHA256=sha_file(leg / "report.json"), summary=summary)
            journal.append("complete", block=block, attempt=attempt)
            return dict(block=block, attempt=attempt, completed=True)
        except core.AuditFailure as failure:
            journal.append("fail", block=block, attempt=attempt, reason=failure.reason, detail=str(failure))
            return dict(block=block, attempt=attempt, completed=False, reason=failure.reason, detail=str(failure))


def recover(root, detail):
    """Explicitly records a host crash mid-attempt as an excluded, retryable interruption."""
    journal = core.Journal(root)
    with journal.locked():
        state = journal.state()
        if not state["active"]:
            raise ValueError("nothing to recover")
        active = state["active"]
        journal.append("fail", block=active["block"], attempt=active["attempt"], reason="interrupted", detail=detail)


def analyze(root):
    state = core.Journal(root).state()
    verify_frozen(state)
    if state["stopped"] != "complete":
        raise ValueError(f"no confirmatory analysis: series {state['stopped'] or 'in progress'}")
    result = core.analyze(state["completed"], state["series"]["arms"])
    result["excludedAttempts"] = state["failures"]
    save_new(Path(root) / "analysis.json", result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("install", "stage-photos", "qualify", "freeze", "run-block", "recover", "status", "analyze"):
        command = sub.add_parser(name)
        if name != "stage-photos":
            command.add_argument("--root", type=Path, required=True)
        if name in ("install", "stage-photos", "qualify", "freeze"):
            command.add_argument("--device", required=True)
        if name in ("install", "freeze"):
            command.add_argument("--app", type=Path, required=True)
    sub.choices["stage-photos"].add_argument("--corpus", type=Path, default=Path(
        "/Users/sergeimikhailov/Documents/Suretare/.worktrees/dual-kawase-matched-quality/"
        "DualKawaseBlur/Benchmarks/Results/2026-10-10-resumable-preparation/corpus"))
    sub.choices["freeze"].add_argument("--qualification", type=Path, required=True)
    sub.choices["freeze"].add_argument("--conditions", type=Path, required=True)
    sub.choices["freeze"].add_argument("--three-arm-fallback", action="store_true")
    sub.choices["freeze"].add_argument("--reference-qualification", type=Path, default=REFERENCE_QUALIFICATION)
    for name in ("qualify", "freeze"):
        sub.choices[name].add_argument("--protocol", choices=(core.PROTOCOL, core.PATH_PROTOCOL), default=core.PROTOCOL)
        sub.choices[name].add_argument("--transport", choices=core.PATH_TRANSPORTS,
                                       help=f"{core.PATH_PROTOCOL} only (required there)")
    sub.choices["run-block"].add_argument("--authorize-retry")
    sub.choices["recover"].add_argument("--detail", required=True)
    args = parser.parse_args(argv)
    if args.command == "install":
        print(json.dumps(install(Device(args.device), args.app, args.root), indent=2))
    elif args.command == "stage-photos":
        stage_photos(Device(args.device), args.corpus)
    elif args.command == "qualify" and args.protocol == core.PATH_PROTOCOL:
        path, code, report = qualify(Device(args.device), args.root, args.protocol, args.transport)
        print(json.dumps(dict(report=str(path), exit=code, shQualityPassed=report.get("shQualityPassed"),
            photos=report.get("photoFixturesIncluded"), failure=report.get("failure"), transport=args.transport),
            indent=2))
    elif args.command == "qualify":
        path, code, report = qualify(Device(args.device), args.root, args.protocol, args.transport)
        print(json.dumps(dict(report=str(path), exit=code, sQualityPassed=report.get("sQualityPassed"),
            s4QualityPassed=report.get("s4QualityPassed"), photos=report.get("photoFixturesIncluded"),
            failure=report.get("failure")), indent=2))
    elif args.command == "freeze" and args.protocol == core.PATH_PROTOCOL:
        if args.three_arm_fallback:
            parser.error(f"--three-arm-fallback is a v1 option; {core.PATH_PROTOCOL} has one arm set")
        series = freeze(args.root, args.device, args.app, args.qualification, args.conditions,
                        protocol=args.protocol, transport=args.transport)
        print(json.dumps(dict(seriesSHA256=series["seriesSHA256"], transport=series["transport"],
                              maxDifferenceVersusSC=series["qualification"]["maxDifferenceVersusSC"]), indent=2))
    elif args.command == "freeze":
        series = freeze(args.root, args.device, args.app, args.qualification, args.conditions,
                        require_s4=not args.three_arm_fallback, reference=args.reference_qualification,
                        protocol=args.protocol, transport=args.transport)
        print(json.dumps(dict(seriesSHA256=series["seriesSHA256"],
                              referenceComparison=series["referenceComparison"]), indent=2))
    elif args.command == "run-block":
        state = core.Journal(args.root).state()
        print(json.dumps(run_block(args.root, Device(state["series"]["device"]), args.authorize_retry), indent=2))
    elif args.command == "recover":
        recover(args.root, args.detail)
    elif args.command == "status":
        state = core.Journal(args.root).state()
        print(json.dumps({k: state[k] for k in ("block", "attempt", "active", "failures", "stopped")}
                         | dict(completedBlocks=len(state["completed"])), indent=2))
    elif args.command == "analyze":
        print(json.dumps(analyze(args.root), indent=2))


if __name__ == "__main__":
    main()
