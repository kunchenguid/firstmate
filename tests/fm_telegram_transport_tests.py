#!/usr/bin/env python3
import dataclasses
import hashlib
import json
import unittest

from fm_telegram.envelope import (
    AuthenticationBinding,
    BotBinding,
    EnvelopeDisposition,
    TelegramEnvelopeError,
    normalize_update,
)
from fm_telegram.fake_api import (
    DeterministicTransport,
    FakeReply,
    FakeTelegramServer,
    json_response,
)
from fm_telegram.protocol import (
    PROTOCOL_NAME,
    PROTOCOL_VERSION,
    BridgeResult,
    BridgeStatus,
    BusyPolicy,
    FinalOutcome,
    Milestone,
    MilestoneKind,
    ProtocolValidationError,
    SessionRegistration,
    SessionUnavailable,
    TurnFinal,
    TurnKind,
    TurnOffer,
    TurnReconcile,
    decode_frame,
    encode_frame,
    validate_message,
)
from fm_telegram.render import (
    RenderError,
    ReplyParameters,
    escape_html,
    render_plain_text,
)
from fm_telegram.telegram_api import (
    AmbiguousDelivery,
    AmbiguousResponse,
    BotToken,
    ConnectionFailure,
    DefinitiveRejection,
    MalformedResponse,
    OwnershipConflict,
    RateLimited,
    ServerFailure,
    TelegramBotApiClient,
    TransportFailure,
    WriteState,
)


HASH_A = "a" * 64
HASH_B = "b" * 64
EXTERNAL_ID = f"tg:{HASH_A}:511294429"


