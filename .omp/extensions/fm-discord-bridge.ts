// fm-discord-bridge.ts — bridge the firstmate OMP session to one Discord channel.
//
// Inbound:  messages in BRIDGE_CHANNEL_ID are injected into this session as a
//           user turn (as if typed + Enter).
// Outbound: assistant TEXT blocks from the session JSONL log are posted back to
//           the channel. Tool calls, tool results, thinking, and user echoes are
//           never posted.
// Typing:   Discord "typing…" is shown while the agent is working.
//
// Reuses NOTHING from the mini yian / relay path. Own bot token: BRIDGE_BOT_TOKEN.
// Loaded via the firstmate -e overlay (see fm-worker-overlay / primary overlay).
//
// Env (from firstmate home .env, already exported into the session):
//   BRIDGE_BOT_TOKEN     required — the firstmate-bridge Discord bot token
//   BRIDGE_CHANNEL_ID    required — the one channel to bridge
//   BRIDGE_GUILD_ID      optional — sanity only
//
// Design notes:
//  - Outbound reads the session JSONL (structured), not the TUI. Assistant text
//    is role=assistant with a content block type=text. toolCall/thinking blocks
//    are skipped; a mixed [text,toolCall] message posts only its text.
//  - Inbound polls the Discord REST API every 2s for new messages authored by a
//    human (not this bot) in the channel, then injects via ctx.ui.
//  - No gateway websocket: REST polling keeps the extension dependency-free
//    (no discord.js), which matters inside the compiled-Bun OMP runtime.

const API = "https://discord.com/api/v10";

