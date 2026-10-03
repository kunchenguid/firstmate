// The shapes the Spyglass mod keeps, and the plugin state the manifest's types contract names.
// A contract must be self-contained, so this file imports nothing; ./fm-spyglass.ts re-exports the shapes.

/** One worker in the fleet, as the /fleet pane lists it. */
export type UnderWay = {
  id: string;
  kind: string;
  state: string;
  project: string;
  pr: string | null;
  target: string | null;
  model: string | null;
  effort: string | null;
};
/** The live tail of one worker's terminal. */
export type Session = { id: string; target: string | null; text: string; at: string; error: string | null };
export type CaptainCall = { id: string; title: string; reason: string };
export type Queued = { id: string; title: string };

export type Fleet = {
  generated: string;
  underWay: UnderWay[];
  calls: CaptainCall[];
  prs: { id: string; url: string }[];
  queued: Queued[];
};

/** This Firstmate checkout against origin's main: how far behind, and local edits an update would collide with. */
export type Update = {
  remote: string;
  behind: number;
  local: string[];
  conflicts: string[];
  checkedAt: string;
  error: string | null;
};

declare module "claude-code" {
  interface PluginState {
    spyglass: {
      fleet: Fleet | null;
      error: string | null;
      session: Session | null;
      update: Update | null;
      // The captain's Update press: queued until the first mate is free, running once its turn starts, done when main caught up.
      request: "queued" | "running" | "done" | null;
      checking: boolean;
    };
  }
}
