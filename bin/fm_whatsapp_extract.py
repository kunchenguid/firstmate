#!/usr/bin/env python3
"""Local-only attachment decoding; invoked by fm_whatsapp_media, not a poller.

Usage: python fm_whatsapp_extract.py KIND MIME PATH [LOCAL_STT_MODEL]
       python fm_whatsapp_extract.py doctor
Output is bounded JSON. Files are written only in the caller's private scratch
directory. Optional dependencies live in requirements-whatsapp-media.txt;
FFmpeg/ffprobe decode only whitelisted native formats over the file protocol.
PDFium never initializes forms or JavaScript. Office XML is read without macros,
external relationships, archive extraction or evaluating formulas.
Owns interpretation limits: 120 seconds, 12 video frames, 20 PDF pages,
1600-pixel previews, 100000 document and 20000 transcript characters.
"""

import importlib.util
import json
import math
import os
from pathlib import Path
import posixpath
import re
import shutil
import sys
import zipfile
import xml.etree.ElementTree as ET

from fm_whatsapp_process import run_local

MAX_SECONDS = 120
MAX_FRAMES = 12
MAX_PAGES = 20
MAX_TEXT = 100_000
OFFICE = {
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "word",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xl",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": "ppt",
}


def preview(image, name):
    from PIL import Image
    if image.mode == "RGBA" or "transparency" in image.info:
        rgba = image.convert("RGBA")
        image = Image.alpha_composite(Image.new("RGBA", rgba.size, "white"), rgba)
    image.thumbnail((1600, 1600))
    image.convert("RGB").save(name, format="JPEG", quality=85)
    return {"file": name, "width": image.width, "height": image.height}


def image_content(path, mime):
    from PIL import Image, ImageOps
    Image.MAX_IMAGE_PIXELS = 25_000_000
    with Image.open(path) as picture:
        if picture.format != {"image/png": "PNG", "image/jpeg": "JPEG"}[mime]:
            raise ValueError("image type mismatch")
        if picture.width * picture.height > 25_000_000 or picture.mode not in ("RGB", "RGBA", "L", "P"):
            raise ValueError("image limits")
        picture.verify()
    with Image.open(path) as picture:
        picture.load()
        frame = preview(ImageOps.exif_transpose(picture), "image.jpg")
    return {"frames": [frame], "coverage": "complete image preview"}


def pdf_content(path):
    import pypdfium2 as pdfium
    import pypdfium2.raw as raw
    frames, texts = [], []
    with pdfium.PdfDocument(path) as document:
        # Includes files that open with an empty password but remain encrypted.
        if raw.FPDF_GetSecurityHandlerRevision(document) != -1:
            raise ValueError("encrypted PDF")
        count = len(document)
        if not 1 <= count <= MAX_PAGES:
            raise ValueError("PDF page limit")
        for number in range(count):
            page = document[number]
            try:
                width, height = page.get_size()
                if not all(math.isfinite(v) and 0 < v < 100_000 for v in (width, height)):
                    raise ValueError("PDF dimensions")
                textpage = page.get_textpage()
                try:
                    if textpage.count_chars() > MAX_TEXT:
                        raise ValueError("PDF text limit")
                    text = textpage.get_text_range().strip()
                finally:
                    textpage.close()
                texts.append(f"[page {number + 1}]\n{text}")
                if sum(map(len, texts)) > MAX_TEXT:
                    raise ValueError("PDF text limit")
                # Preserve visual tables, diagrams and scanned pages as well as text.
                bitmap = page.render(scale=min(2, 1600 / max(width, height)), may_draw_forms=False)
                try:
                    frame = preview(bitmap.to_pil(), f"page-{number + 1}.jpg")
                finally:
                    bitmap.close()
                frame["page"] = number + 1
                frames.append(frame)
            finally:
                page.close()
    return {"extracted_text": "\n\n".join(texts), "frames": frames, "pages": count,
            "coverage": "all pages; previews plus extractable text, no OCR claim"}


