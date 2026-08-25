"""M1 — Embeddings: Form, Normalisierung, deutsche Semantik."""

from __future__ import annotations

import unittest

import numpy as np
from hilfe import TempDatenTest

from writ_light import embed


class TestEmbedder(TempDatenTest):
    def test_form_und_normalisierung(self):
        e = embed.Embedder()
        v = e.encode(["Ein Commit steht an.", "Die Suite ist rot."])
        self.assertEqual(v.shape, (2, embed.DIM))
        self.assertEqual(v.dtype, np.float32)
        np.testing.assert_allclose(np.linalg.norm(v, axis=1), 1.0, atol=1e-5)

    def test_leere_eingabe(self):
        self.assertEqual(embed.Embedder().encode([]).shape, (0, embed.DIM))

    def test_gleicher_text_gleicher_vektor(self):
        e = embed.Embedder()
        a = e.encode_one("Kein git push ohne Anweisung.")
        b = e.encode_one("Kein git push ohne Anweisung.")
        np.testing.assert_allclose(a, b, atol=1e-6)

    def test_semantische_naehe_deutsch(self):
        """Umschreibung muss naeher sein als ein fachfremder Satz."""
        e = embed.Embedder()
        regel = e.encode_one("Erst bestehende Testsuites gruen machen, dann arbeiten.")
        nah = e.encode_one("Die Testsuite war schon vorher rot.")
        fern = e.encode_one("Das Kartenrendering nutzt einen Skia-Atlas.")
        self.assertGreater(float(regel @ nah), float(regel @ fern))

    def test_batch_und_einzellauf_sind_identisch(self):
        """Ingest kodiert als Liste, Query einzeln — beides muss exakt gleich sein.

        Das quantisierte Modell ist nicht padding-invariant; encode() umgeht das,
        indem es ohne Padding je Text einzeln rechnet.
        """
        e = embed.Embedder()
        texte = ["kurz", "ein deutlich laengerer Satz zum Auffuellen des Batches"]
        batch = e.encode(texte)
        for i, t in enumerate(texte):
            np.testing.assert_array_equal(batch[i], e.encode_one(t))

    def test_count_tokens_deckelt_nicht_bei_128(self):
        """Die tokenizer.json des Modells bringt max_length 128 mit.

        Ohne no_truncation() liefert jede laengere Regel stumm 128 zurueck —
        die Budget-Rechnung laesst dann zu viel durch.
        """
        self.assertEqual(embed.count_tokens("Wort " * 500), 500)

    def test_count_tokens_waechst_mit_der_laenge(self):
        kurz = embed.count_tokens("Ein kurzer Satz.")
        lang = embed.count_tokens("Ein kurzer Satz. " * 40)
        self.assertGreater(lang, kurz * 20)

    def test_lange_regeln_werden_vollstaendig_eingebettet(self):
        """Gemessen: 15 Regeln liegen ueber 128 Tokens, die laengste bei 196.

        Mit dem Modell-Default 128 faellt Query 7 aus den Top 5.
        """
        self.assertGreaterEqual(embed.MAX_LEN, 200)

    def test_rule_text_verbindet_trigger_und_statement(self):
        t = embed.rule_text({"trigger": "WENN", "statement": "DANN"})
        self.assertEqual(t, "WENN\nDANN")


if __name__ == "__main__":
    unittest.main()
