from __future__ import annotations

import threading
from collections import deque
from typing import Any, Callable


class TaskQueue:
    """In-memory task queue with basic push/pop semantics."""

    def __init__(self, max_size: int = 1000) -> None:
        self._queue: deque[dict[str, Any]] = deque(maxlen=max_size)
        self._lock = threading.Lock()

    def push(self, task_name: str, payload: Any) -> None:
        with self._lock:
            self._queue.append({"name": task_name, "payload": payload})

    def pop(self) -> dict[str, Any] | None:
        with self._lock:
            return self._queue.popleft() if self._queue else None

    def size(self) -> int:
        with self._lock:
            return len(self._queue)
