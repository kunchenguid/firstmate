#!/usr/bin/env node
// Inbound WhatsApp listener for the firstmate WhatsApp channel.
//
// Runs as a long-lived child of bin/fm-wa-listen.sh and holds ONE WhatsApp
// connection on its OWN linked-device credential folder, separate from
// mudslide's. That separation is the whole point: WhatsApp allows one live
// connection per credential folder, so a listener sharing mudslide's folder
// would fight `mudslide send`. See docs/whatsapp-channel.md for the decision.
//
// This process is RECEIVE-ONLY. Outbound stays on the untouched `mudslide send`
// path (bin/fm-wa-send.sh), so arming or disarming the listener can never break
// sending.
//
// Commands:
//   pair <e164> [rounds]
//                 request an 8-character pairing code for a NEW linked device,
//                 print it, and wait for the link to complete; each expiry
//                 within <rounds> starts a fresh code
//   listen        run until stopped, stashing accepted captain messages to
//                 <state>/wa-inbox/<message-id>.json
//   status        print one JSON line describing the credential folder
//   handle-fixture
//                 read one synthetic message on stdin and report whether it
//                 would be stashed; used by tests/fm-wa-channel.test.sh
//   captains      print the parsed captain numbers, one per line, so a test can
//                 hold this parse against the shell's own
//
// Everything it writes is private (0600 files, 0700 directories) and lives
// under the home's gitignored state/ tree.
//
// Environment (all set by bin/fm-wa-listen.sh):
//   FM_WA_STATE        state directory (required)
//   FM_WA_AUTH_DIR     credential folder for THIS device (required)
//   FM_WA_CAPTAIN      captain's number(s); bin/fm-wa-listen.sh hands this the
//                      already-parsed list joined by commas, e.g.
//                      447700900123,447700900124
//   FM_WA_ALLOW_DEVICES  comma-separated WhatsApp device numbers to accept
//                        (default "0" - the captain's own phone)
//   FM_WA_BAILEYS_DIR  baileys package directory (auto-discovered when unset)
//   FM_WA_HISTORY_HORIZON  seconds of backlog to accept on first run (default 0)

import { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import process from 'node:process'

const STATE = requiredEnv('FM_WA_STATE')
const AUTH_DIR = requiredEnv('FM_WA_AUTH_DIR')
// fm_wa_parse_captains in bin/fm-wa-lib.sh decides the split, and this must not
// decide it a second time: bin/fm-wa-listen.sh hands over the parsed list joined
// by commas, which is unambiguous because a comma cannot occur inside a number,
// so the comma branch reproduces that list entry for entry.
//
// The whitespace heuristic below is only for a listener run directly by hand on
// a raw value, and it carries the same rule the shell applies to one: a comma
// always separates, while whitespace separates only when every piece is already
// a plausible number, so `+44 7700 900123` stays one number instead of becoming
// three that match no phone.
function parseCaptains(raw) {
  const digits = (s) => s.replace(/[^0-9]/g, '')
  const value = String(raw || '')
  if (value.includes(',')) {
    return value.split(',').map(digits).filter((n) => n !== '')
  }
  const parts = value.split(/\s+/).map(digits).filter((n) => n !== '')
  if (parts.length > 1 && parts.every((n) => n.length >= 8)) return parts
  const joined = digits(value)
  return joined === '' ? [] : [joined]
}

const CAPTAINS = parseCaptains(process.env.FM_WA_CAPTAIN)
const CAPTAIN = CAPTAINS[0] || ''
const ALLOW_DEVICES = parseDevices(process.env.FM_WA_ALLOW_DEVICES ?? '0')
const HISTORY_HORIZON = Number.parseInt(process.env.FM_WA_HISTORY_HORIZON ?? '0', 10) || 0
// How long an unconsumed outbound digest can still suppress an inbound message.
// An echo returns within seconds; anything older is text the captain never sent
// back, so it must stop counting as one.
const ECHO_TTL_SECONDS = 600

const INBOX = path.join(STATE, 'wa-inbox')
const SEEN = path.join(STATE, 'wa-seen')
const SENT = path.join(STATE, 'wa-sent')
const WATERMARK = path.join(STATE, 'wa-watermark')
const LISTENER_STATUS = path.join(STATE, 'wa-listener.status')
const LISTENER_BEAT = path.join(STATE, 'wa-listener.beat')

// Message ids are attacker-influenceable in principle, so they are never used
// as a path component until they match this slug. It must stay the same rule
// as fm_wa_id_safe in bin/fm-wa-lib.sh, leading dot included: an id this side
// accepts and the poll refuses becomes a dotfile that `find` still lists and
// the drain's own glob never does, so the captain's message would be dropped
// behind a fault line that cannot even name it.
const SAFE_ID = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$/

function requiredEnv(name) {
  const value = process.env[name]
  if (!value) {
    process.stderr.write(`fm-wa-listen: ${name} is required\n`)
    process.exit(2)
  }
  return value
}

function parseDevices(raw) {
  const out = new Set()
  for (const part of String(raw).split(',')) {
    const trimmed = part.trim()
    if (trimmed === '') continue
    if (trimmed === '*') return '*'
    const n = Number.parseInt(trimmed, 10)
    if (Number.isInteger(n) && n >= 0) out.add(n)
  }
  return out.size > 0 ? out : new Set([0])
}

function logLine(message) {
  // stdout is the supervisor's log file; keep it one line per event so an
  // operator can tail it without a parser.
  process.stdout.write(`${new Date().toISOString()} ${message}\n`)
}

// ---------------------------------------------------------------- baileys ---

function baileysDir() {
  if (process.env.FM_WA_BAILEYS_DIR) return process.env.FM_WA_BAILEYS_DIR
  const candidates = []
  const globalRoots = [
    path.join(os.homedir(), '.local', 'lib', 'node_modules'),
    '/usr/local/lib/node_modules',
    '/usr/lib/node_modules',
  ]
  for (const root of globalRoots) {
    candidates.push(path.join(root, 'mudslide', 'node_modules', 'baileys'))
    candidates.push(path.join(root, 'baileys'))
  }
  for (const candidate of candidates) {
    if (fs.existsSync(path.join(candidate, 'lib', 'index.js'))) return candidate
  }
  return null
}

async function loadBaileys() {
  const dir = baileysDir()
  if (!dir) {
    process.stderr.write('fm-wa-listen: cannot find the baileys package; set FM_WA_BAILEYS_DIR\n')
    process.exit(3)
  }
  const mod = await import(path.join(dir, 'lib', 'index.js'))
  let logger = null
  try {
    // Reuse the pino that ships beside baileys so the socket stays silent.
    const require = createRequire(path.join(dir, 'package.json'))
    logger = require('pino')({ level: 'silent' })
  } catch {
    logger = null
  }
  return { mod, dir, logger }
}

async function makeSocket(mod, logger) {
  const { useMultiFileAuthState, fetchLatestWaWebVersion } = mod
  const makeWASocket = mod.makeWASocket ?? mod.default
  ensurePrivateDir(AUTH_DIR)
  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR)
  let version
  try {
    ({ version } = await fetchLatestWaWebVersion({}))
  } catch {
    version = undefined
  }
  const platform = process.platform === 'darwin' ? 'macOS'
    : process.platform === 'win32' ? 'Windows' : 'Linux'
  const sock = makeWASocket({
    auth: state,
    ...(logger ? { logger } : {}),
    browser: [platform, 'Chrome', '10.15.0'],
    ...(version ? { version } : {}),
    syncFullHistory: false,
    markOnlineOnConnect: false,
    // The captain's other devices own read receipts and history; this listener
    // must never resend anything, so it declines to look messages up.
    getMessage: async () => undefined,
  })
  sock.ev.on('creds.update', async () => {
    await saveCreds()
    hardenAuthDir()
  })
  return sock
}

