// Exact interactive s/S shortcut for Firstmate's project-owned Bearings skill.
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const bearingsSkillPath = resolve(root, ".agents/skills/bearings/SKILL.md");

function isBearingsSkillPath(path: string): boolean {
  try {
    return realpathSync(path) === realpathSync(bearingsSkillPath);
  } catch {
    return false;
  }
}

export default function (pi: ExtensionAPI): void {
  pi.on("input", (event, ctx) => {
    if (
      event.source !== "interactive" ||
      !/^[sS]$/.test(event.text.trim()) ||
      (event.images?.length ?? 0) !== 0
    ) {
      return { action: "continue" };
    }

    const bearingsAvailable = pi.getCommands().some((command) =>
      command.name === "skill:bearings" &&
      command.source === "skill" &&
      command.sourceInfo.scope === "project" &&
      isBearingsSkillPath(command.sourceInfo.path)
    );
    if (!bearingsAvailable) {
      ctx.ui.notify("Firstmate Bearings is unavailable in this project.", "error");
      return { action: "handled" };
    }

    return { action: "transform", text: "/skill:bearings captains-call-only" };
  });
}
