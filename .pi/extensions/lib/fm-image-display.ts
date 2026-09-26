// Inline display of one local bitmap in a Firstmate Pi session.
//
// Pi's TUI owns the terminal image protocol. Its Image component picks Kitty,
// iTerm2, or a text fallback from Pi's own capability detection, so this module
// never writes a graphics escape itself; Herdr relays Pi's Kitty images from a
// pane to a Kitty-capable outer terminal on its own. This module owns only what
// Pi cannot know: which local file to show, whether that file is a safe, bounded,
// ordinary PNG, JPEG, or WebP image, and the PNG display copy Kitty needs
// (Kitty's f=100 transmission accepts PNG only). The file path line is always
// rendered above the image, so a terminal path that silently drops graphics
// still leaves an openable link. .pi/extensions/fm-image.ts owns the /image
// command and fm_show_image tool built on it; docs/inline-images.md owns the
// operator-facing behavior.
//
// Verified against Pi 0.81.1 declarations and the Pi 0.87.1 CLI, which export
// resizeImage() and convertToPng() from the coding-agent package and Image,
// getCapabilities(), getImageDimensions(), imageFallback(), and
// truncateToWidth() from pi-tui.
import { constants } from "node:fs";
import { open, type FileHandle } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { convertToPng, resizeImage, type Theme } from "@earendil-works/pi-coding-agent";
import {
  getCapabilities,
  getImageDimensions,
  Image,
  imageFallback,
  truncateToWidth,
  type Component,
} from "@earendil-works/pi-tui";

export type FmImageMimeType = "image/png" | "image/jpeg" | "image/webp";

/** A bounded PNG copy of the image, sized for the terminal rather than the original. */
export interface FmImageDisplayCopy {
  data: string;
  width: number;
  height: number;
}

/** Everything the transcript needs to show one image again, including after a resume. */
export interface FmImageView {
  path: string;
  mimeType: FmImageMimeType;
  width: number;
  height: number;
  bytes: number;
  display?: FmImageDisplayCopy;
}

export type FmImageLoadResult = { ok: true; image: FmImageView } | { ok: false; error: string };

export interface FmImageLimits {
  maxFileBytes: number;
  maxSide: number;
  maxPixels: number;
  displayMaxSide: number;
  displayMaxBase64Bytes: number;
}

// The file bound admits the largest single image a Pi image-generation tool
// returns; the pixel bounds are checked from the header before any decode, so a
// small file that declares an enormous canvas is refused rather than expanded.
// The display copy only needs Pi's default 60-cell image width, about 1080
// pixels on a high-density screen, and its byte budget bounds both the session
// entry and each terminal transmission.
export const FM_IMAGE_LIMITS: FmImageLimits = {
  maxFileBytes: 32 * 1024 * 1024,
  maxSide: 16384,
  maxPixels: 40_000_000,
  displayMaxSide: 1200,
  displayMaxBase64Bytes: 3 * 1024 * 1024,
};

const MIME_TYPES: readonly FmImageMimeType[] = ["image/png", "image/jpeg", "image/webp"];
const CONTROL_CHARACTER = /[\u0000-\u001f\u007f-\u009f]/;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f-\u009f]/g;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const USAGE = "give the path of a local PNG, JPEG, or WebP file";

/** Replace terminal control characters so untrusted text can never emit an escape. */
export function sanitizeForDisplay(text: string): string {
  return text.replace(CONTROL_CHARACTERS, "?");
}

/**
 * Resolve a user- or model-supplied path against the working directory.
 * One pair of matching surrounding quotes is dropped, `~` expands to the home
 * directory, and file:// URLs resolve to their local path.
 */
export function resolveImagePath(rawPath: string, cwd: string): { ok: true; path: string } | { ok: false; error: string } {
  let text = rawPath.trim();
  if (text.length >= 2 && (text[0] === '"' || text[0] === "'") && text.endsWith(text[0])) {
    text = text.slice(1, -1).trim();
  }
  if (!text) return { ok: false, error: `No image path given; ${USAGE}.` };
  if (CONTROL_CHARACTER.test(text)) {
    return { ok: false, error: "Refusing an image path that contains control characters." };
  }
  if (text.startsWith("file://")) {
    try {
      text = fileURLToPath(text);
    } catch {
      return { ok: false, error: `Refusing a file URL that does not name a local path: ${text}` };
    }
    // Percent-encoding can hide a control character until the URL is decoded.
    if (CONTROL_CHARACTER.test(text)) {
      return { ok: false, error: "Refusing an image path that contains control characters." };
    }
  } else if (text === "~" || text.startsWith("~/")) {
    text = `${homedir()}${text.slice(1)}`;
  }
  return { ok: true, path: resolve(cwd, text) };
}

