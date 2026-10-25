// Fleet delete guard: the one rule every runtime adapter calls (pi, opencode, and this file's CLI for the Claude hook).
// A block is final: no allow-once, flag or env override. Each block appends one JSON line to <home>/state/delete-guard.log
// for the delete-guard check; a repeat by the same task within REPEAT_SECS also queues an immediate wake for that home.
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir, userInfo } from "node:os";
import { dirname, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SELF = fileURLToPath(import.meta.url);
const HOMES = [...new Set([userInfo().homedir, homedir()].map((h) => h.replace(/\/+$/, "")))];
const REPEAT_SECS = 600;
const BARE_VAR = /^(\$\w+|\$\{[^}]+\})(\/+(\.?\*|\.)?)?$/; // $X, ${X:-y}, $X/, $X/*, $X/.
const SHELL_VARS = /^(HOME|PWD|OLDPWD|TMPDIR|TMP|TEMP|USER|LOGNAME|SHELL|PATH|IFS|BASH\w*|(XDG|FM|CLAUDE|CODEX|HERDR|PI|OPENCODE|NO_MISTAKES)_\w*)$/;
// An optional declaration keyword before an assignment, with only the plain flags -r -x -g: -n (a nameref such as
// declare -n T=HOME) and any other flag change what the value means, so such a statement never counts as a plain one.
const DECL = String.raw`(?:(?:export|local|readonly|typeset|declare)(?:\s+-[rxg]+)*\s+)?`;

