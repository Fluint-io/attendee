from unittest.mock import MagicMock, patch

import requests
from django.test import TestCase, override_settings

from accounts.models import Organization
from bots.external_callback_utils import (
    ZOOM_TOKENS_CALLBACK_MAX_ATTEMPTS,
    ZOOM_TOKENS_CALLBACK_MAX_BACKOFF_SECONDS,
    get_zoom_tokens,
)
from bots.models import Bot, Project

EMPTY_TOKENS = {"zak_token": None, "join_token": None, "app_privilege_token": None, "onbehalf_token": None}


def _response(status_code, body=None):
    response = MagicMock()
    response.status_code = status_code
    response.text = ""
    response.json.return_value = body if body is not None else {}
    return response


@override_settings(REQUIRE_PUBLIC_WEBHOOK_URLS=False)
@patch("bots.external_callback_utils.time.sleep")
@patch("bots.external_callback_utils.requests.post")
class TestGetZoomTokensRetry(TestCase):
    def setUp(self):
        organization = Organization.objects.create(name="Test Org")
        project = Project.objects.create(name="Test Project", organization=organization)
        self.bot = Bot.objects.create(
            project=project,
            meeting_url="https://zoom.us/j/123456789",
            settings={"callback_settings": {"zoom_tokens_url": "https://example.com/zoom-tokens"}},
        )

    def test_retries_transient_failures_then_succeeds(self, mock_post, mock_sleep):
        mock_post.side_effect = [
            requests.ConnectionError("boom"),
            requests.Timeout("slow"),
            _response(503),
            _response(429),
            _response(200, {"zak_token": "zak"}),
        ]

        tokens = get_zoom_tokens(self.bot)

        self.assertEqual(tokens["zak_token"], "zak")
        self.assertEqual(mock_post.call_count, 5)
        self.assertEqual([c.args[0] for c in mock_sleep.call_args_list], [2, 4, 8, 16])

    def test_no_retry_on_4xx(self, mock_post, mock_sleep):
        mock_post.return_value = _response(404)

        self.assertEqual(get_zoom_tokens(self.bot), EMPTY_TOKENS)
        self.assertEqual(mock_post.call_count, 1)
        mock_sleep.assert_not_called()

    def test_no_retry_on_empty_200(self, mock_post, mock_sleep):
        mock_post.return_value = _response(200, {})

        self.assertEqual(get_zoom_tokens(self.bot), EMPTY_TOKENS)
        self.assertEqual(mock_post.call_count, 1)
        mock_sleep.assert_not_called()

    def test_no_retry_on_invalid_json(self, mock_post, mock_sleep):
        response = _response(200)
        response.json.side_effect = ValueError("bad json")
        mock_post.return_value = response

        self.assertEqual(get_zoom_tokens(self.bot), EMPTY_TOKENS)
        self.assertEqual(mock_post.call_count, 1)
        mock_sleep.assert_not_called()

    def test_gives_up_after_max_attempts(self, mock_post, mock_sleep):
        mock_post.return_value = _response(502)

        self.assertEqual(get_zoom_tokens(self.bot), EMPTY_TOKENS)
        self.assertEqual(mock_post.call_count, ZOOM_TOKENS_CALLBACK_MAX_ATTEMPTS)
        self.assertEqual(mock_sleep.call_count, ZOOM_TOKENS_CALLBACK_MAX_ATTEMPTS - 1)
        self.assertEqual(max(c.args[0] for c in mock_sleep.call_args_list), ZOOM_TOKENS_CALLBACK_MAX_BACKOFF_SECONDS)