class ProtocolContractTest(unittest.TestCase):
    def session(self):
        return SessionRegistration(
            request_id="req-1",
            idempotency_key="session-register-12",
            home_id="home-main",
            daemon_instance_id="daemon-7",
            bot_fingerprint=HASH_A,
            bridge_build="bridge-1",
            harness="pi",
            harness_version="0.80.10",
            session_id="session-1",
            route_id="route-1",
            session_epoch=12,
            project_root_sha256=HASH_B,
        )

    def offer(self):
        return TurnOffer(
            request_id="req-2",
            idempotency_key="offer-1",
            external_id=EXTERNAL_ID,
            payload_sha256=HASH_B,
            route_id="route-1",
            session_epoch=12,
            kind=TurnKind.REPLY,
            text="Captain says hello.",
            busy_policy=BusyPolicy.FOLLOW_UP,
            telegram_reply_to_message_id="7001",
            known_reply_external_id=f"tg:{HASH_A}:511294400",
        )

    def test_session_registration_is_harness_neutral_and_versioned(self):
        wire = self.session().to_wire()
        self.assertEqual(wire["protocol"], PROTOCOL_NAME)
        self.assertEqual(wire["protocol_version"], PROTOCOL_VERSION)
        self.assertEqual(validate_message(wire), self.session())
        wire["harness"] = "claude-code"
        parsed = validate_message(wire)
        self.assertEqual(parsed.harness, "claude-code")

    def test_session_unavailable_round_trips(self):
        message = SessionUnavailable(
            request_id="req-3",
            route_id="route-1",
            session_id="session-1",
            session_epoch=12,
            reason_code="SESSION_REPLACED",
        )
        self.assertEqual(validate_message(message.to_wire()), message)

    def test_turn_offer_and_reconcile_round_trip(self):
        offer = self.offer()
        self.assertEqual(validate_message(offer.to_wire()), offer)
        reconcile = TurnReconcile(
            request_id="req-4",
            external_id=EXTERNAL_ID,
            payload_sha256=HASH_B,
            route_id="route-1",
            session_epoch=12,
        )
        self.assertEqual(validate_message(reconcile.to_wire()), reconcile)
        self.assertNotIn("Captain says hello.", repr(offer))
        wire = offer.to_wire()
        wire["busy_policy"] = "steer"
        self.assertEqual(validate_message(wire).busy_policy, BusyPolicy.STEER)

    def test_binary_frame_is_bounded_and_round_trips(self):
        session = self.session()
        frame = encode_frame(session)
        self.assertEqual(decode_frame(frame), session)
        with self.assertRaises(ProtocolValidationError):
            decode_frame(frame[:-1])
        with self.assertRaises(ProtocolValidationError):
            decode_frame(b"\x00\x00\x00\x02{}extra")

    def test_every_bridge_result_variant_round_trips(self):
        common = {
            "request_id": "req-5",
            "external_id": EXTERNAL_ID,
            "payload_sha256": HASH_B,
        }
        variants = [
            BridgeResult(
                **common,
                status=BridgeStatus.ACCEPTED,
                session_epoch=12,
                session_id="session-1",
                adapter_entry_id="entry-1",
            ),
            BridgeResult(
                **common,
                status=BridgeStatus.DUPLICATE,
                session_epoch=12,
                session_id="session-1",
                adapter_entry_id="entry-1",
            ),
            BridgeResult(
                **common,
                status=BridgeStatus.NOT_FOUND,
                session_epoch=12,
                session_id="session-1",
            ),
            BridgeResult(
                **common,
                status=BridgeStatus.BUSY,
                session_epoch=12,
                retry_after_ms=250,
            ),
            BridgeResult(
                **common,
                status=BridgeStatus.UNAVAILABLE,
                reason_code="SESSION_UNAVAILABLE",
            ),
            BridgeResult(
                **common,
                status=BridgeStatus.AMBIGUOUS,
                reason_code="MARKER_HASH_MISMATCH",
            ),
        ]
        for variant in variants:
            with self.subTest(status=variant.status):
                self.assertEqual(validate_message(variant.to_wire()), variant)

    def test_positive_bridge_results_require_durable_entry_fields(self):
        common = {
            "request_id": "req-6",
            "external_id": EXTERNAL_ID,
            "payload_sha256": HASH_B,
        }
        for status in (BridgeStatus.ACCEPTED, BridgeStatus.DUPLICATE):
            with self.subTest(status=status):
                with self.assertRaises(ProtocolValidationError):
                    BridgeResult(**common, status=status)
        hacked = object.__new__(BridgeResult)
        for key, value in {
            **common,
            "status": BridgeStatus.ACCEPTED,
            "session_epoch": None,
            "session_id": None,
            "adapter_entry_id": None,
            "retry_after_ms": None,
            "reason_code": None,
        }.items():
            object.__setattr__(hacked, key, value)
        with self.assertRaises(ProtocolValidationError):
            hacked.to_wire()

    def test_normalized_milestones_are_allowlisted_and_detail_free(self):
        for sequence, kind in enumerate(MilestoneKind):
            event = Milestone(
                event_id=f"event-{sequence}",
                external_id=EXTERNAL_ID,
                route_id="route-1",
                session_id="session-1",
                session_epoch=12,
                sequence_no=sequence,
                kind=kind,
                occurred_at=2000000000 + sequence,
            )
            wire = event.to_wire()
            self.assertEqual(validate_message(wire), event)
            self.assertNotIn("details", wire)
            self.assertNotIn("tool_arguments", wire)

    def test_final_response_is_correlated_and_body_safe_in_repr(self):
        text = "The requested work is ready."
        final = TurnFinal(
            event_id="event-final",
            external_id=EXTERNAL_ID,
            route_id="route-1",
            session_id="session-1",
            session_epoch=12,
            adapter_entry_id="entry-1",
            outcome=FinalOutcome.ANSWERED,
            text=text,
            content_sha256=hashlib.sha256(text.encode()).hexdigest(),
        )
        self.assertEqual(validate_message(final.to_wire()), final)
        self.assertNotIn(text, repr(final))
        wire = final.to_wire()
        wire["content_sha256"] = HASH_A
        with self.assertRaises(ProtocolValidationError):
            validate_message(wire)

    def test_unknown_fields_versions_and_types_fail_closed(self):
        for mutation in (
            lambda value: value.update({"surprise": True}),
            lambda value: value.update({"protocol_version": 2}),
            lambda value: value.update({"protocol": "other.v1"}),
            lambda value: value.update({"type": "turn.magic"}),
        ):
            wire = self.session().to_wire()
            mutation(wire)
            with self.subTest(wire=wire):
                with self.assertRaises(ProtocolValidationError):
                    validate_message(wire)

    def test_status_specific_fields_are_exact(self):
        wire = BridgeResult(
            request_id="req-5",
            external_id=EXTERNAL_ID,
            payload_sha256=HASH_B,
            status=BridgeStatus.UNAVAILABLE,
            reason_code="SESSION_UNAVAILABLE",
        ).to_wire()
        wire["session_id"] = "should-not-be-here"
        with self.assertRaises(ProtocolValidationError):
            validate_message(wire)

    def test_stale_or_invalid_identifiers_fail_validation(self):
        wire = self.offer().to_wire()
        wire["session_epoch"] = 0
        with self.assertRaises(ProtocolValidationError):
            validate_message(wire)
        wire = self.offer().to_wire()
        wire["kind"] = "unknown"
        with self.assertRaises(ProtocolValidationError):
            validate_message(wire)
        wire = self.offer().to_wire()
        wire["payload_sha256"] = "not-a-hash"
        with self.assertRaises(ProtocolValidationError):
            validate_message(wire)