// ------------------------------------------------------------ private i/o ---

function ensurePrivateDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
  try {
    const st = fs.lstatSync(dir)
    if (!st.isDirectory() || st.isSymbolicLink()) throw new Error('not a directory')
    if ((st.mode & 0o077) !== 0) fs.chmodSync(dir, 0o700)
  } catch (err) {
    throw new Error(`unusable private directory ${dir}: ${err.message}`)
  }
}

// Create-exclusive write: two listeners, or a listener racing its own restart,
// can never both claim the same message id, and a drained id is never rebuilt.
function publishOnce(dir, base, body) {
  ensurePrivateDir(dir)
  const dest = path.join(dir, base)
  let fd
  try {
    fd = fs.openSync(dest, 'wx', 0o600)
  } catch (err) {
    if (err.code === 'EEXIST') return false
    throw err
  }
  try {
    fs.writeFileSync(fd, body)
  } finally {
    fs.closeSync(fd)
  }
  return true
}

function readWatermark() {
  try {
    const n = Number.parseInt(fs.readFileSync(WATERMARK, 'utf8').trim(), 10)
    return Number.isFinite(n) ? n : null
  } catch {
    return null
  }
}

function writeWatermark(ts) {
  const tmp = `${WATERMARK}.tmp-${process.pid}`
  fs.writeFileSync(tmp, `${ts}\n`, { mode: 0o600 })
  fs.renameSync(tmp, WATERMARK)
}

// The accepted-sender-device filter is the guard that separates the captain
// from firstmate's own echo, and it reads a baileys internal. When that hook
// cannot be attached the connection still comes up perfectly, so the fault
// rides along on every status the listener writes rather than being overwritten
// by the next `connected` line, and bin/fm-wa-poll.sh raises it as a channel
// error instead of the home going silently deaf.
let deviceHookFault = false

function writeListenerStatus(fields) {
  const body = deviceHookFault ? { ...fields, deviceHook: 'unavailable' } : fields
  const tmp = `${LISTENER_STATUS}.tmp-${process.pid}`
  fs.writeFileSync(tmp, `${JSON.stringify(body)}\n`, { mode: 0o600 })
  fs.renameSync(tmp, LISTENER_STATUS)
}

// ----------------------------------------------------------- echo guard -----

// Must agree with fm_wa_normalize_text in bin/fm-wa-lib.sh byte for byte: the
// digest is computed independently on each side and any disagreement disables
// the echo guard without a word. The shell side runs under LC_ALL=C, so it
// collapses only ASCII whitespace and strips one space from each end; \s and
// trim() would additionally eat U+00A0, U+2028, U+2029, U+202F, U+3000 and
// U+FEFF, and a reply carrying one of those would come straight back in as a
// fresh captain instruction.
function normalizeText(text) {
  return String(text).replace(/[ \t\n\v\f\r]+/g, ' ').replace(/^ /, '').replace(/ $/, '')
}

