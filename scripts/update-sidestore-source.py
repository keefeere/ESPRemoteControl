#!/usr/bin/env python3

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepend a release to an AltSource feed")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--size", type=int, required=True)
    parser.add_argument("--description")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source = json.loads(args.source.read_text(encoding="utf-8"))
    versions = source["apps"][0]["versions"]

    release = {
        "version": args.version,
        "date": args.date,
        "downloadURL": args.download_url,
        "size": args.size,
        "minOSVersion": "17.0",
    }
    if args.description:
        release["localizedDescription"] = args.description

    source["apps"][0]["versions"] = [
        release,
        *(entry for entry in versions if entry.get("version") != args.version),
    ]
    args.source.write_text(
        json.dumps(source, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
