#!/usr/bin/env python3
"""Merge a freshly generated Sparkle appcast item into the published appcast.

Sparkle's ``generate_appcast`` only emits items for archives it can see in a
folder, and we don't keep every past release's zip around — each release builds
one archive and publishes it to GitHub Releases. So the published appcast has to
be carried forward and the new item spliced in.

Why a parser and not sed: the obvious implementation splits the old file at
``<channel>`` and cats the new ``<item>`` in. That works right up until any
formatting changes — a self-closing ``<channel/>``, an attribute on the tag, a
comment containing the word, CRLF line endings — and then it emits malformed XML
that Sparkle rejects at the point where the only symptom is "no updates found".
ElementTree either parses it or fails loudly, which is the behaviour worth
having in a release pipeline.

Usage: merge-appcast.py <new-appcast.xml> <old-appcast.xml|-> <output.xml>

Passing ``-`` for the old appcast means "no published appcast yet" (the first
release), and the new one is written through unchanged.
"""

import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def item_version(item):
    """The value Sparkle actually compares: CFBundleVersion, as sparkle:version.

    Older appcasts put it in an attribute on <enclosure> rather than in its own
    element, so both spellings are accepted. Returns None when neither is
    present, which the caller treats as "can't dedupe this one" rather than
    guessing.
    """
    element = item.find(f"{{{SPARKLE_NS}}}version")
    if element is not None and element.text:
        return element.text.strip()
    enclosure = item.find("enclosure")
    if enclosure is not None:
        attr = enclosure.get(f"{{{SPARKLE_NS}}}version")
        if attr:
            return attr.strip()
    return None


def channel_of(tree, path):
    channel = tree.find("channel")
    if channel is None:
        sys.exit(f"error: {path} has no <channel> element")
    return channel


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    new_path, old_path, out_path = sys.argv[1:]

    # Keep the sparkle prefix as "sparkle" on output. Without this ElementTree
    # invents ns0:, which is technically equivalent XML but makes every future
    # diff of the published appcast unreadable.
    ET.register_namespace("sparkle", SPARKLE_NS)

    new_tree = ET.parse(new_path)
    new_items = channel_of(new_tree, new_path).findall("item")
    if not new_items:
        sys.exit(f"error: {new_path} contains no <item> — nothing to publish")

    if old_path == "-":
        new_tree.write(out_path, encoding="UTF-8", xml_declaration=True)
        print(f"no published appcast; wrote {len(new_items)} item(s) as-is")
        return

    old_tree = ET.parse(old_path)
    old_channel = channel_of(old_tree, old_path)

    # Re-running a release must not append a duplicate item: Sparkle picks the
    # best of them, but the appcast grows a copy on every retry and the extra
    # entries are indistinguishable from real history.
    new_versions = {v for v in (item_version(i) for i in new_items) if v}
    for existing in list(old_channel.findall("item")):
        version = item_version(existing)
        if version and version in new_versions:
            old_channel.remove(existing)
            print(f"replaced existing item for version {version}")

    # Newest first. Sparkle does not require the order, but a human reading the
    # published file does, and this is the file people check when an update
    # didn't appear.
    for offset, item in enumerate(new_items):
        old_channel.insert(offset, item)

    old_tree.write(out_path, encoding="UTF-8", xml_declaration=True)
    print(f"merged {len(new_items)} item(s); {len(old_channel.findall('item'))} total")


if __name__ == "__main__":
    main()
