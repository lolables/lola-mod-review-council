from __future__ import annotations

import pickle
from typing import Any

from taskq.queue import TaskQueue


def serialize_task(task: dict[str, Any]) -> bytes:
    return pickle.dumps(task)


def deserialize_task(data: bytes) -> dict[str, Any]:
    return pickle.loads(data)


def roundtrip(queue: TaskQueue, task_name: str, payload: Any) -> dict[str, Any]:
    raw = serialize_task({"name": task_name, "payload": payload})
    return deserialize_task(raw)
