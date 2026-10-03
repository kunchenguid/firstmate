// Firstmate Spyglass for Claude Code: the hooks module of the Spyglass mod, whose plugin name is `spyglass`.
//
// A Claude Code "mod" is a plugin whose behavior lives in one hooks module. Claude Code
// may load this module through its rollout flag or `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS`,
// but every handler requires that environment variable to equal `1`, so rollout-only
// loading remains a complete no-op, and it stays silent outside a Firstmate home.
// The plugin carries no command, skill, agent, or classic hook of its own; the `/fleet`
// command below exists only once this module has registered it. docs/spyglass.md owns
// the captain-facing contract.
//
// This file is the only place the engine interface `$` is touched: every decision that
// needs no engine (home resolution, snapshot trimming, the status line, the update
// comparison, the capture sanitizer) lives in ../lib/fm-spyglass.ts, so the policy is
// testable under Node and the engine glue under `claude plugin test`.
//
// The mod is read-only. It runs `bin/fm-fleet-snapshot.sh --json` and `bin/fm-peek.sh`,
// reads `state/<id>.meta`, asks git and the GitHub compare API how far this checkout is
// behind origin, and opens a worker's tmux window in a terminal. It never runs a mutating
// fm-* script and never sends text to a worker; the Update button submits the captain's
// own words, `update firstmate`, as the user.
import { atom, read, update } from "claude-code";
import type { EngineInterface, Register, RenderChildren } from "claude-code";

import {
  clockTime,
  githubRepoFromRemote,
  isSafeTarget,
  localEdits,
  parseWorkerMeta,
  sanitizeCapture,
  signalIds,
  spyglassCodeRoot,
  spyglassHome,
  spyglassStateDirectory,
  summary,
  trimSnapshot,
  updateFrom,
  watchName,
  type Session,
} from "../lib/fm-spyglass.ts";

const PANE = "spyglass";
const TITLE = "Spyglass";
const SESSION_PANE = "spyglass-session";
const SNAPSHOT = "bin/fm-fleet-snapshot.sh";
const PEEK = "bin/fm-peek.sh";
const fleet = atom({ plugin: "spyglass", key: "fleet" } as const, null);
const error = atom({ plugin: "spyglass", key: "error" } as const, null);
const session = atom({ plugin: "spyglass", key: "session" } as const, null);
const upd = atom({ plugin: "spyglass", key: "update" } as const, null);
const request = atom({ plugin: "spyglass", key: "request" } as const, null);
const checking = atom({ plugin: "spyglass", key: "checking" } as const, false);

// Navy palette: brass fittings, deep hull, sea foam, signal-flag red.
const NAVY = {
  brass: "#D4A84B",
  hull: "#3A6EA5",
  sea: "#4FA3D1",
  foam: "#7FD1C7",
  mist: "#8A9BB4",
  signal: "#E5674F",
};

// One module environment holds one Spyglass state; each `session.start` starts it afresh.
let activation: Promise<boolean> | undefined;
// Where the `bin/` scripts live, the home whose fleet is shown, and its state directory; empty when this is no Firstmate home.
let codeRoot = "";
let home = "";
let stateDirectory = "";
// The GitHub repo origin names: undefined until the first update check, null when the check cannot run here.
let upstream: string | null | undefined;
let timers: { cancel(): void }[] = [];
let seen: Set<string> | null = null;
let busy = false;
// The element the fleet pane's focus ring last sat on, or undefined while it sits outside that pane.
let ring: string | undefined;
// The id of the first mate's turn running the captain's update, once that turn has started.
let updateTurn: string | undefined;

function isActivated($: EngineInterface): Promise<boolean> {
  if (activation === undefined) {
    activation = $.env.get("CLAUDE_CODE_ENABLE_FUNCTION_HOOKS").then(
      (value) => value === "1",
      () => false,
    );
  }
  return activation;
}

