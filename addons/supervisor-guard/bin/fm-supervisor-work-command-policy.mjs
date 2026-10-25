#!/usr/bin/env node
// Semantic policy for the supervisor-work guard: is this shell command a
// firstmate SUPERVISOR doing a WORKER's job, or polling inside a turn?
//
// The written rules already forbid both. bin/fm-validation-supervision refuses
// a supervisor to invoke `no-mistakes axi respond` for a crew-owned run, and
// captain-shared preferences refuse sleeping or polling inside a turn. Nothing
// enforced them, so a lead session on 2026-10-05 ran `no-mistakes axi respond`
// for its worker's run and then a `sleep 110; no-mistakes axi run --wait` poll
// loop with 17 watcher wakes queued unread. This policy is the enforcement.
//
// Scope is deliberately supervisor-only. A ship or scout worker OWNS its own
// no-mistakes run, may sleep while its pipeline runs, and may drive its own
// pane; refusing those in a worker would break the worker. The caller
// (bin/fm-supervisor-work-pretool-check.sh) therefore scopes to a genuine
// primary home first, and passes --secondmate for the one rule that applies only
// to a secondmate lead.
//
// This file is the single owner of every pattern here. The shell tokenizer and
// command-position analysis are imported from bin/fm-arm-command-policy.mjs, so
// no shell lexing is duplicated. It never executes, sources, or expands any byte
// of the submitted command.
// See docs/supervisor-work-guard.md for the full contract and validation record.

// The lexer module is bound at run time from the Firstmate checkout that owns it
// (see fm-supervisor-work-decide.mjs), so this file carries no path of its own.
let shell = null;

export function bindLexer(api) {
  shell = api;
}

const REASONS = {
  "supervisor-no-mistakes-run":
    "a firstmate supervisor never drives a crew-owned no-mistakes run: the worker that started the run owns it, reports progress itself, and answers its own findings. Read the worker's recorded status, or steer the worker with bin/fm-send.sh. (no-mistakes axi status stays allowed.)",
  "supervisor-poll-in-turn":
    "a firstmate supervisor never sleeps or polls inside a turn: the watcher wakes this session when something changes, so a sleep only burns a turn and hides queued wakes. End the turn instead of waiting in it.",
  "supervisor-pane-typing":
    "a secondmate lead steers its workers with bin/fm-send.sh and drives their lifecycle with bin/fm-control.sh, never by typing raw keys into a pane: a typed command is invisible to the task's durable inbox and unkillable by the watcher's own tools.",
};

// Subcommands that hand the run to a supervisor session. `status` is read-only
// and deliberately absent: reading a worker's run record is supervision.
const ALLOW = Object.freeze({ decision: "allow" });

const OWNED_SUBCOMMANDS = new Set(["run", "respond"]);

// Seconds of sleep a supervisor turn may still spend for its own bounded wait.
const MAX_TURN_SLEEP_SECONDS = 60;

const SHELL_LOOPS = new Set(["for", "while", "until"]);

// command -> subcommand pairs that mean "type into someone else's terminal".
const PANE_TYPING = new Map([
  ["herdr", new Set(["send-text", "send-keys"])],
  ["tmux", new Set(["send-keys"])],
]);

const deny = (code) => ({ decision: "deny", code, reason: REASONS[code] });

const leafName = (value) => value.split("/").pop();

// The no-mistakes command word plus its own subcommand, tolerating leading
// global flags (`no-mistakes --json axi run`) without tolerating a value-taking
// flag, whose argument could masquerade as the subcommand.
function ownedNoMistakesSubcommand(position) {
  const words = position.words.slice(position.index + 1);
  let cursor = 0;
  while (words[cursor] && words[cursor].value.startsWith("-")) cursor += 1;
  if (words[cursor] && words[cursor].value === "axi") cursor += 1;
  const subcommand = words[cursor];
  return subcommand && OWNED_SUBCOMMANDS.has(subcommand.value) ? subcommand.value : "";
}

// Sum every duration in one sleep argument: "1m30s" is 90 seconds, "30" is 30.
// Returns undefined when the argument carries no readable duration at all,
// because an unreadable duration cannot be proven short.
function durationSeconds(argument) {
  const parts = argument.match(/\d+(?:\.\d+)?[smhd]/g);
  if (parts) {
    const seconds = { s: 1, m: 60, h: 3600, d: 86400 };
    let total = 0;
    for (const part of parts) {
      const unit = part.slice(-1);
      total += Number.parseFloat(part.slice(0, -1)) * seconds[unit];
    }
    return total;
  }
  return /^\d+(?:\.\d+)?$/.test(argument) ? Number.parseFloat(argument) : undefined;
}

function sleepsTooLong(position) {
  const arguments_ = position.words.slice(position.index + 1).map((word) => word.value);
  if (arguments_.length === 0) return false;
  let total = 0;
  for (const argument of arguments_) {
    const seconds = durationSeconds(argument);
    if (seconds === undefined) return true;
    total += seconds;
  }
  return total > MAX_TURN_SLEEP_SECONDS;
}

function typedIntoPane(position) {
  const words = position.words.slice(position.index + 1).map((word) => word.value);
  const actions = PANE_TYPING.get(leafName(position.command.value));
  if (!actions) return false;
  // `herdr pane send-keys Enter` and `tmux send-keys -t w0 Enter` both aim at a
  // pane; the target argument is irrelevant to the rule.
  return words.some((word) => actions.has(word));
}

// One pass over the top-level command positions, because (b) is a property of
// the whole command: a loop and its sleep are separate command positions.
export function decision(command, options = {}) {
  const { Lexer, splitProgram, commandPosition } = shell;
  const secondmate = Boolean(options.secondmate);
  const scan = new Lexer(command).tokenize();
  // Fail open on shell syntax this tokenizer cannot lex. This guard's threat
  // model is a supervisor drifting into its worker's job, which is ordinary
  // well-formed shell, so zero false blocks outrank catching malformed input.
  if (scan.error) return ALLOW;

  const { nodes } = splitProgram(scan.tokens);
  const positions = nodes
    .map((node) => commandPosition(node))
    .filter((position) => position.command && !position.unresolvedWrapperOption);

  for (const position of positions) {
    const name = leafName(position.command.value);
    if (name === "no-mistakes" && ownedNoMistakesSubcommand(position)) {
      return deny("supervisor-no-mistakes-run");
    }
    if (secondmate && typedIntoPane(position)) return deny("supervisor-pane-typing");
  }

  // Second, because (b) is a property of the whole command: a loop and its sleep
  // are separate command positions, and `do sleep 5` lexes as one node whose
  // command word is `do`.
  const inLoop = positions.some((position) => SHELL_LOOPS.has(leafName(position.command.value)));
  for (const position of positions) {
    const name = leafName(position.command.value);
    if (name === "sleep" && sleepsTooLong(position)) return deny("supervisor-poll-in-turn");
    if (inLoop && position.words.some((word) => leafName(word.value) === "sleep")) {
      return deny("supervisor-poll-in-turn");
    }
  }
  return ALLOW;
}
