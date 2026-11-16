import logging
from types import SimpleNamespace

from django.test import SimpleTestCase

from bots import bot_log_context
from bots.bot_log_context import BotContextFilter, RepeatLimiter, install_bot_log_context, log_bot_outcome, meeting_host


class _ListHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records = []

    def emit(self, record):
        self.records.append(record)


class _Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


class BotContextFilterTest(SimpleTestCase):
    def setUp(self):
        self.handler = _ListHandler()
        logging.getLogger().addHandler(self.handler)
        self.logger = logging.getLogger("bots.tests.context")
        self.logger.setLevel(logging.INFO)

    def tearDown(self):
        logging.getLogger().removeHandler(self.handler)
        for handler in logging.getLogger().handlers:
            handler.removeFilter(bot_log_context._filter)
        bot_log_context._context.clear()

    def test_stamps_every_record_after_install(self):
        install_bot_log_context(bot_id="bot_abc", provider="google_meet", project_id="proj_1", org_id="org-1", bot_pk=7)
        self.logger.info("hello")
        record = self.handler.records[-1]
        self.assertEqual(record.bot_id, "bot_abc")
        self.assertEqual(record.provider, "google_meet")
        self.assertEqual(record.project_id, "proj_1")
        self.assertEqual(record.org_id, "org-1")
        self.assertEqual(record.bot_pk, 7)

    def test_explicit_extra_wins_and_empty_fields_are_dropped(self):
        install_bot_log_context(bot_id="bot_abc", org_id=None)
        self.logger.info("hello", extra={"bot_id": "bot_other"})
        record = self.handler.records[-1]
        self.assertEqual(record.bot_id, "bot_other")
        self.assertFalse(hasattr(record, "org_id"))

    def test_filter_is_added_once(self):
        install_bot_log_context(bot_id="a")
        install_bot_log_context(bot_id="b")
        self.assertEqual(sum(isinstance(f, BotContextFilter) for f in self.handler.filters), 1)
        self.logger.info("hello")
        self.assertEqual(self.handler.records[-1].bot_id, "b")

    def test_meeting_host_drops_path_and_query(self):
        self.assertEqual(meeting_host("https://Meet.Google.com/abc-defg-hij?authuser=1"), "meet.google.com")
        self.assertEqual(meeting_host(None), "")


class RepeatLimiterTest(SimpleTestCase):
    def setUp(self):
        self.handler = _ListHandler()
        self.logger = logging.getLogger("bots.tests.limiter")
        self.logger.addHandler(self.handler)
        self.logger.setLevel(logging.INFO)
        self.logger.propagate = False
        self.clock = _Clock()
        self.limiter = RepeatLimiter(interval=60, clock=self.clock)

    def tearDown(self):
        self.logger.removeHandler(self.handler)
        self.logger.propagate = True

    def _log(self, key):
        self.limiter.log(self.logger, logging.WARNING, key, "blocked %s", key, exception_type="X")

    def test_logs_first_occurrence_then_suppresses(self):
        for _ in range(5):
            self._log("a")
            self.clock.now += 6
        self.assertEqual(len(self.handler.records), 1)
        self.assertEqual(self.handler.records[0].repeat_count, 1)
        self.assertEqual(self.handler.records[0].exception_type, "X")

    def test_summary_after_interval(self):
        self._log("a")
        for _ in range(10):
            self.clock.now += 6
            self._log("a")
        self.assertEqual(len(self.handler.records), 2)
        summary = self.handler.records[1]
        self.assertEqual(summary.repeat_count, 10)
        self.assertIn("repeated 10 more times", summary.getMessage())

    def test_new_key_logs_immediately(self):
        self._log("a")
        self._log("b")
        self._log("a")
        self.assertEqual([r.getMessage() for r in self.handler.records], ["blocked a", "blocked b"])

    def test_flush_emits_pending_counts_once(self):
        self._log("a")
        self._log("a")
        self._log("a")
        self.limiter.flush()
        self.limiter.flush()
        self.assertEqual(len(self.handler.records), 2)
        self.assertEqual(self.handler.records[1].repeat_count, 2)


class BotOutcomeLogTest(SimpleTestCase):
    def test_outcome_fields(self):
        bot = SimpleNamespace(
            object_id="bot_abc",
            project=SimpleNamespace(object_id="proj_1"),
            metadata={"org_id": "org-1", "meeting_key": "k"},
            meeting_url="https://meet.google.com/abc-defg-hij",
            zoom_rtms_stream_id=None,
        )
        with self.assertLogs("bots.bot_log_context", level="INFO") as captured:
            log_bot_outcome(
                bot,
                event_type="fatal_error",
                event_sub_type="ui_element_not_found",
                old_state="joining",
                new_state="fatal_error",
                event_metadata={"bot_restarts_exceeded_max_retries": True, "exception_type": "UiGoogleBlockingUsException", "step": "name_input"},
            )
        record = captured.records[0]
        self.assertEqual(record.event_name, "bot.outcome")
        self.assertEqual(record.bot_id, "bot_abc")
        self.assertEqual(record.org_id, "org-1")
        self.assertEqual(record.project_id, "proj_1")
        self.assertEqual(record.provider, "google_meet")
        self.assertEqual(record.sub_type, "ui_element_not_found")
        self.assertEqual(record.exception_type, "UiGoogleBlockingUsException")
        self.assertEqual(record.step, "name_input")
        self.assertTrue(record.restarts_exceeded)
        self.assertFalse(hasattr(record, "meeting_key"))
