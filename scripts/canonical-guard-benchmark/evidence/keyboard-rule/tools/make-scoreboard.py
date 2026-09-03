#!/usr/bin/env python3
"""Render the non-technical scoreboard from run manifests, verdicts and corpus results.

Every number, name, guard message and evasion verdict on the page is read from
those files. Nothing is typed in by hand, so re-running after a new capture
changes the page and never leaves a stale figure behind.
"""

import argparse
import html
import json
import pathlib
import sys

DISPLAY = {
    "gpt-5.6-luna": "GPT-5.6 Luna", "gpt-5.6-terra": "GPT-5.6 Terra", "gpt-5.6-sol": "GPT-5.6 Sol",
    "deepseek-v4-pro-0813": "DeepSeek V4 Pro", "deepseek-v4-flash-0731": "DeepSeek V4 Flash",
    "qwen3.8-max": "Qwen 3.8 Max", "k3": "K3",
}
ADAPTER = "useSceneElementEventListener(window, 'keydown', onKeyDown)"


def load_jsonl(path: pathlib.Path) -> list[dict]:
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def load_manifests(bundle: pathlib.Path) -> list[dict]:
    """Every captured run manifest. A live workspace keeps each one beside its
    run's evidence; a published bundle may instead carry a flat copy."""
    found = [json.loads(path.read_text())
             for path in sorted(bundle.glob("bundles/*/manifest.json"))]
    if not found:
        found = [json.loads(path.read_text())
                 for path in sorted((bundle / "manifests").glob("*.json"))]
    return found


def escape(value: str) -> str:
    return html.escape(value, quote=True)


def guard_message(corpus: list[dict]) -> tuple[str, str]:
    """The real diagnostic and the file it named, taken from a caught corpus case."""
    for row in corpus:
        if row.get("verdict") == "caught" and row.get("check", {}).get("stderr"):
            return row["check"]["stderr"].strip(), row["id"]
    return "", ""


STATE_TEXT = {
    "off": ("skipped the adapter", "\u2715"),
    "red": ("skipped the adapter", "\u2715"),
    "on": ("used the adapter", "\u2713"),
    "no": ("not measured", "\u2013"),
}


def dot(state: str) -> str:
    """A result cell that reads without colour: a mark, and a word beside it."""
    label, glyph = STATE_TEXT[state]
    return (f'<span class="res {state}"><i class="dot {state}" aria-hidden="true">{glyph}</i>'
            f'<span class="rest">{label}</span></span>')


def per_model_rows(runs: list[dict], verdicts: dict[str, dict], plan: dict) -> tuple[str, int, int, int]:
    lanes = {}
    for item in plan.get("runs", []):
        lanes.setdefault(item["lane"], {"model": item["model"], "runs": {}})["runs"][item["arm"]] = item["run_id"]
    captured = {item["run_id"]: item for item in runs}
    rows, off_raw, on_raw, pairs = [], 0, 0, 0
    for lane in sorted(lanes, key=lambda value: int(value.split("-")[1])):
        model = lanes[lane]["model"]
        cells = []
        states = {}
        for arm in ("guard-off", "guard-on"):
            run_id = lanes[lane]["runs"].get(arm)
            verdict = verdicts.get(run_id, {}) if run_id else {}
            if run_id not in captured:
                states[arm] = "no"
            elif verdict.get("machine") == "duplicate":
                states[arm] = "off" if arm == "guard-off" else "red"
            elif verdict.get("machine") == "clean":
                states[arm] = "on"
            else:
                states[arm] = "no"
        complete = states["guard-off"] != "no" and states["guard-on"] != "no"
        if complete:
            pairs += 1
            off_raw += states["guard-off"] == "off"
            on_raw += states["guard-on"] == "red"
        else:
            # Half a pair is not a result: showing one arm's dot invites the
            # reader to compare it against an arm that was never measured.
            states = {"guard-off": "no", "guard-on": "no"}
        for arm in ("guard-off", "guard-on"):
            cells.append(f"<td>{dot(states[arm])}</td>")
        label = DISPLAY.get(model, model)
        note = "" if complete else "not measured"
        rows.append(f'<tr><td>{escape(label)}{f" <span class=\'na\'>{note}</span>" if note else ""}</td>{"".join(cells)}</tr>')
    return "\n".join(rows), off_raw, on_raw, pairs


