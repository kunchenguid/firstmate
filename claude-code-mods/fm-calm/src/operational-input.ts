export const FM_OPERATIONAL_PREFIX = "\u2063FIRSTMATE_OP: ";

export type CalmUserMessageProps = {
  text?: unknown;
};

export function isFirstmateOperationalText(text: unknown): boolean {
  return typeof text === "string" && text.startsWith(FM_OPERATIONAL_PREFIX);
}

export function isFirstmateOperationalRow(props: CalmUserMessageProps | undefined): boolean {
  if (props === undefined) return false;
  return isFirstmateOperationalText(props.text);
}