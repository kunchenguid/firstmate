#!/usr/bin/env bash
printf 'session-start\n' >>"$(cd "$(dirname "$0")/.." && pwd)/.session-started"
exit 0