/** Whether this session is live: the opt-in is on and a Firstmate home was found at its start. */
async function isLive($: EngineInterface): Promise<boolean> {
  return codeRoot !== "" && (await isActivated($));
}

const message = (err: unknown) => String((err as Error)?.message ?? err);

async function refresh($: EngineInterface) {
  if (!codeRoot || busy) return;
  busy = true;
  try {
    const run = await $.process.run([`${codeRoot}/${SNAPSHOT}`, "--json"], {
      cwd: codeRoot,
      env: { FM_HOME: home },
      timeoutMs: 20_000,
    });
    if (run.exitCode !== 0) throw new Error(run.stderr.trim().split("\n").pop() || `exit ${run.exitCode}`);
    const f = trimSnapshot(JSON.parse(run.stdout));
    // The snapshot omits the worker's model and effort; its task record holds them.
    for (const t of f.underWay) {
      const meta = await $.fs.read(`${stateDirectory}/${t.id}.meta`).catch(() => "");
      Object.assign(t, parseWorkerMeta(meta));
    }
    // Write only real changes: every write redraws the pane, and a press that lands mid-redraw is lost.
    const prev = await read($, fleet);
    if (!prev || JSON.stringify({ ...prev, generated: "" }) !== JSON.stringify({ ...f, generated: "" })) {
      await update($, fleet, () => f);
    }
    if ((await read($, error)) !== null) await update($, error, () => null);
    $.ui.status(summary(f, await read($, upd)));

    // Clear the update flag the moment local main reaches the commit it was behind, without waiting for the next network check.
    const u = await read($, upd);
    if (u && u.behind > 0 && u.remote) {
      const head = (await $.process.run(["git", "-C", codeRoot, "rev-parse", "HEAD"])).stdout.trim();
      if (head === u.remote) {
        await update($, upd, (cur) => (cur ? { ...cur, behind: 0, local: [], conflicts: [] } : cur));
        await update($, request, (r) => (r ? "done" : r));
        $.ui.status(summary(f, await read($, upd)));
        $.ui.toast("✓ Firstmate updated to the latest");
      }
    }

    const ids = signalIds(f);
    const fresh = seen ? [...ids].filter((id) => !seen!.has(id)) : [];
    if (fresh.length) $.ui.toast(`🚩 ${fresh.length} new signal${fresh.length > 1 ? "s" : ""} for the captain - /fleet`);
    seen = ids;
  } catch (err) {
    await update($, error, () => message(err));
    $.ui.status("⚓ fleet unreadable");
  } finally {
    busy = false;
  }
}

// The GitHub repo this checkout's origin names, or null when the update check cannot run here:
// origin is not a GitHub remote, or `gh` is not installed.
async function updateSource($: EngineInterface): Promise<string | null> {
  try {
    const origin = await $.process.run(["git", "-C", codeRoot, "remote", "get-url", "origin"]);
    const repo = origin.exitCode === 0 ? githubRepoFromRemote(origin.stdout) : undefined;
    const gh = await $.process.run(["/bin/sh", "-c", "command -v gh"]);
    return repo && gh.exitCode === 0 ? repo : null;
  } catch {
    return null;
  }
}

