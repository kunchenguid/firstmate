import type { Register } from "claude-code";
import {
  formatCalmPreference,
  parseCalmPreference,
  resolveCalmConfigPath,
} from "../src/preference.ts";
import {
  calmHidesSite,
  calmShipElement,
  calmViewportColumns,
  hiddenCalmRow,
} from "../src/presentation.ts";
import {
  initialCalmShipState,
  stepCalmShip,
  type CalmShipState,
} from "../src/working-ship.ts";

const CALM_COMMAND_NAME = "calm";
const CALM_COMMAND_DESCRIPTION = "Toggle Firstmate Calm presentation";

let calmActive = false;
let calmConfigPath: string | undefined;
let calmShip: CalmShipState = initialCalmShipState();

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    calmConfigPath = resolveCalmConfigPath({
      configOverride: await $.env.get("FM_CONFIG_OVERRIDE"),
      home: await $.env.get("FM_HOME"),
      rootOverride: await $.env.get("FM_ROOT_OVERRIDE"),
    });
    calmShip = initialCalmShipState();
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

  on("ui.render", { component: "UserMessage" }, ($, e, next) => {
    if (!calmHidesSite("UserMessage", calmActive, e.props)) return next(e);
    return hiddenCalmRow();
  });

  on("ui.render", { component: "Spinner" }, async ($, e, next) => {
    if (!calmActive) return next(e);
    const width = calmViewportColumns(e.viewport);
    const frame = stepCalmShip(calmShip, width, await $.clock.now());
    calmShip = frame.state;
    return calmShipElement(frame.rows);
  });
};