// Read config from process.env first, then fall back to the firstmate home's
// .env file. firstmate does NOT source .env into the OMP process (it reads keys
// on demand via fm-env-lib.sh), so process.env.BRIDGE_* is normally empty and we
// must parse the .env file ourselves, matching fm-env-lib's one-key rule.
function readDotenvValue(key: string): string | undefined {
  try {
    const fs = (globalThis as any).require?.("node:fs") ?? require("node:fs");
    const path = (globalThis as any).require?.("node:path") ?? require("node:path");
    const home = (globalThis as any).process?.env?.FM_HOME || (globalThis as any).process?.cwd?.() || ".";
    const candidates = [path.join(home, ".env"), path.join((globalThis as any).process?.cwd?.() || ".", ".env")];
    for (const f of candidates) {
      if (!fs.existsSync(f)) continue;
      for (const raw of fs.readFileSync(f, "utf8").split("\n")) {
        const line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const m = line.match(new RegExp(`^(?:export\\s+)?${key}=(.*)$`));
        if (m) return m[1].trim().replace(/^['"]|['"]$/g, "");
      }
    }
  } catch {}
  return undefined;
}

function env(k: string): string | undefined {
  const p = (globalThis as any).process?.env?.[k];
  if (p && String(p).trim()) return String(p).trim();
  return readDotenvValue(k);
}



const TOKEN = env("BRIDGE_BOT_TOKEN");
const CHANNEL = env("BRIDGE_CHANNEL_ID");
const GROQ_KEY = env("BRIDGE_GROQ_API_KEY");
const GROQ_MODEL = env("BRIDGE_GROQ_MODEL") || "whisper-large-v3-turbo";
const REPLY_MAX = 1900;
const IMAGE_EXT = /\.(png|jpe?g|gif|webp|bmp)$/i;
const VIDEO_EXT = /\.(mp4|mov|webm|mkv|avi|m4v)$/i;
const AUDIO_EXT = /\.(ogg|oga|mp3|m4a|wav|flac|opus|webm)$/i;

async function dGET(path: string): Promise<any> {
  const r = await fetch(`${API}${path}`, { headers: { Authorization: `Bot ${TOKEN}` } });
  if (!r.ok) return null;
  return r.json();
}
async function dPOST(path: string, body: unknown): Promise<any> {
  const r = await fetch(`${API}${path}`, {
    method: "POST",
    headers: { Authorization: `Bot ${TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) return null;
  // Some endpoints (e.g. POST /typing) return 204 No Content; parsing throws.
  const text = await r.text();
  if (!text) return null;
  try { return JSON.parse(text); } catch { return null; }
}

// Split long text at line/space boundaries under Discord's limit.
function chunk(text: string, max = REPLY_MAX): string[] {
  const out: string[] = [];
  let cur = "";
  for (const line of text.split("\n")) {
    if ((cur + "\n" + line).length > max) {
      if (cur) out.push(cur);
      if (line.length > max) {
        for (let i = 0; i < line.length; i += max) out.push(line.slice(i, i + max));
        cur = "";
      } else cur = line;
    } else cur = cur ? cur + "\n" + line : line;
  }
  if (cur) out.push(cur);
  return out;
}

async function postToDiscord(text: string) {
  const t = text.trim();
  if (!t) return;
  for (const part of chunk(t)) await dPOST(`/channels/${CHANNEL}/messages`, { content: part });
}

async function showTyping() {
  await dPOST(`/channels/${CHANNEL}/typing`, {});
}

// ---- Media helpers ----
const nodefs = (globalThis as any).require?.("node:fs") ?? require("node:fs");
const nodeos = (globalThis as any).require?.("node:os") ?? require("node:os");
const nodepath = (globalThis as any).require?.("node:path") ?? require("node:path");
const MEDIA_DIR = nodepath.join(nodeos.tmpdir(), "fm-discord-bridge");
try { nodefs.mkdirSync(MEDIA_DIR, { recursive: true }); } catch {}

// Download a Discord attachment URL to a local file, return its path.
async function downloadAttachment(url: string, filename: string): Promise<string | null> {
  try {
    const r = await fetch(url);
    if (!r.ok) return null;
    const buf = Buffer.from(await r.arrayBuffer());
    const safe = filename.replace(/[^\w.\-]/g, "_");
    const dest = nodepath.join(MEDIA_DIR, `${Date.now()}_${safe}`);
    nodefs.writeFileSync(dest, buf);
    return dest;
  } catch { return null; }
}

// Transcribe an audio file via Groq Whisper (mirrors Hermes stt.provider=groq).
async function transcribeGroq(filePath: string): Promise<string | null> {
  if (!GROQ_KEY) return null;
  try {
    const data = nodefs.readFileSync(filePath);
    const form = new FormData();
    form.append("file", new Blob([data]), nodepath.basename(filePath));
    form.append("model", GROQ_MODEL);
    form.append("response_format", "text");
    const r = await fetch("https://api.groq.com/openai/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${GROQ_KEY}` },
      body: form,
    });
    if (!r.ok) return null;
    return (await r.text()).trim();
  } catch { return null; }
}

// Upload a local file to the channel as a Discord attachment (multipart).
async function uploadToDiscord(filePath: string, note = ""): Promise<boolean> {
  try {
    if (!nodefs.existsSync(filePath)) return false;
    const data = nodefs.readFileSync(filePath);
    const form = new FormData();
    if (note.trim()) form.append("payload_json", JSON.stringify({ content: note.slice(0, REPLY_MAX) }));
    form.append("files[0]", new Blob([data]), nodepath.basename(filePath));
    const r = await fetch(`${API}/channels/${CHANNEL}/messages`, {
      method: "POST",
      headers: { Authorization: `Bot ${TOKEN}` }, // no Content-Type: FormData sets the boundary
      body: form,
    });
    return r.ok;
  } catch { return false; }
}

// Pull uploadable local file paths out of assistant text; return {clean, paths}.
// Recognizes, in order: an explicit `MEDIA:/abs/path` line; a markdown image
// `![alt](/abs/path)`; and a backtick-wrapped `/abs/path`. Only paths that exist
// on disk AND look like image/video/audio/doc get uploaded; everything else stays
// as text. The matched tokens are stripped from the outgoing message.
function extractMedia(text: string): { clean: string; paths: string[] } {
  const fs = (globalThis as any).require?.("node:fs") ?? require("node:fs");
  const paths: string[] = [];
  const seen = new Set<string>();
  const UPLOADABLE = /\.(png|jpe?g|gif|webp|bmp|svg|mp4|mov|webm|mkv|avi|m4v|ogg|oga|mp3|m4a|wav|flac|opus|pdf|txt|csv|json|md|zip)$/i;

  const consider = (p: string | undefined): "new" | "dup" | false => {
    if (!p) return false;
    const clean = p.trim();
    if (!clean.startsWith("/")) return false;
    if (!UPLOADABLE.test(clean)) return false;
    if (seen.has(clean)) return "dup"; // already collected: still strip its token from text
    try { if (!fs.existsSync(clean) || !fs.statSync(clean).isFile()) return false; } catch { return false; }
    seen.add(clean); paths.push(clean); return "new";
  };

  const lines = text.split("\n").map((line) => {
    // 1) explicit MEDIA: line -> drop the whole line
    const m = line.match(/^\s*MEDIA:\s*(\/\S+)\s*$/);
    if (m && consider(m[1])) return null;
    // 2) markdown image ![alt](/abs/path) -> strip the token (whether new or dup)
    let out = line.replace(/!\[[^\]]*\]\((\/[^)\s]+)\)/g, (whole, p) => (consider(p) ? "" : whole));
    // 3) backtick-wrapped absolute path `/abs/path` -> strip the token
    out = out.replace(/`(\/[^`\s]+)`/g, (whole, p) => (consider(p) ? "" : whole));
    return out;
  });

  const clean = lines
    .filter((l) => l !== null)
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return { clean, paths };
}

export default function (pi: any) {
  // Gate: this bridge runs ONLY in the primary firstmate home, nowhere else.
  // Not on crewmate workers, not on secondmate homes (cleo/cnp treehouse homes),
  // not on any other /firstmate dir. Exact realpath match against the one primary.
  const isWorker = !!env("FM_TASK_ID");
  const cwd = (globalThis as any).process?.cwd?.() || "";
  const PRIMARY_HOME = "/Users/yian/Projects/firstmate";
  let cwdReal = cwd;
  try {
    const fs0 = (globalThis as any).require?.("node:fs") ?? require("node:fs");
    cwdReal = fs0.realpathSync(cwd);
  } catch {}
  const isPrimaryHome =
    cwdReal === PRIMARY_HOME ||
    cwdReal.toLowerCase() === PRIMARY_HOME.toLowerCase(); // case-insensitive FS
  if (isWorker || !isPrimaryHome) return; // silent no-op anywhere but the primary home

  if (!TOKEN || !CHANNEL) {
    // Bridge disabled: no token/channel. Never throw — must not break the session.
    pi.on?.("session_start", (_e: unknown, ctx: any) =>
      ctx?.ui?.notify?.("fm-discord-bridge: BRIDGE_BOT_TOKEN/CHANNEL not set, bridge off"),
    );
    return;
  }

  let botUserId: string | null = null;
  let lastMessageId: string | null = null; // Discord snowflake cursor (inbound)
  let logPath: string | null = null;
  let logOffset = 0;                        // bytes consumed of the session JSONL (outbound)
  let typingTimer: any = null;
  let working = false;
  let announcedOnline = false;   // post "online" only once per process
  let sessionRef: any = null;    // ctx.session captured at session_start, for abort()
  let inboundTimer: any = null;
  let outboundTimer: any = null;

  const fs = (globalThis as any).require?.("node:fs") ?? require("node:fs");
  const os = (globalThis as any).require?.("node:os") ?? require("node:os");
  const path = (globalThis as any).require?.("node:path") ?? require("node:path");

  // ---- Outbound: tail the session JSONL, post assistant text blocks ----
  // OMP writes sessions to ~/.omp/agent/sessions/<munged-cwd>/<ts>_<id>.jsonl.
  // We can't trust a single path pinned at start (a /new or fork rotates the
  // file), so we always tail the NEWEST jsonl under this home's session dir.
  function sessionsDirForCwd(): string | null {
    const base = path.join(os.homedir(), ".omp", "agent", "sessions");
    if (!fs.existsSync(base)) return null;
    // OMP munges the cwd into the dir name by stripping the home prefix and
    // replacing "/" with "-", keeping a leading "-". So
    // /Users/yian/Projects/firstmate -> "-Projects-firstmate".
    // Build that exact suffix (last 2 path segments) and match dirs ending in it;
    // among matches, take the newest. Case-insensitive for macOS Projects/projects.
    const segs = cwd.split("/").filter(Boolean);
    const suffix = "-" + segs.slice(-2).join("-");        // "-Projects-firstmate"
    const suffixLc = suffix.toLowerCase();
    const baseName = "-" + segs.slice(-1).join("-");       // "-firstmate" (fallback)
    let best: string | null = null;
    let bestM = 0;
    let fallback: string | null = null;
    let fallbackM = 0;
    for (const d of fs.readdirSync(base)) {
      const full = path.join(base, d);
      try { if (!fs.statSync(full).isDirectory()) continue; } catch { continue; }
      const m = fs.statSync(full).mtimeMs;
      const dLc = d.toLowerCase();
      if (dLc.endsWith(suffixLc)) {
        if (m > bestM) { bestM = m; best = full; }
      } else if (dLc.endsWith(baseName.toLowerCase())) {
        if (m > fallbackM) { fallbackM = m; fallback = full; }
      }
    }
    return best || fallback;
  }

  function newestLog(): string | null {
    const dir = sessionsDirForCwd();
    if (!dir) return null;
    let best: string | null = null;
    let bestM = 0;
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith(".jsonl")) continue;
      const full = path.join(dir, f);
      const m = fs.statSync(full).mtimeMs;
      if (m > bestM) { bestM = m; best = full; }
    }
    return best;
  }

  function resolveLogPath(_ctx: any): string | null {
    return newestLog();
  }

  function drainLog() {
    // Re-resolve each tick so a rotated/forked session file is picked up.
    const active = newestLog();
    if (active && active !== logPath) {
      // switched to a new session file: start from its current end to avoid replay
      logPath = active;
      try { logOffset = fs.statSync(active).size; } catch { logOffset = 0; }
      return; // next tick reads new content
    }
    if (!logPath || !fs.existsSync(logPath)) return;
    const size = fs.statSync(logPath).size;
    if (size <= logOffset) return;
    const fd = fs.openSync(logPath, "r");
    const buf = Buffer.alloc(size - logOffset);
    fs.readSync(fd, buf, 0, buf.length, logOffset);
    fs.closeSync(fd);
    logOffset = size;
    for (const line of buf.toString("utf8").split("\n")) {
      if (!line.trim()) continue;
      let j: any;
      try { j = JSON.parse(line); } catch { continue; }
      const m = j?.message;
      if (!m || m.role !== "assistant") continue;
      const content = m.content;
      if (!Array.isArray(content)) continue;
      const text = content
        .filter((b: any) => b && b.type === "text" && typeof b.text === "string")
        .map((b: any) => b.text)
        .join("\n")
        .trim();
      if (!text) continue;
      // Outbound media: MEDIA:/abs/path lines become Discord attachments.
      const { clean, paths } = extractMedia(text);
      if (paths.length === 0) {
        void postToDiscord(clean);
      } else {
        (async () => {
          let firstNoteUsed = false;
          for (const p of paths) {
            const note = !firstNoteUsed ? clean : "";
            const ok = await uploadToDiscord(p, note);
            firstNoteUsed = true;
            if (!ok && !firstNoteUsed) void postToDiscord(clean);
          }
          // If no upload consumed the text (all failed) but there was text, still post it.
          if (clean && paths.length && !firstNoteUsed) void postToDiscord(clean);
        })();
      }
    }
  }

  // ---- Inbound: poll channel for new human messages, inject as a user turn ----
  async function pollInbound(ctx: any) {
    const after = lastMessageId ? `?after=${lastMessageId}&limit=10` : `?limit=1`;
    const msgs = await dGET(`/channels/${CHANNEL}/messages${after}`);
    if (!Array.isArray(msgs) || msgs.length === 0) return;
    // Discord returns newest-first; process oldest-first.
    for (const msg of msgs.reverse()) {
      lastMessageId = msg.id;
      if (msg.author?.id === botUserId) continue;   // ignore ONLY our own posts (prevent loop); accept all other bots
      await handleInbound(ctx, msg);
    }
  }

  async function handleInbound(ctx: any, msg: any) {
    let text = (msg.content || "").trim();
    let attachments = Array.isArray(msg.attachments) ? msg.attachments : [];

    // Forwarded messages carry no top-level content/attachments; the real payload
    // lives in message_snapshots[0].message (flags bit 1<<14 = 16384 marks a forward).
    const snaps = Array.isArray(msg.message_snapshots) ? msg.message_snapshots : [];
    for (const s of snaps) {
      const sm = s?.message;
      if (!sm) continue;
      const sc = (sm.content || "").trim();
      if (sc) text = [text, sc].filter(Boolean).join("\n").trim();
      if (Array.isArray(sm.attachments) && sm.attachments.length) {
        attachments = attachments.concat(sm.attachments);
      }
    }

    const mediaLines: string[] = [];
    const transcripts: string[] = [];

    for (const att of attachments) {
      const url = att?.url;
      const name = att?.filename || "file";
      if (!url) continue;
      // Discord voice messages: flag bit 1<<13 (8192), or a .ogg audio attachment.
      const isVoice = (msg.flags && (msg.flags & 8192)) || (att?.waveform !== undefined);
      const local = await downloadAttachment(url, name);
      if (!local) continue;
      if (isVoice || (AUDIO_EXT.test(name) && !VIDEO_EXT.test(name))) {
        const t = await transcribeGroq(local);
        if (t) transcripts.push(t);
        else mediaLines.push(`[audio attachment: ${local} (transcription failed)]`);
      } else if (IMAGE_EXT.test(name)) {
        mediaLines.push(`[image: ${local}]`);
      } else if (VIDEO_EXT.test(name)) {
        mediaLines.push(`[video: ${local}]`);
      } else {
        mediaLines.push(`[file: ${local}]`);
      }
    }

    // Voice transcript(s) become the message body (like Hermes voice mode).
    if (transcripts.length) {
      text = [text, ...transcripts].filter(Boolean).join("\n").trim();
    }
    // Reference downloaded image/video/file paths so OMP can open them.
    if (mediaLines.length) {
      text = [text, ...mediaLines].filter(Boolean).join("\n").trim();
    }
    if (!text) return;
    injectUserTurn(ctx, text);
  }

  function injectUserTurn(_ctx: any, text: string) {
    // The OMP ExtensionAPI only exposes sendUserMessage (no session/abort/prompt),
    // so the extension CANNOT cancel a pending Ask itself. deliverAs:"immediate"
    // starts a turn on an idle session; a message sent while an Ask is open queues
    // behind it. Cancelling an open Ask must be done pane-side (Esc via herdr),
    // outside this extension.
    try {
      pi?.sendUserMessage?.(text, { deliverAs: "immediate" });
    } catch {
      try { pi?.sendUserMessage?.(text, { deliverAs: "followUp" }); } catch {}
    }
  }


  pi.on?.("session_start", async (_e: unknown, ctx: any) => {
    sessionRef = ctx?.session || null;   // capture for abort() on inbound
    const me = await dGET("/users/@me");
    botUserId = me?.id ?? null;
    logPath = resolveLogPath(ctx);
    if (logPath) { try { logOffset = fs.statSync(logPath).size; } catch { logOffset = 0; } }
    // Post "online" ONCE per process. session_start also fires on every /new,
    // /resume, /fork within the same process, so guard against re-announcing.
    if (!announcedOnline) {
      announcedOnline = true;
      await postToDiscord("firstmate bridge online.");
    }
    // pull the cursor to "now" so we don't replay history
    const latest = await dGET(`/channels/${CHANNEL}/messages?limit=1`);
    if (Array.isArray(latest) && latest[0]) lastMessageId = latest[0].id;
    // Start the timers once; a session_start from /new must not stack duplicates.
    if (!inboundTimer) inboundTimer = setInterval(() => void pollInbound(ctx), 2000);
    if (!outboundTimer) outboundTimer = setInterval(() => drainLog(), 1000);
  });

  pi.on?.("agent_start", () => {
    working = true;
    if (!typingTimer) {
      void showTyping();
      typingTimer = setInterval(() => { if (working) void showTyping(); }, 8000); // Discord typing lasts ~10s
    }
  });
  pi.on?.("agent_end", () => {
    working = false;
    if (typingTimer) { clearInterval(typingTimer); typingTimer = null; }
    drainLog(); // flush any final assistant text immediately
  });

  // NOTE: no session_shutdown "offline" post. OMP fires session_shutdown on every
  // ordinary /new, /resume, and /fork within the same live process, not just a real
  // quit — posting "offline" there spams the channel with false offline notices while
  // the session is very much alive. Timers are process-scoped and left running; when
  // the process actually exits they die with it. If a genuine "offline" signal is ever
  // needed, gate it on real process exit, not session_shutdown.
}