class EnvelopeContractTest(unittest.TestCase):
    def setUp(self):
        self.bot = BotBinding(HASH_A, "home-main", HASH_B)
        self.auth = AuthenticationBinding("424242", "31337")

    def message_update(self):
        return {
            "update_id": 511294429,
            "message": {
                "message_id": 7001,
                "date": 2000000001,
                "chat": {"id": 424242},
                "from": {"id": 31337},
                "message_thread_id": 55,
                "reply_to_message": {"message_id": 6999},
                "text": "Cafe\u0301\r\n<unsafe> & exact",
            },
        }

    def test_complete_authenticated_message_envelope(self):
        envelope = normalize_update(self.message_update(), self.bot, self.auth)
        self.assertTrue(envelope.authenticated)
        self.assertEqual(envelope.disposition, EnvelopeDisposition.ACCEPTED)
        self.assertEqual(envelope.kind, "message")
        self.assertEqual(envelope.update_id, "511294429")
        self.assertEqual(envelope.message_id, "7001")
        self.assertEqual(envelope.chat_id, "424242")
        self.assertEqual(envelope.sender_user_id, "31337")
        self.assertIsNone(envelope.sender_chat_id)
        self.assertEqual(envelope.thread_id, "55")
        self.assertEqual(envelope.reply_to_message_id, "6999")
        self.assertEqual(envelope.message_date, 2000000001)
        self.assertIsNone(envelope.edit_date)
        self.assertEqual(envelope.normalized_text, "Café\n<unsafe> & exact")
        self.assertEqual(envelope.external_id, f"tg:{HASH_A}:511294429")
        self.assertRegex(envelope.payload_sha256, r"^[0-9a-f]{64}$")

    def test_edited_message_and_hash_are_deterministic(self):
        update = self.message_update()
        update["edited_message"] = update.pop("message")
        update["edited_message"]["edit_date"] = 2000000002
        first = normalize_update(update, self.bot, self.auth)
        reordered = json.loads(json.dumps(update, sort_keys=True))
        second = normalize_update(reordered, self.bot, self.auth)
        self.assertEqual(first.kind, "edited_message")
        self.assertEqual(first.edit_date, 2000000002)
        self.assertEqual(first.payload_sha256, second.payload_sha256)
        reordered["edited_message"]["text"] = "changed"
        self.assertNotEqual(
            first.payload_sha256,
            normalize_update(reordered, self.bot, self.auth).payload_sha256,
        )
        del update["edited_message"]["edit_date"]
        with self.assertRaises(TelegramEnvelopeError):
            normalize_update(update, self.bot, self.auth)

    def test_present_thread_and_reply_ids_are_rejected_when_malformed(self):
        for mutation in (
            lambda update: update["message"].__setitem__("message_thread_id", 0),
            lambda update: update["message"].__setitem__("reply_to_message", {"message_id": 0}),
        ):
            update = self.message_update()
            mutation(update)
            with self.subTest(update=update):
                with self.assertRaises(TelegramEnvelopeError):
                    normalize_update(update, self.bot, self.auth)

    def test_callback_envelope_retains_private_payload_for_later_lane(self):
        update = {
            "update_id": 511294430,
            "callback_query": {
                "id": "callback-secret-id",
                "from": {"id": 31337},
                "message": {
                    "message_id": 7002,
                    "date": 2000000002,
                    "chat": {"id": 424242},
                },
                "data": "opaque:private-choice",
            },
        }
        envelope = normalize_update(update, self.bot, self.auth)
        self.assertTrue(envelope.authenticated)
        self.assertEqual(envelope.kind, "callback_query")
        self.assertEqual(envelope.disposition, EnvelopeDisposition.CALLBACK_DEFERRED)
        self.assertEqual(envelope.callback_query_id, "callback-secret-id")
        self.assertEqual(envelope.callback_data, "opaque:private-choice")
        self.assertEqual(
            envelope.callback_data_sha256,
            hashlib.sha256(b"opaque:private-choice").hexdigest(),
        )
        rendered = repr(envelope) + repr(
            envelope.diagnostic("update.classified", "CALLBACK_DEFERRED")
        )
        for forbidden in (
            "callback-secret-id",
            "opaque:private-choice",
            "424242",
            "31337",
        ):
            self.assertNotIn(forbidden, rendered)

    def test_exact_chat_and_sender_authentication_drop_unauthorized_body(self):
        for field, value, disposition in (
            ("chat", {"id": 999}, EnvelopeDisposition.UNAUTHORIZED_CHAT),
            ("from", {"id": 999}, EnvelopeDisposition.UNAUTHORIZED_SENDER),
        ):
            update = self.message_update()
            update["message"][field] = value
            envelope = normalize_update(update, self.bot, self.auth)
            self.assertFalse(envelope.authenticated)
            self.assertEqual(envelope.disposition, disposition)
            self.assertIsNone(envelope.normalized_text)
            self.assertNotIn("unsafe", repr(envelope))

    def test_sender_chat_is_preserved_and_rejected(self):
        update = self.message_update()
        update["message"]["sender_chat"] = {"id": -100123}
        envelope = normalize_update(update, self.bot, self.auth)
        self.assertFalse(envelope.authenticated)
        self.assertEqual(
            envelope.disposition, EnvelopeDisposition.SENDER_CHAT_UNSUPPORTED
        )
        self.assertEqual(envelope.sender_chat_id, "-100123")
        self.assertIsNone(envelope.normalized_text)

    def test_unsupported_content_has_explicit_disposition(self):
        update = self.message_update()
        del update["message"]["text"]
        update["message"]["photo"] = [{"file_id": "not-enabled"}]
        envelope = normalize_update(update, self.bot, self.auth)
        self.assertTrue(envelope.authenticated)
        self.assertEqual(
            envelope.disposition, EnvelopeDisposition.UNSUPPORTED_CONTENT
        )
        self.assertEqual(envelope.unsupported_reason, "text_required")
        self.assertIsNone(envelope.normalized_text)

    def test_bot_home_and_api_root_are_hash_bound(self):
        first = normalize_update(self.message_update(), self.bot, self.auth)
        other = normalize_update(
            self.message_update(),
            BotBinding("c" * 64, "home-other", "d" * 64),
            self.auth,
        )
        self.assertNotEqual(first.payload_sha256, other.payload_sha256)
        self.assertNotEqual(first.external_id, other.external_id)

    def test_ambiguous_kind_and_unsafe_text_fail_closed(self):
        update = self.message_update()
        update["edited_message"] = dict(update["message"])
        with self.assertRaises(TelegramEnvelopeError):
            normalize_update(update, self.bot, self.auth)
        update = self.message_update()
        update["message"]["text"] = "bad\x00text"
        with self.assertRaises(TelegramEnvelopeError):
            normalize_update(update, self.bot, self.auth)

    def test_diagnostic_projection_has_no_forbidden_fields(self):
        envelope = normalize_update(self.message_update(), self.bot, self.auth)
        diagnostic = dataclasses.asdict(
            envelope.diagnostic("update.accepted", "AUTHORIZED")
        )
        forbidden_keys = {
            "token",
            "message_body",
            "final_body",
            "raw_chat_id",
            "raw_user_id",
            "callback_data",
            "tool_arguments",
            "environment",
            "url",
            "chat_id",
            "sender_user_id",
        }
        self.assertTrue(forbidden_keys.isdisjoint(diagnostic))
        rendered = json.dumps(diagnostic)
        for forbidden in ("424242", "31337", "Café", "<unsafe>"):
            self.assertNotIn(forbidden, rendered)


