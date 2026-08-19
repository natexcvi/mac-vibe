#!/usr/bin/env python3
"""Write the Sparkle appcast for a release.

Sparkle ships a `generate_appcast` tool, but it wants a directory holding every
archive ever released so it can rebuild the whole feed. A tag-triggered CI job
starts from an empty runner and only has the archive it just built, so instead
we emit the one new <item> and carry forward the previous feed's entries.
"""
import argparse
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from xml.dom import minidom

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

# How many historical entries to keep. Sparkle only needs the newest to offer
# an update; the rest are there so the version history stays browsable.
MAX_ITEMS = 10


def parse_signature_line(line):
    """`sign_update` prints ready-made XML attributes, e.g.
    sparkle:edSignature="Xy…==" length="12345" """
    sig = re.search(r'sparkle:edSignature="([^"]+)"', line)
    length = re.search(r'length="(\d+)"', line)
    if not sig or not length:
        sys.exit(f"could not parse sign_update output: {line!r}")
    return sig.group(1), length.group(1)


def load_previous(source):
    """Previous items from a URL or path. A missing feed is normal — the first
    release has no predecessor — so failures here are not fatal."""
    if not source:
        return []
    try:
        if source.startswith(("http://", "https://")):
            with urllib.request.urlopen(source, timeout=30) as response:
                raw = response.read()
        else:
            with open(source, "rb") as handle:
                raw = handle.read()
        return ET.fromstring(raw).find("channel").findall("item")
    except Exception as exc:  # noqa: BLE001 — any failure means "no history"
        print(f"note: no previous appcast ({exc})", file=sys.stderr)
        return []


def build_item(args, signature, length):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.version}"
    ET.SubElement(item, "pubDate").text = datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = args.min_os
    if args.notes_url:
        ET.SubElement(item, f"{{{SPARKLE_NS}}}releaseNotesLink").text = args.notes_url
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.url,
            "length": length,
            "type": "application/octet-stream",
            f"{{{SPARKLE_NS}}}edSignature": signature,
        },
    )
    return item


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--build", required=True, help="CFBundleVersion — what Sparkle compares")
    parser.add_argument("--min-os", required=True)
    parser.add_argument("--url", required=True, help="download URL for the zip")
    parser.add_argument("--signature-line", required=True, help="raw sign_update output")
    parser.add_argument("--notes-url", default="")
    parser.add_argument("--previous", default="", help="URL or path of the existing appcast")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    signature, length = parse_signature_line(args.signature_line)

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "MacVibe"
    ET.SubElement(channel, "link").text = (
        "https://github.com/natexcvi/mac-vibe/releases/latest/download/appcast.xml"
    )
    ET.SubElement(channel, "description").text = "MacVibe updates"
    ET.SubElement(channel, "language").text = "en"

    channel.append(build_item(args, signature, length))

    # Drop any previous entry for this same build, so re-running a release
    # replaces its item instead of listing it twice.
    for item in load_previous(args.previous):
        existing = item.find(f"{{{SPARKLE_NS}}}version")
        if existing is not None and existing.text == args.build:
            continue
        channel.append(item)
        if len(channel.findall("item")) >= MAX_ITEMS:
            break

    pretty = minidom.parseString(ET.tostring(rss, "utf-8")).toprettyxml(indent="  ")
    # minidom leaves blank lines behind wherever it reindents existing nodes.
    pretty = "\n".join(line for line in pretty.split("\n") if line.strip())
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(pretty + "\n")
    print(f"wrote {args.output} ({args.version} / build {args.build})")


if __name__ == "__main__":
    main()
