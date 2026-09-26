# Agent Cookbook - converting a verified process into an SSF-style custom workflow

This manual converts any process that has already been executed and verified into a custom agent-factory workflow in the shape of the Super Simple Software Factory (SSF).
It extracts SSF's shape, not its code, and adapts that shape to firstmate's existing machinery.
Use it when the conversion target is a workflow you will run repeatedly, rather than a single skill.

The companion `../SKILL.md` owns the verifier loop that checks a produced artifact.
This manual owns the conversion shape.
The worked example throughout is the verified Whoa Tea July-2026 retail sales analysis, which is already a proven process.

## What to carry over from SSF

Do not copy SSF's code.
Carry over these five ideas, and adapt each to firstmate's machinery.

1. **Agents propose, code disposes.**
   An agent owns the work inside one bounded phase.
   Deterministic code owns sequencing, retries, and acceptance between phases.
   The agent never decides whether its own work passed.

2. **Observable phases.**
   A run is a sequence of named phases.
   Each phase has a kind, an owner, and a completion condition.
   The trace records what phase ran, who ran it, and whether it passed.
   The plan/build/test/review/fix loop is the repeated shape.

3. **Per-agent config.**
   One config entry per agent: name, model, thinking level, prompts, harness, and the boundary of what it may change.
   Different phases can run different models at different price or speed points.

4. **YAML plus Python only, no invented DSL.**
   The config is YAML.
   The deterministic layer is real code in the repo's language.
   There is no proprietary schema to learn.

5. **Sessions reusable and resumable.**
   Running an agent and continuing it are the same call.
   A correction is a message into a live session, never a cold restart.

## Firstmate's machinery is the adaptation target

SSF applies to a repo you own.
Firstmate applies to a fleet of agent tasks.
The parts line up one to one.

| SSF idea | Firstmate equivalent |
| --- | --- |
| ADW script (`adw_*.py`) | a run recipe built from the role briefs and the backlog |
| Agent node (`kind="agent"`) | a crewmate launched through `bin/fm-spawn.sh` |
| Agent prompt (`prompt_engineering/`) | the task brief from `bin/fm-brief.sh` |
| Per-agent config (`sssf.config.yaml`) | the dispatch profile in `config/crew-dispatch.json` plus the harness and model pins |
| Deterministic gate (`gates.py`) | a no-mistakes gate, a shellcheck-clean script, a set check |
| Trace (`sssf.db`, `events`) | the task's status file, metadata, and the durable backlog record |
| Session resume (`--session-id`) | the crewmate's persistent session through `bin/fm-control.sh` |
| Run surface (`just demo`, trace UI) | a herdr pane projecting the run |

The point of the adaptation is that firstmate already owns most of the machinery.
The conversion is mainly a mapping decision: which part of the verified process becomes an agent phase, and which part becomes a deterministic gate.

## The ADW phase shape

Every phase is one of three kinds.

- **engineer** - the human decides something the workflow cannot.
- **agent** - a bounded agent does the work and returns a typed result.
- **code** - a deterministic step runs on its own, like a commit or a check.

A phase defaults to not having passed.
It passes when it could have failed and did not.
An agent phase also needs its result to parse and its gates to come back green.
Let `code` own anything whose invocation is already known, such as running a test suite or a formatter, because paying an agent to do arithmetic is wasted leverage.

An agent has exactly two output channels: reference files it leaves in a handoff location, and a final structured result that code validates.
Context crosses a seam in code, not in conversation.

## The config schema, adapted

A firstmate-flavored config keeps SSF's shape but speaks firstmate's nouns.
This is illustration, not a shipped format.

```yaml
defaults:
  coding_agent: pi
  model: anthropic/claude-sonnet-4
  thinking: medium
  # Anything an agent may not edit, even with bash.
  protected_files:
    - bin/
    - data/

run:
  breadcrumb: data/skills-verifier-build-i1   # where this run's artifacts land
  trace:
    status_file: state/<id>.status
    meta_file: state/<id>.meta

phases:
  - name: plan
    kind: agent
    owner: planner
    model: google/gemini-3.6-flash
    writes: [specs/]
  - name: build
    kind: agent
    owner: builder
    model: anthropic/claude-sonnet-4
    writes: [src/, tests/]           # the only phase that may change source
  - name: test
    kind: code
    owner: gates                     # no agent; run the suite
    command: bin/gate-test.sh
  - name: review
    kind: agent
    owner: reviewer
    model: openai/gpt-5.6-terra
    writes: []
  - name: fix
    kind: agent
    owner: builder
    model: anthropic/claude-sonnet-4
    writes: [src/, tests/]           # fix re-enters source with build's boundary; review is the only read-only phase
```

