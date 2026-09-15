const FM_OPERATIONAL_MARK = "⁣";

export const FM_OPERATIONAL_PREFIX = `${FM_OPERATIONAL_MARK}FIRSTMATE_OP: `;
export const FM_FROMFIRST_MARK = `[fm-from-firstmate]${FM_OPERATIONAL_MARK}`;
export const FM_LEGACY_AWAY_PREFIX = `${FM_OPERATIONAL_MARK}Supervisor escalate (`;

const FM_OPERATIONAL_PREFIXES = [FM_OPERATIONAL_PREFIX, FM_FROMFIRST_MARK, FM_LEGACY_AWAY_PREFIX];

export type CalmUserMessageProps = {
  text?: unknown;
};

export function isFirstmateOperationalText(text: unknown): boolean {
  if (typeof text !== "string") return false;
  return FM_OPERATIONAL_PREFIXES.some((prefix) => text.startsWith(prefix));
}

export function isFirstmateOperationalRow(props: CalmUserMessageProps | undefined): boolean {
  if (props === undefined) return false;
  return isFirstmateOperationalText(props.text);
}