class RenderingContractTest(unittest.TestCase):
    def test_canonical_escape_is_available_but_plain_text_is_default(self):
        self.assertEqual(escape_html("<captain> & crew\r\n"), "&lt;captain&gt; &amp; crew\n")
        chunks = render_plain_text("<captain> & crew")
        self.assertEqual(chunks[0].text, "<captain> & crew")
        self.assertNotIn("parse_mode", chunks[0].send_payload("424242"))

    def test_chunking_is_deterministic_bounded_and_lossless(self):
        text = ("Evidence 🚀 line remains bound.\n" * 300).rstrip()
        first = render_plain_text(
            text,
            reply_to_message_id="7001",
            thread_id="55",
            message_bytes=256,
        )
        second = render_plain_text(
            text,
            reply_to_message_id="7001",
            thread_id="55",
            message_bytes=256,
        )
        self.assertEqual(first, second)
        self.assertEqual("".join(item.text for item in first), text)
        self.assertGreater(len(first), 2)
        self.assertEqual(len({item.delivery_id for item in first}), len(first))
        self.assertTrue(all(len(item.text.encode()) <= 256 for item in first))
        self.assertTrue(all(item.total_chunks == len(first) for item in first))
        self.assertTrue(all(item.content_sha256 == first[0].content_sha256 for item in first))

    def test_every_chunk_preserves_reply_and_thread_binding(self):
        chunks = render_plain_text(
            "one\ntwo\nthree\nfour",
            reply_to_message_id="7001",
            thread_id="55",
            message_bytes=32,
        )
        for chunk in chunks:
            payload = chunk.send_payload("424242")
            self.assertEqual(
                payload["reply_parameters"],
                {
                    "message_id": 7001,
                    "allow_sending_without_reply": False,
                },
            )
            self.assertEqual(payload["message_thread_id"], 55)

    def test_content_change_changes_delivery_identity(self):
        first = render_plain_text("same content")[0]
        second = render_plain_text("different content")[0]
        self.assertNotEqual(first.content_sha256, second.content_sha256)
        self.assertNotEqual(first.delivery_id, second.delivery_id)

    def test_reply_identity_is_safe_in_repr(self):
        value = ReplyParameters("7001")
        self.assertNotIn("7001", repr(value))
        with self.assertRaises(RenderError):
            ReplyParameters("0")
        with self.assertRaises(RenderError):
            ReplyParameters("7001", allow_sending_without_reply=True)

    def test_controls_and_excessive_chunk_counts_fail(self):
        with self.assertRaises(RenderError):
            render_plain_text("")
        with self.assertRaises(RenderError):
            render_plain_text("bad\x00content")
        with self.assertRaises(RenderError):
            render_plain_text("x" * (32 * 65), message_bytes=32)

    def test_credential_shaped_content_is_rejected_without_echo(self):
        secret = "api_key=THIS_VALUE_MUST_NEVER_APPEAR"
        with self.assertRaises(RenderError) as caught:
            render_plain_text(secret)
        self.assertNotIn(secret, str(caught.exception))


