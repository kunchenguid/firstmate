import { fileURLToPath } from "node:url";
import {
  calmPreferencePath,
  loadCalmPreference,
  persistCalmPreference,
} from "./lib/fm-calm-preference.js";
import {
  calmOpencodeBoatWidth,
  calmOpencodePalette,
  createCalmPresentation,
} from "./lib/fm-calm-presentation.js";

const pluginFile = fileURLToPath(import.meta.url);
const preferencePath = calmPreferencePath(process.env, pluginFile);

export default {
  id: "fm.calm",
  tui: async (api) => {
    const [{ jsx }, { createSignal }, spriteMod] = await Promise.all([
      import("@opentui/solid/jsx-runtime"),
      import("solid-js"),
      import("./lib/fm-calm-working-ship-sprite.ts"),
    ]);
    const sprite = spriteMod.createCalmWorkingShipSprite();
    const presentation = createCalmPresentation(sprite);
    presentation.setActive(loadCalmPreference(preferencePath));

    const [frameRows, setFrameRows] = createSignal(null);
    let timer = null;

    const boatWidth = () => calmOpencodeBoatWidth(api.renderer?.width);
    const stopTimer = () => {
      if (timer === null) return;
      clearInterval(timer);
      timer = null;
    };
    const startTimer = () => {
      if (timer !== null) return;
      timer = setInterval(() => {
        presentation.tick();
        setFrameRows(presentation.frame(boatWidth()));
      }, spriteMod.CALM_WORKING_SHIP_TICK_MS);
    };
    const publish = () => {
      presentation.sync();
      if (presentation.isShown()) {
        startTimer();
        setFrameRows(presentation.frame(boatWidth()));
        return;
      }
      stopTimer();
      setFrameRows(null);
    };

    const toggle = () => {
      const next = !presentation.active();
      try {
        persistCalmPreference(preferencePath, next);
      } catch {
        api.ui.toast({
          variant: "error",
          message: "Calm preference could not be saved; the current choice is unchanged.",
        });
        return;
      }
      presentation.setActive(next);
      publish();
      api.ui.toast({
        variant: "info",
        message: next ? "Calm on" : "Calm off",
      });
    };

    const boat = jsx("box", {
      flexDirection: "column",
      children: () => {
        const rows = frameRows();
        if (!rows || rows.length === 0) return null;
        const palette = calmOpencodePalette(api.theme?.mode?.());
        return rows.map((row) =>
          jsx("text", {
            wrap: "none",
            children: row.map((run) => {
              const fg = palette[run.color];
              return fg
                ? jsx("span", { style: { fg }, children: run.text })
                : jsx("span", { children: run.text });
            }),
          }),
        );
      },
    });

    api.keymap.registerLayer({
      commands: [
        {
          name: "calm",
          title: "Calm",
          category: "Plugin",
          namespace: "palette",
          slashName: "calm",
          run() {
            toggle();
          },
        },
      ],
    });

    api.slots.register({
      slots: {
        session_prompt_right(_ctx, value) {
          const sessionID = value?.session_id;
          presentation.bind(sessionID);
          const snapshot = sessionID ? api.state?.session?.status?.(sessionID) : undefined;
          if (snapshot) presentation.setStatus(sessionID, snapshot);
          publish();
          return boat;
        },
      },
    });

    const offStatus = api.event.on("session.status", (event) => {
      const properties = event?.properties ?? event;
      const sessionID = properties?.sessionID;
      const status = properties?.status;
      if (!sessionID || !status) return;
      presentation.setStatus(sessionID, status);
      publish();
    });
    const offIdle = api.event.on("session.idle", (event) => {
      const properties = event?.properties ?? event;
      const sessionID = properties?.sessionID;
      if (!sessionID) return;
      presentation.setStatus(sessionID, { type: "idle" });
      publish();
    });

    api.lifecycle.onDispose(() => {
      offStatus();
      offIdle();
      stopTimer();
    });
  },
};