// An echo comes back within seconds, so a digest older than the TTL belongs to
// text the captain never repeated. Keeping it forever would make those exact
// words a permanent trap: the first time the captain himself typed them, his
// instruction would be swallowed as an echo. Sweeping bounds both that risk and
// the growth of the directory.
function pruneStaleEchoes() {
  const cutoff = Date.now() - ECHO_TTL_SECONDS * 1000
  let entries = []
  try { entries = fs.readdirSync(SENT) } catch { return }
  for (const entry of entries) {
    if (!entry.endsWith('.sent')) continue
    const marker = path.join(SENT, entry)
    try {
      if (fs.statSync(marker).mtimeMs < cutoff) fs.rmSync(marker, { force: true })
    } catch { /* raced with another sweep */ }
  }
}

// Second line of defence alongside the device filter, and checked before it.
// bin/fm-wa-send.sh records a digest of everything firstmate sends; if an
// inbound message matches an unconsumed digest that is still within the TTL it
// is firstmate's own words coming back and is dropped. The echo consuming its
// own marker is what keeps the captain free to repeat those same words
// seconds later rather than for the rest of the TTL.
//
// One reply now goes to every configured number, and each delivery echoes back
// separately under its own message id, so the send records ONE MARKER PER
// DELIVERY and each echo consumes one of them. A single marker would be spent
// by the first echo and leave the rest unguarded, which under
// FM_WA_ALLOW_DEVICES=* is firstmate reading its own reply as a fresh
// instruction and answering it - the unattended self-reply loop this exists to
// prevent.
// Whether any reply is still waiting to be echoed back. Almost none of the
// captain's own outgoing traffic is one - his linked device sees every message
// he sends to anyone - so this is what keeps the work and the durable per-id
// claim below to the window where a reply is actually outstanding, rather than
// spending both on every word he types to somebody else.
function echoMarkersPending() {
  try {
    return fs.readdirSync(SENT).some((entry) => entry.endsWith('.sent'))
  } catch {
    return false
  }
}

async function consumeOwnEcho(text) {
  const normalized = normalizeText(text)
  if (normalized === '') return false
  pruneStaleEchoes()
  const { createHash } = await import('node:crypto')
  const digest = createHash('sha256').update(normalized, 'utf8').digest('hex')
  let entries = []
  try { entries = fs.readdirSync(SENT) } catch { return false }
  // Everything after the digest is the send's own key, so `<digest>.sent`,
  // `<digest>.<n>.sent` and `<digest>.<send>-<n>.sent` all match and a marker
  // written by an older send is still consumed by the echo it belongs to.
  const prefix = `${digest}.`
  for (const entry of entries.filter((e) => e.startsWith(prefix) && e.endsWith('.sent')).sort()) {
    try {
      fs.unlinkSync(path.join(SENT, entry))
      return true
    } catch { /* raced with another sweep */ }
  }
  return false
}

// -------------------------------------------------------- message reading ---

function unwrap(message) {
  let current = message
  for (let depth = 0; current && depth < 8; depth += 1) {
    if (current.ephemeralMessage?.message) { current = current.ephemeralMessage.message; continue }
    if (current.viewOnceMessage?.message) { current = current.viewOnceMessage.message; continue }
    if (current.viewOnceMessageV2?.message) { current = current.viewOnceMessageV2.message; continue }
    if (current.viewOnceMessageV2Extension?.message) { current = current.viewOnceMessageV2Extension.message; continue }
    if (current.documentWithCaptionMessage?.message) { current = current.documentWithCaptionMessage.message; continue }
    if (current.editedMessage?.message) { current = current.editedMessage.message; continue }
    return current
  }
  return current
}

function extractText(message) {
  if (!message) return ''
  if (typeof message.conversation === 'string') return message.conversation
  if (typeof message.extendedTextMessage?.text === 'string') return message.extendedTextMessage.text
  for (const key of ['imageMessage', 'videoMessage', 'documentMessage', 'audioMessage']) {
    const caption = message[key]?.caption
    if (typeof caption === 'string' && caption !== '') return caption
  }
  return ''
}

function contextInfoOf(message) {
  if (!message) return null
  if (message.extendedTextMessage?.contextInfo) return message.extendedTextMessage.contextInfo
  for (const key of Object.keys(message)) {
    const ctx = message[key]?.contextInfo
    if (ctx) return ctx
  }
  return null
}

function quotedContext(ctx) {
  if (!ctx?.quotedMessage) return null
  const quoted = unwrap(ctx.quotedMessage)
  return {
    stanza_id: ctx.stanzaId ?? null,
    participant: ctx.participant ?? null,
    text: extractText(quoted) || null,
  }
}

function attachmentKind(message) {
  if (!message) return null
  for (const key of ['imageMessage', 'videoMessage', 'documentMessage', 'audioMessage', 'stickerMessage']) {
    if (message[key]) return key.replace(/Message$/, '')
  }
  return null
}

// ------------------------------------------------------------- accept/deny ---

