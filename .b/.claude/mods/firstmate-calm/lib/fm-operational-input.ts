// A faithful port of bin/fm-operational-input.sh's `classify` command.
//
// bin/fm-operational-input.sh is the single owner of the Firstmate operational-input
// protocol; this module mirrors only its classification so the Claude Code mod can
// recognize operational user rows inside a render hook, where no host process may be
// spawned per row. tests/fm-calm-claude-mod.test.sh deterministically runs both over
// the full envelope and near-miss contract and is this port's drift guard, so a change
// to the canonical shell owner must land here in the same change. Never widen this
// beyond what the owner recognizes.
//
// Current generic wire form:
//   U+2063 FIRSTMATE_OP: v1 <kind>: <body>
// plus the established `[fm-from-firstmate]` U+2063 routing carrier, and the narrow
// pre-protocol shapes the owner keeps only for persisted transcripts.
//
// It also mirrors the owner's record-backed doorbell parse and record classification
// (`fm_operational_doorbell_path`, `fm_operational_record_kind`), which the `doorbell-kind`
// command composes: a harness that strips U+2063 from submitted prompts receives a plain
// ASCII doorbell naming a record that holds the envelope. The file read stays with the
// caller, so this module remains pure.

const OPERATIONAL_MARK = "\u2063";
const OPERATIONAL_PREFIX = `${OPERATIONAL_MARK}FIRSTMATE_OP: `;
const OPERATIONAL_VERSION = "v1";
const OPERATIONAL_HEADER_PREFIX = `${OPERATIONAL_PREFIX}${OPERATIONAL_VERSION} `;

/** The kinds the owner's `FM_OPERATIONAL_KINDS` names, in its order. */
export const FIRSTMATE_OPERATIONAL_GENERIC_KINDS = [
  "session-start",
  "watcher",
  "turn-end-guard",
  "away-supervisor",
  "launch-brief",
  "branch-outcome",
] as const;

const FROMFIRST_LABEL = "[fm-from-firstmate]";
const FROMFIRST_MARK = `${FROMFIRST_LABEL}${OPERATIONAL_MARK}`;

// Historical payload literals, isolated exactly as the owner isolates them: they exist
// only for persisted pre-protocol transcripts.
const LEGACY_SESSIONSTART =
  "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.";
const LEGACY_WATCHER_PREFIX = "FIRSTMATE WATCHER WAKE: ";
const LEGACY_WATCHER_SUFFIX =
  "\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.";
const LEGACY_TURNEND_PREFIX =
  "TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n";
const LEGACY_AWAY_PREFIX = `${OPERATIONAL_MARK}Supervisor escalate (`;

function isCurrentKind(kind: string): boolean {
  return (FIRSTMATE_OPERATIONAL_GENERIC_KINDS as readonly string[]).includes(kind);
}

/** `fm_operational_generic_kind`: the kind of a current generic envelope, else undefined. */
function genericKind(message: string): string | undefined {
  if (!message.startsWith(OPERATIONAL_HEADER_PREFIX)) return undefined;
  const remainder = message.slice(OPERATIONAL_HEADER_PREFIX.length);
  const separator = remainder.indexOf(": ");
  if (separator < 0) return undefined;
  const kind = remainder.slice(0, separator);
  if (!isCurrentKind(kind)) return undefined;
  const body = remainder.slice(separator + 2);
  return body === "" ? undefined : kind;
}

/** `fm_operational_input_kind`: a current input's kind, generic or from-firstmate. */
export function firstmateOperationalInputKind(message: string): string | undefined {
  const generic = genericKind(message);
  if (generic !== undefined) return generic;
  if (message.startsWith(FROMFIRST_MARK) && message.length > FROMFIRST_MARK.length) {
    return "from-firstmate";
  }
  return undefined;
}

/** `fm_legacy_operational_input_kind`: the narrow pre-protocol shapes, in the owner's order. */
export function firstmateLegacyOperationalInputKind(message: string): string | undefined {
  // PR 899 landed an untyped FIRSTMATE_OP prefix whose subtype cannot be recovered
  // without body prose, so it is explicitly generic.
  if (message.startsWith(OPERATIONAL_PREFIX) && message.length > OPERATIONAL_PREFIX.length) {
    return "legacy-operational";
  }
  if (message === LEGACY_SESSIONSTART) return "session-start";
  if (message.startsWith(LEGACY_AWAY_PREFIX)) return "away-supervisor";
  if (
    message.startsWith(LEGACY_WATCHER_PREFIX) &&
    message.endsWith(LEGACY_WATCHER_SUFFIX) &&
    message.length > LEGACY_WATCHER_PREFIX.length + LEGACY_WATCHER_SUFFIX.length
  ) {
    return "watcher";
  }
  if (message.startsWith(LEGACY_TURNEND_PREFIX) && message.length > LEGACY_TURNEND_PREFIX.length) {
    return "turn-end-guard";
  }
  return undefined;
}

/** `fm_operational_input_classify`: current kinds first, then the legacy shapes. */
export function classifyFirstmateOperationalText(message: string): string | undefined {
  return firstmateOperationalInputKind(message) ?? firstmateLegacyOperationalInputKind(message);
}

const RECORD_DIRNAME = "operational-inbox";
const DOORBELL_PREFIX = ": Firstmate operational input waiting: read '";
const DOORBELL_SUFFIX = "' and handle its contents as Firstmate operational input.";

/** `fm_operational_doorbell_path`: the record path a well-formed doorbell names. */
export function firstmateOperationalDoorbellPath(message: string): string | undefined {
  if (
    message.length < DOORBELL_PREFIX.length + DOORBELL_SUFFIX.length ||
    !message.startsWith(DOORBELL_PREFIX) ||
    !message.endsWith(DOORBELL_SUFFIX)
  ) {
    return undefined;
  }
  const path = message.slice(DOORBELL_PREFIX.length, message.length - DOORBELL_SUFFIX.length);
  if (!path.startsWith("/") || path.includes("'") || !/^[\x20-\x7e]*$/.test(path)) return undefined;
  const cut = path.lastIndexOf("/");
  const directory = path.slice(0, cut);
  if (directory.slice(directory.lastIndexOf("/") + 1) !== RECORD_DIRNAME) return undefined;
  const name = path.slice(cut + 1);
  if (!name.endsWith(".msg") || !/^[0-9a-z-]+$/.test(name.slice(0, -".msg".length))) return undefined;
  return path;
}

/** `fm_operational_record_kind` over a record's content: its current generic kind. */
export function firstmateOperationalRecordKind(content: string): string | undefined {
  return genericKind(content);
}