/** Identify a supported image from its signature bytes, never from its name. */
export function sniffImageMimeType(bytes: Uint8Array): FmImageMimeType | undefined {
  const matches = (offset: number, signature: readonly number[]) =>
    bytes.length >= offset + signature.length && signature.every((value, index) => bytes[offset + index] === value);
  if (matches(0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "image/png";
  if (matches(0, [0xff, 0xd8, 0xff])) return "image/jpeg";
  if (matches(0, [0x52, 0x49, 0x46, 0x46]) && matches(8, [0x57, 0x45, 0x42, 0x50])) return "image/webp";
  return undefined;
}

type ReadResult = { ok: true; bytes: Buffer } | { ok: false; error: string };

// O_NOFOLLOW refuses a symbolic link as the final path component, O_NONBLOCK
// keeps a FIFO from blocking the open, and fstat on the opened descriptor decides
// regular-file and size limits for exactly the object that is then read.
async function readBoundedRegularFile(path: string, maxBytes: number): Promise<ReadResult> {
  const flags = constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0);
  let handle: FileHandle;
  try {
    handle = await open(path, flags);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    switch (code) {
      case "ENOENT":
        return { ok: false, error: `No such file: ${path}` };
      case "ELOOP":
      case "EMLINK":
        return { ok: false, error: `Refusing a symbolic link; give the image file's own path: ${path}` };
      case "EACCES":
      case "EPERM":
        return { ok: false, error: `Permission denied: ${path}` };
      case "EISDIR":
      case "ENOTDIR":
        return { ok: false, error: `Not a regular file: ${path}` };
      default:
        return { ok: false, error: `Could not open ${path} (${code ?? "unknown error"}).` };
    }
  }
  try {
    const info = await handle.stat();
    if (!info.isFile()) return { ok: false, error: `Not a regular file: ${path}` };
    if (info.size === 0) return { ok: false, error: `Empty file: ${path}` };
    if (info.size > maxBytes) {
      return { ok: false, error: `Image file is ${info.size} bytes, above the ${maxBytes}-byte limit: ${path}` };
    }
    const bytes = Buffer.alloc(info.size);
    let offset = 0;
    while (offset < bytes.length) {
      const { bytesRead } = await handle.read(bytes, offset, bytes.length - offset, offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    return { ok: true, bytes: bytes.subarray(0, offset) };
  } finally {
    await handle.close();
  }
}

// Resize first so the PNG conversion decodes a bounded canvas, then step the
// side limit down from the image's own size until the PNG itself fits the
// display budget.
async function prepareDisplayCopy(
  bytes: Buffer,
  mimeType: FmImageMimeType,
  longestSide: number,
  limits: FmImageLimits,
): Promise<FmImageDisplayCopy | undefined> {
  let source = new Uint8Array(bytes);
  let sourceMimeType: string = mimeType;
  const firstSide = Math.min(limits.displayMaxSide, longestSide);
  for (let side = firstSide; side >= Math.min(64, firstSide); side = Math.floor(side * 0.75)) {
    const resized = await resizeImage(source, sourceMimeType, {
      maxWidth: side,
      maxHeight: side,
      maxBytes: limits.displayMaxBase64Bytes,
    });
    if (!resized) return undefined;
    const png = await convertToPng(resized.data, resized.mimeType);
    if (!png) return undefined;
    if (png.data.length <= limits.displayMaxBase64Bytes) {
      const dimensions = getImageDimensions(png.data, "image/png");
      return {
        data: png.data,
        width: dimensions?.widthPx ?? resized.width,
        height: dimensions?.heightPx ?? resized.height,
      };
    }
    // Later steps shrink the already-bounded copy instead of decoding the original again.
    source = new Uint8Array(Buffer.from(resized.data, "base64"));
    sourceMimeType = resized.mimeType;
  }
  return undefined;
}

/**
 * Validate one local image and prepare its bounded display copy.
 * The result is plain data: it is safe to persist in a session and carries no
 * terminal escape sequences. A missing display copy means the image is valid but
 * Pi's image codec could not produce a bounded PNG, so only its path is shown.
 */
export async function loadImageForDisplay(
  rawPath: string,
  cwd: string,
  limits: FmImageLimits = FM_IMAGE_LIMITS,
): Promise<FmImageLoadResult> {
  const resolved = resolveImagePath(rawPath, cwd);
  if (!resolved.ok) return resolved;
  const { path } = resolved;
  const read = await readBoundedRegularFile(path, limits.maxFileBytes);
  if (!read.ok) return read;
  const mimeType = sniffImageMimeType(read.bytes);
  if (!mimeType) return { ok: false, error: `Not a PNG, JPEG, or WebP image: ${path}` };
  const dimensions = getImageDimensions(read.bytes.toString("base64"), mimeType);
  if (!dimensions || dimensions.widthPx < 1 || dimensions.heightPx < 1) {
    return { ok: false, error: `Could not read the image dimensions of ${path}; the file may be damaged.` };
  }
  const { widthPx: width, heightPx: height } = dimensions;
  if (width > limits.maxSide || height > limits.maxSide || width * height > limits.maxPixels) {
    return {
      ok: false,
      error: `Image is ${width}x${height}, above the ${limits.maxSide}-pixel side or ${limits.maxPixels}-pixel area limit: ${path}`,
    };
  }
  let display: FmImageDisplayCopy | undefined;
  try {
    display = await prepareDisplayCopy(read.bytes, mimeType, Math.max(width, height), limits);
  } catch {
    display = undefined;
  }
  return {
    ok: true,
    image: { path, mimeType, width, height, bytes: read.bytes.length, ...(display ? { display } : {}) },
  };
}

const positiveInteger = (value: unknown): value is number =>
  typeof value === "number" && Number.isInteger(value) && value > 0;

/** Re-validate persisted view data, which a session file could have altered. */
export function parseImageView(value: unknown): FmImageView | undefined {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  const { path, mimeType, width, height, bytes, display } = record;
  if (typeof path !== "string" || !path || CONTROL_CHARACTER.test(path)) return undefined;
  if (typeof mimeType !== "string" || !MIME_TYPES.includes(mimeType as FmImageMimeType)) return undefined;
  if (!positiveInteger(width) || !positiveInteger(height) || !positiveInteger(bytes)) return undefined;
  const view: FmImageView = { path, mimeType: mimeType as FmImageMimeType, width, height, bytes };
  if (display !== undefined) {
    if (!display || typeof display !== "object") return undefined;
    const copy = display as Record<string, unknown>;
    if (typeof copy.data !== "string" || !BASE64.test(copy.data)) return undefined;
    if (!positiveInteger(copy.width) || !positiveInteger(copy.height)) return undefined;
    view.display = { data: copy.data, width: copy.width, height: copy.height };
  }
  return view;
}

/** One-line plain-text description of an image, for model-facing results and notices. */
export function describeImage(view: FmImageView): string {
  return `${view.path} (${view.mimeType}, ${view.width}x${view.height})`;
}

/**
 * The path line, then the image itself when Pi can draw it here.
 * Pi's imageFallback() formats the path line, shortening the home directory
 * and linking the file when the terminal supports OSC 8 hyperlinks.
 */
export class FmImageComponent implements Component {
  readonly view: FmImageView;
  private theme: Theme;
  private showImages: boolean;
  private image: Image | undefined;

  constructor(view: FmImageView, theme: Theme, showImages = true) {
    this.view = view;
    this.theme = theme;
    this.showImages = showImages;
  }

  /** Reuse this component for the same image so its Kitty image id stays stable. */
  update(theme: Theme, showImages: boolean): void {
    this.theme = theme;
    this.showImages = showImages;
  }

  invalidate(): void {
    this.image?.invalidate();
  }

  render(width: number): string[] {
    const { view } = this;
    const pathLine = imageFallback(view.mimeType, { widthPx: view.width, heightPx: view.height }, view.path);
    const lines = [truncateToWidth(this.theme.fg("muted", pathLine), Math.max(1, width))];
    if (!view.display || !this.showImages || !getCapabilities().images) return lines;
    this.image ??= new Image(
      view.display.data,
      "image/png",
      { fallbackColor: (text) => this.theme.fg("muted", text) },
      { filename: view.path },
      { widthPx: view.display.width, heightPx: view.display.height },
    );
    return [...lines, ...this.image.render(width)];
  }
}
