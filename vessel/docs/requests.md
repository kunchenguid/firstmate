# vessel requests

A vessel request asks firstmate to run one Remy-style workflow with one vessel agent.
The captain can phrase it in chat ("review https://github.com/acme/webapp/pull/42", "implement AA4FI-1234 with Slim Charles").
Tools such as the future TUI hotkeys send the canonical form below as a firstmate inbox note:

```sh
bin/fm-inbox.sh note --request-id vessel-<uuid> --json -- '[vessel] review acme/webapp#42 agent="Snoop"'
```

The `vessel-workflows` skill (`.agents/skills/vessel-workflows/SKILL.md`) handles both forms the same way.
In chat the target may be loose or left out ("review this PR"); the skill resolves it from what vessel shows, in `data/vessel/context.json`.

## Canonical form

```
[vessel] <workflow> <target> [key=value ...]
```

Values that contain spaces are double-quoted, and `\"` escapes a quote inside a value.

| Workflow      | Target                     | Agent mode  | firstmate kind       |
| ------------- | -------------------------- | ----------- | -------------------- |
| `implement`   | Jira key (`AA4FI-1234`)    | Implement   | ship                 |
| `plan`        | Jira key                   | Plan        | scout                |
| `review`      | PR (`owner/repo#N` or URL) | Review      | scout                |
| `address`     | PR                         | Address     | ship on existing PR  |
| `conflicts`   | PR                         | Conflicts   | ship on existing PR  |
| `description` | PR                         | Description | scout                |
| `ticket`      | Jira feature key           | Ticket      | scout                |
| `free`        | PR                         | none        | captain's own prompt |

## Options

| Key        | Meaning                                                                         |
| ---------- | ------------------------------------------------------------------------------- |
| `agent`    | Agent name from `config/vessel/agents.json`; defaults to the mode's default agent |
| `model`    | Overrides the agent's model for this run only                                   |
| `effort`   | Overrides the agent's effort for this run only                                  |
| `plan`     | Task id of an earlier `plan` run; its `data/<id>/report.md` becomes the plan    |
| `comments` | Comma-separated review comment/thread ids to address (`address` only)           |
| `base`     | Base branch for `implement` when the project default does not apply             |
| `extra`    | Extra context, copied verbatim into the brief                                   |
| `prompt`   | The prompt for `free`, or the description for `ticket`                          |

## Task ids

`<workflow>-<target-slug>`, lowercase, e.g. `implement-aa4fi-1234`, `review-webapp-42`, `ticket-aa4fi-100`.
A rerun appends `-2`, `-3`, … so earlier runs keep their history.