// The captain's own account has TWO identities, and WhatsApp uses both. His
// self-chat arrives addressed to his phone number (@s.whatsapp.net) on some
// deliveries and to his LID (@lid) on others, and a message addressed to the
// LID form is still the same chat with the same person. Both identities come
// from THIS listener's own credentials rather than from configuration or a
// string pattern, so the pairing itself is what proves which LID is his.
const SELF = { pn: null, lid: null }

function adoptSelfIdentity(user) {
  if (!user) return
  const pn = jidUser(user.id)
  const lid = jidUser(user.lid)
  if (pn) SELF.pn = pn
  if (lid) SELF.lid = lid
}

// Read the identities straight from the credential folder, so they are known
// before the socket reports open and survive a reconnect.
function loadSelfIdentityFromCreds() {
  try {
    const creds = JSON.parse(fs.readFileSync(path.join(AUTH_DIR, 'creds.json'), 'utf8'))
    adoptSelfIdentity(creds?.me)
  } catch { /* not paired yet */ }
  if (process.env.FM_WA_SELF_LID) SELF.lid = String(process.env.FM_WA_SELF_LID).replace(/[^0-9]/g, '') || SELF.lid
}

// A captain's direct chat, in either identity form, and nothing else.
// Groups, broadcasts, status and newsletters can never match: they carry their
// own server suffixes.
//
// Two shapes reach firstmate, and they prove themselves by opposite evidence.
//
// The first is our OWN chat with ourselves, the "Message yourself" chat the
// mudslide device is linked to. It is recognised by this listener's own
// credentials - the chat's user is our own phone number on a
// `@s.whatsapp.net` delivery, or our own LID on a `@lid` one - and it is
// necessarily `fromMe`, so the sender-device filter is what keeps discriminating
// there between the captain's phone and firstmate's own replies coming back.
//
// The second is any OTHER chat, which is a conversation with a second person.
// The counterparty has to be a number this home was configured with AND the
// message has to have come FROM them, never from us. Requiring `fromMe === false`
// is the whole point: `sender_pn` names the SENDER, so on one of our own
// outgoing messages it is always our own number and would match the configured
// list in every chat the captain has, turning his private conversations with
// third parties into firstmate instructions. Direction is therefore structural
// here rather than a check bolted on afterwards.
//
// For a `@s.whatsapp.net` chat the counterparty is the chat's own user. For a
// `@lid` chat the address is opaque and carries no number, so the server has to
// supply one: baileys 6.7.23 lifts the stanza's `sender_pn` attribute onto the
// message key, and that is valid evidence of the counterparty only on an
// inbound message. The LID is never trusted on its own.
//
// Fail closed when nothing supplies a number: an unresolvable LID is refused
// rather than assumed, and the caller reports it apart from an ordinary
// stranger so that refusal is visible instead of silent.
//
// The verdict carries the number it resolved, so a caller can record who the
// message actually came from rather than guessing at the configured list.
function captainChatVerdict(remoteJid, key) {
  const user = jidUser(remoteJid)
  if (!user) return { ok: false }
  const phoneChat = remoteJid.endsWith('@s.whatsapp.net')
  const lidChat = remoteJid.endsWith('@lid')
  if (!phoneChat && !lidChat) return { ok: false }

  const fromMe = key?.fromMe === true

  // Our own chat with ourselves, under whichever of our own identities this
  // delivery was addressed to. Each identity is only ever compared within its
  // own namespace, so a LID can never be mistaken for a phone number.
  const ownChat = phoneChat
    ? (SELF.pn !== null && user === SELF.pn)
    : (SELF.lid !== null && user === SELF.lid)
  if (ownChat) {
    if (!fromMe) return { ok: false }
    return { ok: true, number: SELF.pn || CAPTAIN || null }
  }

  // Someone else's chat. Only a message the captain sent INTO it can be an
  // instruction; one we sent is his own conversation and is never ours to read.
  if (fromMe) return { ok: false, outgoing: true }

  const counterparty = phoneChat
    ? user
    : jidUser(key?.senderPn ?? key?.participantPn ?? null)
  if (!counterparty) return { ok: false, unresolved: true }
  if (!CAPTAINS.includes(counterparty)) return { ok: false }
  return { ok: true, number: counterparty }
}

function jidUser(jid) {
  if (typeof jid !== 'string') return null
  const at = jid.indexOf('@')
  if (at < 0) return null
  return jid.slice(0, at).split(':')[0].split('_')[0]
}

function jidDevice(jid) {
  if (typeof jid !== 'string') return null
  const at = jid.indexOf('@')
  if (at < 0) return null
  const combined = jid.slice(0, at)
  const sep = combined.indexOf(':')
  if (sep < 0) return 0
  const n = Number.parseInt(combined.slice(sep + 1), 10)
  return Number.isInteger(n) ? n : null
}

function deviceAllowed(device) {
  if (ALLOW_DEVICES === '*') return true
  return device !== null && ALLOW_DEVICES.has(device)
}

// ------------------------------------------------------------------ listen ---

