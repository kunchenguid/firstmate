// fm-pid-identity.mjs - the Node mirror of the legacy-identity rule that
// bin/fm-pid-identity-lib.sh owns (fm_pid_identity_legacy_matches), for the
// extension host. Pure functions with no side effects, so a test can check
// that both implementations reach the same verdict.

const LSTART_RE = /^\s*[A-Z][a-z]{2} ([A-Z][a-z]{2}) +([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([0-9]{4})([\s\S]*)$/u;
const LSTART_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// The seconds the leading C-locale lstart date of text names when read as
// UTC, and the text after it with blanks flattened and trimmed; null when text
// does not begin with such a date.
export function lstartParts(text) {
  const match = LSTART_RE.exec(text);
  const month = match ? LSTART_MONTHS.indexOf(match[1]) : -1;
  if (month < 0) return null;
  return {
    seconds: Date.UTC(Number(match[6]), month, Number(match[2]), Number(match[3]), Number(match[4]), Number(match[5])) / 1000,
    rest: match[7].replace(/[\t\r\n]/gu, " ").replace(/^ +| +$/gu, ""),
  };
}

// True when recorded is the unkeyed local-time identity a build before the
// UTC pin wrote and names the same process as utcText, the same ps fields
// rendered in UTC: identical text after the date, and dates a whole quarter
// hour apart within the -12:00..+14:00 range of civil zone offsets.
export function legacyIdentityMatches(recorded, utcText) {
  const legacy = lstartParts(recorded);
  const current = lstartParts(utcText);
  if (!legacy || !current || legacy.rest !== current.rest) return false;
  const offset = legacy.seconds - current.seconds;
  return offset % 900 === 0 && offset >= -43200 && offset <= 50400;
}