// Compares this Firstmate checkout with origin's main without fetching into it (ls-remote + GitHub compare),
// and names locally edited tracked files the incoming commits also change, which would block a fast-forward.
async function checkUpdate($: EngineInterface) {
  if (!codeRoot) return;
  await update($, checking, () => true);
  const git = (...args: string[]) => $.process.run(["git", "-C", codeRoot, ...args], { timeoutMs: 30_000 });
  try {
    if (upstream === undefined) upstream = await updateSource($);
    if (upstream === null) return;
    const head = (await git("rev-parse", "HEAD")).stdout.trim();
    const remote = (await git("ls-remote", "origin", "refs/heads/main")).stdout.split("\t")[0]?.trim();
    if (!head || !remote) throw new Error("could not read local or remote main");
    const local = localEdits((await git("status", "--porcelain", "--untracked-files=no")).stdout);
    let compare: { n?: number; files?: string[] } | undefined;
    if (head !== remote) {
      const cmp = await $.process.run(
        ["gh", "api", `repos/${upstream}/compare/${head}...${remote}`, "--jq", "{n: .ahead_by, files: [.files[].filename]}"],
        { timeoutMs: 30_000 },
      );
      if (cmp.exitCode !== 0) throw new Error(cmp.stderr.trim().split("\n").pop() || "compare failed");
      compare = JSON.parse(cmp.stdout);
    }
    const at = new Date().toTimeString().slice(0, 5);
    const next = updateFrom(remote, local, compare, at);
    await update($, upd, () => next);
    if (next.behind === 0) await update($, request, (r) => (r ? "done" : r));
  } catch (err) {
    await update($, upd, (u) => ({
      ...(u ?? { remote: "", behind: 0, local: [], conflicts: [], checkedAt: "" }),
      error: message(err),
    }));
  } finally {
    await update($, checking, () => false);
  }
}

async function requestUpdate($: EngineInterface) {
  // Say so at once: the prompt only enters when the first mate is free, which can be minutes away.
  await update($, request, () => "queued");
  $.ui.toast("⬆ Update queued - the first mate runs it as soon as it is free");
  const sent = await $.prompt.submit({ text: "update firstmate", asUser: true });
  if (sent.drop) {
    await update($, request, () => null);
    $.ui.toast(`Update not sent: ${sent.drop}`);
  }
}

// After the first mate's update turn: done when main caught up, else the Update button comes back for a retry.
async function settleUpdate($: EngineInterface) {
  await checkUpdate($);
  if ((await read($, request)) !== "running") return;
  await update($, request, () => null);
  $.ui.toast("⬆ Firstmate update did not land - see the first mate's reply");
}

// Live tail of one worker's session through fm-peek (read-only capture).
async function refreshSession($: EngineInterface) {
  const cur = await read($, session);
  if (!codeRoot || !cur) return;
  let next: Session;
  try {
    const run = await $.process.run([`${codeRoot}/${PEEK}`, cur.id, "80"], {
      cwd: codeRoot,
      env: { FM_HOME: home },
      timeoutMs: 15_000,
    });
    const text = sanitizeCapture(run.stdout || run.stderr);
    next = { ...cur, text, at: new Date().toTimeString().slice(0, 8), error: run.exitCode === 0 ? null : `exit ${run.exitCode}` };
  } catch (err) {
    next = { ...cur, error: message(err) };
  }
  // Same text, same error: no write, so the session pane's buttons are not redrawn under the pointer every 3s.
  if (next.text === cur.text && next.error === cur.error) return;
  await update($, session, (s) => (s && s.id === cur.id ? next : s));
}

// Opens the worker's tmux window in a real terminal: Ghostty when installed, else Terminal.app.
async function openTerminal($: EngineInterface, target: string) {
  if (!isSafeTarget(target)) {
    $.ui.toast(`Could not open a terminal: unexpected session name ${target}`);
    return;
  }
  const which = await $.process.run(["/bin/sh", "-lc", "command -v tmux"]);
  const tmux = which.stdout.trim() || "tmux";
  const ghostty = await $.fs.stat("/Applications/Ghostty.app").catch(() => null);
  const argv = ghostty
    ? ["open", "-na", "Ghostty", "--args", "-e", tmux, "attach", "-t", target]
    : ["osascript", "-e", `tell application "Terminal" to do script "${tmux} attach -t ${target}"`, "-e", 'tell application "Terminal" to activate'];
  const run = await $.process.run(argv, { timeoutMs: 15_000 });
  $.ui.toast(run.exitCode === 0 ? `🔭 Opened ${target} in a terminal` : `Could not open a terminal: ${run.stderr.trim() || `exit ${run.exitCode}`}`);
}