async function runListen() {
  loadSelfIdentityFromCreds()
  ensurePrivateDir(STATE)

  // The status file is how bin/fm-wa-poll.sh judges the LIVE listener, and it
  // stops one that reports it cannot read sender devices. A predecessor's last
  // status left in place would be read as this process's own and get a healthy
  // replacement killed, so claim the file as the very first act of the process
  // - before the baileys import, which is a large bundle and costs seconds on a
  // cold start while the pid file the wrapper wrote is already visible to the
  // poll.
  writeListenerStatus({ state: 'starting', at: Date.now() })

  const { mod, logger } = await loadBaileys()
  const { DisconnectReason } = mod

  ensurePrivateDir(INBOX)
  ensurePrivateDir(SEEN)
  ensurePrivateDir(SENT)

  // A first run must not ingest the account's backlog. The watermark is the
  // durable "everything at or before this second is already accounted for"
  // line, so a restart still picks up what arrived while we were down.
  let watermark = readWatermark()
  if (watermark === null) {
    watermark = Math.floor(Date.now() / 1000) - HISTORY_HORIZON
    writeWatermark(watermark)
    logLine(`initialized watermark at ${watermark}`)
  }

  // The device number is the signal that separates the captain typing on his
  // phone from firstmate's own replies coming back through the shared
  // self-chat. baileys drops it from the emitted key, so capture it from the
  // raw stanza and correlate by message id.
  const deviceById = new Map()
  const rememberDevice = (stanza) => {
    const id = stanza?.attrs?.id
    const from = stanza?.attrs?.participant || stanza?.attrs?.from
    if (!id || !from) return
    deviceById.set(id, jidDevice(from))
    if (deviceById.size > 512) {
      const oldest = deviceById.keys().next().value
      deviceById.delete(oldest)
    }
  }

  let backoff = 1000
  let closing = false
  let current = null
  let connected = false

  // The pid alone says nothing about the channel: a listener can sit alive with
  // a socket that never comes back. The beat is touched only while the
  // connection is actually open, so bin/fm-wa-poll.sh can tell a working
  // listener from a wedged one.
  const touchBeat = () => {
    try {
      fs.writeFileSync(LISTENER_BEAT, `${Math.floor(Date.now() / 1000)}\n`, { mode: 0o600 })
    } catch { /* best effort */ }
  }
  const beatTimer = setInterval(() => { if (connected) touchBeat() }, 60000)
  if (beatTimer.unref) beatTimer.unref()

  const endSocket = (sock) => {
    if (!sock) return
    try { sock.end(undefined) } catch { /* already gone */ }
  }

  // The timer is the ONLY thing keeping the retry chain alive, so a connect
  // that throws (an unreadable credential folder, a transient permission
  // problem) must arm the next attempt rather than ending the chain silently
  // and leaving a process that is alive with no socket and no way back.
  const scheduleReconnect = () => {
    if (closing) return
    const delay = backoff
    backoff = Math.min(backoff * 2, 60000)
    setTimeout(() => {
      connect().catch((err) => {
        logLine(`reconnect failed: ${err.message}; retrying in ${backoff}ms`)
        writeListenerStatus({ state: 'reconnecting', error: err.message, at: Date.now() })
        scheduleReconnect()
      })
    }, delay)
  }

  const shutdown = () => {
    closing = true
    clearInterval(beatTimer)
    writeListenerStatus({ state: 'stopped', at: Date.now() })
    endSocket(current)
    process.exit(0)
  }
  process.once('SIGTERM', shutdown)
  process.once('SIGINT', shutdown)

  const connect = async () => {
    const sock = await makeSocket(mod, logger)
    current = sock
    if (typeof sock.ws?.on === 'function') {
      sock.ws.on('CB:message', rememberDevice)
      deviceHookFault = false
    } else if (ALLOW_DEVICES === '*') {
      deviceHookFault = false
      logLine('raw stanza hook unavailable; every device is accepted, so the sender-device filter is not needed')
    } else {
      deviceHookFault = true
      logLine('raw stanza hook unavailable: sender devices cannot be read, so every message would be rejected by FM_WA_ALLOW_DEVICES')
      writeListenerStatus({ state: 'degraded', at: Date.now() })
    }

    sock.ev.on('connection.update', (update) => {
      const { connection, lastDisconnect, qr } = update
      if (qr) {
        logLine('connection needs pairing: run bin/fm-wa-listen.sh pair')
        writeListenerStatus({ state: 'unpaired', at: Date.now() })
      }
      if (connection === 'open') {
        backoff = 1000
        connected = true
        adoptSelfIdentity(sock.user)
        const me = sock.user?.id ?? null
        touchBeat()
        logLine(`connected as ${me}`)
        writeListenerStatus({ state: 'connected', me, at: Date.now() })
      }
      if (connection === 'close') {
        connected = false
        const code = lastDisconnect?.error?.output?.statusCode
        if (code === DisconnectReason?.loggedOut) {
          logLine('logged out on WhatsApp; re-pair with bin/fm-wa-listen.sh pair')
          writeListenerStatus({ state: 'logged-out', at: Date.now() })
          endSocket(sock)
          process.exit(4)
        }
        if (closing) return
        // Release the dead socket before opening its replacement, so one
        // credential folder never carries two live connections.
        endSocket(sock)
        writeListenerStatus({ state: 'reconnecting', code: code ?? null, at: Date.now() })
        logLine(`connection closed (${code ?? 'unknown'}); reconnecting in ${backoff}ms`)
        scheduleReconnect()
      }
    })

    // The emitter does not wait for an async handler, so two emissions would
    // otherwise run interleaved - and WhatsApp routinely emits the same message
    // twice, once as `notify` and again as `append`, with a restart replaying
    // what was offline on top. Every guard here is a read followed by a write
    // (has this id been handled, is this text an unconsumed echo), and two
    // deliveries of one id crossing inside that gap each spend a marker the
    // other still needed. Handling is chained so one message is finished before
    // the next begins; the durable per-id claims below then cover a restart and
    // a second process, which serialisation on its own cannot.
    let handling = Promise.resolve()
    sock.ev.on('messages.upsert', ({ messages, type }) => {
      if (type !== 'notify' && type !== 'append') return
      handling = handling.then(async () => {
        for (const msg of messages ?? []) {
          try {
            await handleMessage(msg, deviceById, () => watermark, (ts) => { watermark = ts })
          } catch (err) {
            logLine(`message handling failed: ${err.message}`)
          }
        }
      })
    })
  }

  await connect()
}

