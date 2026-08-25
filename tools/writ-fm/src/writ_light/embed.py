"""Embeddings: paraphrase-multilingual-MiniLM-L12-v2 als ONNX.

Mean-Pooling ueber die Token-Embeddings mit Attention-Maske, danach
L2-Normalisierung — das ist die Pooling-Konfiguration des Modells
(1_Pooling/config.json: pooling_mode_mean_tokens). Cosine-Aehnlichkeit
entspricht damit dem Skalarprodukt.

Das Modell wird trage geladen: `writ-light query` bezahlt den Ladevorgang
nur, wenn wirklich eingebettet wird.
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np

from . import paths

DIM = 384
MAX_LEN = 256

# Reihenfolge = Praeferenz. Die quantisierte AVX2-Variante entspricht mit
# ~118 MB der Groessenangabe der Spezifikation; fp32 ist der Rueckfall.
MODEL_CANDIDATES = ("model_quint8_avx2.onnx", "model.onnx")


def model_file() -> Path:
    """Pfad zum ONNX-Modell. WRIT_MODEL erzwingt eine bestimmte Datei."""
    forced = os.environ.get("WRIT_MODEL")
    if forced:
        return Path(forced).expanduser()
    d = paths.model_dir()
    for name in MODEL_CANDIDATES:
        if (d / name).exists():
            return d / name
    return d / MODEL_CANDIDATES[0]


def tokenizer_file() -> Path:
    return paths.model_dir() / "tokenizer.json"


class Embedder:
    def __init__(self) -> None:
        self._session = None
        self._tokenizer = None
        self._input_names: tuple[str, ...] = ()

    def _load(self) -> None:
        if self._session is not None:
            return
        import onnxruntime as ort
        from tokenizers import Tokenizer

        mf, tf = model_file(), tokenizer_file()
        if not mf.exists() or not tf.exists():
            raise FileNotFoundError(
                f"Embedding-Modell fehlt ({mf} / {tf}). "
                "`writ-light modell-laden` holt es nach."
            )
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = max(1, (os.cpu_count() or 2) - 1)
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        self._session = ort.InferenceSession(
            str(mf), sess_options=opts, providers=["CPUExecutionProvider"]
        )
        self._input_names = tuple(i.name for i in self._session.get_inputs())
        self._tokenizer = tokenizer()

    def encode(self, texts: list[str]) -> np.ndarray:
        """Gibt (n, 384) float32 zurueck, zeilenweise L2-normalisiert.

        Bewusst ohne Padding, ein Text pro Durchlauf: das quantisierte Modell
        ist nicht padding-invariant (gemessen: cos 0.9868 zwischen Einzel- und
        Batch-Lauf, fp32 dagegen exakt 1.0). Ohne Padding rechnen Ingest und
        Query auf identischer Grundlage. Kosten: ~9 ms je Regel, bei einigen
        hundert Regeln bleibt der Neuaufbau weit unter den 30 s der Spec.
        """
        if not texts:
            return np.zeros((0, DIM), dtype=np.float32)
        self._load()
        return np.vstack([self._encode_single(t) for t in texts])

    def _encode_single(self, text: str) -> np.ndarray:
        enc = self._tokenizer.encode(text)
        roh_ids, roh_mask = enc.ids, enc.attention_mask
        if len(roh_ids) > MAX_LEN:
            # Selbst kuerzen statt ueber den Tokenizer: der ist geteilt und
            # muss fuer count_tokens ungekuerzt bleiben. Das schliessende
            # Sondertoken bleibt erhalten.
            roh_ids = roh_ids[:MAX_LEN - 1] + [roh_ids[-1]]
            roh_mask = roh_mask[:MAX_LEN - 1] + [roh_mask[-1]]
        ids = np.array([roh_ids], dtype=np.int64)
        mask = np.array([roh_mask], dtype=np.int64)
        feed = {}
        for name in self._input_names:
            if name == "input_ids":
                feed[name] = ids
            elif name == "attention_mask":
                feed[name] = mask
            elif name == "token_type_ids":
                feed[name] = np.zeros_like(ids)
        out = self._session.run(None, feed)[0]  # (1, seq, 384)

        m = mask.astype(np.float32)[..., None]
        vec = (out * m).sum(axis=1) / np.clip(m.sum(axis=1), 1e-9, None)
        norm = np.clip(np.linalg.norm(vec, axis=1, keepdims=True), 1e-12, None)
        return (vec / norm).astype(np.float32)

    def encode_one(self, text: str) -> np.ndarray:
        self._load()
        return self._encode_single(text)[0]


_tokenizer = None


def tokenizer():
    """EIN geteilter Tokenizer fuer Einbettung und Token-Zaehlung.

    Zwei Instanzen kosteten gemessen 0,74 s extra je Hook-Aufruf — das
    Einlesen der 9 MB grossen tokenizer.json schlaegt zweimal zu.

    `no_truncation()` ist zwingend: die Datei bringt `max_length: 128` mit.
    Ohne das Abschalten laege jede Zaehlung stumm bei hoechstens 128, und die
    Budget-Rechnung liesse zu viel durch. Die Kuerzung fuers Modell macht
    `Embedder._encode_single` selbst.
    """
    global _tokenizer
    if _tokenizer is None:
        from tokenizers import Tokenizer

        _tokenizer = Tokenizer.from_file(str(tokenizer_file()))
        _tokenizer.no_truncation()
        _tokenizer.no_padding()
    return _tokenizer


def count_tokens(text: str) -> int:
    """Naeherung fuer die Budget-Rechnung.

    Gezaehlt wird mit dem Tokenizer des Embedding-Modells, nicht mit dem des
    Ziel-LLM — belastbare Naeherung, keine exakte Angabe.
    """
    return len(tokenizer().encode(text, add_special_tokens=False).ids)


_shared: Embedder | None = None


def shared() -> Embedder:
    global _shared
    if _shared is None:
        _shared = Embedder()
    return _shared


def rule_text(rule: dict) -> str:
    """Was eingebettet wird: trigger + statement (Spezifikation)."""
    return f"{rule.get('trigger') or ''}\n{rule.get('statement') or ''}".strip()


def download_model(quantized: bool = True) -> Path:
    """Modell + Tokenizer nach ~/.local/share/writ-light/model/ holen."""
    import shutil

    from huggingface_hub import hf_hub_download

    repo = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
    dest = paths.model_dir()
    dest.mkdir(parents=True, exist_ok=True)
    remote = "onnx/model_quint8_avx2.onnx" if quantized else "onnx/model.onnx"
    local = "model_quint8_avx2.onnx" if quantized else "model.onnx"
    for r, l in ((remote, local), ("tokenizer.json", "tokenizer.json")):
        if (dest / l).exists():
            continue
        shutil.copyfile(hf_hub_download(repo_id=repo, filename=r), dest / l)
    return dest
