// Firstmate Telegram terminal mirror bridge for Pi.
//
// This extension is the Pi half of the WSL and macOS Telegram mirror. bin/fm-telegram.py
// owns Telegram, pairing, mirror mode, the in-memory inbound queue, voice
// transcription, and every Telegram reply. This half only:
//
//   - reports ordinary terminal submissions so the bot can mirror them,
//   - reports Firstmate's final visible reply after each completed run,
//   - submits queued Telegram text and images through Pi's normal user input, and
//   - confirms to the bot when Pi accepted each Telegram message.
//
// Telegram text reaches Firstmate exactly as terminal text: no origin marker,
// no hidden provenance, and no Telegram-specific instruction. Mirror mode,
// pairing, and all transport policy live in the bot, so this file carries no
// conversation state machine of its own.
//
// The bot owns the Unix socket (bin/fm-telegram.py's "bot.sock") and this
// extension is the client, because the bot outlives every Pi session. The wire
// protocol is stated once in that script's header.
import { spawnSync } from "node:child_process";
import {
  closeSync,
  constants as fsConstants,
  existsSync,
  fstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  writeFileSync,
} from "node:fs";
import { connect, type Socket } from "node:net";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { getSettingsListTheme, type ExtensionAPI, type ExtensionContext }
  from "@earendil-works/pi-coding-agent";
import { Container, type SettingItem, SettingsList, Text } from "@earendil-works/pi-tui";
import { classifyFirstmateOperationalText } from "./lib/fm-operational-input.ts";

type BotFrame = {
  t?: string;
  id?: unknown;
  text?: unknown;
  image?: unknown;
  mirror?: unknown;
  confirmations?: unknown;
};

type QueuedImage = { data: string; mime: string };

type AssistantPart = { type?: unknown; text?: unknown };
type FinalizedMessage = {
  role?: unknown;
  content?: unknown;
  stopReason?: unknown;
};

const RECONNECT_MS = positiveInteger("FM_TELEGRAM_RECONNECT_MS", 2000);
const RECONNECT_MAX_MS = positiveInteger("FM_TELEGRAM_RECONNECT_MAX_MS", 60000);
const COMMAND_TIMEOUT_MS = positiveInteger("FM_TELEGRAM_COMMAND_TIMEOUT_MS", 5000);
// Pi loads this file while the session is starting, and the Firstmate session
// lock is recorded from inside that same session moments later, so the first
// ownership answer of a fresh session is "not yet" rather than "never". These
// bound how long an unclaimed home is given to record its session before the
// bridge stops asking.
const LOCK_WAIT_MS = positiveInteger("FM_TELEGRAM_LOCK_WAIT_MS", 2000);
const LOCK_WAIT_ATTEMPTS = positiveInteger("FM_TELEGRAM_LOCK_WAIT_ATTEMPTS", 30);
// The footer item Pi renders, and the only Pi-side preference: whether that
// item is shown. It is stored beside the bot's private directory so it survives
// a restart and can still be read while the bot is unreachable.
const FOOTER_KEY = "firstmate-telegram";
// Pi renders every extension status on one shared footer line: it sorts the
// statuses by key, joins them with a single space, strips control characters,
// and truncates the result to the terminal width. An extension therefore owns
// only its own text, so the mirror ends its status with the same separator Pi's
// other statuses use between their own fields, and the status that follows it
// on that shared line reads as a separate item.
const STATUS_SEPARATOR = "\u2022";
// Pi's terminal does not preview an attached image, so every image message
// carries this marker as its visible text. It names no origin: an image sent
// from anywhere reads the same to Firstmate.
const IMAGE_MARKER = "[Image attached]";
const DISPLAY_SETTING_FILE = "pi-display-status";

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function botHome(): string {
  return process.env.FM_TELEGRAM_DIR || join(homedir(), ".firstmate-telegram");
}

function botSocketPath(): string {
  return join(botHome(), "bot.sock");
}