class TelegramApiContractTest(unittest.TestCase):
    def client(self, script, timeout=1):
        transport = DeterministicTransport(script)
        client = TelegramBotApiClient(
            BotToken("123456:fake-test-credential"),
            api_root="http://127.0.0.1:1",
            transport=transport,
            timeout_seconds=timeout,
        )
        return client, transport

    def test_positive_operations_and_postconditions(self):
        scripts = [
            json_response(200, {"ok": True, "result": [{"update_id": 1}]}),
            json_response(200, {"ok": True, "result": {"url": ""}}),
            json_response(
                200,
                {"ok": True, "result": {"message_id": 7, "chat": {"id": 424242}}},
            ),
            json_response(
                200,
                {"ok": True, "result": {"message_id": 7, "chat": {"id": 424242}}},
            ),
            json_response(200, {"ok": True, "result": True}),
            json_response(200, {"ok": True, "result": True}),
        ]
        client, transport = self.client(scripts)
        self.assertEqual(client.get_updates(offset=1, timeout_seconds=30), [{"update_id": 1}])
        self.assertEqual(client.get_webhook_info()["url"], "")
        message = client.send_message(
            chat_id="424242",
            text="reply",
            reply_parameters={
                "message_id": 7001,
                "allow_sending_without_reply": False,
            },
            message_thread_id="55",
        )
        self.assertEqual(message["message_id"], 7)
        self.assertEqual(
            client.edit_message_text(
                chat_id="424242", message_id="7", text="activity"
            )["message_id"],
            7,
        )
        self.assertTrue(client.delete_message(chat_id="424242", message_id="7"))
        self.assertTrue(
            client.answer_callback_query(
                callback_query_id="callback-private",
                text="Choice received.",
            )
        )
        self.assertEqual(
            [request.method for request in transport.requests],
            [
                "getUpdates",
                "getWebhookInfo",
                "sendMessage",
                "editMessageText",
                "deleteMessage",
                "answerCallbackQuery",
            ],
        )
        send = transport.requests[2].payload
        self.assertEqual(send["reply_parameters"]["message_id"], 7001)
        self.assertIs(send["reply_parameters"]["allow_sending_without_reply"], False)
        callback = transport.requests[5].payload
        self.assertEqual(callback["text"], "Choice received.")
        self.assertIs(callback["show_alert"], False)

    def test_definitive_rejection(self):
        client, _ = self.client(
            [json_response(400, {"ok": False, "error_code": 400, "description": "private body"})]
        )
        with self.assertRaises(DefinitiveRejection) as caught:
            client.send_message(chat_id="424242", text="private body")
        self.assertNotIn("private body", str(caught.exception))

    def test_ownership_conflict_is_specific_to_long_poll(self):
        client, _ = self.client(
            [json_response(409, {"ok": False, "error_code": 409})]
        )
        with self.assertRaises(OwnershipConflict):
            client.get_updates(offset=0, timeout_seconds=30)

    def test_rate_limit_is_bounded(self):
        client, _ = self.client(
            [
                json_response(
                    429,
                    {
                        "ok": False,
                        "error_code": 429,
                        "parameters": {"retry_after": 99999},
                    },
                )
            ]
        )
        with self.assertRaises(RateLimited) as caught:
            client.send_message(chat_id="424242", text="reply")
        self.assertEqual(caught.exception.retry_after_seconds, 3600)

    def test_server_failure_is_classified(self):
        client, _ = self.client(
            [json_response(503, {"ok": False, "error_code": 503})]
        )
        with self.assertRaises(ServerFailure):
            client.send_message(chat_id="424242", text="reply")

    def test_connection_failure_before_write_is_not_sent(self):
        client, transport = self.client(
            [TransportFailure(WriteState.BEFORE_WRITE)]
        )
        with self.assertRaises(ConnectionFailure) as caught:
            client.send_message(chat_id="424242", text="reply")
        self.assertEqual(caught.exception.delivery_state.value, "not_sent")
        self.assertEqual(transport.requests, [])

    def test_post_write_timeout_is_ambiguous_and_never_delivered(self):
        client, transport = self.client(
            [TransportFailure(WriteState.AFTER_WRITE)]
        )
        with self.assertRaises(AmbiguousDelivery) as caught:
            client.send_message(chat_id="424242", text="reply")
        self.assertEqual(caught.exception.delivery_state.value, "ambiguous")
        self.assertEqual(len(transport.requests), 1)

    def test_malformed_reads_and_mutations_have_distinct_semantics(self):
        client, _ = self.client(
            [
                json_response(200, {"ok": True, "result": "not-a-list"}),
                json_response(200, {"ok": True}),
            ]
        )
        with self.assertRaises(MalformedResponse):
            client.get_updates(offset=0, timeout_seconds=30)
        with self.assertRaises(AmbiguousResponse):
            client.send_message(chat_id="424242", text="reply")

    def test_reply_parameters_cannot_escape_origin_binding(self):
        client, _ = self.client(
            [
                json_response(
                    200,
                    {
                        "ok": True,
                        "result": {"message_id": 7, "chat": {"id": 424242}},
                    },
                )
            ]
        )
        with self.assertRaises(ValueError):
            client.send_message(
                chat_id="424242",
                text="reply",
                reply_parameters={
                    "message_id": 7001,
                    "allow_sending_without_reply": True,
                },
            )

    def test_client_rejects_credential_shaped_body_before_transport(self):
        client, transport = self.client([])
        secret = "bot_token=THIS_VALUE_MUST_NEVER_APPEAR"
        with self.assertRaises(ValueError) as caught:
            client.send_message(chat_id="424242", text=secret)
        self.assertNotIn(secret, str(caught.exception))
        self.assertEqual(transport.requests, [])

    def test_positive_message_requires_exact_chat_and_message_id(self):
        for result in (
            {"message_id": 0, "chat": {"id": 424242}},
            {"message_id": 7, "chat": {"id": 999}},
            True,
        ):
            client, _ = self.client(
                [json_response(200, {"ok": True, "result": result})]
            )
            with self.subTest(result=result):
                with self.assertRaises(AmbiguousResponse):
                    client.send_message(chat_id="424242", text="reply")

    def test_edit_message_text_requires_exact_chat_and_message_id(self):
        for result in (
            {"message_id": 8, "chat": {"id": 424242}},
            {"message_id": 7, "chat": {"id": 999}},
        ):
            client, _ = self.client(
                [json_response(200, {"ok": True, "result": result})]
            )
            with self.subTest(result=result):
                with self.assertRaises(AmbiguousResponse):
                    client.edit_message_text(
                        chat_id="424242", message_id="7", text="activity"
                    )

    def test_token_and_diagnostics_are_structurally_secret_safe(self):
        secret = "123456:credential-that-must-not-leak"
        token = BotToken(secret)
        self.assertNotIn(secret, repr(token))
        self.assertNotIn(secret, str(token))
        client, _ = self.client(
            [json_response(400, {"ok": False, "error_code": 400})]
        )
        with self.assertRaises(DefinitiveRejection) as caught:
            client.answer_callback_query(callback_query_id="callback-private")
        diagnostic = dataclasses.asdict(caught.exception.diagnostic)
        forbidden = {
            "token",
            "body",
            "payload",
            "chat_id",
            "user_id",
            "callback_data",
            "environment",
            "url",
            "tool_arguments",
        }
        self.assertTrue(forbidden.isdisjoint(diagnostic))
        rendered = json.dumps(diagnostic) + str(caught.exception)
        for value in (secret, "callback-private", "api.telegram.org"):
            self.assertNotIn(value, rendered)


