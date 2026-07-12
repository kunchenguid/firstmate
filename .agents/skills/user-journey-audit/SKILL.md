---
name: user-journey-audit
description: Run an evidence-backed, two-persona user-journey audit of an app and consolidate the findings into a prioritized report. Use when the captain invokes /user-journey-audit or asks to audit an app as a new and returning user, walk its onboarding, or evaluate its user experience end to end. Resolves the target project, exercises an isolated new user and an isolated returning user against a local test instance with headless browser automation by default, records goal completion and friction with screenshots/URLs/console evidence, separates defects from UX improvements from grounded feature ideas, presents a rendered HTML report plus a concise chat summary, and files no work until the captain explicitly approves.
user-invocable: true
metadata:
  internal: true
---

# user-journey-audit

Produce an evidence-backed audit of how a real person experiences an app, from two isolated vantage points: a genuinely new user meeting the product for the first time, and a returning user with established history who is trying to continue their work.
The deliverable is knowledge, not a code change, so this runs as a scout task (`AGENTS.md` section 7): its output is a report at `data/<id>/report.md`, durable evidence and a rendered HTML review surface under `data/<id>/evidence/`, and a concise chat summary, never a PR.
It ends with proposed work presented to the captain for approval; it never files, dispatches, or starts an implementation task on its own.

This skill is invoked only when the captain asks for it.
It is idle by default and must never schedule, repeat, or self-initiate an audit.
Each invocation is one audit of one target; when it is done, it stops.

## Safety rails (apply before any browsing)

- **Local test instance by default.**
  Audit a locally running instance of the app, never production.
  Do not mutate production data or create production user accounts.
  Only audit against production, or create real user data anywhere, when the captain explicitly authorizes that scope in this invocation, and even then never take a destructive, irreversible, or account-deleting action without a second explicit confirmation.
- **Headless by default.**
  Drive the browser through `chrome-devtools-axi` in headless mode.
  Use visible headed mode only when the captain explicitly asks to watch the run.
  Do not memorize the headless flag; read `chrome-devtools-axi --help` for the current invocation.
- **Do not read the implementation to script the journey.**
  Resolve the target and how to launch it, then experience the app the way a user would - through its UI, copy, and navigation.
  Reading source to learn the "intended" happy path biases the audit toward what the code expects instead of what a real user would actually do, which is exactly the gap this audit exists to find.
  Consult code only afterward, when explaining or reproducing a specific defect for the report.
- **This is firstmate's own work to orchestrate, not to perform.**
  Firstmate resolves scope and supervises; the browsing itself runs in a scout crewmate's isolated worktree (see "Run it as a scout"), so firstmate's single thread stays free to supervise the fleet.

## 1. Resolve the target and scope

Resolve the project first, using the intake signals in `AGENTS.md` section 7.
The captain will rarely name it explicitly; match the request against the projects under `projects/` and ask a one-line question only if more than one is plausible or none is.
State the resolved project in plain language in your reply so a wrong guess costs one correction.

Then settle the scope.
The captain may supply any of these; useful defaults cover the rest so an audit can start from a bare `/user-journey-audit`:

- **Target journeys** - default to the journey set in section 5.
- **Personas** - default to the two personas in section 3.
- **Device sizes** - default to one desktop viewport and one mobile viewport.
- **Production vs local scope** - default to a local test instance (see Safety rails).
- **Focus area** - default to a full-breadth audit; a captain-named focus (for example "just onboarding" or "sharing and privacy") narrows the journeys and personas accordingly.

Learn how to launch the app's local instance from its `README.md` or `AGENTS.md` - the launch command, the URL, and any seed/reset step - without reading further into the implementation.
If the app cannot be launched locally and the captain has not authorized production, append `blocked:` and stop.

## 2. Run it as a scout

Dispatch the audit as a scout task through the normal lifecycle in `AGENTS.md` section 7, do not perform the browsing yourself.
Scaffold with `bin/fm-brief.sh <id> <repo> --scout` and spawn with `bin/fm-spawn.sh <id> projects/<repo> --scout`.
Fill the brief's `{TASK}` with the resolved scope from section 1 and the full audit methodology in sections 3 through 9 of this skill, so the crewmate carries the personas, the goals-before-browsing rule, the journey set, what to record, the evidence and secret-avoidance rules, and the report contract.
Supervise per section 8; when the crewmate reports `done`, its report is at `data/<id>/report.md`.

## 3. Two isolated personas

Run exactly two personas, each in genuinely separate browser and account state so their experiences never contaminate each other.

- **New user (clean state).**
  A first-time visitor with a fresh browser profile: no cookies, no local storage, no logged-in session, no prior account.
  Sign up or start from the very first screen the way a stranger would, reading only what the UI presents.
  This persona surfaces onboarding friction, unexplained concepts, and the cost of the empty state.

- **Returning user (established state).**
  A realistic repeat user in a separate browser profile with an existing account and established history appropriate to the app - prior charts, saved documents, past activity, settings already chosen, whatever "a week of real use" looks like for this product.
  Seed that state before the journey using the app's own supported paths (its seed/import/setup flows, or a first session that creates the history), never by hand-editing production data.
  This persona surfaces continuation friction, findability of past work, and whether the product respects state the user already built.

