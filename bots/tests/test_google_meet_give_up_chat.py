from unittest import mock

from django.test import SimpleTestCase

from bots.google_meet_bot_adapter.google_meet_bot_adapter import DEFAULT_CANNOT_RECORD_CHAT_MESSAGE, OPEN_CHAT_AND_SEND_SCRIPT, GoogleMeetBotAdapter
from bots.web_bot_adapter.ui_methods import UiCouldNotLocateElementException


class GoogleMeetGiveUpChatTest(SimpleTestCase):
    def make_adapter(self, step):
        adapter = object.__new__(GoogleMeetBotAdapter)
        adapter.meeting_url = "https://meet.google.com/abc-defg-hij"
        adapter.left_meeting = False
        adapter.cleaned_up = False
        adapter.driver = mock.Mock()
        adapter.init_driver = mock.Mock()
        adapter.attempt_to_join_meeting = mock.Mock(side_effect=UiCouldNotLocateElementException("Could not find captions button. Timed out.", step))
        adapter.send_debug_screenshot_message = mock.Mock()
        return adapter

    def give_up(self, adapter):
        with mock.patch("bots.web_bot_adapter.web_bot_adapter.sleep"):
            adapter.repeatedly_attempt_to_join_meeting()

    def test_posts_chat_once_when_giving_up_on_the_captions_button(self):
        adapter = self.make_adapter("click_captions_button")
        self.give_up(adapter)

        self.assertEqual(adapter.attempt_to_join_meeting.call_count, 4)
        adapter.driver.execute_async_script.assert_called_once_with(OPEN_CHAT_AND_SEND_SCRIPT, DEFAULT_CANNOT_RECORD_CHAT_MESSAGE)
        adapter.send_debug_screenshot_message.assert_called_once()

    def test_message_text_comes_from_env(self):
        adapter = self.make_adapter("click_captions_button")
        with mock.patch.dict("os.environ", {"CANNOT_RECORD_CHAT_MESSAGE": "custom"}):
            self.give_up(adapter)
        adapter.driver.execute_async_script.assert_called_once_with(OPEN_CHAT_AND_SEND_SCRIPT, "custom")

    def test_chat_failure_does_not_block_giving_up(self):
        adapter = self.make_adapter("click_captions_button")
        adapter.driver.execute_async_script.side_effect = RuntimeError("chat panel gone")
        self.give_up(adapter)
        adapter.send_debug_screenshot_message.assert_called_once()

    def test_other_steps_post_nothing(self):
        adapter = self.make_adapter("join_button")
        self.give_up(adapter)
        adapter.driver.execute_async_script.assert_not_called()
        adapter.send_debug_screenshot_message.assert_called_once()