async function handleMessage(msg, deviceById, getWatermark, setWatermark) {
  const key = msg?.key ?? {}
  const id = key.id
  const remoteJid = key.remoteJid ?? ''
  const timestamp = Number(msg?.messageTimestamp ?? 0) || 0

  if (!id || !SAFE_ID.test(id)) return reject('unsafe or missing message id', id)

  // Everything strictly before the watermark is history, not a new instruction.
  // The comparison must stay strict: WhatsApp timestamps are whole seconds, so
  // two messages typed in quick succession routinely share one, and the durable
  // wa-seen marker is what makes a redelivery idempotent.
  if (timestamp !== 0 && timestamp < getWatermark()) {
    return reject('older than the history watermark', id)
  }

  // The channel is the captain's own chat with himself - his phone writes it,
  // firstmate's linked device reads it - plus a message a second configured
  // phone sends in. He reaches either under both of his identity forms, and
  // everything else - groups, broadcasts, status, newsletters, another user,
  // and our own outgoing words in somebody else's chat - is refused.
  const verdict = captainChatVerdict(remoteJid, key)
  if (!verdict.ok) {
    // An unresolvable LID is reported apart from an ordinary stranger: it is the
    // one refusal that can hide a real message from the captain, so it must be
    // visible in the log rather than looking like routine traffic.
    if (verdict.unresolved) {
      return reject('LID chat carries no phone number to check against the configured captains', remoteJid)
    }
    // Equally distinct, and named so an operator can tell the two things it
    // covers apart: usually it is one delivery of firstmate's own reply coming
    // back, but it is ALSO what a message from the captain looks like when his
    // chat identity is not recognised, and that second case is a dropped
    // instruction rather than routine traffic. docs/whatsapp-channel.md
    // troubleshoots it alongside the device filter.
    //
    // A fanned-out reply echoes back once per delivery, so the digest marker is
    // consumed here even though the message is refused anyway: a marker no echo
    // ever consumes outlives the reply as a trap, and the first time the captain
    // himself typed those words inside the echo window his instruction would be
    // swallowed. One marker per delivery, one delivery consuming each.
    //
    // The consume is single-shot, and WhatsApp redelivers - the same echo
    // arrives as `notify` and again as `append`, and a restart replays what was
    // offline - so a redelivery would spend a SECOND marker and leave the echo
    // it belonged to unguarded.
    //
    // The create-exclusive marker IS the claim, rather than something read
    // before the consume and written after it: that pair is not atomic across
    // the await inside the consume, and it does not survive a restart or a
    // second process at all. Nothing is lost by claiming first here because the
    // message is refused either way, and the claim is only taken while a reply
    // is actually outstanding, so the captain's ordinary traffic to everybody
    // else leaves nothing behind.
    if (verdict.outgoing && echoMarkersPending()) {
      if (!publishOnce(SEEN, `${id}.seen`, `${timestamp}\n`)) {
        return reject('our own outgoing message, already accounted for', remoteJid)
      }
      await consumeOwnEcho(extractText(unwrap(msg.message)))
    }
    if (verdict.outgoing) {
      return reject('our own outgoing message in a chat that is not the captain\'s own', remoteJid)
    }
    return reject('not the captain\'s direct chat', remoteJid)
  }

  // Ahead of everything the accepted path does, the echo consume included. The
  // marker outlives the inbox file, so a message firstmate has already drained
  // is never re-offered - and a redelivery that reached the consume would spend
  // a marker belonging to an echo that has not arrived yet, or swallow the
  // captain's own repeat of words firstmate happened to send.
  if (fs.existsSync(path.join(SEEN, `${id}.seen`))) return reject('already handled', id)

  const body = unwrap(msg.message)
  if (!body) return reject('no readable message body', id)
  const ctx = contextInfoOf(body)
  if (ctx?.isForwarded === true || (ctx?.forwardingScore ?? 0) > 0) {
    return reject('forwarded message', id)
  }

  const text = extractText(body)
  const attachment = attachmentKind(body)
  // A photo, voice note, sticker, video or document sent with no caption is
  // still the captain reaching out, and from his phone a refusal is
  // indistinguishable from being ignored. It is stashed with empty text and its
  // kind named, so firstmate wakes and can answer that the media is unreadable.
  if (String(text ?? '').trim() === '' && attachment === null) {
    return reject('no text to act on', id)
  }

  // Ahead of the sender-device filter on purpose. With the default filter the
  // real echo arrives on mudslide's device, so a device check first would
  // reject it before it ever consumed its own marker, and that marker would
  // then sit out the whole TTL as a trap for the captain typing those same
  // words himself. Letting the echo consume its marker here bounds that window
  // to the seconds the round trip actually takes.
  // The digest is single-consume by design, so on its own it stops exactly one
  // delivery. WhatsApp gives no such guarantee: one message arrives as `notify`
  // and again as `append`, and a restart replays what was offline. The second
  // delivery finds no digest, and with FM_WA_ALLOW_DEVICES=* no device filter
  // either, so firstmate's own words would be stashed as a fresh instruction it
  // then answers - a self-reply loop over the captain's own account, unattended.
  //
  // The wildcard is kept rather than refused because it has a real use: it is
  // the only way a host whose baileys exposes no raw stanza hook can read the
  // captain at all, and refusing it there would silently take the channel down.
  // So the guard gains a second, durable mechanism instead of relying on one:
  // the same per-id marker that already makes a redelivery idempotent is
  // written here, and it outlives the digest by thirty days.
  if (await consumeOwnEcho(text)) {
    publishOnce(SEEN, `${id}.seen`, `${timestamp}\n`)
    return reject('matches firstmate outbound', id)
  }

  const device = deviceById.get(id) ?? null
  if (!deviceAllowed(device)) {
    // Device 2 is mudslide, i.e. firstmate's own outbound echoing back.
    return reject(`device ${device ?? 'unknown'} is not an accepted captain device`, id)
  }

  const record = {
    schema: 'fm-wa-inbox-v1',
    id,
    chat_jid: remoteJid,
    // The number the chat actually resolved to, so a record from his second
    // phone names that phone rather than whichever number happens to be listed
    // first, and a consumer never has to know which identity WhatsApp addressed
    // this delivery to.
    sender: verdict.number || CAPTAIN || SELF.pn || jidUser(remoteJid),
    chat_identity: remoteJid.endsWith('@lid') ? 'lid' : 'phone-number',
    sender_device: device,
    from_me: key.fromMe === true,
    timestamp,
    received_at: Math.floor(Date.now() / 1000),
    push_name: msg.pushName ?? null,
    text,
    attachment,
    quoted: quotedContext(ctx),
  }
  // The inbox record is published first and its create-exclusive write is the
  // real claim on this id. Marking the message seen before it is safely stashed
  // would turn a failed inbox write into a permanently lost instruction.
  if (!publishOnce(INBOX, `${id}.json`, `${JSON.stringify(record, null, 2)}\n`)) {
    return reject('already stashed', id)
  }
  publishOnce(SEEN, `${id}.seen`, `${timestamp}\n`)
  if (timestamp > getWatermark()) {
    setWatermark(timestamp)
    writeWatermark(timestamp)
  }
  logLine(`stashed ${id} from device ${device}`)
}

