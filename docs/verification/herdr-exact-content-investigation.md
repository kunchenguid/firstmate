# Herdr exact-content investigation (R5)

Status: **unresolved; F1 acceptance remains unmet on Herdr**. Exact equality remains mandatory. No live Herdr pane was read or modified during this investigation.

## Installed CLI evidence

The following read-only metadata commands were executed in the review environment.

`herdr --version` returned:

```text
herdr 0.8.0
```

`herdr api --help` returned:

```text
Inspect socket API metadata and live runtime state

Usage: herdr api [COMMAND]

Commands:
  snapshot  Print the live session snapshot
  schema    Print or write the bundled API schema
```

`herdr pane read --help` returned these arguments and options:

```text
Read pane terminal output

Usage: herdr pane read [OPTIONS] <PANE_ID>

Arguments:
  <PANE_ID>

Options:
      --source <SOURCE>
          Terminal snapshot source (default: recent)

          [possible values: visible, recent, recent-unwrapped, detection]

      --lines <N>

      --format <FORMAT>
          [possible values: text, ansi]

      --ansi

      --raw
```

`herdr api schema --help` exposed `--json` and `--output <PATH>`.

`herdr api schema` returned:

```text
Herdr API schema
protocol: 19
schema_version: 1
schemas: error_response, event, request, subscription_event, success_response

Use `herdr api schema --json` to print the full schema.
Use `herdr api schema --output PATH` to write it to a file.
```

`herdr api schema --json` returned the bundled schema. Its `PaneReadParams` properties are `format` (default `text`), `lines` (nullable uint32), `pane_id`, `source`, and `strip_ansi` (default `true`). Required parameters are `pane_id` and `source`.

Its `PaneReadResult` requires `pane_id`, `workspace_id`, `tab_id`, `source`, `format`, `text`, `revision`, and `truncated`. The result supplies rendered text and a truncation indicator, but no cell occupancy or whitespace-preservation contract.

## What this establishes—and does not

Visible capture and raw/ANSI modes exist. The help does not explain whether `--raw` preserves input spaces, changes escape handling, or only changes CLI serialization. The schema does not settle that question. Neither metadata absence nor the current adapter's refusal proves that Herdr cannot capture losslessly. Consequently, adding `lossless=1` on this evidence would be unjustified.

`printf 'HERDR_ENV=%s\n' "${HERDR_ENV:-}"` returned:

```text
HERDR_ENV=
```

This agent is outside Herdr. The Herdr skill prohibits inspecting or controlling the focused session from that context. Static help and bundled schema inspection do not access a live session. No `pane read` against a live pane, real-capture regression, or Muse inbox acceptance was performed. R5 therefore remains open, not resolved as an API impossibility.

## Required follow-up

In a Herdr-managed verification environment, render known byte fixtures in a dedicated test pane and compare real `visible` reads across `text`, `ansi`, and `--raw` modes. Include an exact doorbell, a trailing-space variant, and a multiline draft with a blank row followed by other text. Verify capture completeness and truncation handling as well as space preservation before assigning `lossless=1`. Then exercise ring and lifecycle recovery through the production capture adapter. The outer acceptance phase must separately prove that a newly launched Muse lane reads `001.msg` without human assistance.
