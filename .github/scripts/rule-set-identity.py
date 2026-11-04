#!/usr/bin/env python3
"""Canonical fingerprint of a decompiled sing-box rule-set.

Upstream rebuilds can reorder domain and regex lists, or rewrite the binary,
without changing which names and addresses match. Sorting those lists makes
that noise compare equal. Rule order is preserved.
"""

import hashlib
import json
import sys


def canonical(value):
    if isinstance(value, list):
        items = [canonical(item) for item in value]
        if items and all(isinstance(item, str) for item in items):
            return sorted(items)
        if items and all(isinstance(item, (int, float)) and not isinstance(item, bool) for item in items):
            return sorted(items)
        return items
    if isinstance(value, dict):
        return {key: canonical(item) for key, item in value.items()}
    return value


def fingerprint(payload):
    encoded = json.dumps(canonical(payload), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode()).hexdigest()


def main():
    if len(sys.argv) != 2:
        print("usage: rule-set-identity.py <decompiled.json>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as handle:
        payload = json.load(handle)
    print(fingerprint(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
