#!/usr/bin/env python3
"""Render named SVG layers into a compact, GitHub-safe animated GIF."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

try:
    from PIL import Image, ImageChops
except ImportError as exc:  # pragma: no cover - dependency error path
    raise SystemExit("Pillow is required: python3 -m pip install Pillow") from exc


SVG_NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG_NS)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Animate named SVG layers from a JSON motion spec and encode a GIF."
    )
    parser.add_argument("input_svg", type=Path)
    parser.add_argument("output_gif", type=Path)
    parser.add_argument("--spec", required=True, type=Path, help="JSON motion spec")
    parser.add_argument(
        "--keep-frames",
        type=Path,
        help="Keep rendered layers and PNG frames in this new or empty directory",
    )
    return parser.parse_args()


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def load_spec(path: Path) -> dict:
    try:
        spec = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"motion spec not found: {path}")
    except json.JSONDecodeError as exc:
        fail(f"invalid motion spec JSON: {exc}")

    defaults = {
        "width": 1200,
        "fps": 30,
        "duration": 5.0,
        "colors": 192,
        "dither": "none",
        "transparent_color": "#ff00ff",
        "alpha_threshold": 128,
        "clip_to_base_alpha": False,
        "max_size_mb": 2.0,
        "reveals": [],
        "layers": [],
    }
    defaults.update(spec)
    return defaults


def validate_spec(spec: dict) -> None:
    if not 1 <= int(spec["fps"]) <= 60:
        fail("fps must be between 1 and 60")
    if float(spec["duration"]) <= 0:
        fail("duration must be positive")
    if int(spec["width"]) <= 0:
        fail("width must be positive")
    if not 2 <= int(spec["colors"]) <= 256:
        fail("colors must be between 2 and 256")
    if not 0 <= int(spec["alpha_threshold"]) <= 255:
        fail("alpha_threshold must be between 0 and 255")
    parse_hex_color(spec["transparent_color"])
    if not isinstance(spec["clip_to_base_alpha"], bool):
        fail("clip_to_base_alpha must be true or false")
    allowed_dither = {
        "none",
        "bayer",
        "heckbert",
        "floyd_steinberg",
        "sierra2",
        "sierra2_4a",
    }
    if spec["dither"] not in allowed_dither:
        fail(f"unsupported dither mode: {spec['dither']}")

    ids: list[str] = []
    for item in [*spec["reveals"], *spec["layers"]]:
        element_id = item.get("id")
        if not element_id:
            fail("every reveal and layer needs a non-empty id")
        ids.append(element_id)
    if len(ids) != len(set(ids)):
        fail("motion element ids must be unique")


def command_path(name: str) -> str:
    path = shutil.which(name)
    if not path:
        fail(f"required command not found: {name}")
    return path


def parse_hex_color(value: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", value):
        fail("transparent_color must use #RRGGBB format")
    return tuple(int(value[index : index + 2], 16) for index in (1, 3, 5))


def choose_renderer() -> tuple[str, str]:
    if shutil.which("rsvg-convert"):
        return "rsvg-convert", command_path("rsvg-convert")
    if shutil.which("sips"):
        return "sips", command_path("sips")
    fail("install rsvg-convert, or run on macOS with sips available")


def write_svg(root: ET.Element, path: Path) -> None:
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


def find_path(root: ET.Element, element_id: str) -> list[ET.Element] | None:
    if root.attrib.get("id") == element_id:
        return [root]
    for child in root:
        path = find_path(child, element_id)
        if path:
            return [root, *path]
    return None


def remove_ids(root: ET.Element, element_ids: set[str]) -> None:
    for parent in root.iter():
        for child in list(parent):
            if child.attrib.get("id") in element_ids:
                parent.remove(child)


def extracted_layer(root: ET.Element, element_id: str) -> ET.Element:
    path = find_path(root, element_id)
    if not path:
        fail(f"SVG element id not found: {element_id}")

    layer_root = ET.Element(root.tag, dict(root.attrib))
    for child in root:
        if child.tag.rsplit("}", 1)[-1] == "defs":
            layer_root.append(copy.deepcopy(child))

    destination = layer_root
    for node in path[1:-1]:
        shell = ET.Element(node.tag, dict(node.attrib))
        destination.append(shell)
        destination = shell
    destination.append(copy.deepcopy(path[-1]))
    return layer_root


def render_svg(
    renderer: tuple[str, str], svg_path: Path, png_path: Path
) -> None:
    name, executable = renderer
    if name == "rsvg-convert":
        command = [executable, str(svg_path), "-o", str(png_path)]
    else:
        command = [
            executable,
            "-s",
            "format",
            "png",
            str(svg_path),
            "--out",
            str(png_path),
        ]
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)


def ease_out_cubic(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return 1 - (1 - value) ** 3


def smoothstep(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * (3 - 2 * value)


def progress(value: float, start: float, end: float) -> float:
    if end <= start:
        fail(f"motion end must be greater than start: {start} -> {end}")
    if value <= start:
        return 0.0
    if value >= end:
        return 1.0
    return (value - start) / (end - start)


def opacity_layer(image: Image.Image, opacity: float) -> Image.Image:
    if opacity >= 0.999:
        return image
    result = image.copy()
    result.putalpha(result.getchannel("A").point(lambda value: round(value * opacity)))
    return result


def motion_progress(time: float, block: dict, easing: str) -> float:
    value = progress(time, float(block["start"]), float(block["end"]))
    return ease_out_cubic(value) if easing == "enter" else smoothstep(value)


def flatten_to_chroma(
    image: Image.Image, key: tuple[int, int, int], alpha_threshold: int
) -> Image.Image:
    """Flatten RGBA onto a reserved key color for compact GIF delta encoding."""
    mask = image.getchannel("A").point(
        lambda alpha: 255 if alpha >= alpha_threshold else 0
    )
    flattened = Image.new("RGB", image.size, key)
    flattened.paste(image.convert("RGB"), mask=mask)
    return flattened


def uses_visible_color(
    image: Image.Image,
    color: tuple[int, int, int],
    alpha_threshold: int,
) -> bool:
    red, green, blue, alpha = image.split()

    def matching(channel: Image.Image, value: int) -> Image.Image:
        return channel.point(lambda pixel: 255 if pixel == value else 0)

    match = ImageChops.multiply(matching(red, color[0]), matching(green, color[1]))
    match = ImageChops.multiply(match, matching(blue, color[2]))
    visible = alpha.point(lambda value: 255 if value >= alpha_threshold else 0)
    return ImageChops.multiply(match, visible).getbbox() is not None


def build_frames(
    root: ET.Element,
    spec: dict,
    renderer: tuple[str, str],
    workspace: Path,
) -> tuple[Path, int, int, int, bool]:
    moving_ids = {
        item["id"] for item in [*spec["reveals"], *spec["layers"]]
    }

    base_root = copy.deepcopy(root)
    remove_ids(base_root, moving_ids)
    base_svg = workspace / "base.svg"
    base_png = workspace / "base.png"
    write_svg(base_root, base_svg)
    render_svg(renderer, base_svg, base_png)

    rendered: dict[str, Image.Image] = {}
    for element_id in moving_ids:
        svg_path = workspace / f"layer-{element_id}.svg"
        png_path = workspace / f"layer-{element_id}.png"
        write_svg(extracted_layer(root, element_id), svg_path)
        render_svg(renderer, svg_path, png_path)
        rendered[element_id] = Image.open(png_path).convert("RGBA")

    base_source = Image.open(base_png).convert("RGBA")
    source_width, source_height = base_source.size
    output_width = int(spec["width"])
    output_height = round(source_height * output_width / source_width)
    scale = output_width / source_width
    size = (output_width, output_height)

    base = base_source.resize(size, Image.Resampling.LANCZOS)
    rendered = {
        key: image.resize(size, Image.Resampling.LANCZOS)
        for key, image in rendered.items()
    }

    fps = int(spec["fps"])
    frame_count = round(float(spec["duration"]) * fps)
    frames_dir = workspace / "frames"
    frames_dir.mkdir()
    transparent_color = parse_hex_color(spec["transparent_color"])
    alpha_threshold = int(spec["alpha_threshold"])
    for label, image in [("base", base), *sorted(rendered.items())]:
        if uses_visible_color(image, transparent_color, alpha_threshold):
            fail(
                f"{label} visibly uses transparent_color "
                f"{spec['transparent_color']}; choose an unused key color"
            )
    alpha_signature: bytes | None = None
    has_transparency = False

    for frame in range(frame_count):
        time = frame / fps
        canvas = base.copy()

        for reveal in spec["reveals"]:
            state = ease_out_cubic(
                progress(time, float(reveal["start"]), float(reveal["end"]))
            )
            exit_state = 0.0
            if reveal.get("exit"):
                exit_state = motion_progress(time, reveal["exit"], "exit")
            if state <= 0 or exit_state >= 1:
                continue

            layer = rendered[reveal["id"]]
            bbox = layer.getbbox()
            if not bbox:
                fail(f"rendered reveal is empty: {reveal['id']}")
            axis = reveal.get("axis", "x")
            if axis == "x":
                edge = round(bbox[0] + (bbox[2] - bbox[0]) * state)
                visible = layer.crop((0, 0, edge, output_height))
            elif axis == "y":
                edge = round(bbox[1] + (bbox[3] - bbox[1]) * state)
                visible = layer.crop((0, 0, output_width, edge))
            else:
                fail(f"unsupported reveal axis: {axis}")
            visible = opacity_layer(visible, 1 - exit_state)
            canvas.alpha_composite(visible, (0, 0))

        for item in spec["layers"]:
            entered = motion_progress(time, item["enter"], "enter")
            exit_state = motion_progress(time, item["exit"], "exit")
            opacity = entered * (1 - exit_state)
            if opacity <= 0:
                continue

            start_x, start_y = item["enter"].get("from", [0, 0])
            end_x, end_y = item["exit"].get("to", [0, 0])
            dx = start_x * scale * (1 - entered) + end_x * scale * exit_state
            dy = start_y * scale * (1 - entered) + end_y * scale * exit_state
            layer = opacity_layer(rendered[item["id"]], opacity)
            canvas.alpha_composite(layer, (round(dx), round(dy)))

        if spec["clip_to_base_alpha"]:
            canvas.putalpha(base.getchannel("A"))

        alpha_mask = canvas.getchannel("A").point(
            lambda alpha: 255 if alpha >= alpha_threshold else 0
        )
        signature = hashlib.sha256(alpha_mask.tobytes()).digest()
        if alpha_signature is None:
            alpha_signature = signature
        elif signature != alpha_signature:
            fail(
                "GIF transparency silhouette changes across frames; place motion "
                "inside a stable background or enable clip_to_base_alpha"
            )
        has_transparency |= alpha_mask.getextrema()[0] == 0

        frame_image = flatten_to_chroma(
            canvas, transparent_color, alpha_threshold
        )
        frame_image.save(frames_dir / f"frame-{frame:04d}.png")

    return frames_dir, frame_count, output_width, output_height, has_transparency


def mark_key_color_transparent(
    output: Path,
    key: tuple[int, int, int],
    expected_frames: int,
) -> None:
    """Mark the reserved palette entry transparent in every GIF frame."""
    with Image.open(output) as image:
        palette = image.getpalette()
        if image.mode != "P" or not palette:
            fail("encoded GIF does not contain an indexed global palette")
        key_indices = [
            index
            for index in range(len(palette) // 3)
            if tuple(palette[index * 3 : index * 3 + 3]) == key
        ]
        if not key_indices:
            fail("transparent key color was not preserved in the GIF palette")
        key_index = key_indices[0]
        key_mask = image.point(
            [255 if index == key_index else 0 for index in range(256)],
            mode="L",
        )
        bounds = key_mask.getbbox()
        if not bounds:
            fail("transparent key color is not used by the first GIF frame")
        probe: tuple[int, int] | None = None
        for y in range(bounds[1], bounds[3]):
            for x in range(bounds[0], bounds[2]):
                if image.getpixel((x, y)) == key_index:
                    probe = (x, y)
                    break
            if probe:
                break
        if probe is None:
            fail("could not locate a transparent GIF pixel")

    data = bytearray(output.read_bytes())
    positions, image_count = gif_control_blocks(data)
    if image_count != expected_frames or len(positions) != expected_frames:
        fail(
            "could not identify every GIF frame control block: "
            f"expected {expected_frames}, found {image_count} images and "
            f"{len(positions)} controls"
        )

    for position in positions:
        data[position + 3] |= 0x01
        data[position + 6] = key_index
    output.write_bytes(data)

    with Image.open(output) as image:
        if image.info.get("transparency") != key_index:
            fail("GIF transparency metadata could not be verified")
        checkpoints = {0, expected_frames // 2, expected_frames - 1}
        for frame in sorted(checkpoints):
            image.seek(frame)
            if image.convert("RGBA").getpixel(probe)[3] != 0:
                fail(f"GIF transparency is missing at frame {frame}")


def gif_control_blocks(data: bytearray) -> tuple[list[int], int]:
    """Parse a GIF stream and return real GCE offsets, ignoring image data bytes."""
    if data[:6] not in (b"GIF87a", b"GIF89a") or len(data) < 13:
        fail("encoded output is not a valid GIF stream")

    packed = data[10]
    cursor = 13
    if packed & 0x80:
        cursor += 3 * (2 ** ((packed & 0x07) + 1))

    controls: list[int] = []
    image_count = 0

    def skip_sub_blocks(position: int) -> int:
        while True:
            if position >= len(data):
                fail("truncated GIF sub-block")
            size = data[position]
            position += 1
            if size == 0:
                return position
            position += size
            if position > len(data):
                fail("truncated GIF sub-block payload")

    while cursor < len(data):
        marker = data[cursor]
        if marker == 0x3B:
            return controls, image_count
        if marker == 0x21:
            if cursor + 2 >= len(data):
                fail("truncated GIF extension")
            if data[cursor + 1] == 0xF9:
                if data[cursor + 2] != 0x04 or cursor + 7 >= len(data):
                    fail("invalid GIF graphics control extension")
                controls.append(cursor)
            cursor = skip_sub_blocks(cursor + 2)
            continue
        if marker == 0x2C:
            if cursor + 9 >= len(data):
                fail("truncated GIF image descriptor")
            image_count += 1
            image_packed = data[cursor + 9]
            cursor += 10
            if image_packed & 0x80:
                cursor += 3 * (2 ** ((image_packed & 0x07) + 1))
            if cursor >= len(data):
                fail("truncated GIF image data")
            cursor = skip_sub_blocks(cursor + 1)
            continue
        fail(f"unexpected GIF block marker: 0x{marker:02x}")

    fail("GIF trailer not found")


def encode_gif(
    frames_dir: Path,
    output: Path,
    spec: dict,
    ffmpeg: str,
    frame_count: int,
    has_transparency: bool,
) -> None:
    palette = frames_dir.parent / "palette.png"
    fps = int(spec["fps"])
    input_pattern = frames_dir / "frame-%04d.png"
    subprocess.run(
        [
            ffmpeg,
            "-y",
            "-framerate",
            str(fps),
            "-i",
            str(input_pattern),
            "-vf",
            f"palettegen=stats_mode=diff:max_colors={int(spec['colors'])}:reserve_transparent=0",
            str(palette),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [
            ffmpeg,
            "-y",
            "-framerate",
            str(fps),
            "-i",
            str(input_pattern),
            "-i",
            str(palette),
            "-lavfi",
            f"paletteuse=dither={spec['dither']}:diff_mode=rectangle",
            "-gifflags",
            "+offsetting-transdiff",
            "-loop",
            "0",
            str(output),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if has_transparency:
        mark_key_color_transparent(
            output,
            parse_hex_color(spec["transparent_color"]),
            frame_count,
        )


def run(args: argparse.Namespace) -> None:
    input_svg = args.input_svg.expanduser().resolve()
    output_gif = args.output_gif.expanduser().resolve()
    spec_path = args.spec.expanduser().resolve()
    if not input_svg.is_file():
        fail(f"input SVG not found: {input_svg}")

    spec = load_spec(spec_path)
    validate_spec(spec)
    ffmpeg = command_path("ffmpeg")
    renderer = choose_renderer()

    try:
        root = ET.parse(input_svg).getroot()
    except ET.ParseError as exc:
        fail(f"invalid SVG XML: {exc}")

    if args.keep_frames:
        workspace = args.keep_frames.expanduser().resolve()
        if workspace.exists() and any(workspace.iterdir()):
            fail(f"keep-frames directory must be empty: {workspace}")
        workspace.mkdir(parents=True, exist_ok=True)
        temporary = None
    else:
        temporary = tempfile.TemporaryDirectory(prefix="readme-motion-")
        workspace = Path(temporary.name)

    try:
        frames_dir, frame_count, width, height, has_transparency = build_frames(
            root, spec, renderer, workspace
        )
        output_gif.parent.mkdir(parents=True, exist_ok=True)
        encode_gif(
            frames_dir,
            output_gif,
            spec,
            ffmpeg,
            frame_count,
            has_transparency,
        )
    finally:
        if temporary:
            temporary.cleanup()

    size_mb = output_gif.stat().st_size / (1024 * 1024)
    print(f"GIF: {output_gif}")
    print(
        f"Output: {width}x{height}, {frame_count} frames, "
        f"{spec['fps']} FPS, {float(spec['duration']):.2f}s, {size_mb:.2f} MB"
    )
    if size_mb > float(spec["max_size_mb"]):
        print(
            f"WARNING: exceeds preferred {spec['max_size_mb']} MB budget",
            file=sys.stderr,
        )


if __name__ == "__main__":
    run(parse_args())
