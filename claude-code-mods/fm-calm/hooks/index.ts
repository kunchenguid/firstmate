import type { Register } from "claude-code";
import {
  formatCalmPreference,
  parseCalmPreference,
  resolveCalmConfigPath,
} from "../src/preference.ts";
import { calmHidesSite, hiddenCalmRow } from "../src/presentation.ts";

const CALM_COMMAND_NAME = "calm";
const CALM_COMMAND_DESCRIPTION = "Toggle Firstmate Calm presentation";

let calmActive = false;
let calmConfigPath: string | undefined;

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    calmConfigPath = resolveCalmConfigPath({
      configOverride: await $.env.get("FM_CONFIG_OVERRIDE"),
      home: await $.env.get("FM_HOME"),
      rootOverride: await $.env.get("FM_ROOT_OVERRIDE"),
    });
    calmActive = false;

    if (calmConfigPath !== undefined) {
      try {
        if (await $.fs.exists(calmConfigPath)) {
          calmActive = parseCalmPreference(await $.fs.read(calmConfigPath)) === "on";
        }
      } catch {
        calmActive = false;
      }
    }

    await $.command.register({
      name: CALM_COMMAND_NAME,
      description: CALM_COMMAND_DESCRIPTION,
      immediate: true,
    });

    return next(e);
  });

  on("command.run", { command: CALM_COMMAND_NAME }, async ($) => {
    const nextActive = !calmActive;
    const configPath = calmConfigPath;

    if (configPath !== undefined) {
      try {
        await $.fs.write(configPath, formatCalmPreference(nextActive));
      } catch {
        return {
          text: `Calm stayed ${calmActive ? "on" : "off"}: ${configPath} could not be written.`,
        };
      }
    }

    calmActive = nextActive;
    $.ui.invalidate("ui.render");

    if (configPath === undefined) {
      return {
        text: `Calm ${nextActive ? "on" : "off"} for this session only: set FM_HOME so the choice can persist.`,
      };
    }
    return { text: `Calm ${nextActive ? "on" : "off"}` };
  });

  on("ui.render", { component: "ToolUse" }, ($, e, next) => {
    if (!calmHidesSite("ToolUse", calmActive, e.props)) return next(e);
    return hiddenCalmRow();
  });

  on("ui.render", { component: "ToolResult" }, ($, e, next) => {
    if (!calmHidesSite("ToolResult", calmActive, e.props)) return next(e);
    return hiddenCalmRow();
  });

  on("ui.render", { component: "ToolGroup" }, ($, e, next) => {
    if (!calmHidesSite("ToolGroup", calmActive, e.props)) return next(e);
    return hiddenCalmRow();
  });

  on("ui.render", { component: "UserMessage" }, ($, e, next) => {
    if (!calmHidesSite("UserMessage", calmActive, e.props)) return next(e);
    return hiddenCalmRow();
  });
};
