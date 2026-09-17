export const CALM_OPENCODE_PALETTES = {
  dark: { water: "#93a5ff", boat: "#d77757" },
  light: { water: "#5769f7", boat: "#d77757" },
};

export function calmOpencodePalette(mode) {
  return mode === "light" ? CALM_OPENCODE_PALETTES.light : CALM_OPENCODE_PALETTES.dark;
}

export function calmOpencodeBoatWidth(terminalWidth) {
  const width = Number(terminalWidth);
  if (!Number.isFinite(width) || width <= 0) return 14;
  return Math.max(14, Math.min(56, Math.floor(width * 0.45)));
}

export function calmOpencodeStatusIsWorking(status) {
  const type = status && typeof status === "object" ? status.type : status;
  return type === "busy" || type === "retry";
}

export function createCalmPresentation(sprite) {
  const statuses = new Map();
  let active = false;
  let boundSession = null;
  let lastAnimatedSession = null;
  let shown = null;

  const sync = () => {
    const next =
      active && boundSession && calmOpencodeStatusIsWorking(statuses.get(boundSession))
        ? boundSession
        : null;
    if (next === shown) return shown;
    if (next !== null) {
      if (lastAnimatedSession !== next) {
        sprite.reset();
        lastAnimatedSession = next;
      }
    } else if (shown !== null) {
      sprite.restoreLastRendered();
    }
    shown = next;
    return shown;
  };

  return {
    active: () => active,
    setActive(value) {
      active = Boolean(value);
      return sync();
    },
    bind(sessionID) {
      boundSession = sessionID || null;
      return sync();
    },
    setStatus(sessionID, status) {
      if (!sessionID) return shown;
      statuses.set(sessionID, status);
      return sync();
    },
    sync,
    isShown: () => shown !== null,
    shownSession: () => shown,
    tick() {
      if (shown !== null) sprite.tick();
    },
    frame(width) {
      return shown !== null ? sprite.frame(width) : null;
    },
  };
}