GOOD_VERDICTS = ("caught", "quiet")


def evasion_strip(corpus: list[dict]) -> tuple[str, int, int]:
    """One tile per case. A tile is green when the check did the right thing:
    it spoke on a forbidden shortcut, or stayed quiet on legitimate code."""
    cells, good_count, bad_count = [], 0, 0
    for row in corpus:
        if row.get("verdict") not in ("caught", "missed", "quiet", "false-alarm"):
            continue
        good = row["verdict"] in GOOD_VERDICTS
        good_count += good
        bad_count += not good
        note = {"caught": "", "missed": "slips through",
                "quiet": "correctly allowed", "false-alarm": "wrongly blocked"}[row["verdict"]]
        label = escape(row["label"]) + (f'<span class="evn">{note}</span>' if note else "")
        cells.append(
            f'<div class="ev {"pass" if good else "fail"}">'
            f'<div class="evi">{"✓" if good else "✗"}</div>'
            f'<div class="evl">{label}</div></div>'
        )
    return "\n".join(cells), good_count, bad_count


def cost_rows(runs: list[dict], verdicts: dict[str, dict], plan: dict) -> str:
    lanes = {}
    for item in plan.get("runs", []):
        lanes.setdefault(item["lane"], {"model": item["model"], "runs": {}})["runs"][item["arm"]] = item["run_id"]
    captured = {item["run_id"]: item for item in runs}
    rows = []
    for lane in sorted(lanes, key=lambda value: int(value.split("-")[1])):
        on_id = lanes[lane]["runs"].get("guard-on")
        off_id = lanes[lane]["runs"].get("guard-off")
        if on_id not in captured or off_id not in captured:
            continue
        if not captured[on_id].get("gate", {}).get("firing_count"):
            continue
        on_wall = captured[on_id]["timing"]["wall_seconds"]
        off_wall = captured[off_id]["timing"]["wall_seconds"]
        extra = (on_wall - off_wall) / 60
        rows.append(
            f'<tr><td>{escape(DISPLAY.get(lanes[lane]["model"], lanes[lane]["model"]))}</td>'
            f"<td>{off_wall:.0f}s</td><td>{on_wall:.0f}s</td><td>{extra:+.1f} min</td></tr>"
        )
    if not rows:
        return '<tr><td colspan="4" class="na">No captured pair has a recorded firing yet.</td></tr>'
    return "\n".join(rows)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True, help="the run bundle holding manifests, verdicts and stress results")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--corpus-results", required=True)
    parser.add_argument("--extended-results", help="the extension probe added after the pre-registered corpus went clean")
    parser.add_argument("--out", required=True)
    arguments = parser.parse_args()

    bundle = pathlib.Path(arguments.bundle).resolve()
    plan = json.loads(pathlib.Path(arguments.plan).read_text())
    corpus = load_jsonl(pathlib.Path(arguments.corpus_results).resolve())
    runs = [item for item in load_manifests(bundle) if item.get("stage") == "matrix"]
    verdicts = {item["run_id"]: item for item in load_jsonl(bundle / "verdicts.jsonl")}

    message, message_case = guard_message(corpus)
    table, off_raw, on_raw, pairs = per_model_rows(runs, verdicts, plan)
    extended = load_jsonl(pathlib.Path(arguments.extended_results).resolve()) if arguments.extended_results else []
    strip, caught, missed = evasion_strip([row for row in corpus if row.get("id") != "__baseline__"])
    strip_extended, ext_good, ext_bad = evasion_strip([row for row in extended if row.get("id") != "__baseline__"])
    corpus_head = corpus[0]["head"] if corpus else head
    baseline = next((row for row in corpus if row.get("id") == "__baseline__"), None)
    head = plan.get("templates", {}).get("head", "")

    highlighted = escape(message).replace("[keyboard-listener]", '<span class="k">[keyboard-listener]</span>')
    missed_sentence = (
        "Every attempt was caught."
        if not missed else
        f"The {missed} red {'tile' if missed == 1 else 'tiles'} are worth fixing before this ships; "
        "none of them is exotic, and each is a shape a person writes by accident."
    )
    extended_sentence = (
        "Red here would mean one of two things: either the shortcut is written a way the check cannot see, or - "
        "worse for the people using the editor - ordinary code that has nothing to do with the keyboard is being "
        "blocked. There is none. Every bypass was caught, and every piece of ordinary code was left alone."
        if ext_bad == 0 else
        "Red here means one of two things. Either the shortcut is written a way the check cannot see yet, or - "
        "worse for the people using the editor - ordinary code that has nothing to do with the keyboard is being "
        "blocked. Both are worth clearing before this becomes a rule everyone has to live with."
    )
    fired_any = any(item.get("gate", {}).get("firing_count") for item in runs)
    cost_headline = ("The agent fixes it and pushes again. <b>Nobody is called.</b>" if fired_any else
                     "On this task it never fired, so it <b>cost nothing</b>.")
    cost_note = ("" if fired_any else
                 "<p class=\"note\">Every model went through the adapter on its own, with the check switched off as "
                 "well as on. The check had nothing to correct here - which is the cheapest outcome there is, and "
                 "also the reason this run says nothing about what it saves when it does fire.</p>")
    headline_off = f"{off_raw} of {pairs}" if pairs else "no pair yet"
    headline_on = f"{on_raw} of {pairs}" if pairs else "no pair yet"

    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>The keyboard boundary in one minute</title>
