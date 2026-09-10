#!/usr/bin/env python3
"""Verify prototype audio packets, timing, HDR video, and self-contained media."""
import argparse
import hashlib
import json
import struct
import subprocess
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def probe(tool, path, raw=False):
    command = [str(tool), "-v", "error"]
    if raw:
        command += ["-ignore_editlist", "1"]
    command += ["-show_streams", "-show_packets", "-show_data_hash", "sha256", "-show_entries",
                "stream=index,codec_tag_string,codec_type,channels,sample_rate,width,height,pix_fmt,"
                "color_transfer,color_primaries,color_space:packet=stream_index,pts_time,data_hash",
                "-of", "json", str(path)]
    return json.loads(subprocess.check_output(command))


def packets(report, stream):
    return [p for p in report["packets"] if p["stream_index"] == stream["index"]]


def matching_start(original, exported):
    before = [p["data_hash"] for p in original]
    after = [p["data_hash"] for p in exported]
    require(after, "Exported stream has no packets")
    return next((i for i in range(len(before) - len(after) + 1)
                 if before[i:i + len(after)] == after), None)


def ordered_payload_subset(original, exported):
    remaining = iter(p["data_hash"] for p in original)
    return bool(exported) and all(any(value == packet["data_hash"] for value in remaining) for packet in exported)


def self_contained(path):
    """Check every QuickTime data reference's self-contained flag, without decoding media."""
    refs = []
    with path.open("rb") as handle:
        def boxes(start, end):
            while start < end:
                handle.seek(start)
                size, kind = struct.unpack(">I4s", handle.read(8))
                header = 8
                if size == 1:
                    size = struct.unpack(">Q", handle.read(8))[0]
                    header = 16
                elif size == 0:
                    size = end - start
                require(size >= header and start + size <= end, "Invalid movie atom")
                yield kind, start + header, start + size
                start += size

        def walk(start, end):
            for kind, payload, stop in boxes(start, end):
                if kind in (b"moov", b"trak", b"mdia", b"minf", b"dinf"):
                    walk(payload, stop)
                elif kind == b"dref":
                    for ref_type, ref_payload, _ in boxes(payload + 8, stop):
                        handle.seek(ref_payload)
                        flags = struct.unpack(">I", handle.read(4))[0] & 0xFFFFFF
                        # QuickTime writes a self-referencing 'alis' entry; ISO media uses 'url '.
                        refs.append(ref_type in (b"url ", b"alis") and bool(flags & 1))
        walk(0, path.stat().st_size)
    return bool(refs) and all(refs)


def sha256(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", type=Path)
    parser.add_argument("results", type=Path)
    parser.add_argument("--ffprobe", type=Path, default=Path(__file__).resolve().parents[1] /
                        "Trimato/Trimato/Resources/Tools/ffprobe")
    args = parser.parse_args()
    reports = []
    for native_path in sorted(args.results.glob("*-native-validation.json")):
        native = json.loads(native_path.read_text())
        source_path = args.sources / native["source"]
        original = probe(args.ffprobe, source_path)
        raw_original = probe(args.ffprobe, source_path, raw=True)
        rendered = probe(args.ffprobe, args.sources / "validation-results" / native["renderedVideo"], raw=True)
        report = {"source": native["source"], "source_sha256": sha256(source_path), "exports": []}
        for export in native["exports"]:
            path = args.results / export["file"]
            output, raw_output = probe(args.ffprobe, path), probe(args.ffprobe, path, raw=True)
            trimmed = "trim-1s-to-5s" in path.name
            entry = {"file": path.name, "self_contained": self_contained(path), "audio": []}
            require(entry["self_contained"], f"External media references: {path.name}")
            source_audio = [s for s in original["streams"] if s["codec_type"] == "audio"]
            output_audio = [s for s in output["streams"] if s["codec_type"] == "audio"]
            require(len(source_audio) == len(output_audio) == 2, "Expected paired audio tracks")
            for before, after in zip(source_audio, output_audio):
                for key in ("codec_tag_string", "channels", "sample_rate"):
                    require(before[key] == after[key], f"Audio format changed: {key}")
                a, b = packets(original, before), packets(output, after)
                start = matching_start(a, b)
                require(start is not None, f"Recompressed audio: {path.name}")
                shift = 1 if trimmed else 0
                require(all(abs(float(a[start+i]["pts_time"]) - float(p["pts_time"]) - shift) < 0.000002
                            for i, p in enumerate(b)), f"Audio timing changed: {path.name}")
                raw_a, raw_b = packets(raw_original, before), packets(raw_output, after)
                raw_start = matching_start(raw_a, raw_b)
                require(raw_start is not None, "Raw audio packet data changed")
                if not trimmed:
                    # The export may omit encoded padding outside the source edit list.
                    # Require the complete presented sequence; native PCM checks verify
                    # that decoder preroll and end padding still produce identical sound.
                    require(start == 0 and len(a) == len(b), "Full export omitted presented audio packets")
                entry["audio"].append({"codec": before["codec_tag_string"], "channels": before["channels"],
                                       "raw_packets": len(raw_b), "first_source_raw_packet": raw_start,
                                       "source_raw_packets": len(raw_a), "presented_packets": len(b),
                                       "payloads_identical": True, "presentation_time_shift_seconds": shift})
            # Compare metadata packets independently of the native Audio Mix helper.
            before_data = [s for s in raw_original["streams"] if s["codec_type"] == "data"]
            after_data = [s for s in raw_output["streams"] if s["codec_type"] == "data"]
            require(len(before_data) == len(after_data), "Metadata track count changed")
            for before, after in zip(before_data, after_data):
                a, b = packets(raw_original, before), packets(raw_output, after)
                require(matching_start(a, b) is not None, "Metadata packet data changed")
                if not trimmed:
                    require(len(a) == len(b), "Full export omitted metadata packets")
            entry["metadata_payloads_preserved"] = True
            reference = rendered if "Trimato-HDR" in path.name else raw_original
            before_video = next(s for s in reference["streams"] if s["codec_type"] == "video")
            after_video = next(s for s in raw_output["streams"] if s["codec_type"] == "video")
            for key in ("width", "height", "pix_fmt", "color_transfer", "color_primaries", "color_space"):
                require(before_video[key] == after_video[key], f"Video format changed: {key}")
            require(after_video["pix_fmt"] == "yuv420p10le" and after_video["color_transfer"] == "arib-std-b67",
                    "Expected 10-bit HLG video")
            # Passthrough may omit unneeded video preroll packets before the cut.
            require(ordered_payload_subset(packets(reference, before_video), packets(raw_output, after_video)),
                    "Video recompressed during audio preservation")
            entry["video_payloads_preserved"] = True
            report["exports"].append(entry)
            print("PASS", path.name)
        reports.append(report)
    require(len(reports) == 3 and sum(len(r["exports"]) for r in reports) == 12, "Missing prototype exports")
    with (args.results / "packet-validation.json").open("x") as handle:
        json.dump(reports, handle, indent=2)
        handle.write("\n")


if __name__ == "__main__":
    main()