function reject(why, detail) {
  logLine(`ignored (${why}) ${detail ?? ''}`.trimEnd())
}

// --------------------------------------------------------------- fixture ---
//
// Drive handleMessage with a synthetic message so every accept/reject rule -
// device, chat kind, sender, forwarding, echo, watermark, text extraction - is
// testable without a live WhatsApp session. Reads one JSON object on stdin:
//   { "stanza_from": "447700900123:0@s.whatsapp.net", "message": <WAMessage> }
// and prints the resulting inbox decision.

async function runFixture() {
  loadSelfIdentityFromCreds()
  ensurePrivateDir(STATE)
  ensurePrivateDir(INBOX)
  ensurePrivateDir(SEEN)
  ensurePrivateDir(SENT)

  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  const fixture = JSON.parse(Buffer.concat(chunks).toString('utf8'))

  let watermark = readWatermark()
  if (watermark === null) {
    watermark = 0
    writeWatermark(watermark)
  }

  const deviceById = new Map()
  const msg = fixture.message
  if (fixture.stanza_from && msg?.key?.id) {
    deviceById.set(msg.key.id, jidDevice(fixture.stanza_from))
  }

  const before = fs.existsSync(path.join(INBOX, `${msg?.key?.id}.json`))
  await handleMessage(msg, deviceById, () => watermark, (ts) => { watermark = ts })
  const after = msg?.key?.id && SAFE_ID.test(msg.key.id)
    ? fs.existsSync(path.join(INBOX, `${msg.key.id}.json`))
    : false
  process.stdout.write(`${(!before && after) ? 'ACCEPTED' : 'REJECTED'} ${msg?.key?.id ?? ''}\n`)
}

// -------------------------------------------------------------------- pair ---

