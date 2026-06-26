#!/usr/bin/env python3
"""Validate that every key in Helm values files has a matching entry in values.schema.json.

Walks YAML values files recursively and checks that each dot-separated key path
exists in the JSON Schema's properties hierarchy.

Usage:
    validate-values-schema.py <schema.json> <values.yaml> [<values.yaml> ...]

Exit codes:
    0 — all keys covered
    1 — missing schema entries found
"""

import json
import sys

import yaml


def extract_paths(obj, prefix=""):
    """Yield all dot-separated key paths from a nested dict."""
    if not isinstance(obj, dict):
        return
    for key, value in obj.items():
        path = f"{prefix}.{key}" if prefix else key
        yield path
        if isinstance(value, dict) and value:
            yield from extract_paths(value, path)


def schema_has_path(schema, path):
    """Check whether a dot-separated path exists in the JSON Schema properties tree."""
    node = schema
    for part in path.split("."):
        props = node.get("properties", {})
        if part not in props:
            return False
        node = props[part]
    return True


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <schema.json> <values.yaml> [<values.yaml> ...]",
              file=sys.stderr)
        return 1

    schema_path = sys.argv[1]
    values_paths = sys.argv[2:]

    with open(schema_path) as f:
        schema = json.load(f)

    errors = 0
    for vpath in values_paths:
        with open(vpath) as f:
            values = yaml.safe_load(f)
        if not isinstance(values, dict):
            continue

        missing = sorted(
            p for p in extract_paths(values) if not schema_has_path(schema, p)
        )
        for p in missing:
            print(f"{vpath}: key '{p}' has no schema entry")
            errors += 1

    if errors:
        print(f"\n{errors} value key(s) missing from schema.", file=sys.stderr)
        return 1

    print("All value keys are covered by the schema.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
