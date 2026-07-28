import type { ThemeColor } from "@earendil-works/pi-coding-agent";
import { visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";

export type FooterTheme = {
  fg(color: ThemeColor, text: string): string;
};

export type FooterStatus = {
  key: string;
  value: string;
};

export type FooterData = {
  state: "running" | "idle";
  model: string;
  thinking: string;
  project: string;
  branch: string;
  context: string;
  input: string;
  output: string;
  cost: string;
  statuses: FooterStatus[];
};

const colorize = (theme: FooterTheme, color: ThemeColor, label: string, value: string): string =>
  theme.fg(color, label) + theme.fg("text", value);

const sanitizeSingleLine = (text: string): string =>
  text
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/ +/g, " ")
    .trim();

const pack = (segments: string[], width: number): string[] => {
  const lines: string[] = [];
  const maxWidth = Math.max(1, width);
  let line = "";
  for (const segment of segments) {
    if (footerVisibleWidth(segment) > maxWidth) {
      if (line) lines.push(line);
      const wrapped = wrapTextWithAnsi(segment, maxWidth);
      lines.push(...wrapped.slice(0, -1));
      line = wrapped.at(-1) || "";
    } else if (!line) {
      line = segment;
    } else if (footerVisibleWidth(line) + 2 + footerVisibleWidth(segment) <= maxWidth) {
      line += `  ${segment}`;
    } else {
      lines.push(line);
      line = segment;
    }
  }
  if (line) lines.push(line);
  return lines;
};

export function formatFooterLines(data: FooterData, width: number, theme: FooterTheme): string[] {
  const state = colorize(theme, data.state === "running" ? "success" : "muted", "● ", data.state);
  const model = colorize(theme, "accent", "model ", data.model);
  const thinking = colorize(theme, "accent", "think ", data.thinking);
  const location = colorize(theme, "borderAccent", "dir ", data.project);
  const branch = colorize(theme, "accent", "git ", data.branch || "-");
  const usage = [
    colorize(theme, "warning", "ctx ", data.context),
    colorize(theme, "muted", "↑", data.input),
    colorize(theme, "muted", "↓", data.output),
    colorize(theme, "accent", "$", data.cost),
  ];
  const statuses = data.statuses
    .map(({ key, value }) => ({ key: sanitizeSingleLine(key), value: sanitizeSingleLine(value) }))
    .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : a.value < b.value ? -1 : a.value > b.value ? 1 : 0))
    .map(({ key, value }) => colorize(theme, "muted", `${key}${value ? ": " : ""}`, value));

  return [...pack([state, model, thinking, location, branch], width), ...pack(usage, width), ...pack(statuses, width)];
}

export function footerVisibleWidth(line: string): number {
  return visibleWidth(line);
}
