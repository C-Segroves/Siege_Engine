"""Shared helper for exporters that write a pack's pack.json."""
import json
import os


def merge_pack_json(out_dir, own_keys):
    """The exporter's own keys over an existing pack.json, keeping what the importer added
    (e.g. era / year); returns the merged dict."""
    path = os.path.join(out_dir, 'pack.json')
    meta = json.load(open(path, encoding='utf-8')) if os.path.exists(path) else {}
    meta.update(own_keys)
    return meta
