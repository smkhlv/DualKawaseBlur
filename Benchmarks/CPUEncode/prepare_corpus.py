"""Bundle the qualified 2026-10-10 corpus into the demo app as raw-deflate resources.

Sphere and deterministic diagnostic inputs are committed (about 0.9 MB compressed).
The two photo fixtures (about 5.3 MB compressed) are not bundled: they are staged into
the app container by `run_cpu_encode.py stage-photos` and verified by SHA-256 there.
Every source file is verified against the original manifest before anything is written.
"""
import argparse
import hashlib
import json
from pathlib import Path
import zlib

WORKSPACE = Path(__file__).resolve().parents[3]
READ_ONLY_CORPUS = Path("/Users/sergeimikhailov/Documents/Suretare/.worktrees/dual-kawase-matched-quality/"
                        "DualKawaseBlur/Benchmarks/Results/2026-10-10-resumable-preparation/corpus")
APP_RESOURCES = WORKSPACE / "DualKawaseBlur/Examples/DualKawaseBlurDemo/DualKawaseBlurDemo/Resources/CPUEncodeCorpus"
SOURCE_MANIFEST_SHA256 = "693cfeb263e35cbdb0f706e9c11d2237513a5959bd2ec6dfacea0cb636e510bd"
MANIFEST_NAME = "cpu-encode-corpus.json"
PROTOCOL = "cpu-encode-corpus-v1"
BUNDLED_KINDS = {"sphere", "diagnostic"}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def deflate(data):
    """Raw deflate (wbits -15): what Apple's `NSData.decompressed(using: .zlib)` reads."""
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return compressor.compress(data) + compressor.flush()


def inflate(data):
    return zlib.decompress(data, -15)


def build(source, destination):
    source, destination = Path(source), Path(destination)
    manifest_bytes = (source / "manifest.json").read_bytes()
    if sha(manifest_bytes) != SOURCE_MANIFEST_SHA256:
        raise ValueError("source manifest is not the qualified 2026-10-10 corpus")
    original = json.loads(manifest_bytes)
    destination.mkdir(parents=True, exist_ok=True)
    records = []
    for record in original["records"]:
        raw = (source / record["file"]).read_bytes()
        if len(raw) != record["bytes"] or sha(raw) != record["sha256"]:
            raise ValueError("corpus file does not match its manifest: " + record["file"])
        entry = dict(file=record["file"], kind=record["kind"], bytes=record["bytes"], sha256=record["sha256"])
        if record["kind"] in BUNDLED_KINDS:
            packed = deflate(raw)
            if inflate(packed) != raw:
                raise ValueError("deflate round trip failed: " + record["file"])
            name = record["file"] + ".deflate"
            (destination / name).write_bytes(packed)
            entry.update(bundled=True, resource=name, resourceSHA256=sha(packed))
        else:
            entry.update(bundled=False, stagedName=record["file"])
        records.append(entry)
    manifest = dict(protocolID=PROTOCOL, sourceManifestSHA256=SOURCE_MANIFEST_SHA256,
        width=original["width"], height=original["height"], rowBytes=original["rowBytes"],
        pixelFormat=original["pixelFormat"], primarySequence=original["primarySequence"],
        compression="raw-deflate", records=records)
    text = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    (destination / MANIFEST_NAME).write_text(text)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=READ_ONLY_CORPUS)
    parser.add_argument("--destination", type=Path, default=APP_RESOURCES)
    args = parser.parse_args()
    manifest = build(args.source, args.destination)
    bundled = sum(r["bundled"] for r in manifest["records"])
    print(f"bundled {bundled}/{len(manifest['records'])} records into {args.destination}")


if __name__ == "__main__":
    main()