def office_content(path, mime):
    root = OFFICE[mime]
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        if len(infos) > 1000 or sum(info.file_size for info in infos) > 20_000_000:
            raise ValueError("Office expansion limit")
        names = {info.filename for info in infos}
        if len(names) != len(infos):
            raise ValueError("duplicate Office members")
        if "[Content_Types].xml" not in names or not any(name.startswith(root + "/") for name in names):
            raise ValueError("Office type mismatch")
        for info in infos:
            if info.flag_bits & 1 or info.file_size > 4_000_000 or "vbaproject" in info.filename.lower():
                raise ValueError("encrypted, oversized or macro Office file")
        def read_xml(name):
            data = archive.read(name)
            # Reject declarations in both ordinary UTF-8 and UTF-16 XML.
            declarations = data.replace(b"\x00", b"").upper()
            if b"<!DOCTYPE" in declarations or b"<!ENTITY" in declarations:
                raise ValueError("Office entities refused")
            return ET.fromstring(data)

        def text_runs(element):
            return "".join((node.text or "") if node.tag.rsplit("}", 1)[-1] == "t"
                           else {"br": "\n", "cr": "\n", "tab": "\t"}.get(node.tag.rsplit("}", 1)[-1], "")
                           for node in element.iter())

        def ordered_parts(index, list_tag, member_kind, folder):
            document = read_xml(f"{root}/{index}.xml")
            relationships = read_xml(f"{root}/_rels/{index}.xml.rels")
            members = document.find("{*}" + list_tag)
            if members is None:
                raise ValueError("Office member order missing")
            targets = {}
            for relationship in relationships:
                rid = relationship.get("Id")
                if not rid or rid in targets:
                    raise ValueError("invalid Office relationship")
                targets[rid] = relationship
            parts = []
            for member in members:
                rid = next((value for key, value in member.attrib.items() if key.endswith("}id")), None)
                relationship = targets.get(rid)
                if (relationship is None or relationship.get("TargetMode", "Internal") != "Internal"
                        or not relationship.get("Type", "").endswith("/" + member_kind)):
                    raise ValueError("invalid Office member relationship")
                target = relationship.get("Target", "")
                name = posixpath.normpath(target.lstrip("/") if target.startswith("/") else root + "/" + target)
                if not name.startswith(f"{root}/{folder}/") or not name.endswith(".xml") or name not in names:
                    raise ValueError("Office member target missing or invalid")
                parts.append((member, name))
            return parts

        shared = []
        if root == "xl" and "xl/sharedStrings.xml" in names:
            shared = [text_runs(item) for item in read_xml("xl/sharedStrings.xml")]
        if root == "ppt":
            parts = [(name, f"slide {position}: {name}") for position, (_, name) in enumerate(
                ordered_parts("presentation", "sldIdLst", "slide", "slides"), 1)]
        elif root == "xl":
            parts = []
            for position, (sheet, name) in enumerate(ordered_parts("workbook", "sheets", "worksheet", "worksheets"), 1):
                title = sheet.get("name")
                if not title:
                    raise ValueError("worksheet name missing")
                parts.append((name, f"sheet {position}: {title} ({name})"))
        else:
            parts = [(name, name) for name in sorted(names) if name == "word/document.xml"
                     or re.fullmatch(r"word/(header|footer)\d+.xml", name)]
        texts = []
        for name, label in parts:
            document = read_xml(name)
            if root == "xl":
                values = []
                for cell in document.iter():
                    if cell.tag.rsplit("}", 1)[-1] != "c":
                        continue
                    if cell.get("t") == "inlineStr":
                        inline = cell.find("{*}is")
                        value = text_runs(inline) if inline is not None else ""
                    else:
                        cached = cell.find("{*}v")
                        value = (cached.text or "") if cached is not None else ""
                    if cell.get("t") == "s":
                        index = int(value)
                        if not 0 <= index < len(shared):
                            raise ValueError("invalid shared string index")
                        value = shared[index]
                    values.append(f"{cell.get('r', '?')}: {value}")
            else:
                values = [text_runs(element) for element in document.iter()
                          if element.tag.rsplit("}", 1)[-1] == "p"]
            texts.append(f"[{label}]\n" + "\n".join(values))
            if sum(map(len, texts)) > MAX_TEXT:
                raise ValueError("Office text limit")
    if not texts:
        raise ValueError("Office has no readable text")
    return {"extracted_text": "\n\n".join(texts), "frames": [],
            "coverage": "Office text and cached cell values only; no macros, formulas, embedded media or layout"}


def probe(path, mime):
    formats = {"video/mp4": "mov", "video/3gpp": "mov", "audio/mp4": "mov",
               "audio/ogg": "ogg", "audio/opus": "ogg", "audio/aac": "aac",
               "audio/mpeg": "mp3", "audio/amr": "amr"}
    decoder = ["-protocol_whitelist", "file", "-format_whitelist", formats[mime],
               "-max_alloc", "64000000", "-probesize", "1000000", "-analyzeduration", "3000000",
               "-threads", "2"]
    output = run_local(["ffprobe", "-v", "error", *decoder, "-show_streams", "-show_format",
                        "-of", "json", str(path)], Path.cwd(), timeout=15, max_output=100_000)
    info = json.loads(output)
    duration = float(info.get("format", {}).get("duration", 0))
    if not math.isfinite(duration) or not 0 < duration <= MAX_SECONDS:
        raise ValueError("media duration limit")
    streams = info.get("streams", [])
    if len(streams) > 2:
        raise ValueError("too many media streams")
    return decoder, duration, streams