// Only the one Firstmate session the captain is talking to may mirror. Every
// crewmate and scout is a Pi session too, and a globally installed copy of this
// extension loads in all of them, so without this gate a worker's brief, its
// replies and its tool activity would flow into the captain's private chat the
// moment it connected. Primacy is decided the way the tracked watcher extension
// decides it: the Firstmate home's session lock names the live session, and only
// a process inside that session's own ancestry owns it. That record is written
// from inside the session Pi has already started, so ownership is re-read while
// the home is still unclaimed instead of being settled once at load.
function firstmateHome(): string {
  return process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE ||
    resolve(dirname(fileURLToPath(import.meta.url)), "../..");
}

function sessionLockChecker(): string {
  if (process.env.FM_TELEGRAM_TESTING === "1" &&
      process.env.FM_TELEGRAM_SESSION_LOCK_CHECK) {
    return process.env.FM_TELEGRAM_SESSION_LOCK_CHECK;
  }
  return join(firstmateHome(), "bin", "fm-session-lock-check.sh");
}

function stateDirectory(): string {
  return process.env.FM_STATE_OVERRIDE || join(firstmateHome(), "state");
}

function ownsSessionLock(): boolean {
  const result = spawnSync(sessionLockChecker(), [stateDirectory(), String(process.pid)], {
    stdio: "ignore",
    timeout: 2000,
  });
  return result.status === 0;
}

// A home already claimed by another live Firstmate session belongs to that
// session, and no later check can hand it to this one. Anything else - no
// record, a malformed or symlinked one, a dead pid, or a pid an unrelated
// process has since inherited - means the home is unclaimed, which is exactly
// the window between Pi starting and bin/fm-session-start.sh recording the new
// session. Both answers come from the same checker script, so which processes
// count as a live Firstmate session is decided once, in bash, rather than
// approximated here: a bare kill(pid, 0) would read a recycled pid as a live
// claim and leave the mirror dark until the captain reloaded Pi, while
// Firstmate's own session start would overwrite that record without hesitating.
function sessionLockClaimed(): boolean {
  const result = spawnSync(sessionLockChecker(), ["--claimed", stateDirectory()], {
    stdio: "ignore",
    timeout: 2000,
  });
  return result.status === 0;
}

function readDisplayStatus(): boolean {
  try {
    return readFileSync(join(botHome(), DISPLAY_SETTING_FILE), "utf8").trim() !== "off";
  } catch {
    return true;
  }
}

function writeDisplayStatus(shown: boolean): void {
  try {
    const home = botHome();
    if (!existsSync(home)) mkdirSync(home, { recursive: true, mode: 0o700 });
    writeFileSync(join(home, DISPLAY_SETTING_FILE), shown ? "on\n" : "off\n", { mode: 0o600 });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(`fm-telegram-mirror: could not persist the status display choice: ${detail}`);
  }
}

function asQueuedImage(value: unknown): QueuedImage | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const candidate = value as { data?: unknown; mime?: unknown };
  if (typeof candidate.data !== "string" || typeof candidate.mime !== "string") return undefined;
  return { data: candidate.data, mime: candidate.mime };
}

// Pi's clipboard paste writes the image into the system temp directory as
// pi-clipboard-<uuid>.<ext> and inserts that path into the editor as ordinary
// text (interactive-mode's handleClipboardPaste in Pi 0.84.2). There is no
// image event to subscribe to, so a pasted screenshot can only be recognised by
// that artifact. Recognition is deliberately narrow: exactly Pi's own file name
// in Pi's own temp directory, a real file this account owns, and bytes whose
// magic matches the extension. A path merely typed into the terminal never
// qualifies, so naming a file cannot make the mirror upload it.
// One owner for the artifact shape: Pi's own uuid file name and the image
// extensions its clipboard paste can produce.
const CLIPBOARD_UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const CLIPBOARD_EXTENSIONS = "png|jpg|jpeg|webp";
const MAX_CLIPBOARD_BYTES = positiveInteger("FM_TELEGRAM_MAX_IMAGE_BYTES", 10 * 1024 * 1024);
const MAX_CLIPBOARD_TOTAL_BYTES = MAX_CLIPBOARD_BYTES * 3;
const MAX_CLIPBOARD_IMAGES = 10;
const MAX_OUTSTANDING_IMAGE_WRITE_BYTES = positiveInteger(
  "FM_TELEGRAM_MAX_OUTSTANDING_WRITE_BYTES",
  Math.ceil(MAX_CLIPBOARD_TOTAL_BYTES / 3) * 4 + 3 * 1024 * 1024,
);