async function runPair(number, rounds) {
  const digits = String(number).replace(/[^0-9]/g, '')
  if (digits.length < 8) {
    process.stderr.write('fm-wa-listen: pair needs the captain number in international form\n')
    process.exit(2)
  }
  if (isRegistered()) {
    process.stderr.write(`fm-wa-listen: ${AUTH_DIR} already holds a linked device; unpair first\n`)
    process.exit(2)
  }
  const { mod, logger } = await loadBaileys()
  const { delay, DisconnectReason } = mod
  let remaining = Number.isInteger(rounds) && rounds > 0 ? rounds : 1

  // A pairing code lives for a couple of minutes. The captain is often away
  // from his phone when the link is set up, so each expiry (408) starts a fresh
  // round with a new code rather than ending the attempt. Every round prints
  // its own PAIRING_CODE line, so whoever is relaying codes always has the
  // current one.
  //
  // Once WhatsApp accepts the code it asks for a reconnect (restartRequired),
  // and baileys has already saved the credentials that reconnect must use. That
  // reconnect therefore keeps the credential folder and requests no new code;
  // only a genuinely fresh round clears the folder.
  let linked = false
  let relinks = 0
  const MAX_RELINKS = 5

  const attempt = async ({ fresh }) => {
    remaining -= 1
    if (fresh) clearAuthDir()
    // A restart reconnect is finishing an accepted link, not starting one.
    let requested = !fresh
    const sock = await makeSocket(mod, logger)
    sock.ev.on('connection.update', async (update) => {
      const { connection, lastDisconnect } = update
      if (connection === 'connecting' && !requested) {
        requested = true
        await delay(5000)
        try {
          const code = await sock.requestPairingCode(digits)
          const shown = code && code.length === 8 ? `${code.slice(0, 4)}-${code.slice(4)}` : code
          process.stdout.write(`PAIRING_CODE ${shown}\n`)
        } catch (err) {
          process.stderr.write(`fm-wa-listen: pairing code request failed: ${err.message}\n`)
          process.exit(5)
        }
      }
      if (connection === 'open') {
        hardenAuthDir()
        writeListenerStatus({ state: 'paired', me: sock.user?.id ?? null, at: Date.now() })
        process.stdout.write(`PAIRED ${sock.user?.id ?? ''}\n`)
        // Let the credential writes flush before exiting.
        await delay(3000)
        process.exit(0)
      }
      if (connection === 'close') {
        const code = lastDisconnect?.error?.output?.statusCode
        try { sock.end(undefined) } catch { /* already gone */ }
        if (code === DisconnectReason?.restartRequired || linked) {
          // The link completed and WhatsApp wants a reconnect to finish it.
          // Reconnect on the credentials baileys just saved; clearing them here
          // would throw away the link and ask for another code forever.
          linked = true
          relinks += 1
          if (relinks > MAX_RELINKS) {
            process.stderr.write('fm-wa-listen: the linked device never settled after pairing\n')
            process.exit(6)
          }
          if (relinks === 1) process.stdout.write('PAIRING_ACCEPTED; reconnecting to finish the link\n')
          remaining += 1
          await delay(2000)
          await attempt({ fresh: false })
          return
        }
        if (remaining > 0) {
          process.stdout.write(`PAIRING_EXPIRED ${code ?? 'unknown'}; requesting a fresh code\n`)
          await delay(2000)
          await attempt({ fresh: true })
          return
        }
        process.stderr.write(`fm-wa-listen: pairing connection closed (${code ?? 'unknown'})\n`)
        process.exit(6)
      }
    })
  }
  await attempt({ fresh: true })
}

// ------------------------------------------------------------------ status ---

function isRegistered() {
  try {
    return JSON.parse(fs.readFileSync(path.join(AUTH_DIR, 'creds.json'), 'utf8'))?.registered === true
  } catch {
    return false
  }
}

function clearAuthDir() {
  let entries = []
  try { entries = fs.readdirSync(AUTH_DIR) } catch { return }
  for (const entry of entries) {
    if (entry.endsWith('.json')) fs.rmSync(path.join(AUTH_DIR, entry), { force: true })
  }
}

// baileys writes its credential files world-readable; the folder is 0700 so
// they are already unreachable, but narrow the files too.
function hardenAuthDir() {
  let entries = []
  try { entries = fs.readdirSync(AUTH_DIR) } catch { return }
  for (const entry of entries) {
    try { fs.chmodSync(path.join(AUTH_DIR, entry), 0o600) } catch { /* best effort */ }
  }
}

function runStatus() {
  const creds = path.join(AUTH_DIR, 'creds.json')
  let me = null
  let registered = false
  try {
    const parsed = JSON.parse(fs.readFileSync(creds, 'utf8'))
    me = parsed?.me?.id ?? null
    registered = parsed?.registered === true
  } catch { /* not paired yet */ }
  process.stdout.write(`${JSON.stringify({ auth_dir: AUTH_DIR, paired: me !== null, registered, me })}\n`)
}

// -------------------------------------------------------------------- main ---

const [command, ...rest] = process.argv.slice(2)
switch (command) {
  case 'listen':
    runListen().catch((err) => {
      process.stderr.write(`fm-wa-listen: ${err.stack ?? err.message}\n`)
      process.exit(1)
    })
    break
  case 'pair':
    runPair(rest[0] ?? CAPTAIN, Number.parseInt(rest[1] ?? '1', 10)).catch((err) => {
      process.stderr.write(`fm-wa-listen: ${err.stack ?? err.message}\n`)
      process.exit(1)
    })
    break
  case 'status':
    runStatus()
    break
  case 'captains':
    process.stdout.write(CAPTAINS.map((n) => `${n}\n`).join(''))
    break
  case 'handle-fixture':
    runFixture().catch((err) => {
      process.stderr.write(`fm-wa-listen: ${err.stack ?? err.message}\n`)
      process.exit(1)
    })
    break
  default:
    process.stderr.write('usage: fm-wa-listen.mjs listen|pair [<e164>] [<rounds>]|status|captains|handle-fixture\n')
    process.exit(2)
}
