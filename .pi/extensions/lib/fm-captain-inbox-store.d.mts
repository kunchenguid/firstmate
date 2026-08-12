export type CaptainInboxPaths = {
  home: string;
  config: string;
  state: string;
  root: string;
  directory: string;
  lock: string;
  messages: string;
  readState: string;
};

export const CAPTAIN_INBOX_VERSION: number;
export const CAPTAIN_INBOX_DEFAULT_MAX_MESSAGES: number;

export function resolveCaptainInboxPaths(input: {
  home: string;
  state?: string;
  config?: string;
}): CaptainInboxPaths;

export function captainInboxIsEnabled(paths: CaptainInboxPaths): boolean;
export function isPrimaryCaptainInboxSession(paths: CaptainInboxPaths): boolean;

export function captureCaptainResponse(
  paths: CaptainInboxPaths,
  input: {
    harness: "pi" | "pi-signed";
    sessionId: string;
    completedAt: string;
    body: string;
  },
): Promise<{ captured: boolean; reason?: string; id?: string }>;

export function listCaptainInbox(paths: CaptainInboxPaths): Promise<{
  version: number;
  messages: Array<{
    id: string;
    completed_at: string;
    body: string;
    source: { harness: "pi" | "pi-signed"; session_id: string };
    read: boolean;
  }>;
}>;

export function markCaptainInboxMessage(
  paths: CaptainInboxPaths,
  id: string,
  read: boolean,
): Promise<{ version: number; id: string; read: boolean }>;

export function deleteCaptainInboxMessage(
  paths: CaptainInboxPaths,
  id: string,
): Promise<{ version: number; id: string; deleted: true }>;

export function deleteCaptainInboxMessagesByReadState(
  paths: CaptainInboxPaths,
  read: boolean,
): Promise<{ version: number; read: boolean; deleted: number }>;
