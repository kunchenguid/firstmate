// Bridge Pi's interactive clipboard-image path marker into a structured image attachment.
import { lstat, open, readdir, unlink, type FileHandle } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, extname, join, resolve } from "node:path";
import type { Dirent, Stats } from "node:fs";
import {
  resizeImage,
  type ExtensionAPI,
  type InputEvent,
} from "@earendil-works/pi-coding-agent";

type ImageContent = NonNullable<InputEvent["images"]>[number];

const STALE_CLIPBOARD_AGE_MS = 24 * 60 * 60 * 1000;
const CLIPBOARD_BASENAME_SOURCE =
  String.raw`pi-clipboard-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(?:png|jpg|webp|gif)`;
const CLIPBOARD_BASENAME = new RegExp(`^${CLIPBOARD_BASENAME_SOURCE}$`);
const TEMP_DIRECTORY = resolve(tmpdir());

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function clipboardPathPattern(): RegExp {
  const tempPath = escapeRegex(TEMP_DIRECTORY);
  return new RegExp(
    String.raw`(?<![A-Za-z0-9_./\\-])${tempPath}[\\/]${CLIPBOARD_BASENAME_SOURCE}(?![A-Za-z0-9_.\\/-])`,
    "g",
  );
}

function imageMimeType(bytes: Uint8Array): string | null {
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    return "image/png";
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "image/jpeg";
  }
  if (bytes.length >= 6) {
    const header = Buffer.from(bytes.subarray(0, 6)).toString("ascii");
    if (header === "GIF87a" || header === "GIF89a") return "image/gif";
  }
  if (
    bytes.length >= 12 &&
    Buffer.from(bytes.subarray(0, 4)).toString("ascii") === "RIFF" &&
    Buffer.from(bytes.subarray(8, 12)).toString("ascii") === "WEBP"
  ) {
    return "image/webp";
  }
  return null;
}

function extensionMatchesMimeType(filePath: string, mimeType: string): boolean {
  const extension = extname(filePath);
  return (
    (extension === ".png" && mimeType === "image/png") ||
    (extension === ".jpg" && mimeType === "image/jpeg") ||
    (extension === ".gif" && mimeType === "image/gif") ||
    (extension === ".webp" && mimeType === "image/webp")
  );
}

function sameFile(left: Stats, right: Stats): boolean {
  return (
    left.dev === right.dev &&
    left.ino === right.ino &&
    left.size === right.size &&
    left.mtimeMs === right.mtimeMs
  );
}

async function removeIfUnchanged(filePath: string, openedStats: Stats): Promise<void> {
  try {
    const currentStats = await lstat(filePath);
    if (!currentStats.isFile() || !sameFile(openedStats, currentStats)) return;
    await unlink(filePath);
  } catch {
    // The image is still safe to attach if a concurrent cleanup already removed it.
  }
}

async function processClipboardImage(filePath: string): Promise<ImageContent | null> {
  if (!CLIPBOARD_BASENAME.test(basename(filePath))) return null;

  let handle: FileHandle | undefined;
  try {
    const pathStats = await lstat(filePath);
    if (!pathStats.isFile()) return null;
    handle = await open(filePath, "r");
    const openedStats = await handle.stat();
    if (!openedStats.isFile() || !sameFile(pathStats, openedStats)) return null;

    const bytes = await handle.readFile();
    const mimeType = imageMimeType(bytes);
    if (!mimeType || !extensionMatchesMimeType(filePath, mimeType)) return null;

    const processed = await resizeImage(bytes, mimeType);
    if (!processed) return null;

    await handle.close();
    handle = undefined;
    await removeIfUnchanged(filePath, openedStats);
    return {
      type: "image",
      data: processed.data,
      mimeType: processed.mimeType,
    };
  } catch {
    return null;
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

async function cleanStaleClipboardImages(now = Date.now()): Promise<void> {
  let entries: Dirent[];
  try {
    entries = await readdir(TEMP_DIRECTORY, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    if (!CLIPBOARD_BASENAME.test(entry.name) || !entry.isFile()) continue;
    const filePath = join(TEMP_DIRECTORY, entry.name);
    try {
      const stats = await lstat(filePath);
      if (!stats.isFile() || now - stats.mtimeMs < STALE_CLIPBOARD_AGE_MS) continue;
      await removeIfUnchanged(filePath, stats);
    } catch {
      // Cleanup is best effort and never broadens beyond one exact stale basename.
    }
  }
}

export default function (pi: ExtensionAPI): void {
  pi.on("session_start", async () => {
    await cleanStaleClipboardImages();
  });

  pi.on("input", async (event, ctx) => {
    if (event.source !== "interactive") return { action: "continue" };

    const paths = [...event.text.matchAll(clipboardPathPattern())].map((match) => match[0]);
    if (paths.length === 0) return { action: "continue" };

    const consumed = new Set<string>();
    const attached: ImageContent[] = [];
    for (const filePath of new Set(paths)) {
      const image = await processClipboardImage(filePath);
      if (!image) continue;
      consumed.add(filePath);
      attached.push(image);
    }
    if (attached.length === 0) return { action: "continue" };

    if (ctx.hasUI) {
      ctx.ui.notify(
        attached.length === 1 ? "Attached 1 clipboard image." : `Attached ${attached.length} clipboard images.`,
        "info",
      );
    }
    return {
      action: "transform",
      text: event.text.replace(clipboardPathPattern(), (filePath) =>
        consumed.has(filePath) ? "" : filePath,
      ),
      images: [...(event.images ?? []), ...attached],
    };
  });
}
