#!/usr/bin/env python3
"""Parse the small YAML subset used by tracked GitHub workflow contracts."""

import ast
import json
import sys


def scalar(value):
    value = value.strip()
    if not value:
        return {}
    if value in {"true", "True"}:
        return True
    if value in {"false", "False"}:
        return False
    if value in {"null", "Null", "NULL", "~"}:
        return None
    if value.isdigit():
        return int(value)
    if value[:1] in {"'", '"'} and value[-1:] == value[:1]:
        return ast.literal_eval(value)
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [scalar(part) for part in inner.split(",")]
    return value


def split_key(content):
    key, separator, value = content.partition(":")
    if not separator:
        raise ValueError(f"mapping entry missing colon: {content}")
    key = key.strip()
    if key[:1] in {"'", '"'} and key[-1:] == key[:1]:
        key = ast.literal_eval(key)
    return key, value.strip()


def load_lines(path):
    result = []
    with open(path, encoding="utf-8") as stream:
        for raw in stream:
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            result.append((len(raw) - len(raw.lstrip(" ")), raw.rstrip("\n")))
    return result


def assign_value(lines, index, key_indent, remainder, key, mapping):
    if remainder in {"|", "|-", ">", ">-"}:
        chunks = []
        content_indent = lines[index][0] if index < len(lines) else key_indent + 2
        while index < len(lines) and lines[index][0] > key_indent:
            chunks.append(lines[index][1][content_indent:])
            index += 1
        mapping[key] = ("\n" if remainder.startswith("|") else " ").join(chunks)
        return index
    if remainder:
        mapping[key] = scalar(remainder)
        return index
    if index < len(lines) and lines[index][0] > key_indent:
        mapping[key], index = parse_block(lines, index, lines[index][0])
    else:
        mapping[key] = {}
    return index


def parse_block(lines, index, indent):
    is_list = lines[index][0] == indent and lines[index][1][indent:].startswith("- ")
    value = [] if is_list else {}
    while index < len(lines):
        current_indent, raw = lines[index]
        if current_indent != indent:
            break
        content = raw[indent:]
        if is_list:
            if not content.startswith("- "):
                break
            remainder = content[2:].strip()
            if ":" not in remainder:
                value.append(scalar(remainder))
                index += 1
                continue
            key, remainder = split_key(remainder)
            item = {}
            index += 1
            assign_indent = indent + 2
            index = assign_value(lines, index, assign_indent, remainder, key, item)
            while index < len(lines) and lines[index][0] == assign_indent:
                key, remainder = split_key(lines[index][1][assign_indent:])
                index += 1
                index = assign_value(lines, index, assign_indent, remainder, key, item)
            value.append(item)
            continue
        key, remainder = split_key(content)
        index += 1
        index = assign_value(lines, index, indent, remainder, key, value)
    return value, index


def load_yaml_subset(path):
    lines = load_lines(path)
    if not lines:
        return {}
    value, index = parse_block(lines, 0, lines[0][0])
    if index != len(lines):
        raise ValueError(f"unparsed workflow content at line {index + 1}")
    return value


if len(sys.argv) != 2:
    raise SystemExit("usage: workflow-contract.py WORKFLOW")
print(json.dumps(load_yaml_subset(sys.argv[1]), separators=(",", ":")))
