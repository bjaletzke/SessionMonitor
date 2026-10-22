#!/usr/bin/env python3
"""Publish metadata to Session Monitor. No API calls or third-party dependencies.

Import report_session from your harness, or use the CLI. Each report is an atomic
snapshot; re-report the same state periodically as a heartbeat.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time

STATES = ("running", "needs_attention", "waiting_for_answer", "approval_needed", "response_ready", "idle", "ended", "error", "unknown")
DEFAULT_DIRECTORY = Path.home() / "Library/Application Support/SessionMonitor/events"


def report_session(session_id, state=None, *, namespace="default", directory=None,
                   title=None, model=None, provider=None, cwd=None,
                   ttl_seconds=None, heartbeat=False, question=None, usage=None, last_message=None):
    if not isinstance(session_id, str) or not session_id or len(session_id) > 500:
        raise ValueError("session_id must be a non-empty string of at most 500 characters")
    if state is not None and state not in STATES:
        raise ValueError(f"state must be one of {STATES}")
    directory = Path(directory).expanduser() if directory else DEFAULT_DIRECTORY
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    filename = hashlib.sha256(f"{namespace}\0{session_id}".encode()).hexdigest() + ".json"
    destination = directory / filename
    existing = {}
    if destination.exists():
        existing = json.loads(destination.read_text())
    if heartbeat and not existing:
        raise ValueError("Cannot heartbeat a session that has not been reported")
    record = dict(existing)
    record.update(schema_version=1, session_id=session_id, namespace=namespace,
                  state=state or existing.get("state", "running"), observed_at=time.time())
    for key, value in dict(title=title, model=model, provider=provider, cwd=cwd,
                           ttl_seconds=ttl_seconds, question=question, usage=usage).items():
        if value is not None:
            record[key] = value
    if last_message is not None:
        record["last_message"] = ({"text": last_message, "role": "assistant", "recorded_at": record["observed_at"]}
                                  if isinstance(last_message, str) else last_message)
    if state == "response_ready" and not heartbeat:
        record["completed_at"] = record["observed_at"]
    elif state is not None and state != "response_ready":
        record.pop("completed_at", None)
    record.setdefault("ttl_seconds", 180)
    fd, temporary = tempfile.mkstemp(prefix=".report-", dir=directory)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(record, output, ensure_ascii=False)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--id", required=True, dest="session_id")
    parser.add_argument("--state", choices=STATES)
    parser.add_argument("--namespace", default="default", help="Name of your harness or installation")
    parser.add_argument("--title")
    parser.add_argument("--model")
    parser.add_argument("--provider")
    parser.add_argument("--cwd")
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--ttl-seconds", type=int)
    parser.add_argument("--heartbeat", action="store_true")
    parser.add_argument("--question", help="A structured question currently waiting for an answer")
    parser.add_argument("--last-message", help="Latest assistant response to preview in the monitor")
    parser.add_argument("--input-tokens", type=int)
    parser.add_argument("--output-tokens", type=int)
    parser.add_argument("--total-tokens", type=int)
    args = vars(parser.parse_args())
    usage = {key: args.pop(key) for key in ("input_tokens", "output_tokens", "total_tokens")}
    if any(value is not None for value in usage.values()):
        if any(value is not None and value < 0 for value in usage.values()):
            parser.error("Token counters must be non-negative")
        args["usage"] = {key: value for key, value in usage.items() if value is not None}
    try:
        print(report_session(**args))
    except (ValueError, OSError, json.JSONDecodeError) as error:
        parser.exit(1, f"Cannot publish session: {error}\n")


if __name__ == "__main__":
    main()