function imageMimeFromMagic(bytes: Buffer): string | undefined {
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "image/jpeg";
  }
  if (bytes.length >= 12 && bytes.subarray(0, 4).toString("latin1") === "RIFF" &&
      bytes.subarray(8, 12).toString("latin1") === "WEBP") return "image/webp";
  return undefined;
}

function clipboardMime(name: string): string | undefined {
  if (name.endsWith(".png")) return "image/png";
  if (name.endsWith(".jpg") || name.endsWith(".jpeg")) return "image/jpeg";
  if (name.endsWith(".webp")) return "image/webp";
  return undefined;
}

type ClipboardScan = { images: QueuedImage[]; caption: string; recognized: boolean; omitted: boolean };
type ClipboardArtifact =
  | { kind: "invalid" }
  | { kind: "proven"; image?: QueuedImage; bytes?: number };

function escapeForRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Pi concatenates two pastes with nothing between them, so artifacts are found
// by scanning spans rather than splitting on whitespace. A span may start at the
// beginning, after whitespace, or exactly where the previous artifact ended;
// anywhere else it is part of a longer word and stays ordinary prose.
function clipboardScan(text: string): ClipboardScan {
  const prefix = join(tmpdir(), "pi-clipboard-");
  const artifact = new RegExp(
    `^${escapeForRegExp(prefix)}${CLIPBOARD_UUID}\\.(${CLIPBOARD_EXTENSIONS})(?![A-Za-z0-9._-])`,
  );
  const images: QueuedImage[] = [];
  const proven: Array<[number, number]> = [];
  const artifacts = new Map<string, ClipboardArtifact>();
  let index = 0;
  let previousEnd = -1;
  let total = 0;
  let omitted = false;
  while (index < text.length) {
    const at = text.indexOf(prefix, index);
    if (at < 0) break;
    const startsCleanly = at === 0 || at === previousEnd || /\s/.test(text[at - 1] ?? "");
    const match = startsCleanly ? artifact.exec(text.slice(at)) : null;
    if (!match) {
      index = at + prefix.length;
      continue;
    }
    const token = match[0];
    const end = at + token.length;
    let artifactResult = artifacts.get(token);
    if (!artifactResult) {
      const remaining = images.length >= MAX_CLIPBOARD_IMAGES
        ? 0
        : MAX_CLIPBOARD_TOTAL_BYTES - total;
      artifactResult = readClipboardArtifact(token, remaining);
      artifacts.set(token, artifactResult);
    }
    if (artifactResult.kind === "proven") {
      proven.push([at, end]);
      previousEnd = end;
      const bytes = artifactResult.bytes ?? 0;
      if (artifactResult.image && images.length < MAX_CLIPBOARD_IMAGES &&
          total + bytes <= MAX_CLIPBOARD_TOTAL_BYTES) {
        total += bytes;
        images.push(artifactResult.image);
      } else {
        omitted = true;
      }
    }
    index = end;
  }
  // Only proven artifacts leave the caption; anything that failed a check is
  // ordinary text the captain wrote and stays exactly as written.
  const removed = proven.map(([start, end]): [number, number] => {
    if (/[ \t]/.test(text[end] ?? "")) return [start, end + 1];
    if (end === text.length && /[ \t]/.test(text[start - 1] ?? "")) return [start - 1, end];
    return [start, end];
  });
  let caption = text;
  for (const [start, end] of [...removed].reverse()) {
    caption = `${caption.slice(0, start)}${caption.slice(end)}`;
  }
  return { images, caption, recognized: proven.length > 0, omitted };
}

