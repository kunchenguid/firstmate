# Crewmate reference

Audience: a crewmate or scout working a firstmate task.

Your brief is deliberately short.
It carries what you must act on without being prompted.
This file carries the rest: contracts that only matter once you reach a specific moment.
Your brief names that moment and points here; read the matching section then, not before.

## Closing a decision, blocker, or wait you opened

Read this when a `needs-decision:`, `blocked:`, or declared-wait line you appended has stopped being true.

Firstmate tracks each escalation you open as a record that stays open until a `resolved` line closes it.
Only a `resolved` line closes one.
A later `done:` or `working:` line does not, even when the answer you received is exactly what started that work.
Without the closing line, firstmate keeps re-surfacing a decision you have already moved past.

Two paths close a record, depending on who ended it:

- **Firstmate answered you.** Firstmate normally writes the closing line at answer time; you do not need to write one.
- **It cleared on its own.** Append `resolved: {how it cleared}` yourself as you resume.

If you opened the record with a key - `blocked [key=<slug>]: ...` - the closing line must carry that same key: `resolved [key=<slug>]: ...`.
The key is how firstmate matches the close to the record; a `resolved` line with the wrong key or no key leaves the original open.

## Driving the no-mistakes pipeline

Read this before your first `no-mistakes` command on a task whose delivery contract is `mode=no-mistakes`.

Your role changes when the pipeline starts.
Up to that point you were implementing; from that point you are answering gates.
The pipeline applies every fix itself, so do not hand-edit, commit, or fix findings while a run is active - a hand-edit during a run puts your changes and the pipeline's in conflict over the same branch.

The mechanics are owned by the installed binary, not by this file.
`/no-mistakes` loads its own guidance when you invoke it, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to what is installed.
Follow those over any remembered flag.

### What `--intent` must carry

`--intent` is how the pipeline learns what you were asked to build, and it is judged against that text.
Make it preserve all relevant content from your brief's `# Task` section, plus every later accepted firstmate requirement, clarification, constraint, exclusion, and supersession.
Carry only each requirement's current accepted form: when a requirement was superseded, state the version that now stands rather than both.
Retain the direct requirements themselves instead of substituting a summary of the diff you wrote.
Exclude generic operational, status, delivery, and other scaffold boilerplate unless it is specific to this task.

### ask-user findings are not yours to answer

An ask-user finding is a decision above the implementation worker, and you are the implementation worker.
Escalate it with a `needs-decision:` line and stop, exactly as your brief's escalation rule says.
Firstmate applies the authority contract in its own `AGENTS.md` and obtains any captain decision the finding requires.

When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it.
Do not route the question onward to "the user", and do not implement the fix yourself.
Avoid `--yes`: it answers gates on your behalf, and would silently bypass firstmate's authority check and any required captain escalation.

### Where you stop

CI turning green is your return point.
Report it and stop; do not keep monitoring in the background until merge.
Merge authority sits with firstmate and the captain, never with you.
