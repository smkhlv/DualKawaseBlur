"""Q1 endpoints (MAIN_THREAD_ENCODE_PROCEDURE.md §4) from xctrace exports. Stdlib only.

Usage: python3 -I analyze_q1.py <trace>...   (prints one JSON object per trace, then medians per build)
"""
import json
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET

E1 = ("SharedBlurEncodeWorker.encodeLatest", "SharedBlurEncodeWorker.encode(",
      "DualKawaseBlurRenderer.encode(source:destination:workspace:configuration:into:)")
E1S = ("SharedMetalBlurSession.renderLatest", "SharedBlurEncodeWorker.requestRender")
E1P = ("SphereFrameProducer.render",)
E2 = ("AnimatedBackgroundSession.tick",)
SPLIT = ("SplitRoleBlurEncoder.",)  # sanity: S must never run on main


def export(trace, xpath):
    out = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath],
                         capture_output=True, check=True).stdout
    return ET.fromstring(out)


def rows(root, node=None):
    # xctrace dedups values with id/ref across every <node> of one export, so resolve refs export-wide;
    # nodes of the same schema after the first omit <schema>, so fall back to the first declared one.
    ids = {e.get("id"): e for e in root.iter() if e.get("id")}
    node = root.find("node") if node is None else node
    schema = node.find("schema") if node.find("schema") is not None else root.find("node/schema")
    cols = [c.findtext("mnemonic") for c in schema.findall("col")]
    for row in node.findall("row"):
        cells = {}
        for col, child in zip(cols, list(row)):
            cells[col] = ids.get(child.get("ref"), child) if child.get("ref") else child
        yield cells, ids


def frames(stack, ids):
    if stack is None or stack.tag == "sentinel":
        return []
    return [(ids.get(f.get("ref"), f) if f.get("ref") else f).get("name", "") for f in stack.iter("frame")]


def duration_s(trace):
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"],
                         capture_output=True, check=True, text=True).stdout
    return float(ET.fromstring(toc).find(".//summary/duration").text)


def analyze(trace):
    seconds = duration_s(trace)
    ms = dict(E1=0.0, E1s=0.0, E1p=0.0, E2=0.0, splitOnMain=0.0, mainTotal=0.0)
    tp = export(trace, '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]')
    for cells, ids in rows(tp):
        if "Main Thread" not in cells["thread"].get("fmt", ""):
            continue
        weight = int(cells["weight"].text) / 1e6
        names = frames(cells.get("stack"), ids)
        ms["mainTotal"] += weight
        for key, needles in (("E1", E1), ("E1s", E1S), ("E1p", E1P), ("E2", E2), ("splitOnMain", SPLIT)):
            if any(n in name for name in names for n in needles):
                ms[key] += weight
    # The template records Points of Interest into two identical tables; count each event once.
    begins, intervals, seen = {}, [], set()
    signposts = export(trace, '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]')
    for table in signposts.findall("node"):
        for cells, _ in rows(signposts, table):
            name = cells.get("name")
            if name is None or name.text != "blur.encode":
                continue
            key, t = cells["identifier"].text, int(cells["time"].text)
            if (key, t, cells["event-type"].text) in seen:
                continue
            seen.add((key, t, cells["event-type"].text))
            if cells["event-type"].text == "Begin":
                begins[key] = (t, cells["thread"].get("fmt", ""))
            elif key in begins:
                start, thread = begins.pop(key)
                intervals.append(((t - start) / 1e6, thread))
    hitch_ms = []
    for cells, _ in rows(export(trace, '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]')):
        if "Suretare" in cells["process"].get("fmt", ""):
            hitch_ms.append(int(cells["duration"].text) / 1e6)
    durations = sorted(d for d, _ in intervals)
    return dict(
        trace=trace, seconds=round(seconds, 3),
        **{f"{k}_msPerS": round(v / seconds, 3) for k, v in ms.items()},
        E3=dict(count=len(intervals), perS=round(len(intervals) / seconds, 2),
                medianMs=round(statistics.median(durations), 3) if durations else None,
                p95Ms=round(durations[max(0, -(-len(durations) * 95 // 100) - 1)], 3) if durations else None,
                onMain=sum("Main Thread" in th for _, th in intervals),
                threads=sorted({th.split(" (")[0] for _, th in intervals})),
        E4=dict(hitches=len(hitch_ms), hitchTimeRatio_msPerS=round(sum(hitch_ms) / seconds, 3),
                longestMs=round(max(hitch_ms), 3) if hitch_ms else 0.0))


if __name__ == "__main__":
    results = [analyze(t) for t in sys.argv[1:]]
    for r in results:
        print(json.dumps(r, ensure_ascii=False))
    for build in ("before", "after"):
        rs = [r for r in results if build in r["trace"]]
        if rs:
            print(json.dumps(dict(build=build, medians={
                k: statistics.median(r[k] for r in rs) for k in rs[0] if k.endswith("_msPerS")},
                hitchRatioMedian=statistics.median(r["E4"]["hitchTimeRatio_msPerS"] for r in rs),
                longestHitchMs=max(r["E4"]["longestMs"] for r in rs))))