async function openSession($: EngineInterface, id: string, target: string | null) {
  await update($, session, () => ({ id, target, text: "", at: "", error: null }));
  await $.ui.open({ id: SESSION_PANE, title: `Session · ${id}`, focus: true });
  await refreshSession($);
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    for (const timer of timers) timer.cancel();
    timers = [];
    codeRoot = "";
    seen = null;
    ring = undefined;
    upstream = undefined;
    updateTurn = undefined;

    const env = {
      FM_HOME: await $.env.get("FM_HOME"),
      FM_ROOT_OVERRIDE: await $.env.get("FM_ROOT_OVERRIDE"),
      FM_STATE_OVERRIDE: await $.env.get("FM_STATE_OVERRIDE"),
    };
    const root = spyglassCodeRoot(env, $.plugin.root);
    const where = spyglassHome(env, $.plugin.root);
    // Not a Firstmate home: stay silent.
    if (!(await $.fs.exists(`${root}/${SNAPSHOT}`)) || !(await $.fs.exists(where))) return next(e);

    codeRoot = root;
    home = where;
    stateDirectory = spyglassStateDirectory(env, $.plugin.root);
    await $.command.register({ name: "fleet", description: "Open the Spyglass fleet pane" });
    await refresh($);
    timers.push($.clock.every(15_000, () => void refresh($)));
    timers.push($.clock.every(3_000, () => void refreshSession($)));
    void checkUpdate($);
    timers.push($.clock.every(10 * 60_000, () => void checkUpdate($)));
    void $.ui.open({ id: PANE, title: TITLE });

    return next(e);
  });

  // Desktop: a click on a Button in an unfocused pane only takes the keyboard. Coming from the session pane,
  // the ring lands on the clicked button (no press), so treat that as the press. Coming from the chat box the
  // ring lands on nothing and the click cannot be attributed; that case still needs a second click.
  on("ui.focus", async ($, e, next) => {
    if (!(await isLive($))) return next(e);
    const done = await next(e);
    if (e.requestId !== PANE) {
      ring = undefined;
      return done;
    }
    const was = ring;
    ring = e.element;
    if (!was && e.origin.kind === "person" && e.element?.startsWith("view:")) {
      const id = e.element.slice("view:".length);
      const t = (await read($, fleet))?.underWay.find((w) => w.id === id);
      if (t) void openSession($, t.id, t.target);
    }

    return done;
  });

  // The queued update starts running when the first mate's turn on the captain's words begins.
  on("turn.start", async ($, e, next) => {
    if (!(await isLive($))) return next(e);
    if (e.text === "update firstmate" && (await read($, request)) === "queued") {
      updateTurn = e.turnId;
      await update($, request, () => "running");
    }
    return next(e);
  });

  on("turn.complete", async ($, e, next) => {
    if (!(await isLive($))) return next(e);
    const done = await next(e);
    void refresh($);
    if (!e.agentId && updateTurn !== undefined && e.turnId === updateTurn) {
      updateTurn = undefined;
      void settleUpdate($);
    }

    return done;
  });

  on("command.run", { command: "fleet" }, async ($, e, next) => {
    if (!(await isLive($))) return next(e);
    void checkUpdate($);
    await refresh($);
    await $.ui.open({ id: PANE, title: TITLE, focus: true });

    return { text: "Spyglass opened." };
  });

  on("ui.render", { component: "Pane", requestId: PANE }, async ($, e, next) => {
    if (!(await isLive($))) return next(e);
    const { Box, Text, Link, Button } = $.ui.resolve(e);
    const f = await read($, fleet);
    const err = await read($, error);
    const u = await read($, upd);
    const req = await read($, request);
    const isChecking = await read($, checking);
    const width = Math.max(20, (e.viewport?.columns ?? 60) - 6);
    // A rule as long as the room allows: clipped to one row, never wrapped or ellipsised.
    const line = (ch: string) => (
      <Box height={1} overflow="hidden">
        <Text color={NAVY.hull} wrap="wrap">
          {ch.repeat(width)}
        </Text>
      </Box>
    );

    const banner = (
      <Box flexDirection="column" borderStyle="double" borderColor={NAVY.brass} paddingX={1}>
        <Text bold color={NAVY.brass}>
          ⚓ S P Y G L A S S ⚓
        </Text>
        <Text color={NAVY.mist}>
          {f ? `${watchName(f.generated)} · fleet changed ${clockTime(f.generated)}` : "Raising the glass..."}
        </Text>
        {upstream !== null && !(u && u.behind > 0) && (
          <Box gap={1} marginTop={1} alignItems="center">
            <Text color={req === "done" ? NAVY.foam : NAVY.mist}>
              {isChecking
                ? "⏳ Checking for updates..."
                : req === "done"
                  ? "✓ Firstmate updated to the latest"
                  : u?.error
                    ? `Update check failed: ${u.error}`
                    : u
                      ? `✓ Firstmate up to date · checked ${u.checkedAt}`
                      : ""}
            </Text>
            {!isChecking && (
              <Button
                key="check-update"
                label="Check for updates"
                dimColor
                onPress={async () => {
                  await update($, request, (r) => (r === "done" ? null : r));
                  await checkUpdate($);
                }}
              />
            )}
          </Box>
        )}
      </Box>
    );

    const updateFlag = u && u.behind > 0 && (
      <Box flexDirection="column" borderStyle="round" borderColor={NAVY.brass} paddingX={1} marginTop={1}>
        <Text bold color={NAVY.brass}>
          ⬆ Firstmate update available - {u.behind} commit{u.behind > 1 ? "s" : ""} behind
        </Text>
        {u.conflicts.length > 0 ? (
          <Text color={NAVY.signal}>Your local change to {u.conflicts.join(", ")} is in the way: the update changes it too.</Text>
        ) : (
          u.local.length > 0 && <Text color={NAVY.mist}>Your local change to {u.local.join(", ")} is not touched by this update.</Text>
        )}
        <Text color={NAVY.mist}>checked {u.checkedAt}</Text>
        <Box marginTop={1}>
          {req === "running" ? (
            <Text color={NAVY.sea}>🔄 Updating Firstmate...</Text>
          ) : (
            <Box gap={1} alignItems="center">
              {req === "queued" && <Text color={NAVY.sea}>⏳ Update queued - starts as soon as the first mate is free</Text>}
              <Button key="update" label="Update Firstmate" onPress={() => requestUpdate($)} />
            </Box>
          )}
        </Box>
      </Box>
    );

    if (!f) {
      return (
        <Box flexDirection="column">
          {banner}
          {err && <Text color={NAVY.signal}>Fleet unreadable: {err}</Text>}
        </Box>
      );
    }

    // One bordered section per part of the fleet, items numbered and split by a thin rule.
    const section = (icon: string, label: string, empty: string, rows: RenderChildren[]) => (
      <Box flexDirection="column" borderStyle="round" borderColor={NAVY.hull} paddingX={1} marginTop={1}>
        <Text bold color={NAVY.brass}>
          {icon} {label} <Text color={NAVY.mist}>({rows.length})</Text>
        </Text>
        <Box height={1} />
        {rows.length === 0 && <Text color={NAVY.mist}>{empty}</Text>}
        {rows.map((row, n) => (
          <Box key={`${label}:${n}`} flexDirection="column">
            {n > 0 && line("┄")}
            <Box alignItems="flex-start">
              <Box width={4} flexShrink={0}>
                <Text bold color={NAVY.brass}>
                  {n + 1}.
                </Text>
              </Box>
              <Box flexDirection="column" flexShrink={1}>
                {row}
              </Box>
            </Box>
          </Box>
        ))}
      </Box>
    );

    const link = (url: string) => (url.startsWith("https://") ? <Link href={url} /> : <Text color={NAVY.sea}>{url}</Text>);

    return (
      <Box flexDirection="column">
        {banner}
        {updateFlag}
        {section("🚩", "Signals for the Captain", "No signals flying - all quiet on deck.", [
          ...f.prs.map((p) => (
            <Box flexDirection="column">
              <Text bold color={NAVY.foam}>PR ready · {p.id}</Text>
              {link(p.url)}
            </Box>
          )),
          ...f.calls.map((c) => (
            <Box flexDirection="column">
              <Text bold color={NAVY.signal}>{c.title}</Text>
              {c.reason && <Text color={NAVY.mist}>{c.reason}</Text>}
            </Box>
          )),
        ])}
        {section(
          "⛵",
          "Under Way",
          "Calm seas - no crew under way.",
          f.underWay.map((t) => (
            <Box key={`uw:${t.id}`} flexDirection="column">
              <Text bold color={NAVY.foam}>{t.id}</Text>
              <Text color={NAVY.mist}>
                {t.kind} · {t.project} · <Text color={NAVY.sea}>{t.state}</Text>
              </Text>
              {(t.model || t.effort) && (
                <Text color={NAVY.brass}>
                  🧭 {t.model ?? "default model"} · {t.effort ?? "default"} effort
                </Text>
              )}
              <Box marginTop={1}>
                <Button key={`view:${t.id}`} label="View session" onPress={() => openSession($, t.id, t.target)} />
              </Box>
            </Box>
          )),
        )}
        {section(
          "⚓",
          "At Anchor",
          "Nothing waiting in harbour.",
          f.queued.map((q) => <Text>{q.title}</Text>),
        )}
        {err && <Text color={NAVY.signal}>Last refresh failed: {err}</Text>}
      </Box>
    );
  });

  on("ui.render", { component: "Pane", requestId: SESSION_PANE }, async ($, e, next) => {
    if (!(await isLive($))) return next(e);
    const { Box, Text, Button, Code } = $.ui.resolve(e);
    const cur = await read($, session);

    if (!cur) return <Text color={NAVY.mist}>Pick a worker in Spyglass to watch its session.</Text>;

    const attach = cur.target ? `tmux attach -t ${cur.target}` : null;
    // Only the newest lines that fit, so the live end of the tail is on screen. viewport.rows is the whole
    // terminal, so reserve room for the header, buttons, and border plus Claude Code's prompt and status rows.
    const tail = cur.text.split("\n").slice(-Math.max(8, (e.viewport?.rows ?? 40) - 20)).join("\n");

    return (
      <Box flexDirection="column">
        <Box flexDirection="column" borderStyle="double" borderColor={NAVY.brass} paddingX={1}>
          <Text bold color={NAVY.brass}>
            🔭 {cur.id}
          </Text>
          <Text color={NAVY.mist}>
            {cur.at ? `live · last output ${cur.at} · checked every 3s` : "Raising the glass..."}
            {cur.error ? ` · ${cur.error}` : ""}
          </Text>
        </Box>
        <Box marginTop={1} gap={1}>
          <Button key="refresh" label="Refresh" onPress={() => refreshSession($)} />
          {cur.target && <Button key="terminal" label="Open in terminal" onPress={() => openTerminal($, cur.target!)} />}
          {attach && (
            <Button key="copy" label="Copy attach command" onPress={(press) => $.ui.copy({ text: attach, surface: press.surface })} />
          )}
          <Button
            key="close"
            label="Close"
            role="dismiss"
            onPress={async () => {
              await update($, session, () => null);
              await $.ui.close({ id: SESSION_PANE });
            }}
          />
        </Box>
        <Box marginTop={1} borderStyle="round" borderColor={NAVY.hull} paddingX={1}>
          {cur.text ? <Code source={tail} language="text" /> : <Text color={NAVY.mist}>Waiting for the first capture...</Text>}
        </Box>
      </Box>
    );
  });
};