def media_content(path, mime, kind, model):
    decoder, duration, streams = probe(path, mime)
    videos = [stream for stream in streams if stream.get("codec_type") == "video"]
    audios = [stream for stream in streams if stream.get("codec_type") == "audio"]
    if len(audios) > 1 or len(videos) != (1 if kind == "video" else 0):
        raise ValueError("media streams mismatch")
    if videos:
        video = videos[0]
        if video.get("codec_name") != "h264" or not 0 < video.get("width", 0) * video.get("height", 0) <= 25_000_000:
            raise ValueError("video codec or size")
    codecs = {"audio/aac": "aac", "audio/mp4": "aac", "audio/mpeg": "mp3",
              "audio/amr": "amr_nb", "audio/ogg": "opus", "audio/opus": "opus",
              "video/mp4": "aac", "video/3gpp": "aac"}
    if audios and (audios[0].get("codec_name") != codecs[mime]
                   or (mime in ("audio/ogg", "audio/opus") and audios[0].get("channels") != 1)):
        raise ValueError("audio codec mismatch")
    if kind == "audio" and not audios:
        raise ValueError("audio stream missing")
    base = ["ffmpeg", "-nostdin", "-v", "error", "-xerror", *decoder, "-i", str(path)]
    result = {"duration_seconds": duration, "has_audio": bool(audios), "frames": []}
    if videos:
        interval = duration / min(MAX_FRAMES, max(1, math.ceil(duration)))
        # Sample uniformly from the beginning; missing between-frame action remains explicit.
        run_local([*base, "-map", "0:v:0", "-an", "-sn", "-dn", "-t", str(MAX_SECONDS),
                   "-vf", f"fps=1/{interval}:start_time=0,scale=1600:1600:force_original_aspect_ratio=decrease",
                   "-frames:v", str(MAX_FRAMES), "-threads", "2", "-q:v", "3", "frame-%02d.jpg"],
                  Path.cwd(), timeout=30)
        from PIL import Image
        for index, file in enumerate(sorted(Path.cwd().glob("frame-*.jpg"))):
            with Image.open(file) as picture:
                picture.verify()
            result["frames"].append({"file": file.name, "timestamp_seconds": round(index * interval, 3)})
        if not result["frames"]:
            raise ValueError("video without decoded frames")
        result["coverage"] = "uniform sampled frames; activity between samples may be missed"
    if audios:
        run_local([*base, "-map", "0:a:0", "-vn", "-sn", "-dn", "-t", str(MAX_SECONDS + 1),
                   "-ac", "1", "-ar", "16000", "-threads", "2", "-c:a", "pcm_s16le", "audio.wav"],
                  Path.cwd(), timeout=20)
        import wave
        with wave.open("audio.wav") as wav:
            if wav.getnframes() > 16000 * MAX_SECONDS:
                raise ValueError("decoded audio duration limit")
        result["audio_file"] = "audio.wav"
        if model:
            from faster_whisper import WhisperModel
            local_model = Path(model)
            if not local_model.is_absolute() or not (local_model / "model.bin").is_file():
                raise ValueError("local STT model missing")
            engine = WhisperModel(str(local_model), device="cpu", compute_type="int8", cpu_threads=2,
                                  num_workers=1, local_files_only=True)
            segments, _ = engine.transcribe("audio.wav", beam_size=3, vad_filter=True,
                                           condition_on_previous_text=False)
            parts = []
            for segment in segments:
                parts.append(segment.text.strip())
                if sum(map(len, parts)) > 20_000:
                    raise ValueError("transcript limit")
            result["transcript"] = " ".join(parts).strip()
    return result


def main():
    if sys.argv[1:] == ["doctor"]:
        return {"Pillow": importlib.util.find_spec("PIL") is not None,
                "pypdfium2": importlib.util.find_spec("pypdfium2") is not None,
                "faster_whisper": importlib.util.find_spec("faster_whisper") is not None,
                "ffmpeg": bool(shutil.which("ffmpeg")), "ffprobe": bool(shutil.which("ffprobe")),
                "network": "offline model loading only"}
    kind, mime, source = sys.argv[1:4]
    path = Path(source)
    if kind == "image":
        return image_content(path, mime)
    if mime == "application/pdf":
        return pdf_content(path)
    if mime in OFFICE:
        return office_content(path, mime)
    if kind in ("video", "audio"):
        return media_content(path, mime, kind, sys.argv[4] if len(sys.argv) > 4 else None)
    raise ValueError("unsupported media")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        print(json.dumps(main(), ensure_ascii=False))
    except Exception:
        # Do not print untrusted library diagnostics or attachment contents.
        print("local media extraction failed", file=sys.stderr)
        sys.exit(1)