function readClipboardArtifact(token: string, remaining: number): ClipboardArtifact {
  const declared = clipboardMime(basename(token));
  if (!declared) return { kind: "invalid" };
  let descriptor: number | undefined;
  try {
    descriptor = openSync(token, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
    const info = fstatSync(descriptor);
    if (!info.isFile() || info.size <= 0) return { kind: "invalid" };
    if (typeof process.getuid === "function" && info.uid !== process.getuid()) {
      return { kind: "invalid" };
    }
    if (info.size > MAX_CLIPBOARD_BYTES || info.size > remaining) {
      const header = Buffer.alloc(12);
      const length = readSync(descriptor, header, 0, header.length, null);
      return imageMimeFromMagic(header.subarray(0, length)) === declared
        ? { kind: "proven" }
        : { kind: "invalid" };
    }
    const parts: Buffer[] = [];
    let length = 0;
    while (length <= MAX_CLIPBOARD_BYTES) {
      const part = Buffer.alloc(Math.min(64 * 1024, MAX_CLIPBOARD_BYTES + 1 - length));
      const count = readSync(descriptor, part, 0, part.length, null);
      if (count === 0) break;
      parts.push(part.subarray(0, count));
      length += count;
    }
    const bytes = Buffer.concat(parts, length);
    if (imageMimeFromMagic(bytes) !== declared) return { kind: "invalid" };
    if (bytes.length > MAX_CLIPBOARD_BYTES || bytes.length > remaining) {
      return { kind: "proven" };
    }
    return {
      kind: "proven",
      image: { data: bytes.toString("base64"), mime: declared },
      bytes: bytes.length,
    };
  } catch {
    return { kind: "invalid" };
  } finally {
    if (descriptor !== undefined) {
      try {
        closeSync(descriptor);
      } catch {}
    }
  }
}

// Pi hands attached images to the input event as its own image content; the
// bot receives the bytes so Telegram can show real media rather than a local
// path the captain's phone cannot open.
function terminalImages(images: unknown): QueuedImage[] {
  if (!Array.isArray(images)) return [];
  const mirrored: QueuedImage[] = [];
  for (const entry of images) {
    if (typeof entry !== "object" || entry === null) continue;
    const candidate = entry as { data?: unknown; mimeType?: unknown };
    if (typeof candidate.data !== "string" || typeof candidate.mimeType !== "string") continue;
    mirrored.push({ data: candidate.data, mime: candidate.mimeType });
  }
  return mirrored;
}

function assistantText(message: unknown): string {
  const content = (message as { role?: string; content?: unknown } | undefined)?.content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part): part is { type: "text"; text: string } =>
      typeof part === "object" && part !== null &&
      (part as { type?: unknown }).type === "text" &&
      typeof (part as { text?: unknown }).text === "string")
    .map((part) => part.text)
    .join("");
}

// The one white reply Pi shows the captain at the end of a response, and nothing
// else. Thinking blocks are not text parts, so they never reach here. A message
// carrying tool calls is the narration Pi prints beside its tool activity rather
// than the answer, and Pi's agent loop follows it with another assistant
// message. "stop" and "length" are the two ways a model actually ends a
// response; "toolUse", "aborted", "error", "pending", and "deferred" are not
// completed answers.
//
// This is decided per finalized message rather than when the agent settles.
// Pi runs back-to-back submissions as one continuous run, so five queued
// messages produce five visible replies but only one settle. Flushing one
// remembered reply at settle mirrored the last one and silently lost the rest,
// whatever origin the submissions came from.
function finalVisibleReply(message: unknown): string {
  const finalized = message as FinalizedMessage | undefined;
  if (finalized?.role !== "assistant") return "";
  const content = finalized.content;
  if (!Array.isArray(content)) return "";
  if (content.some((part: AssistantPart) => part?.type === "toolCall")) return "";
  if (finalized.stopReason !== "stop" && finalized.stopReason !== "length") return "";
  return assistantText(message);
}