Keep the two personas' sessions, profiles, and accounts strictly isolated.
Never reuse the new user's browser context, cookies, or login for the returning user, or the audit conflates two very different experiences.

## 4. Define goals before browsing

For each persona, write down the goals that persona would plausibly arrive with, before opening the app.
For the new user these are first-session goals ("understand what this does", "create my first X", "decide whether to keep using it").
For the returning user these are continuation goals ("pick up the chart I made last week", "adjust a setting", "share my work", "recover from a mistake").
Derive these goals from the persona and the product's apparent purpose, not from the code.
The goals are the audit's yardstick: every journey is measured by whether that persona actually reached its goal.

## 5. Run the journeys

Attempt each goal as a realistic end-to-end journey, in the persona's own voice, making the choices a real user would make - including the wrong turns.
Default journeys, applied per persona where they fit that persona's goals:

- **Onboarding** - first contact through to the first moment of understanding what the product is for (new user).
- **Primary value creation** - the core thing the product exists to let a user do, done for real.
- **Returning-user continuation** - resuming and building on established history (returning user).
- **Account and settings** - finding and changing account, profile, and preference settings.
- **Sharing** - sharing or exporting work, and what a recipient or the public sees.
- **Recovery from errors** - hitting a wrong input, a dead end, or a mistake, and getting back on track.
- **Discovery of advanced features** - whether a user would ever find capabilities beyond the obvious path.

Narrow or extend this set to the captain's focus area and to what the app actually offers.

## 6. What to record

For every journey, record:

- **Goal completion** - did the persona reach the goal, partially reach it, or fail.
- **Ease and friction** - how many steps, how much thinking, where the user hesitated, and roughly how long it took.
- **Confusing copy or navigation** - labels, empty states, or flows that misled or stalled the user.
- **Failures** - broken flows, errors, and dead ends, with the exact step that triggered them.
- **Accessibility and responsive issues** - keyboard/focus/contrast problems and layout breakage across the tested viewports.
- **Trust and privacy concerns** - moments that would make a real user distrust the product or worry about their data.
- **Abandonment and help-seeking** - the exact points where this persona would give up or go looking for support.

## 7. Evidence capture

Back every material finding with concrete evidence a builder can act on, stored under `data/<id>/evidence/` so it survives teardown:

- Screenshots at the moment of friction or failure.
- The URL of the page where it happened.
- Console and network errors observed during the step.
- Concise reproduction steps - the shortest path from a fresh session to the problem.

Avoid capturing secrets and sensitive personal data.
Do not record passwords, tokens, API keys, session cookies, or real personal identifiers in the report or its screenshots; redact them and use synthetic values for any test accounts.
The report is an operational artifact and is still subject to the fleet's security rules.

## 8. Feature ideas, grounded only in journeys

Propose feature ideas only where a real need surfaced during a journey.
Every idea must name the user goal it serves and the specific journey moment that evidenced the need.
Do not brainstorm ungrounded features, and do not propose anything the journeys did not actually motivate.
An idea with no journey behind it does not belong in the report.

## 9. Consolidated, prioritized report

Consolidate everything into a single prioritized report at `data/<id>/report.md`, with three clearly separated classes of finding so nobody mistakes a nice-to-have for a bug:

- **Defects** - things that are broken or wrong.
- **UX improvements** - things that work but cost the user more than they should.
- **Potential features** - the journey-grounded ideas from section 8.

For each item, record:

- **Impact** - how much it helps or hurts the user's goal.
- **Confidence** - how sure the evidence makes you.
- **Effort / risk** - a rough sense of cost and danger to change.
- **Persona** - which persona(s) hit it.
- **Evidence** - the screenshots, URLs, errors, and repro steps from section 7.
- **Recommended acceptance criteria** - what "fixed" or "built" would concretely mean.

Rank items so the highest-impact, highest-confidence work reads first.

## 10. Present the findings

Render the report as HTML under `data/<id>/evidence/` and open it as a review surface with `lavish-axi`, following this fleet's report-viewer convention, so the captain can read the prioritized findings, screenshots, and evidence on a rich surface rather than as a wall of text.
If `lavish-axi` is unavailable, fall back to the markdown report file.
In chat, give a concise summary: the headline of what the two personas experienced, the top few findings per class, and a pointer to the rendered report - not the full report inline.
After presenting the completed report, tear the scout down per `AGENTS.md` section 7 and record it in Done with the report path.
The durable report and evidence remain available while the captain reviews the proposed work.

## 11. Captain approval gate before any task creation

This skill never files, dispatches, or starts an implementation task on its own.
Present the prioritized defects, UX improvements, and features as proposed work and stop there.
Only after the captain explicitly approves specific items do you hand those approved items into Firstmate's normal backlog and delivery lifecycle (`AGENTS.md` sections 7 and 10) - as ordinary ship or scout tasks through their project's delivery mode.
Approval of one item is not approval of the rest; file only what the captain named.

Do not schedule a follow-up audit; this skill stays idle until the captain invokes it again.
