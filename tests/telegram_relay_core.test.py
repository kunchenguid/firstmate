#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.error import URLError

RELAY_PATH = Path(__file__).resolve().parents[1] / "bin" / "telegram_relay_core.py"
SPEC = importlib.util.spec_from_file_location("telegram_relay_core", RELAY_PATH)
RELAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELAY)


class FakeClock:
    def __init__(self):
        self.calls = []

    def sleep(self, seconds):
        self.calls.append(seconds)


class FakeRandom:
    def __init__(self, values):
        self.values = list(values)

    def __call__(self):
        return self.values.pop(0)


class TelegramRelayCoreTest(unittest.TestCase):
    def test_call_with_backoff_is_capped_and_jittered(self):
        attempts = {"count": 0}
        cfg = RELAY.RetryConfig(max_attempts=4, base_delay=1.0, max_delay=2.5, jitter=0.2)
        clock = FakeClock()
        rng = FakeRandom([0.5, 0.2])

        def flaky():
            attempts["count"] += 1
            if attempts["count"] < 3:
                raise URLError("flaky network")
            return {"ok": True}

        result = RELAY.call_with_backoff(
            flaky,
            config=cfg,
            sleep_fn=clock.sleep,
            random_fn=rng,
        )

        self.assertEqual(result, {"ok": True})
        self.assertEqual(attempts["count"], 3)
        self.assertEqual(clock.calls, [1.0, 1.96])

    def test_drain_outbox_no_advance_on_partial_send_failure(self):
        with TemporaryDirectory() as tmpdir:
            base = Path(tmpdir)
            outbox = base / "telegram-outbox"
            offset = base / ".telegram-outbox-offset"
            outbox.write_text("abcdefghijk", encoding="utf-8")

            call_log = []

            def send(chunk: str):
                call_log.append(chunk)
                if chunk == "fghij":
                    raise URLError("transient failure")
                return {"ok": True}

            with self.assertRaises(RELAY.TelegramTransientError):
                RELAY.drain_outbox(
                    outbox,
                    offset,
                    send,
                    chunk_size=5,
                    config=RELAY.RetryConfig(max_attempts=1),
                    sleep_fn=lambda _seconds: None,
                )

            self.assertFalse(offset.exists())
            self.assertEqual(call_log, ["abcde", "fghij"])

            def send_all(chunk: str):
                call_log.append(chunk)
                return {"ok": True}

            RELAY.drain_outbox(
                outbox,
                offset,
                send_all,
                chunk_size=5,
                config=RELAY.RetryConfig(max_attempts=1),
                sleep_fn=lambda _seconds: None,
            )

            self.assertEqual(RELAY.read_offset(offset), len("abcdefghijk"))
            self.assertEqual(call_log, ["abcde", "fghij", "abcde", "fghij", "k"])

    def test_validate_telegram_ok_rejects_false_without_leaking_token(self):
        with self.assertRaises(RELAY.TelegramResponseError) as ctx:
            RELAY.validate_telegram_ok(
                {"ok": False, "description": "Bad auth"},
                method="sendMessage",
            )

        self.assertIn("telegram API sendMessage rejected", str(ctx.exception))
        self.assertNotIn("secret-token", str(ctx.exception))

    def test_drain_outbox_resets_checkpoint_if_outbox_truncated(self):
        with TemporaryDirectory() as tmpdir:
            base = Path(tmpdir)
            outbox = base / "telegram-outbox"
            offset = base / ".telegram-outbox-offset"
            outbox.write_text("first line", encoding="utf-8")
            offset.write_text("1000\n", encoding="utf-8")

            new_offset = RELAY.drain_outbox(
                outbox,
                offset,
                lambda chunk: {"ok": True},
                chunk_size=3900,
            )

            self.assertEqual(new_offset, len("first line"))
            self.assertEqual(RELAY.read_offset(offset), len("first line"))


if __name__ == "__main__":
    unittest.main()
