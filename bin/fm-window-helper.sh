#!/usr/bin/env bash
# fm-window-helper.sh - disabled no-TCC visible-window helper contract.
#
# This initial helper never calls AppKit, CoreGraphics, Apple Events,
# Accessibility, Screen Recording, keyboard, mouse, screenshots, or browser APIs.
# It exists so fm-browser tests and callers can bind to a narrow value-safe
# receipt shape before the signed macOS helper is implemented.
#
# Usage:
#   fm-window-helper.sh capabilities [--json]
#   fm-window-helper.sh activate-visible --browser-pid <pid> --birth-token <token> --display-id <id> [--json]
#   fm-window-helper.sh observe --browser-pid <pid> --birth-token <token> [--json]
#
# Set FM_WINDOW_HELPER_MOCK=1 only in tests to return a synthetic frontmost and
# on-screen receipt. Without it every action refuses before touching the system.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

python3 - "$@" <<'PY'
import argparse, json, os, sys, time

SCHEMA = "fm-window-helper-receipt.v1"
MOCK = os.environ.get("FM_WINDOW_HELPER_MOCK") == "1"


def out(obj, as_json):
    if as_json:
        print(json.dumps(obj, sort_keys=True))
    else:
        for k, v in obj.items():
            print(f"{k}: {v}")


def refuse(as_json):
    obj = {"schema": SCHEMA, "result": "error", "code": "helper-disabled", "message": "real macOS window activation is disabled until the signed no-TCC helper is verified"}
    out(obj, as_json)
    raise SystemExit(1)


def capabilities(args):
    out({"schema": "fm-window-helper-capabilities.v1", "realActivation": False, "mock": MOCK, "usesAccessibility": False, "usesScreenRecording": False, "usesAppleEvents": False, "usesInputInjection": False}, args.json)


def activate(args):
    if not MOCK:
        refuse(args.json)
    out({"schema": SCHEMA, "result": "ok", "mock": True, "browserPid": args.browser_pid, "birthToken": "redacted", "displayId": args.display_id, "frontmost": True, "onScreen": True, "normalWindowCount": 1, "timestamp": int(time.time())}, args.json)


def observe(args):
    if not MOCK:
        refuse(args.json)
    out({"schema": SCHEMA, "result": "ok", "mock": True, "browserPid": args.browser_pid, "birthToken": "redacted", "frontmost": True, "onScreen": True, "normalWindowCount": 1, "timestamp": int(time.time())}, args.json)

parser = argparse.ArgumentParser(prog="fm-window-helper.sh", add_help=False)
sub = parser.add_subparsers(dest="command", required=True)
p = sub.add_parser("capabilities")
p.add_argument("--json", action="store_true")
p.set_defaults(func=capabilities)
p = sub.add_parser("activate-visible")
p.add_argument("--browser-pid", required=True)
p.add_argument("--birth-token", required=True)
p.add_argument("--display-id", required=True)
p.add_argument("--json", action="store_true")
p.set_defaults(func=activate)
p = sub.add_parser("observe")
p.add_argument("--browser-pid", required=True)
p.add_argument("--birth-token", required=True)
p.add_argument("--json", action="store_true")
p.set_defaults(func=observe)
ns = parser.parse_args()
ns.func(ns)
PY