The per-agent essence is the same four plus one: model, thinking, prompts, tools, and the write boundary.
The write boundary is what makes a read-only phase genuinely read-only, because a tool list alone cannot stop `bash` from running `git checkout`.

## Deterministic gates, adapted

A gate verifies a claim the agent declared, after the fact.
It is never a prediction, because nobody knows what an agent will touch before it finishes.
A gate is a check with the signature `gate(result, run) -> report`, and each check names what it verified.

Firstmate's gates are the no-mistakes steps and the repo's own checks.
Map the verified process's checks onto those.

| SSF gate | Firstmate gate |
| --- | --- |
| `json_parses` | the brief's structured exit contract, parsed |
| `artifacts_exist` | the expected deliverables exist at the declared paths |
| `files_non_empty` | the key outputs are non-empty |
| `diff_matches_claims` | the changed files match the task's declared scope |
| `tests_pass(...)` | a no-mistakes run step, or the repo's own test runner |
| `quality` / lint | a shellcheck-clean or lint gate |

The rule to keep is that the gate layer never decides the work is good.
It decides the work meets its own declared contract.
The human decides whether the result is what was asked for.

## The worked example: the data-analysis process

The Whoa Tea July-2026 analysis is already a verified process.
Its evidence is the report, the methods note, the authoritative conventions module, and the 21 executed notebooks in `notebooks/full/`.
The process has eight phases, and each maps cleanly onto the SSF shape.

| Verified process phase | AS a phase kind | Who owns it | The gate |
| --- | --- | --- | --- |
| Setup | code | deterministic script | the conventions module imports read-only |
| Ingest | code | deterministic loader | the On-Account fix is applied |
| Per-branch | agent | builder | `bill_product_coverage >= 0.60` for line items |
| Region | agent | builder | the `REGION` map, none unassigned |
| Company | code | deterministic roll-up | the 17-branch sum equals the roll-up |
| Product & category | agent | builder | exclusions applied, Keeta footnote carried |
| Reconcile | code | deterministic check | exact reconciliation to SAR 1,070,940.27 / 30,857 bills |
| Report | agent | builder | every line-item metric carries the Keeta footnote |

The insight is that most of this process is deterministic and should be `code`.
Only the parts that require reading and deciding, like interpreting each region or choosing which product insight to surface, are `agent`.
The wrong conversion would make every phase an agent and pay for arithmetic that a script already knows.

## Step-by-step conversion procedure

1. **Capture the verified process as named phases.**
   Write each phase, its input, its output, and the condition that says it is done.
   Use the evidence, not a spec.

2. **Split each phase into agent versus code.**
   A phase whose invocation is already known is `code`.
   A phase that needs reading and deciding is `agent`.

3. **Identify the deterministic gates.**
   For each agent phase, name the after-the-fact check that verifies its declared contract.
   Map each to a no-mistakes step, a repo script, or a set check.

4. **Assign an agent per phase.**
   Give the planner a frontier model and the builder a cheaper, faster one.
   Give the reviewer no writes at all (writes: []).

5. **Write the config.**
   YAML only, one entry per agent, with model, thinking, prompts, harness, and the write boundary.
   Do not invent a DSL.

6. **Wire the gate calls.**
   Each agent phase ends by handing a structured result to the deterministic layer, which validates and gates it.
   A violation returns to the same live session as a correction, not a restart.

7. **Run and observe.**
   Each phase writes to the task's status and meta records as it runs.
   Read the run from the trace, not from a transcript novel.

8. **Fix and re-run.**
   A correction is a steering message into the same session.
   The fix phase reuses the session, so it does not relearn what it just learned.

## Sessions reusable and resumable

A session is keyed by its identity, not by its process, so resuming is the same call as running.
In SSF that is `--session-id` create-or-continue.
In firstmate that is the crewmate's persistent session, steered and resumed through `bin/fm-control.sh`.
A correction must cost one message, never a cold start.
Never restart a session to throw away what the agent learned; restart only when the task is genuinely stuck.

## Gotchas and honest limits

- Keeping a phase as `code` instead of `agent` is the single biggest leverage decision.
  Most teams ship agents that do arithmetic.
- A read-only agent is read-only with respect to the repo, not unable to write its own report.
- The gate layer verifies contract, not quality.
  Do not let a green gate stand in for the human's judgement.
- The configuration and the prompt are both owned by the run, not by a copy inside a skill.
  Edit them in place, or the run drifts from the description.
- A verifier loop (see the parent skill) is the path to trust the agent-built artifact.
  A workflow that gates with code cannot vouch for prose it did not write.

## Open questions the captain should answer

- Should the deterministic layer be `bin/` shell gates, or a dedicated script module?
- Which phases of the data-analysis process warrant an agent, versus staying as `code`?
- Should the config be a tracked file or a private dispatch profile?
