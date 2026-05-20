from __future__ import annotations

import logging
from typing import Any, Callable

from taskq.queue import TaskQueue
from taskq.serializer import deserialize_task

logger = logging.getLogger(__name__)


class Worker:
    """Processes tasks from a TaskQueue."""

    def __init__(
        self,
        queue: TaskQueue,
        handlers: dict[str, Callable[..., Any]],
        priority_levels: int = 3,
    ) -> None:
        self._queue = queue
        self._handlers = handlers
        self._priority_levels = priority_levels

    def process_one(self) -> bool:
        task = self._queue.pop()
        if task is None:
            return False

        name = task["name"]
        payload = task["payload"]

        handler = self._handlers.get(name)
        if handler is None:
            logger.warning("no handler for task %s, dropping", name)
            return True

        handler(payload)
        return True

    def run(self, max_iterations: int = 0) -> int:
        processed = 0
        i = 0
        while max_iterations == 0 or i < max_iterations:
            if not self.process_one():
                break
            processed += 1
            i += 1
        return processed