class FakeEndpointTest(unittest.TestCase):
    def test_loopback_server_covers_all_supported_operations(self):
        with FakeTelegramServer() as server:
            client = TelegramBotApiClient(
                BotToken("123456:fake-test-credential"),
                api_root=server.api_root,
                timeout_seconds=1,
            )
            self.assertEqual(client.get_updates(offset=0, timeout_seconds=1), [])
            self.assertEqual(client.get_webhook_info()["url"], "")
            self.assertGreater(
                client.send_message(chat_id="424242", text="hello")["message_id"],
                0,
            )
            self.assertGreater(
                client.edit_message_text(
                    chat_id="424242", message_id="3", text="working"
                )["message_id"],
                0,
            )
            self.assertTrue(client.delete_message(chat_id="424242", message_id="3"))
            self.assertTrue(
                client.answer_callback_query(callback_query_id="callback-private")
            )
            self.assertEqual(
                [request.method for request in server.requests()],
                [
                    "getUpdates",
                    "getWebhookInfo",
                    "sendMessage",
                    "editMessageText",
                    "deleteMessage",
                    "answerCallbackQuery",
                ],
            )

    def test_loopback_script_covers_malformed_rejection_conflict_rate_and_5xx(self):
        cases = [
            (
                "sendMessage",
                FakeReply(payload={"ok": True}),
                lambda client: client.send_message(chat_id="424242", text="x"),
                AmbiguousResponse,
            ),
            (
                "sendMessage",
                FakeReply(
                    status_code=400,
                    payload={"ok": False, "error_code": 400},
                ),
                lambda client: client.send_message(chat_id="424242", text="x"),
                DefinitiveRejection,
            ),
            (
                "getUpdates",
                FakeReply(
                    status_code=409,
                    payload={"ok": False, "error_code": 409},
                ),
                lambda client: client.get_updates(offset=0, timeout_seconds=1),
                OwnershipConflict,
            ),
            (
                "sendMessage",
                FakeReply(
                    status_code=429,
                    payload={
                        "ok": False,
                        "error_code": 429,
                        "parameters": {"retry_after": 7},
                    },
                ),
                lambda client: client.send_message(chat_id="424242", text="x"),
                RateLimited,
            ),
            (
                "sendMessage",
                FakeReply(
                    status_code=503,
                    payload={"ok": False, "error_code": 503},
                ),
                lambda client: client.send_message(chat_id="424242", text="x"),
                ServerFailure,
            ),
        ]
        for method, reply, action, expected in cases:
            with self.subTest(expected=expected):
                with FakeTelegramServer() as server:
                    server.enqueue(method, reply)
                    client = TelegramBotApiClient(
                        BotToken("123456:fake-test-credential"),
                        api_root=server.api_root,
                        timeout_seconds=1,
                    )
                    with self.assertRaises(expected):
                        action(client)

    def test_loopback_disconnect_after_read_is_post_write_ambiguity(self):
        with FakeTelegramServer() as server:
            server.enqueue(
                "sendMessage",
                FakeReply(disconnect_after_read=True),
            )
            client = TelegramBotApiClient(
                BotToken("123456:fake-test-credential"),
                api_root=server.api_root,
                timeout_seconds=1,
            )
            with self.assertRaises(AmbiguousDelivery):
                client.send_message(chat_id="424242", text="possible delivery")
            self.assertEqual(len(server.requests()), 1)

    def test_loopback_post_write_timeout_is_ambiguous(self):
        with FakeTelegramServer() as server:
            server.enqueue(
                "sendMessage",
                FakeReply(
                    payload={
                        "ok": True,
                        "result": {"message_id": 8, "chat": {"id": 424242}},
                    },
                    delay_seconds=0.2,
                ),
            )
            client = TelegramBotApiClient(
                BotToken("123456:fake-test-credential"),
                api_root=server.api_root,
                timeout_seconds=0.05,
            )
            with self.assertRaises(AmbiguousDelivery):
                client.send_message(chat_id="424242", text="possible delivery")
            self.assertEqual(len(server.requests()), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
