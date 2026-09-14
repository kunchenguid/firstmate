#!/usr/bin/env python3
"""Inbound WhatsApp media validation, local storage and safe extraction.

Owner of MIME/size/checksum/URL rules for received image, audio and document
and video payloads. Outbound media, stickers, TTS and remote deletion stay out of
scope. Bytes are untrusted content: never executed, never used as authorization.
"""

import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import tempfile
import urllib.parse

from fm_whatsapp_store import BridgeError, token
from fm_whatsapp_process import run_local

ALLOWED_HOSTS = frozenset({"lookaside.fbsbx.com"})
ALLOWED_MIME = {
    "image": frozenset({"image/jpeg", "image/png"}),
    "audio": frozenset({"audio/ogg", "audio/opus", "audio/mpeg", "audio/mp4", "audio/aac", "audio/amr"}),
    "video": frozenset({"video/mp4", "video/3gpp"}),
    "document": frozenset({"application/pdf", "text/plain",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation"}),
}
EXTENSION = {"image/jpeg": ".jpg", "image/png": ".png", "audio/ogg": ".ogg", "audio/opus": ".opus",
             "audio/mpeg": ".mp3", "audio/mp4": ".m4a", "audio/aac": ".aac", "audio/amr": ".amr",
             "application/pdf": ".pdf", "text/plain": ".txt", "video/mp4": ".mp4", "video/3gpp": ".3gp",
             "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
             "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
             "application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx"}
MAGIC = {"image/jpeg": b"\xff\xd8", "image/png": b"\x89PNG\r\n\x1a\n", "application/pdf": b"%PDF",
         "audio/ogg": b"OggS", "audio/opus": b"OggS"}
LIMITS = {"image": 5_000_000, "audio": 16_000_000, "document": 16_000_000, "video": 16_000_000}
MAX_PIXELS = 25_000_000
MAX_CAPTION = 1024
MAX_TRANSCRIPT = 20_000
MAX_EXTRACT = 100_000
MAX_RETAINED_BYTES = 1_000_000_000
PLACEHOLDER = {"image": "Imagem recebida.", "audio": "Áudio recebido.",
               "voice": "Nota de voz recebida.", "video": "Vídeo recebido.", "document": "Documento recebido."}


class MediaError(BridgeError):
    """Safe inbound-media diagnostic; never includes bytes or secrets."""


def check_storage_budget(root):
    # Reserve room for one original, scratch decode and bounded page previews.
    # Never delete retained attachments to make room for a new message.
    total, count = 120_000_000, 0
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            if path.is_symlink():
                raise MediaError("diretório de mídia contém link inseguro")
            count += 1
            if count > 10_000:
                raise MediaError("armazenamento de mídia precisa de revisão local")
        for name in files:
            total += (Path(directory) / name).stat().st_size
            if total > MAX_RETAINED_BYTES:
                raise MediaError("armazenamento de mídia cheio; arquivos anteriores preservados")


def inbound_payload(kind, payload):
    if kind not in ALLOWED_MIME or not isinstance(payload, dict):
        raise MediaError("anexo ausente ou tipo não suportado nesta etapa")
    media_id = payload.get("id")
    mime = normalize_mime(payload.get("mime_type"))
    digest = payload.get("sha256")
    if not isinstance(media_id, str) or not media_id or len(media_id) > 180:
        raise MediaError("identificador de mídia inválido")
    try:
        token(media_id, "media id")
    except BridgeError as error:
        raise MediaError("identificador de mídia inválido") from error
    if not isinstance(mime, str) or mime not in ALLOWED_MIME[kind]:
        raise MediaError("formato não suportado nesta etapa")
    if not isinstance(digest, str) or not digest or len(digest) > 200:
        raise MediaError("checksum de mídia ausente")
    try:
        if len(base64.b64decode(digest, validate=True)) != 32:
            raise ValueError()
    except (ValueError, binascii.Error) as error:
        raise MediaError("checksum de entrada inválido") from error
    caption = payload.get("caption")
    if caption is None:
        caption = ""
    elif not isinstance(caption, str) or len(caption) > MAX_CAPTION or "\x00" in caption:
        raise MediaError("legenda inválida")
    filename = payload.get("filename") if kind == "document" else None
    if filename is not None and (not isinstance(filename, str) or len(filename) > 255 or "\x00" in filename):
        raise MediaError("nome de arquivo inválido")
    voice = payload.get("voice") is True if kind == "audio" else False
    if any(0xD800 <= ord(char) <= 0xDFFF for char in caption + (filename or "")):
        raise MediaError("metadados de texto inválidos")
    return {"id": media_id, "mime": mime, "sha256": digest, "caption": caption.strip(),
            "filename": filename, "voice": voice}


def validate_download_url(url):
    if not isinstance(url, str) or len(url) > 2000:
        raise MediaError("URL de download inválida")
    try:
        parsed = urllib.parse.urlparse(url)
        port = parsed.port
    except ValueError as error:
        raise MediaError("URL de download recusada") from error
    if any(ord(char) < 33 for char in url) or parsed.fragment:
        raise MediaError("URL de download recusada")
    if parsed.scheme != "https" or parsed.username or parsed.password:
        raise MediaError("URL de download recusada")
    if port not in (None, 443):
        raise MediaError("URL de download recusada")
    host = (parsed.hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        raise MediaError("host de download não permitido")
    if ".." in urllib.parse.unquote(parsed.path).split("/"):
        raise MediaError("URL de download recusada")
    return url


def hex_digest(data):
    return hashlib.sha256(data).hexdigest()


def match_checksum(data, b64_digest, hex_digest_value=None):
    digest = hashlib.sha256(data).digest()
    try:
        inbound = base64.b64decode(b64_digest, validate=True)
    except (ValueError, binascii.Error) as error:
        raise MediaError("checksum de entrada inválido") from error
    if inbound != digest:
        raise MediaError("integridade da mídia não confere")
    if hex_digest_value is not None:
        try:
            meta = binascii.unhexlify(hex_digest_value)
        except (ValueError, binascii.Error) as error:
            raise MediaError("checksum dos metadados inválido") from error
        if meta != digest:
            raise MediaError("integridade da mídia não confere")


def image_pixels(data, mime):
    if mime == "image/png":
        if len(data) < 24 or not data.startswith(MAGIC["image/png"]):
            raise MediaError("PNG inválido")
        width, height = struct.unpack(">II", data[16:24])
    elif mime == "image/jpeg":
        if not data.startswith(MAGIC["image/jpeg"]):
            raise MediaError("JPEG inválido")
        width = height = 0
        index = 2
        while index + 9 < len(data):
            if data[index] != 0xFF:
                index += 1
                continue
            marker = data[index + 1]
            if marker in (0xC0, 0xC1, 0xC2):
                height, width = struct.unpack(">HH", data[index + 5:index + 9])
                break
            if marker in (0xD8, 0xD9) or marker == 0xFF:
                index += 1
                continue
            if index + 4 > len(data):
                break
            length = struct.unpack(">H", data[index + 2:index + 4])[0]
            index += 2 + length
        if not width or not height:
            raise MediaError("JPEG inválido")
    else:
        raise MediaError("imagem não suportada")
    if width * height > MAX_PIXELS or width <= 0 or height <= 0:
        raise MediaError("imagem excede o limite de pixels")
    return width, height


def sniff(data, mime):
    magic = MAGIC.get(mime)
    if magic and not data.startswith(magic):
        raise MediaError("conteúdo não corresponde ao tipo declarado")
    if mime == "text/plain":
        if b"\x00" in data:
            raise MediaError("texto com bytes nulos")
        try:
            data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise MediaError("texto não é UTF-8") from error


def sanitize_filename(name, mime):
    default = "anexo" + EXTENSION.get(mime, ".bin")
    if not isinstance(name, str) or not name.strip():
        return default
    base = name.replace("\\", "/").split("/")[-1]
    base = re.sub(r"[^A-Za-z0-9._-]", "_", base)[:180]
    if not base or base in (".", "..") or base.startswith("."):
        return default
    return base


def normalize_mime(value):
    if not isinstance(value, str):
        return None
    # The API stores Opus as audio/ogg; codecs=opus.
    parts = [part.strip().lower() for part in value.split(";")]
    if len(parts) == 1 or (parts[0] == "audio/ogg" and parts[1:] == ["codecs=opus"]):
        return "audio/ogg" if parts[0] == "audio/opus" else parts[0]
    return None


def extract_text(data, mime):
    if mime != "text/plain":
        raise MediaError("este documento exige o decodificador local")
    text = data.decode("utf-8").strip()
    if not text:
        raise MediaError("documento de texto vazio")
    if len(text) > MAX_EXTRACT:
        raise MediaError("documento excede o limite de texto extraído")
    return text


def store_bytes(directory, mime, data):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid() or directory.stat().st_mode & 0o077:
        raise MediaError("diretório de mídia inseguro")
    path = directory / ("payload" + EXTENSION.get(mime, ".bin"))
    if path.is_symlink() or directory.joinpath(".payload.partial").is_symlink():
        raise MediaError("arquivo de mídia inseguro")
    if path.exists():
        if path.read_bytes() == data:
            return path
        raise MediaError("arquivo de mídia já existe; preserve o original")
    tmp = directory / ".payload.partial"
    if tmp.exists():
        tmp.unlink()
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
    os.chmod(path, 0o600)
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    return path


def transcribe(command, path, timeout=30):
    if command is None:
        raise MediaError("transcrição não configurada")
    executable = Path(command)
    if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise MediaError("comando de transcrição inválido")
    info = executable.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise MediaError("comando de transcrição inseguro")
    try:
        output = run_local([str(executable), str(path)], path.parent, timeout=timeout,
                           max_output=MAX_TRANSCRIPT * 4)
        text = output.decode("utf-8").strip()
    except (BridgeError, OSError, UnicodeError) as error:
        raise MediaError("transcrição não concluiu dentro dos limites locais") from error
    if len(text) > MAX_TRANSCRIPT or "\x00" in text:
        raise MediaError("transcrição inválida ou excede o limite")
    return text


def prepare_local(config, path, kind, mime, transcriber=None):
    if kind == "document" and mime == "text/plain":
        return {"extracted_text": extract_text(path.read_bytes(), mime), "frames": [],
                "coverage": "complete UTF-8 text"}
    if kind == "audio" and not (config.stt_model or config.stt_command or transcriber):
        raise MediaError("transcrição não configurada")
    # Only scratch products are removed; original attachments remain private.
    with tempfile.TemporaryDirectory(prefix="decode-", dir=path.parent) as scratch:
        directory = Path(scratch)
        command = [str(config.media_python), str(Path(__file__).with_name("fm_whatsapp_extract.py")),
                   kind, mime, str(path)]
        if config.stt_model:
            command.append(str(config.stt_model))
        try:
            value = json.loads(run_local(command, directory, timeout=180, max_output=500_000))
        except (BridgeError, OSError, ValueError) as error:
            raise MediaError("extração local falhou ou excedeu limites; verifique formato e media-doctor") from error
        if value.get("has_audio"):
            if transcriber:
                value["transcript"] = transcriber(directory / "audio.wav")
            elif config.stt_command:
                value["transcript"] = transcribe(config.stt_command, directory / "audio.wav", timeout=120)
            elif not config.stt_model:
                raise MediaError("transcrição não configurada para o áudio do vídeo")
            transcript = value.get("transcript")
            if not isinstance(transcript, str) or len(transcript) > MAX_TRANSCRIPT or "\x00" in transcript:
                raise MediaError("transcrição inválida ou excede o limite")
            value["transcript"] = transcript.strip()
            if not value["transcript"] and kind == "audio":
                raise MediaError("transcrição vazia; nenhuma fala foi confirmada")
            value["speech_detected"] = bool(value["transcript"])
        value.pop("audio_file", None)
        for frame in value.get("frames", []):
            name = frame.pop("file")
            if not re.fullmatch(r"(image|page-[0-9]+|frame-[0-9]+)\.jpg", name):
                raise MediaError("prévia inválida")
            source = directory / name
            if source.is_symlink() or source.stat().st_size > 5_000_000:
                raise MediaError("prévia excede limite")
            target_dir = path.parent / name.removesuffix(".jpg")
            frame_path = store_bytes(target_dir, "image/jpeg", source.read_bytes())
            frame["path"] = str(frame_path)
        return value


def media_doctor(config):
    with tempfile.TemporaryDirectory(prefix="media-doctor-", dir=config.state) as directory:
        try:
            value = json.loads(run_local([str(config.media_python),
                str(Path(__file__).with_name("fm_whatsapp_extract.py")), "doctor"], Path(directory)))
        except (OSError, BridgeError, ValueError):
            return {"ready": False, "error": "interpretador ou dependências locais indisponíveis"}
    value["stt_model"] = bool(config.stt_model and (config.stt_model / "model.bin").is_file())
    value["stt_command"] = bool(config.stt_command and config.stt_command.is_file())
    value["ready"] = all(value[k] for k in ("Pillow", "pypdfium2", "ffmpeg", "ffprobe")) and (
        value["stt_command"] or (value["stt_model"] and value["faster_whisper"]))
    value["interpretation_proven"] = False
    return value


def display_text(kind, caption, voice):
    if caption:
        return caption
    if kind == "audio" and voice:
        return PLACEHOLDER["voice"]
    return PLACEHOLDER[kind]