export default function (pi: ExtensionAPI) {
  // A session that can never hold this home's lock stays completely inert: no
  // socket, no footer, no commands. A session that simply has not been recorded
  // yet is a different case, and waits below rather than deciding against
  // itself once, at load, before its own session start could record it.
  let owned = ownsSessionLock();
  if (!owned && sessionLockClaimed()) return;
  const socketPath = botSocketPath();
  let socket: Socket | null = null;
  let buffer = "";
  let stopped = false;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let reconnectDelay = RECONNECT_MS;
  let deliveries: Promise<void> = Promise.resolve();
  let outstandingImageWriteBytes = 0;
  let commandSequence = 0;
  const commandWaiters = new Map<number, (text: string) => void>();

  // Footer state. "unavailable" is the honest answer whenever the bot's socket
  // is not connected, because mirror mode then has no reachable owner.
  let activeCtx: ExtensionContext | null = null;
  let connected = false;
  let mirrorOn = false;
  let confirmations = true;
  let displayStatus = readDisplayStatus();
  let commandsRegistered = false;
  let lockWaitTimer: ReturnType<typeof setTimeout> | null = null;
  let lockWaitAttempts = 0;

  function footerText(): string {
    const state = connected ? (mirrorOn ? "on" : "off") : "unavailable";
    return `telegram: ${state} ${STATUS_SEPARATOR}`;
  }

  function refreshFooter(): void {
    if (!owned) return;
    activeCtx?.ui?.setStatus?.(FOOTER_KEY, displayStatus ? footerText() : undefined);
  }

  // Everything the live session may do, and nothing a session without the lock
  // may do. Idempotent, because it runs on every session start and again when a
  // pending lock finally names this session.
  function startBridge(): void {
    registerCommands();
    displayStatus = readDisplayStatus();
    refreshFooter();
    openSocket();
  }

  // Firstmate records its session lock from inside the session Pi has already
  // started, so a fresh session's first ownership answer is "not yet". Waiting
  // for that record is what keeps the bridge from needing a Pi reload; a home
  // claimed by another live session, or one that never records a session within
  // the window, ends the wait and leaves this session inert.
  function waitForSessionLock(): void {
    if (owned || stopped || lockWaitTimer) return;
    if (lockWaitAttempts >= LOCK_WAIT_ATTEMPTS) return;
    const timer = setTimeout(() => {
      lockWaitTimer = null;
      lockWaitAttempts += 1;
      if (stopped) return;
      if (ownsSessionLock()) {
        owned = true;
        startBridge();
        return;
      }
      if (sessionLockClaimed()) return;
      waitForSessionLock();
    }, LOCK_WAIT_MS);
    timer.unref?.();
    lockWaitTimer = timer;
  }

  function stopWaitingForSessionLock(): void {
    if (lockWaitTimer) clearTimeout(lockWaitTimer);
    lockWaitTimer = null;
  }

  function write(frame: Record<string, unknown>): boolean {
    const target = socket;
    if (!target || target.destroyed) return false;
    const payload = `${JSON.stringify(frame)}\n`;
    const imageBytes = Array.isArray(frame.images) ? Buffer.byteLength(payload) : 0;
    if (imageBytes > MAX_OUTSTANDING_IMAGE_WRITE_BYTES ||
        outstandingImageWriteBytes + imageBytes > MAX_OUTSTANDING_IMAGE_WRITE_BYTES) return false;
    outstandingImageWriteBytes += imageBytes;
    try {
      target.write(payload, () => {
        if (socket === target) outstandingImageWriteBytes -= imageBytes;
      });
      return true;
    } catch {
      outstandingImageWriteBytes -= imageBytes;
      return false;
    }
  }

  // A home that never installed the bot retries on a widening delay rather than
  // hammering a socket that will never exist, and a real connection resets it.
  function scheduleReconnect(): void {
    if (stopped || reconnectTimer) return;
    const delay = reconnectDelay;
    reconnectDelay = Math.min(RECONNECT_MAX_MS, reconnectDelay * 2);
    const timer = setTimeout(() => {
      reconnectTimer = null;
      openSocket();
    }, delay);
    timer.unref?.();
    reconnectTimer = timer;
  }

  function closeSocket(): void {
    const current = socket;
    socket = null;
    buffer = "";
    outstandingImageWriteBytes = 0;
    if (current) {
      current.removeAllListeners();
      current.destroy();
    }
  }

  function openSocket(): void {
    if (stopped || socket) return;
    const client = connect(socketPath);
    socket = client;
    client.on("connect", () => {
      reconnectDelay = RECONNECT_MS;
      connected = true;
      refreshFooter();
      // The bot sends only what this bridge announces it can deliver, so an
      // older bridge never receives an image it would silently drop.
      write({ t: "hello", features: ["image"] });
    });
    client.on("data", (chunk: Buffer) => {
      buffer += chunk.toString("utf8");
      let index = buffer.indexOf("\n");
      while (index >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (line.trim()) handleFrame(line);
        index = buffer.indexOf("\n");
      }
    });
    const drop = (): void => {
      if (socket !== client) return;
      closeSocket();
      connected = false;
      refreshFooter();
      scheduleReconnect();
    };
    client.on("error", drop);
    client.on("close", drop);
  }

  function handleFrame(line: string): void {
    let frame: BotFrame;
    try {
      frame = JSON.parse(line) as BotFrame;
    } catch {
      return;
    }
    if (frame.t === "deliver" && typeof frame.text === "string" && typeof frame.id === "string") {
      queueDelivery(frame.id, frame.text, asQueuedImage(frame.image));
      return;
    }
    if (frame.t === "state") {
      if (typeof frame.mirror === "boolean") mirrorOn = frame.mirror;
      if (typeof frame.confirmations === "boolean") confirmations = frame.confirmations;
      refreshFooter();
      return;
    }
    if (frame.t === "command_result" && typeof frame.id === "number") {
      const waiter = commandWaiters.get(frame.id);
      if (waiter) {
        commandWaiters.delete(frame.id);
        waiter(typeof frame.text === "string" ? frame.text : "");
      }
    }
  }

  // Telegram arrival order is the socket's order, so each delivery is submitted
  // on one chain, in that order. Pi keeps its own batching, steering, and
  // continuation behavior from there. "steer" is what Pi's own terminal uses
  // for text submitted while a run is streaming, and Pi ignores it when idle,
  // so this is the same path as typing the message in the terminal.
  //
  // A screenshot travels the same way, as Pi's own image content, so Firstmate
  // receives exactly what pasting it into the terminal would send.
  function queueDelivery(id: string, text: string, image?: QueuedImage): void {
    deliveries = deliveries.then(async () => {
      if (image) {
        const content = [
          { type: "text", text: text.trim() ? `${text}\n\n${IMAGE_MARKER}` : IMAGE_MARKER },
          { type: "image", data: image.data, mimeType: image.mime },
        ];
        await pi.sendUserMessage(content as never, { deliverAs: "steer" });
      } else {
        await pi.sendUserMessage(text, { deliverAs: "steer" });
      }
      write({ t: "accepted", id });
    }).catch((error: unknown) => {
      const detail = error instanceof Error ? error.message : String(error);
      console.error(`fm-telegram-mirror: could not submit a Telegram message: ${detail}`);
    });
  }

  function sendCommand(command: string): Promise<string> {
    if (!socket || socket.destroyed) {
      return Promise.resolve("Telegram mirror bot is not running.");
    }
    commandSequence += 1;
    const id = commandSequence;
    return new Promise<string>((resolveCommand) => {
      const timer = setTimeout(() => {
        commandWaiters.delete(id);
        resolveCommand("Telegram mirror bot did not answer.");
      }, COMMAND_TIMEOUT_MS);
      timer.unref?.();
      commandWaiters.set(id, (text) => {
        clearTimeout(timer);
        resolveCommand(text || "Telegram mirror bot returned no status.");
      });
      if (!write({ t: "command", id, command })) {
        clearTimeout(timer);
        commandWaiters.delete(id);
        resolveCommand("Telegram mirror bot is not running.");
      }
    });
  }

  pi.on?.("session_start", (_event, ctx) => {
    activeCtx = ctx;
    stopped = false;
    reconnectDelay = RECONNECT_MS;
    if (owned) {
      startBridge();
      return;
    }
    lockWaitAttempts = 0;
    waitForSessionLock();
  });

  pi.on?.("session_shutdown", () => {
    stopped = true;
    stopWaitingForSessionLock();
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = null;
    closeSocket();
    connected = false;
    activeCtx?.ui?.setStatus?.(FOOTER_KEY, undefined);
    activeCtx = null;
  });

  // Ordinary captain submissions typed in the terminal, images included.
  // Telegram-originated text and screenshots arrive as source "extension" and
  // are already visible in Telegram, so they are never echoed back, and
  // Firstmate's own operational input is never mirrored at all.
  pi.on?.("input", (event) => {
    if (event.source !== "interactive") return;
    const text = typeof event.text === "string" ? event.text : "";
    if (text.trim() && classifyFirstmateOperationalText(text) !== undefined) return;
    const pasted = clipboardScan(text);
    const images = [...terminalImages(event.images), ...pasted.images];
    // The local path is Pi's own plumbing and means nothing on a phone, so the
    // caption keeps only what the captain actually wrote around it. Firstmate
    // still receives the submission exactly as typed.
    const caption = pasted.recognized ? pasted.caption : text;
    if (pasted.omitted) {
      activeCtx?.ui.notify("Telegram image was not mirrored because it exceeds clipboard image limits.", "warning");
    }
    // An image-only submission has no text but is still a real submission.
    if (!caption.trim() && images.length === 0) return;
    const written = write(images.length > 0
      ? { t: "terminal", text: caption, images }
      : { t: "terminal", text: caption });
    if (!written && images.length > 0) {
      if (caption.trim()) write({ t: "terminal", text: caption });
      activeCtx?.ui.notify("Telegram image was not mirrored because its transport queue is full.", "warning");
    }
  });

  // Every completed reply is mirrored as Pi finalizes it, exactly once.
  pi.on?.("message_end", (event) => {
    const text = finalVisibleReply(event.message);
    if (text.trim()) write({ t: "reply", text });
  });

  // Registered when this session is the live one, whether that was already true
  // at load or became true while the bridge waited for the session lock.
  function registerCommands(): void {
    if (commandsRegistered) return;
    commandsRegistered = true;

    pi.registerCommand?.("telegram", {
      description: "Toggle the Telegram terminal mirror.",
      handler: async (_args, ctx) => {
        activeCtx = ctx;
        ctx.ui.notify(await sendCommand("toggle"), "info");
      },
    });

    pi.registerCommand?.("telegram-settings", {
      description: "Show and change the Telegram mirror settings.",
      handler: async (_args, ctx) => {
        activeCtx = ctx;
        if (ctx.mode !== "tui") {
          ctx.ui.notify(
            `Telegram settings: display status ${displayStatus ? "on" : "off"}, ` +
            `delivery confirmations ${connected ? (confirmations ? "on" : "off") : "unavailable"}.`,
            "info",
          );
          return;
        }
        const items: SettingItem[] = [
          {
            id: "display",
            label: "Display Telegram status",
            currentValue: displayStatus ? "on" : "off",
            values: ["on", "off"],
          },
          {
            id: "confirmations",
            label: "Delivery confirmations",
            currentValue: connected ? (confirmations ? "on" : "off") : "unavailable",
            values: connected ? ["on", "off"] : ["unavailable"],
          },
        ];
        await ctx.ui.custom((_tui, theme, _keybindings, done) => {
          const container = new Container();
          container.addChild(new Text(theme.fg("accent", theme.bold("Telegram mirror")), 1, 1));
          const list = new SettingsList(
            items,
            Math.min(items.length + 2, 15),
            getSettingsListTheme(),
            (id, value) => {
              if (id === "display") {
                displayStatus = value === "on";
                writeDisplayStatus(displayStatus);
                refreshFooter();
                return;
              }
              if (id === "confirmations") {
                if (!connected) {
                  ctx.ui.notify("The Telegram mirror bot is not running.", "warning");
                  return;
                }
                // The bot owns this setting for both surfaces; its state frame is
                // what updates the local copy.
                write({ t: "set", setting: "confirmations", value: value === "on" });
              }
            },
            () => done(undefined),
            { enableSearch: false },
          );
          container.addChild(list);
          return {
            render: (width: number) => container.render(width),
            invalidate: () => container.invalidate(),
            handleInput: (data: string) => list.handleInput?.(data),
          };
        });
      },
    });
  }

  // A session that already holds the lock keeps today's behavior exactly:
  // its commands exist from the moment Pi loads this file.
  if (owned) registerCommands();
}
