#!/usr/bin/env python3
"""Read tests/ambient-seal.tsv and report on the ambient operator environment.

Two modes:

  names <registry>    print, one per line, every environment variable currently
                      set that the seal covers. tests/run.sh unsets each one
                      before it admits a test.
  records <registry>  print the declared records as `kind<TAB>value`, for the
                      structural guard to pin.

The registry is data, not code, so the seal cannot be widened or narrowed
without a visible diff. A malformed or unreadable registry is a refusal (exit
97), never an empty seal: "no names matched" and "the seal did not load" must not
look the same to the caller.
"""

from __future__ import annotations

import os
import sys

KINDS = ("exact", "prefix")


def load(path: str) -> list[tuple[str, str]]:
    records: list[tuple[str, str]] = []
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as error:
        print("ambient seal is unreadable: {}".format(error), file=sys.stderr)
        raise SystemExit(97)
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 3 or fields[0] not in KINDS or not fields[1] or not fields[2].strip():
            print(
                "ambient seal line {} is malformed (want kind<TAB>value<TAB>why): {!r}".format(
                    number, line
                ),
                file=sys.stderr,
            )
            raise SystemExit(97)
        records.append((fields[0], fields[1]))
    if not records:
        print("ambient seal declares nothing; an empty seal is a wiring mistake", file=sys.stderr)
        raise SystemExit(97)
    return records


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("names", "records"):
        print("usage: ambient-seal.py names|records <registry>", file=sys.stderr)
        return 2
    records = load(argv[2])
    if argv[1] == "records":
        for kind, value in records:
            print("{}\t{}".format(kind, value))
        return 0
    exact = {value for kind, value in records if kind == "exact"}
    prefixes = tuple(value for kind, value in records if kind == "prefix")
    for name in sorted(os.environ):
        if name in exact or name.startswith(prefixes):
            print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
