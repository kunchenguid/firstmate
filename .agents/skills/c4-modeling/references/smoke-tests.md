# Behavioral smoke tests

Evaluate outcomes, not exact wording or required diagram counts.
Use synthetic source fixtures in an isolated workspace; do not contact live services.
These are test cases for installation/maintenance, not a claim that an independent agent already ran them.

| Input request and evidence | Expected observable behavior | Failure to catch |
|---|---|---|
| “Draw C4 for this app”: one API process, an imported SDK, owned cloud bucket, relational schema and a separate worker. | Context stays at system/people level; container view shows API, store/schema and worker; SDK is described inside its host, not a fake microservice. | Treating every folder/package or hosted bucket as an external software system. |
| “Explain approvals”: API transaction calls an external authority after acquiring a lock, then writes decision and outbox. | Component view expands only API; dynamic view orders authority recheck and transaction effects accurately and labels protocols. | Several bounded modules drawn as network services or authority granted by an earlier stale check. |
| “Show current and future deployment”: code exists but the only runtime evidence is mocked tests. | Current source and target environment are labelled separately; no live URL or running replica count is invented. | A renderable diagram described as deployed proof. |
| “Show migration rollback”: old and new stores, writes admitted after cutover. | Distinguishes pre-write routing reversal, post-write preservation/replay, content rollback and binary/schema compatibility. | Claim that toggling a route automatically recovers accepted writes. |
| “Make an org chart.” | Does not activate C4 modeling merely because the request says diagram. | Applying software container semantics to reporting hierarchy. |
| User supplies valid-looking Mermaid with an unclosed node or unlabeled relationship. | Parser failure is fixed or disclosed; semantic review catches the unlabeled relationship even when syntax passes. | Declaring model quality from parser success alone. |
| “Only context and containers, use PlantUML.” | Uses those two views and the requested notation; no forced Level 3/4, renderer change or extra workflow. | Expanding scope because templates are available. |

For a forward test after installation, give a fresh agent one input plus the skill and raw fixture sources, without an intended solution.
Record its diagrams, parser output and model-classification errors; revise only demonstrated problems.
Respect the active task's delegation and external-action permissions.