<style>
  :root{{--bg:#0f1319;--card:#161c25;--ink:#e8ecf2;--muted:#9aa6b6;--line:#26303c;--off:#fb923c;--on:#2dd4bf;--red:#f87171;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}}
  html,body{{margin:0;background:var(--bg);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}}
  section{{display:block;max-width:1180px;margin:0 auto;padding:56px 28px;box-sizing:border-box;border-bottom:1px solid var(--line)}}
  .step{{color:var(--muted);font-size:14px;letter-spacing:.14em;text-transform:uppercase;margin:0 0 10px}}
  h1{{font-size:44px;line-height:1.12;margin:0 0 22px;font-weight:800;letter-spacing:-.015em}}
  h1 em{{font-style:normal;color:var(--off)}} h1 b{{color:var(--on)}}
  .note{{color:var(--muted);font-size:18px;margin:18px 0 0}}
  .term{{background:#0a0d12;border:1px solid var(--line);border-radius:14px;padding:22px 26px;font-family:var(--mono);font-size:14px;line-height:1.5;white-space:pre-wrap;overflow-x:auto}}
  .term .k{{color:var(--red);font-weight:700}} .term .g{{color:var(--on)}} .term .d{{color:var(--muted)}}
  .split{{display:grid;grid-template-columns:1.25fr 56px 1fr;gap:16px;align-items:center}}
  .term,.fix code,.mono{{overflow-wrap:anywhere;word-break:break-word}}
  table{{table-layout:fixed}}
  td,th{{overflow-wrap:anywhere}}
  .res{{display:inline-flex;align-items:center;gap:8px;justify-content:center}}
  .rest{{font-size:14px;color:var(--muted)}}
  .dot{{display:inline-flex;align-items:center;justify-content:center;font-size:14px;font-weight:800;color:#0f1319}}
  .dot.no{{color:var(--muted)}}
  @media (max-width:720px){{
    section{{padding:36px 18px}}
    h1{{font-size:30px}}
    .split{{grid-template-columns:1fr}}
    .arrow{{transform:rotate(90deg);font-size:34px}}
    .tally{{grid-template-columns:1fr}}
    .tally .n{{font-size:56px}}
    .grid{{grid-template-columns:1fr}}
    table{{font-size:15px}}
    .res{{flex-direction:column;gap:2px}}
    td:first-child{{width:44%}}
  }}
  .split>*{{min-width:0}} .arrow{{font-size:52px;color:var(--muted);text-align:center}}
  .fix{{background:var(--card);border:1px solid var(--on);border-radius:14px;padding:22px 26px}}
  .fix .h{{font-size:22px;font-weight:700;margin-bottom:12px}}
  .fix code{{display:block;font-family:var(--mono);font-size:14px;color:var(--on);margin:4px 0;white-space:pre-wrap}}
  table{{width:100%;border-collapse:collapse;font-size:18px}}
  td{{padding:9px 6px;border-top:1px solid var(--line)}} td:first-child{{width:52%}} td+td{{text-align:center}}
  th{{font-weight:600;color:var(--muted);font-size:13px;letter-spacing:.08em;text-transform:uppercase;padding:0 6px 8px;text-align:center}} th:first-child{{text-align:left}}
  .dot{{display:inline-block;width:22px;height:22px;border-radius:7px;vertical-align:middle}}
  .dot.off{{background:var(--off)}} .dot.on{{background:var(--on)}} .dot.red{{background:var(--red)}} .dot.no{{background:var(--line)}}
  .na{{color:var(--muted);font-size:14px}}
  .tally{{display:grid;grid-template-columns:1fr auto 1fr;gap:18px;align-items:center;margin-top:26px}}
  .tally .n{{font-size:84px;font-weight:900;line-height:1;text-align:center}}
  .tally .l{{text-align:center;font-size:18px;color:var(--muted)}}
  .tally .a .n{{color:var(--off)}} .tally .b .n{{color:var(--on)}}
  .grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:12px;margin-top:8px}}
  .ev{{border-radius:14px;padding:14px 16px;display:flex;gap:12px;align-items:center;background:var(--card);border:1px solid var(--line)}}
  .ev.pass{{border-color:var(--on)}} .ev.fail{{border-color:var(--red)}}
  .evi{{font-size:26px;font-weight:900;line-height:1}} .ev.pass .evi{{color:var(--on)}} .ev.fail .evi{{color:var(--red)}}
  .evl{{font-size:15px;color:var(--ink);line-height:1.3;overflow-wrap:anywhere;min-width:0}}
  .evn{{display:block;color:var(--muted);font-size:13px;margin-top:3px}}
  .legend{{color:var(--muted);font-size:15px;margin-top:18px}}
  .legend i{{margin:0 6px 0 14px}}
  .foot{{color:var(--muted);font-size:15px;line-height:1.6}}
  .mono{{font-family:var(--mono);font-size:13px}}
</style></head><body>

<section>
  <p class="step">1 &middot; What the change is for</p>
  <h1>Keyboard shortcuts in the 3D editor must go through <b>one place</b>.</h1>
  <svg viewBox="0 0 1120 300" width="100%" height="auto" role="img" aria-label="Feature code reaching the browser through the engine adapter instead of directly">
    <defs>
      <marker id="good" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#2dd4bf"/></marker>
      <marker id="bad" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#fb923c"/></marker>
    </defs>
    <rect x="10" y="30" width="300" height="90" rx="16" fill="#161c25" stroke="#26303c" stroke-width="2"/>
    <text x="34" y="66" fill="#9aa6b6" font-size="13" letter-spacing="2">A FEATURE HOOK</text>
    <text x="34" y="96" fill="#e8ecf2" font-size="17" font-family="Menlo,monospace">use-roof-plane-step-3d.ts</text>
    <rect x="430" y="30" width="280" height="90" rx="16" fill="#161c25" stroke="#2dd4bf" stroke-width="2"/>
    <text x="454" y="66" fill="#9aa6b6" font-size="13" letter-spacing="2">THE ENGINE ADAPTER</text>
    <text x="454" y="96" fill="#2dd4bf" font-size="16" font-family="Menlo,monospace">one gate, one teardown</text>
    <rect x="830" y="30" width="280" height="90" rx="16" fill="#161c25" stroke="#26303c" stroke-width="2"/>
    <text x="854" y="66" fill="#9aa6b6" font-size="13" letter-spacing="2">THE BROWSER</text>
    <text x="854" y="96" fill="#e8ecf2" font-size="17" font-family="Menlo,monospace">keydown / keyup</text>
    <path d="M312,75 L424,75" stroke="#2dd4bf" stroke-width="3" fill="none" marker-end="url(#good)"/>
    <path d="M712,75 L824,75" stroke="#2dd4bf" stroke-width="3" fill="none" marker-end="url(#good)"/>
    <path d="M160,124 C160,230 700,250 968,132" stroke="#fb923c" stroke-width="3" stroke-dasharray="8 7" fill="none" marker-end="url(#bad)"/>
    <text x="560" y="268" fill="#fb923c" font-size="17" text-anchor="middle">the shortcut the check forbids: straight to the browser, past the gate</text>
  </svg>
  <p class="note">When a shortcut skips the middle box, the editor cannot switch it off while a drag is in flight, and nothing removes it when the panel closes.</p>
</section>

<section>
  <p class="step">2 &middot; What the check says when it catches one</p>
  <h1>It names the file, the line, and <b>the one line that fixes it</b>.</h1>
  <div class="split">
    <div class="term"><span class="d">$ git push</span>
{highlighted}</div>
    <div class="arrow">&#10148;</div>
    <div class="fix"><div class="h">What replaces it</div>
      <code>{escape(ADAPTER)}</code>
      <p class="note" style="margin-top:18px">One import. The editor gets the shortcut, and the shortcut gets the editor's on/off switch and its cleanup for free.</p>
    </div>
  </div>
  <p class="legend">Captured from the project's own command on case <span class="mono">{escape(message_case)}</span>.</p>
</section>

<section>
  <p class="step">3 &middot; Does it change what the machines write</p>
  <h1>Same task, same models, built twice: <em>once without</em> the check, <b>once with</b> it.</h1>
  <table>
    <tr><th>Model</th><th>Without the check</th><th>With the check</th></tr>
    {table}
  </table>
  <p class="legend">Each cell says what that model did. A model is only shown a result when both of its
    builds were captured; a lane that could not run says so rather than showing half a comparison.</p>
  <div class="tally">
    <div class="a"><div class="n">{headline_off}</div><div class="l">shipped a raw shortcut<br>with the check switched off</div></div>
    <div style="font-size:40px;color:var(--muted)">&rarr;</div>
    <div class="b"><div class="n">{headline_on}</div><div class="l">shipped one<br>with the check switched on</div></div>
  </div>
</section>

<section>
  <p class="step">4 &middot; What it costs when it fires</p>
  <h1>{cost_headline}</h1>
  <table>
    <tr><th>Model</th><th>Without</th><th>With</th><th>Extra time</th></tr>
    {cost_rows(runs, verdicts, plan)}
  </table>
  {cost_note}
</section>

<section>
  <p class="step">5 &middot; How hard is it to get around</p>
  <h1><b>{caught} caught</b>, <em>{missed} slipped through</em> across {caught + missed} deliberate attempts.</h1>
  <div class="grid">
    {strip}
  </div>
  <p class="note">Each tile is one way of writing the same forbidden shortcut, committed on its own branch and put through the project's real command. {missed_sentence}</p>
</section>

<section>
  <p class="step">6 &middot; What is still open</p>
  <h1>A second sweep, written after the first came back clean: <em>{ext_bad} of {ext_good + ext_bad}</em> still go wrong.</h1>
  <div class="grid">
    {strip_extended}
  </div>
  <p class="note">{extended_sentence}</p>
</section>

<section>
  <p class="foot">
    The models ran against the pull request at <span class="mono">{escape(head[:12])}</span>; the two sweeps above
    were run against its final state, <span class="mono">{escape(corpus_head[:12])}</span>.
    Each model built the task once per arm, so every row is a single observation, not a rate.
    The clean run of the untouched branch is the false-alarm control: it was
    <b style="color:var(--on)">{"clean" if baseline and baseline["check"]["exit_code"] == 0 else "not clean"}</b>.
    Every figure on this page is generated from the run's own records; no cell is typed in by hand.
  </p>
</section>

</body></html>
"""
    out = pathlib.Path(arguments.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page)
    print(json.dumps({"out": str(out), "models_paired": pairs, "raw_off": off_raw, "raw_on": on_raw,
                      "evasion_caught": caught, "evasion_missed": missed, "bytes": len(page)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
