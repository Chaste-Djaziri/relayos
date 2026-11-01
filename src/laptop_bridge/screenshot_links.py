# Path: src/laptop_bridge/screenshot_links.py
"""Short-lived, in-memory HTTPS fallback for locally approved screenshots.

The signed capture helper supplies JPEG bytes only after a local Once approval.
This module never captures screens, persists image data, or broadens approval.
The URL token is a bearer credential: never log it or include it in audit events.
"""
from __future__ import annotations

from dataclasses import dataclass
import secrets
import threading
import time
from urllib.parse import urlsplit

TTL_SECONDS = 120
MAX_READS = 3  # Tolerate one preview/probe and a retry.
MAX_ENTRIES = 4
MAX_IMAGE_BYTES = 4_000_000


@dataclass
class _Entry:
    image: bytes
    expires_at: float
    remaining_reads: int


class ScreenshotLinkStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._entries: dict[str, _Entry] = {}

    def _prune(self, now: float) -> None:
        for token, entry in list(self._entries.items()):
            if now >= entry.expires_at or entry.remaining_reads <= 0:
                del self._entries[token]

    def issue(self, image: bytes, public_origin: str) -> dict:
        """Publish only through the existing configured public HTTPS origin."""
        origin = public_origin.strip().rstrip("/") if isinstance(public_origin, str) else ""
        parsed = urlsplit(origin)
        if (
            parsed.scheme != "https" or not parsed.hostname or
            parsed.username is not None or parsed.password is not None or
            parsed.path or parsed.query or parsed.fragment or parsed.netloc.endswith("@")
        ):
            raise ValueError("Screenshot link requires a configured public HTTPS origin")
        if not isinstance(image, bytes) or not image.startswith(b"\xff\xd8\xff") or not 100 < len(image) <= MAX_IMAGE_BYTES:
            raise ValueError("Only a bounded JPEG may be shared")
        now = time.monotonic()
        token = secrets.token_urlsafe(32)
        with self._lock:
            self._prune(now)
            # Bound process memory even if a client never fetches the image.
            while len(self._entries) >= MAX_ENTRIES:
                del self._entries[next(iter(self._entries))]
            self._entries[token] = _Entry(image, now + TTL_SECONDS, MAX_READS)
        return {
            "image_url": f"{origin}/screenshots/{token}",
            "image_url_expires_in_seconds": TTL_SECONDS,
            "image_url_max_downloads": MAX_READS,
        }

    def retrieve(self, token: str) -> bytes | None:
        if not isinstance(token, str) or len(token) > 128 or len(token) < 32:
            return None
        now = time.monotonic()
        with self._lock:
            self._prune(now)
            entry = self._entries.get(token)
            if entry is None:
                return None
            entry.remaining_reads -= 1
            image = entry.image
            if entry.remaining_reads == 0:
                del self._entries[token]
            return image

    def revoke_all(self) -> None:
        with self._lock:
            self._entries.clear()


store = ScreenshotLinkStore()