function words(segment) {
	return (segment.match(/(?:"[^"]*"|'[^']*'|[^\s"'])+/g) ?? []).map((t) => t.replace(/"([^"]*)"|'([^']*)'/g, "$1$2"));
}

// Assignments to $name, including read/unset/for and ${name:=x} forms: any of these replaces a previous value.
// Tested on the segment with quoted spans removed, so a word like "unset" inside a string never counts as one.
function assignsRe(name) {
	return new RegExp(`(^|[\\s;({])(export\\s+|local\\s+|readonly\\s+|typeset\\s+|declare(\\s+-\\w+)*\\s+)?${name}\\+?=|\\$\\{${name}:?=|\\b(read|for|unset|mapfile|readarray|printf\\s+-v)\\b.*\\b${name}\\b`);
}

function unquoted(s) {
	return s.replace(/'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"/g, " ");
}

// The mktemp bare-variable exception: the last assignment to it before the delete, in the same command, is its own
// statement d=$(mktemp ...) (optionally after export, local, declare -r and the like) with any options or template (mktemp always makes a fresh unique path),
// where the arguments may hold plain $NAME or ${NAME} expansions but no command substitution, backticks or ; & | ( ), or
// d=$(mktemp ... || mktemp ...) where every || alternative is a mktemp call, and it is not a variable the shell or
// runtime sets. The target must be exactly "$d" or "${d}".
function freshTempVar(arg, segments, at) {
	const name = (arg.match(/^\$(\w+)$|^\$\{(\w+)\}$/) ?? []).slice(1).find(Boolean);
	if (!name || SHELL_VARS.test(name)) return false;
	const assigns = assignsRe(name);
	const stmt = new RegExp(`^${DECL}${name}=("?)\\$\\((.*)\\)\\1$`, "s");
	let fresh = false;
	for (let j = 0; j <= at; j++) {
		if (!assigns.test(unquoted(segments[j].s))) continue;
		// An unquoted || inside $( ) split the statement into segments; rejoin them until its parentheses balance.
		let s = segments[j].s, end = j;
		while (end + 1 < at && (s.match(/\(/g) ?? []).length > (s.match(/\)/g) ?? []).length) s += segments[++end].sep + segments[end].s;
		const body = j < at && s.trim().match(stmt)?.[2];
		fresh = !!body && body.split("||").every((alt) => /^\s*mktemp(\s([^\x60;$&|()]|\$\w+|\$\{\w+\})*)?$/.test(alt));
	}
	return fresh;
}

// Inside a block keyword (if/for/while/until/case) or an unmatched ( or { group in the segments before at?
function nested(segments, at) {
	let kw = 0, group = 0;
	for (let i = 0; i < at; i++) {
		const t = segments[i].s.trim();
		group += (t.match(/\(/g) ?? []).length - (t.match(/\)/g) ?? []).length + (t.match(/\{/g) ?? []).length - (t.match(/\}/g) ?? []).length;
		if (/^(if|for|while|until|case)\b/.test(t)) kw++;
		if (/^(fi|done|esac)\b/.test(t)) kw--;
	}
	return kw > 0 || group > 0;
}

// The literal-assignment exception: the last assignment to the variable before the delete, in the same command, is an
// unconditional statement (after ; or a newline or at the start, not inside an if or loop, a subshell or a {} group,
// and not after && || | &) whose value is a literal path: plain characters with an optional leading ~ or ~/, no $,
// backticks, command substitution, glob, or .. segment. HOME and other shell or runtime variables are never substituted.
function literalValue(arg, segments, at) {
	const name = (arg.match(/^\$(\w+)$|^\$\{(\w+)\}$/) ?? []).slice(1).find(Boolean);
	if (!name || SHELL_VARS.test(name)) return null;
	const assigns = assignsRe(name);
	const stmt = new RegExp(`^${DECL}${name}=(.+)$`);
	let value = null;
	for (let j = 0; j < at; j++) {
		if (!assigns.test(unquoted(segments[j].s))) continue;
		value = null; // the last assignment decides; anything else it could be leaves the value unknown
		const m = segments[j].s.trim().match(stmt);
		if (!m || !["", ";", "\n"].includes(segments[j].sep) || nested(segments, j)) continue;
		const v = m[1].replace(/^"(.*)"$/s, "$1").replace(/^'(.*)'$/s, "$1");
		if (/^[~/\p{L}\p{N}.@%+=:,+-]+$/u.test(v) && !/(^|\/)\.\.(\/|$)/.test(v)) value = v;
	}
	return value;
}

function dangerousTarget(arg, segments, at) {
	if (!arg || arg === "--") return false;
	if (BARE_VAR.test(arg)) {
		if (freshTempVar(arg, segments, at)) return false;
		const lit = literalValue(arg, segments, at);
		if (lit === null) return true; // otherwise blocked whatever the variable holds
		arg = lit; // set to a literal path in the same command: judge it exactly like a direct target
	}
	if (arg.includes("$") && /(^|\/)\.\.(\/|$)/.test(arg)) return true; // $d/.. and $d/../x
	let a = arg.replace(/^(\$HOME|\$\{HOME\}|~)(?=\/|$)/, HOMES[0]);
	a = posix.normalize(a.replace(/\/\.?\*$/, "")).replace(/\/+$/, "") || "/";
	if (/^(\.\.?|(\.\.\/)*\.\.)$/.test(a) || a === "*" || a === ".*") return true;
	if (a === "/" || a === "/home" || /^\/home\/[^/]+$/.test(a)) return true;
	return HOMES.some((h) => a === h || (a.startsWith(h + "/") && !a.slice(h.length + 1).includes("/")));
}

// Simple commands, split on ; | & and newlines outside quotes; sep records the character that started each segment
// ("" for the first), so a plain statement can be told from one guarded by && or ||. A heredoc body fed to a shell
// stays commands; any other is data.
function segmentsOf(command) {
	const text = command.replace(/([^\n]*?)<<-?\s*(['"]?)(\w+)\2([^\n]*)\n([\s\S]*?)\n[ \t]*\3[ \t]*(?=\n|$)/g, (m, pre, q, tag, rest, body) =>
		/(^|[\s;&|(/])(ba|z|da)?sh(\s|$)/.test(pre + rest) ? `${pre}${rest}\n${body}` : pre + rest);
	const out = [{ s: "", sep: "" }];
	for (let i = 0, q = ""; i < text.length; i++) {
		const c = text[i];
		if (!q && ";|&\n".includes(c)) { out.push({ s: "", sep: c }); continue; }
		if (c === "\\" && q !== "'") out[out.length - 1].s += c + (text[++i] ?? "");
		else out[out.length - 1].s += c;
		if (c === q) q = "";
		else if (!q && (c === '"' || c === "'")) q = c;
	}
	return out;
}

export function blockedDelete(command) {
	const segments = segmentsOf(command);
	for (const [at, segment] of segments.entries()) {
		const w = words(segment.s.trim());
		const shell = w.findIndex((t, i) => /(^|\/)(ba|z|da)?sh$/.test(t) && w[i + 1] === "-c");
		if (shell >= 0 && w[shell + 2]) {
			const inner = blockedDelete(w[shell + 2]);
			if (inner !== null) return inner;
		}
		const i = w.findIndex((t) => /(^|\/|\\)(rm|rimraf)$/.test(t));
		const f = w.findIndex((t) => /(^|\/)find$/.test(t));
		const isFind = f >= 0 && w.includes("-delete");
		if (i < 0 && !isFind) continue;
		let args = i >= 0 ? w.slice(i + 1) : w.slice(f + 1);
		if (i < 0) args = args.slice(0, Math.max(0, args.findIndex((t) => /^[-(!]/.test(t)))); // find start paths
		const recursive = i < 0 || /rimraf$/.test(w[i]) || args.some((t) => /^-[a-zA-Z]*[rR]/.test(t) || t === "--recursive");
		if (!recursive) continue;
		const target = args.find((t) => (!t.startsWith("-") || i < 0) && dangerousTarget(t, segments, at));
		if (target !== undefined) return target;
	}
	return null;
}

// Log rows keep any block replayable: the whole command, or the head plus the part around the blocked delete.
function loggedCommand(command, target) {
	const cmd = String(command);
	if (cmd.length <= 600) return cmd;
	const at = cmd.lastIndexOf(target);
	const around = cmd.slice(Math.max(0, (at < 0 ? cmd.length : at) - 250), (at < 0 ? cmd.length : at) + 350);
	return `${cmd.slice(0, 600)} …[${cmd.length} chars total; around the delete: ${around}]`;
}

function escalate(row) {
	let home = "";
	try { home = readFileSync(`${dirname(SELF)}/home`, "utf8").trim(); } catch {}
	if (!home) return;
	const log = `${home}/state/delete-guard.log`, key = row.task || row.cwd, since = Date.parse(row.at) - REPEAT_SECS * 1000;
	appendFileSync(log, JSON.stringify(row) + "\n");
	const recent = readFileSync(log, "utf8").split("\n").filter((l) => {
		try { const r = JSON.parse(l); return (r.task || r.cwd) === key && Date.parse(r.at) >= since; } catch { return false; }
	});
	if (recent.length < 2) return;
	const reason = `check: delete guard REPEAT: ${row.task ? "task " + row.task : "an agent in " + row.cwd} tried ${recent.length} blocked recursive deletes in ${REPEAT_SECS / 60} min (home ${row.home || "?"}, ${row.runtime}); latest: ${row.command.slice(0, 200)} - stop that task and check it`;
	const wake = spawnSync("bash", ["-c", '. "$1/bin/fm-wake-lib.sh" && fm_wake_append check delete-guard "$2"', "_", home, reason],
		{ env: { PATH: process.env.PATH, FM_HOME: home }, stdio: ["ignore", "ignore", "pipe"] });
	if (wake.status !== 0) throw new Error(`repeat wake failed: ${wake.stderr}`);
}

// Returns the block message, or null to allow. Logging and waking never turn a block into an allow.
export function guard(command, { cwd = process.cwd(), runtime = "unknown" } = {}) {
	const target = blockedDelete(String(command ?? ""));
	if (target === null) return null;
	const env = process.env;
	// The true home: the firstmate home holding cwd (the lane the command ran in, even when an inbox or FM_HOME from
	// elsewhere is inherited), else the task's inbox, else FM_HOME.
	let home = "";
	for (let d = resolve(cwd); !home && d !== "/"; d = dirname(d)) if (existsSync(`${d}/bin/fm-wake-lib.sh`) && existsSync(`${d}/state`)) home = d;
	if (!home && env.FM_TASK_INBOX) home = dirname(dirname(env.FM_TASK_INBOX));
	home = home || env.FM_HOME || "";
	const row = { at: new Date().toISOString(), home, task: env.FM_TASK_ID || "", cwd, runtime, target, command: loggedCommand(command, target) };
	let note = "";
	try { escalate(row); } catch (e) { note = ` (the block could not be logged: ${e.message})`; }
	return (
		`BLOCKED by the fleet delete guard: a recursive delete aimed at "${target}" (/, /home, a home folder or a folder directly in it, a bare . .. * ` +
		`or a $VAR target). To delete the folder in a later command, write its literal path: rm -rf -- /tmp/tmp.Ab12. A variable may be deleted only when the same command sets it under your own name such as d, never TMP, TMPDIR, TEMP, HOME, PWD or another shell or runtime variable: ` +
		`d=$(mktemp -d); ...; rm -rf -- "$d". A $VAR set in an earlier command is unknown to the guard and is always blocked. This block is final and has been reported to your ` +
		`supervisor: do not retry it, reword it, or work around it. If you truly need this delete, stop and report it as blocked.${note}`
	);
}

// Hook CLI for Claude Code: PreToolUse JSON on stdin; exit 2 with the reason on stderr blocks (stdout stays empty for Claude).
if (process.argv[1] === SELF) {
	let p = {};
	try { p = JSON.parse(readFileSync(0, "utf8")); } catch {}
	const r = process.argv.indexOf("--runtime");
	const reason = guard(p?.tool_input?.command, { cwd: p?.cwd || process.cwd(), runtime: (r > 1 && process.argv[r + 1]) || "unknown" });
	if (reason !== null) { process.stderr.write(reason + "\n"); process.exit(2); }
}
