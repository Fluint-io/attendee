"""Structured context for bot logs (ENG-741).

A bot process runs one bot, so its identity is process-wide: once installed, a handler
filter stamps bot_id / provider / project_id / org_id onto every record that reaches the
root handlers. The OTLP handler turns record attributes into Loki structured metadata.
"""

import atexit
import json
import logging
import os
import subprocess
import threading
import time
from urllib.parse import urlparse

from django.conf import settings

logger = logging.getLogger(__name__)

_context: dict = {}


class BotContextFilter(logging.Filter):
    def filter(self, record):
        for key, value in _context.items():
            # An explicit extra= wins.
            if not hasattr(record, key):
                setattr(record, key, value)
        return True


_filter = BotContextFilter()


def install_bot_log_context(**fields):
    _context.clear()
    _context.update({key: value for key, value in fields.items() if value not in (None, "")})
    for handler in logging.getLogger().handlers:
        if _filter not in handler.filters:
            handler.addFilter(_filter)


def bot_log_context() -> dict:
    return dict(_context)


def meeting_host(url) -> str:
    try:
        return (urlparse(url or "").hostname or "").lower()
    except ValueError:
        return ""


def provider_for_bot(bot) -> str:
    from bots.meeting_url_utils import meeting_type_from_url

    if getattr(bot, "zoom_rtms_stream_id", None) is not None:
        return "zoom"
    try:
        meeting_type = meeting_type_from_url(bot.meeting_url)
    except Exception:
        meeting_type = None
    return str(getattr(meeting_type, "value", meeting_type) or "unknown")


def org_id_for_bot(bot):
    metadata = getattr(bot, "metadata", None)
    return metadata.get("org_id") if isinstance(metadata, dict) else None


def chrome_version() -> str:
    try:
        out = subprocess.run(["google-chrome", "--version"], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.rsplit(" ", 1)[-1] if out else ""


def attendee_version() -> str:
    try:
        with open(os.path.join(settings.BASE_DIR, "version.json")) as f:
            return str(json.load(f).get("version", ""))
    except (OSError, ValueError, AttributeError):
        return ""


def log_bot_start(bot, provider):
    install_bot_log_context(
        bot_id=bot.object_id,
        bot_pk=bot.id,
        project_id=bot.project.object_id,
        org_id=org_id_for_bot(bot),
        provider=provider,
    )
    fields = {
        "event_name": "bot.start",
        "meeting_host": meeting_host(bot.meeting_url),
        "chrome_version": chrome_version(),
        "attendee_version": attendee_version(),
        "image_tag": os.getenv("IMAGE_TAG", ""),
    }
    logger.info(
        "bot.start bot=%s provider=%s host=%s chrome=%s attendee=%s image=%s",
        bot.object_id,
        provider,
        fields["meeting_host"],
        fields["chrome_version"],
        fields["attendee_version"],
        fields["image_tag"],
        extra=fields,
    )


def log_bot_outcome(bot, event_type, event_sub_type, old_state, new_state, event_metadata):
    """One record per bot reaching a post-meeting state, from whichever process wrote it."""
    metadata = event_metadata if isinstance(event_metadata, dict) else {}
    fields = {
        "event_name": "bot.outcome",
        "bot_id": bot.object_id,
        "project_id": getattr(getattr(bot, "project", None), "object_id", None),
        "org_id": org_id_for_bot(bot),
        "provider": provider_for_bot(bot),
        "event_type": event_type,
        "sub_type": event_sub_type or "none",
        "old_state": old_state,
        "new_state": new_state,
        "exception_type": metadata.get("exception_type") or "",
        "step": metadata.get("step") or "",
        "restarts_exceeded": bool(metadata.get("bot_restarts_exceeded_max_retries")),
    }
    fields = {key: value for key, value in fields.items() if value is not None}
    logger.info(
        "bot.outcome bot=%s state=%s event_type=%s sub_type=%s exception=%s step=%s",
        bot.object_id,
        new_state,
        event_type,
        fields["sub_type"],
        fields["exception_type"],
        fields["step"],
        extra=fields,
    )


class RepeatLimiter:
    """Logs each distinct key the first time it occurs, then only a count of its repeats every
    ``interval`` seconds and at flush(), instead of once per loop iteration."""

    def __init__(self, interval=60.0, clock=time.monotonic):
        self._interval = interval
        self._clock = clock
        self._lock = threading.Lock()
        # key -> [last (log, level, msg, args, fields), repeats, window_start]
        self._seen = {}

    def log(self, log, level, key, msg, *args, **fields):
        with self._lock:
            now = self._clock()
            state = self._seen.get(key)
            if state is None:
                self._seen[key] = [(log, level, msg, args, fields), 0, now]
                pending = None
            else:
                state[1] += 1
                if now - state[2] < self._interval:
                    return
                pending = self._take(key, state, now)
        if pending:
            self._emit_summary(*pending)
        else:
            log.log(level, msg, *args, extra={**fields, "repeat_key": str(key), "repeat_count": 1})

    def flush(self):
        with self._lock:
            now = self._clock()
            pending = [self._take(key, state, now) for key, state in self._seen.items()]
        for item in pending:
            if item:
                self._emit_summary(*item)

    @staticmethod
    def _take(key, state, now):
        if not state[1]:
            return None
        pending = (state[0], key, state[1], now - state[2])
        state[1] = 0
        state[2] = now
        return pending

    @staticmethod
    def _emit_summary(last, key, repeats, seconds):
        log, level, msg, args, fields = last
        log.log(
            level,
            "repeated %d more times in %.0fs: " + msg,
            repeats,
            seconds,
            *args,
            extra={**fields, "repeat_key": str(key), "repeat_count": repeats},
        )


join_error_limiter = RepeatLimiter()
atexit.register(join_error_limiter.flush)
