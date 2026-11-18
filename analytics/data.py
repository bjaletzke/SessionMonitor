"""Bounded local readers and an in-memory analytical projection.

Only usage_events contains time-attributed consumption. Lifetime counters live
on chats and are never assigned to the day a chat was last active.
"""

from collections import Counter
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import time

from .selection import normalize_filters, select_chats
from .projects import git_project, project_metadata, harmonize_recorded_workspaces

MAX_FILE = 32 * 1024 * 1024
MAX_TEXT = 12000
MAX_MESSAGES = 20000
MAX_EVENTS = 50000
COUNTERS = ("input_tokens", "output_tokens", "cache_read_tokens",
            "cache_write_tokens", "reasoning_tokens", "total_tokens")
STAT_FIELDS = ("user_messages", "assistant_messages", "total_messages", "user_characters",
               "assistant_characters", "avg_user_characters", "avg_assistant_characters",
               "first_message_at", "last_message_at", "span_seconds", "message_coverage", "stats_partial")


def stamp(value):
    if value is None or value == "":
        return None
    try:
        if isinstance(value, (int, float)):
            value = datetime.fromtimestamp(value / 1000 if value > 1e11 else value, timezone.utc)
        else:
            value = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    except (ValueError, OverflowError, OSError):
        return None


def number(value):
    return value if type(value) is int and 0 <= value < 2**63 else None


def obj(value):
    if isinstance(value, dict):
        return value
    try:
        result = json.loads(value or "{}")
        return result if isinstance(result, dict) else {}
    except (ValueError, TypeError):
        return {}


def read_file(path):
    """Never block on a pipe/device, or read an unbounded transcript."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Not a regular file")
        data = source.read(MAX_FILE + 1)
        return data[:MAX_FILE], len(data) > MAX_FILE


@contextmanager
def provider_db(path):
    if not Path(path).is_file():
        raise ValueError("Database not found")
    db = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True, timeout=0.25)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    db.execute("BEGIN")
    try:
        yield db
    finally:
        db.close()


def rows(db, sql, args=()):
    return [dict(row) for row in db.execute(sql, args)]


def visible_text(content):
    """Extract only visible text blocks; never reasoning or tool payloads."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(block.get("text", "") for block in content
                         if isinstance(block, dict) and block.get("type") in ("text", "input_text", "output_text")
                         and isinstance(block.get("text"), str))
    return ""


class MessageStatistics:
    """Keep lengths and dates for logical messages, not their private text."""
    def __init__(self):
        self.messages = {}

    def add(self, mid, role, text, at):
        if role not in ("user", "assistant") or not isinstance(text, str) or not text.strip():
            return
        value = (role, len(text), stamp(at))
        old = self.messages.get(str(mid))
        if not old or value[1] >= old[1]:
            self.messages[str(mid)] = value

    def record(self, chat_id, coverage, partial=False):
        user = [value for value in self.messages.values() if value[0] == "user"]
        assistant = [value for value in self.messages.values() if value[0] == "assistant"]
        dates = [value[2] for value in self.messages.values() if value[2]]
        first, last = (min(dates), max(dates)) if dates else (None, None)
        span = (datetime.fromisoformat(last.replace("Z", "+00:00")) - datetime.fromisoformat(first.replace("Z", "+00:00"))).total_seconds() if first and len(dates) == len(self.messages) else None
        return dict(chat_id=chat_id, user_messages=len(user), assistant_messages=len(assistant),
                    total_messages=len(user) + len(assistant),
                    user_characters=sum(value[1] for value in user),
                    assistant_characters=sum(value[1] for value in assistant),
                    avg_user_characters=sum(value[1] for value in user) / len(user) if user else None,
                    avg_assistant_characters=sum(value[1] for value in assistant) / len(assistant) if assistant else None,
                    first_message_at=first, last_message_at=last, span_seconds=span,
                    message_coverage=coverage, stats_partial=int(partial))


def aggregate_statistics(chat_id, records, coverage):
    counts = {role: 0 for role in ("user", "assistant")}
    characters = dict(counts)
    dates = []
    partial = False
    for record in records:
        role = record["role"]
        counts[role] += record["message_count"] or 0
        characters[role] += record["characters"] or 0
        dates.extend(date for date in (stamp(record["first_at"]), stamp(record["last_at"])) if date)
        partial = partial or bool(record.get("partial"))
    first, last = (min(dates), max(dates)) if dates else (None, None)
    span = (datetime.fromisoformat(last.replace("Z", "+00:00")) - datetime.fromisoformat(first.replace("Z", "+00:00"))).total_seconds() if first else None
    return dict(chat_id=chat_id, user_messages=counts["user"], assistant_messages=counts["assistant"],
                total_messages=sum(counts.values()), user_characters=characters["user"],
                assistant_characters=characters["assistant"],
                avg_user_characters=characters["user"] / counts["user"] if counts["user"] else None,
                avg_assistant_characters=characters["assistant"] / counts["assistant"] if counts["assistant"] else None,
                first_message_at=first, last_message_at=last, span_seconds=span,
                message_coverage=coverage + (" Streaming or unreadable records make this partial." if partial else ""),
                stats_partial=int(partial))


class Warehouse:
    def __init__(self, paths=None, snapshots=(), limit=500, path_overrides=None):
        self.paths = paths if paths is not None else {
            "t3": Path(os.environ.get("T3CODE_HOME", "~/.t3")).expanduser(),
            "codex": Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser(),
            "claude": Path(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")).expanduser(),
            "hermes": Path(os.environ.get("HERMES_HOME", "~/.hermes")).expanduser(),
            "harness": Path(os.environ.get("SESSIONMONITOR_HARNESS_DIR",
                "~/Library/Application Support/SessionMonitor/events")).expanduser(),
        }
        self.paths.update({k: Path(v).expanduser() for k, v in (path_overrides or {}).items()})
        self.snapshots = snapshots
        self.limit = max(1, min(2000, limit))
        self.db = None
        self.refresh()

    def insert(self, table, **record):
        names = ",".join(record)
        self.db.execute(f"INSERT OR REPLACE INTO {table} ({names}) VALUES ({','.join('?' for _ in record)})",
                        list(record.values()))

    def refresh(self):
        old = self.db
        git_project.cache_clear()
        self.db = sqlite3.connect(":memory:")
        self.db.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, 1_000_000)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(Path(__file__).with_name("schema.sql").read_text())
        try:
            for kind, root in self.paths.items():
                self.connection(kind, root, getattr(self, "read_" + kind))
            for index, path in enumerate(self.snapshots):
                self.connection(f"snapshot-{index}", Path(path), self.read_snapshot)
            self.db.execute("UPDATE chats SET host_chat_id=(SELECT source_id FROM relationships WHERE target_id=chats.id AND kind='provider session') WHERE id IN (SELECT target_id FROM relationships WHERE kind='provider session')")
            harmonize_recorded_workspaces(self.db)
            # Prefer recorded T3 project titles across the same verified identity.
            self.db.execute("UPDATE chats SET project_name=COALESCE((SELECT t.project_name FROM chats t WHERE t.project_id=chats.project_id AND t.app='T3 Code' AND t.project_identity LIKE '%recorded T3 project%' AND t.project_name<>'Unknown project' ORDER BY t.updated_at DESC LIMIT 1),project_name)")
            self.db.execute("INSERT INTO conversation_stats(chat_id,message_coverage,stats_partial) SELECT id,'Full conversation history is unavailable; a latest-message preview is not a conversation count.',1 FROM chats WHERE id NOT IN (SELECT chat_id FROM conversation_stats)")
            self.db.commit()
        except Exception:
            self.db.close()
            self.db = old
            raise
        if old:
            old.close()
        self.refreshed_at = stamp(time.time())

    def connection(self, key, root, reader):
        self.db.execute("SAVEPOINT source")
        try:
            detail = reader(key, Path(root))
            status = "connected"
            self.db.execute("RELEASE source")
        except (OSError, ValueError, sqlite3.Error, TypeError, KeyError) as error:
            self.db.execute("ROLLBACK TO source")
            self.db.execute("RELEASE source")
            detail, status = str(error), "unavailable"
        count = self.db.execute("SELECT count(*) FROM chats WHERE connection_id=?", (key,)).fetchone()[0]
        self.insert("connections", id=key, name={"t3": "T3 Code", "codex": "Codex",
                    "claude": "Claude Code", "hermes": "Hermes", "harness": "Harness"}.get(key, "Snapshot"),
                    path=str(root), status=status, detail=detail, chat_count=count)

    def message(self, chat, mid, role, text, at, truncated=False):
        if role not in ("user", "assistant") or not isinstance(text, str) or not text.strip():
            return
        self.insert("messages", id=f"{chat}:{mid}", chat_id=chat, role=role,
                    text=text[:MAX_TEXT], recorded_at=stamp(at),
                    truncated=int(truncated or len(text) > MAX_TEXT))

    def chat(self, key, native, app, **values):
        cid = f"{key}:{native}"
        if not values.get("project_id"):
            values.update(project_metadata(values.get("workspace", "")))
        self.insert("chats", id=cid, connection_id=key, app=app, **values)
        if values.get("parent_id"):
            self.insert("relationships", source_id=cid, target_id=values["parent_id"],
                        kind=values.get("relationship") or "parent")
        return cid

    def read_t3(self, key, root):
        path = root / "userdata/statev2.sqlite" if (root / "userdata/statev2.sqlite").is_file() else root / "statev2.sqlite"
        prefix = "orchestration_v2_projection_"
        with provider_db(path) as db:
            chats = rows(db, f"SELECT thread_id,title,project_id,created_at,updated_at,archived_at,deleted_at,substr(payload_json,1,65536) payload_json FROM {prefix}threads WHERE deleted_at IS NULL ORDER BY updated_at DESC LIMIT ?", (self.limit,))
            tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            projects = {}
            if "projection_projects" in tables:
                project_columns = {row[1] for row in db.execute("PRAGMA table_info(projection_projects)")}
                name = "title" if "title" in project_columns else "name" if "name" in project_columns else "NULL"
                projects = {r["project_id"]: r for r in rows(db, f"SELECT project_id,workspace_root,{name} AS project_name FROM projection_projects")}
            loaded = []
            for row in chats:
                p = obj(row["payload_json"])
                if p.get("deletedAt"):
                    continue
                lineage = obj(p.get("lineage"))
                selection = obj(p.get("modelSelection"))
                project = projects.get(row["project_id"], {})
                workspace = p.get("worktreePath") or project.get("workspace_root", "")
                cid = self.chat(key, row["thread_id"], "T3 Code", title=row["title"],
                    model=selection.get("model", ""), provider=selection.get("instanceId", ""),
                    workspace=workspace,
                    created_at=stamp(row["created_at"]), updated_at=stamp(row["updated_at"]),
                    parent_id=f"{key}:{lineage['parentThreadId']}" if lineage.get("parentThreadId") else None,
                    relationship=lineage.get("relationshipToParent"),
                    is_subagent=int(lineage.get("relationshipToParent") == "subagent"), source_path=str(path),
                    coverage="T3 main-agent recorded turns; workers and inherited history may be absent.",
                    **project_metadata(workspace, recorded_id=row["project_id"],
                        recorded_name=project.get("project_name"), recorded_root=project.get("workspace_root"), namespace=str(path)))
                loaded.append(row["thread_id"])
            if not loaded:
                return "No chats found. Archived chats are included; deleted chats are excluded."
            placeholders = ",".join("?" for _ in loaded)
            messages = rows(db, f"SELECT message_id,thread_id,role,created_at,substr(json_extract(CASE WHEN json_valid(payload_json) THEN payload_json ELSE '{{}}' END,'$.text'),1,{MAX_TEXT+1}) text FROM {prefix}messages WHERE thread_id IN ({placeholders}) AND role IN ('user','assistant') ORDER BY created_at DESC LIMIT ?", (*loaded, MAX_MESSAGES+1))
            for m in messages[:MAX_MESSAGES]:
                self.message(f"{key}:{m['thread_id']}", m["message_id"], m["role"], m["text"], m["created_at"])
            message_columns = {row[1] for row in db.execute(f"PRAGMA table_info({prefix}messages)")}
            updated = "updated_at" if "updated_at" in message_columns else "created_at"
            streaming = "COALESCE(streaming,0)" if "streaming" in message_columns else "0"
            aggregates = rows(db, f"""WITH source AS (
                SELECT thread_id,role,created_at,{updated} AS last_at,
                    CASE WHEN json_valid(payload_json) THEN json_extract(payload_json,'$.text') END AS text,
                    CASE WHEN NOT json_valid(payload_json) THEN 1 ELSE {streaming} END AS partial
                FROM {prefix}messages WHERE thread_id IN ({placeholders}) AND role IN ('user','assistant')
            ) SELECT thread_id,role,
                SUM(CASE WHEN typeof(text)='text' AND trim(text)<>'' THEN 1 ELSE 0 END) AS message_count,
                SUM(CASE WHEN typeof(text)='text' AND trim(text)<>'' THEN length(text) ELSE 0 END) AS characters,
                MIN(CASE WHEN typeof(text)='text' AND trim(text)<>'' THEN created_at END) AS first_at,
                MAX(CASE WHEN typeof(text)='text' AND trim(text)<>'' THEN last_at END) AS last_at,
                MAX(partial) AS partial FROM source GROUP BY thread_id,role""", loaded)
            by_chat = {}
            for record in aggregates:
                by_chat.setdefault(record["thread_id"], []).append(record)
            for native in loaded:
                self.insert("conversation_stats", **aggregate_statistics(f"{key}:{native}", by_chat.get(native, []),
                    "All stored local T3 user/assistant text, independent of display sampling; inherited fork history may be absent."))
            available = {prefix + "provider_threads", prefix + "provider_turns"} <= tables
            events = []
            if available:
                events = rows(db, f"SELECT t.provider_turn_id,t.thread_id,substr(t.payload_json,1,65536) payload_json FROM {prefix}provider_turns t JOIN {prefix}provider_threads p ON p.provider_thread_id=t.provider_thread_id AND p.thread_id=t.thread_id WHERE p.owner_node_id IS NULL AND t.thread_id IN ({placeholders}) ORDER BY t.provider_turn_id LIMIT ?", (*loaded, MAX_EVENTS+1))
                for row in events[:MAX_EVENTS]:
                    p = obj(row["payload_json"])
                    u = obj(p.get("turnTokenUsage"))
                    if u.get("usageScope") != "main_agent" or u.get("usageStatus") not in ("complete", "partial"):
                        continue
                    values = dict(zip(COUNTERS[:-1], [number(u.get(f)) for f in
                        ("inputTokens", "outputTokens", "cachedInputTokens", "cacheCreationTokens", "reasoningTokens")]))
                    known = [values["input_tokens"], values["output_tokens"]]
                    if all(v is None for v in known):
                        continue
                    values["total_tokens"] = sum(v for v in known if v is not None)
                    # Context snapshots (tokenUsage/contextUsage) are intentionally ignored.
                    self.insert("usage_events", id=f"{key}:{row['provider_turn_id']}",
                        chat_id=f"{key}:{row['thread_id']}", recorded_at=stamp(p.get("completedAt")),
                        model=obj(p.get("modelSelection")).get("model"),
                        coverage=u["usageStatus"], **values)
                for cid in loaded:
                    self.db.execute("UPDATE chats SET " + ",".join(f"{c}=(SELECT sum({c}) FROM usage_events WHERE chat_id=chats.id)" for c in COUNTERS) + " WHERE id=?", (f"{key}:{cid}",))
                # Preserve exact native links. Ambiguous matches are left unlinked.
                owners = {}
                for row in rows(db, f"SELECT thread_id,substr(payload_json,1,65536) payload_json FROM {prefix}provider_threads WHERE owner_node_id IS NULL AND thread_id IN ({placeholders})", loaded):
                    ref = obj(obj(row["payload_json"]).get("nativeThreadRef"))
                    driver = {"claudeAgent": "claude", "claude-code": "claude"}.get(ref.get("driver"), ref.get("driver"))
                    if ref.get("strength") == "strong" and driver in ("codex", "claude") and ref.get("nativeId"):
                        owners.setdefault(f"{driver}:{ref['nativeId']}", set()).add(f"{key}:{row['thread_id']}")
                for native, hosts in owners.items():
                    if len(hosts) == 1:
                        self.insert("relationships", source_id=next(iter(hosts)), target_id=native, kind="provider session")
            clipped = len(messages) > MAX_MESSAGES or len(events) > MAX_EVENTS
            return (f"Latest {self.limit} chats, including archived. Up to {MAX_MESSAGES} messages and {MAX_EVENTS} turns. "
                    + ("Read limit reached. " if clipped else "")
                    + ("Recorded turn consumption; overlaps native provider records." if available else "Consumption tables unavailable; context snapshots excluded."))

    def read_codex(self, key, root):
        paths = sorted(root.glob("state_*.sqlite"), key=lambda p: int(p.stem.split("_")[-1]) if p.stem.split("_")[-1].isdigit() else -1)
        if not paths:
            raise ValueError("No Codex state_*.sqlite found")
        with provider_db(paths[-1]) as db:
            columns = {r[1] for r in db.execute("PRAGMA table_info(threads)")}
            wanted = [c for c in ("id", "title", "model", "model_provider", "cwd", "created_at", "updated_at", "tokens_used", "rollout_path") if c in columns]
            for r in rows(db, "SELECT " + ",".join(wanted) + " FROM threads ORDER BY updated_at DESC LIMIT ?", (self.limit,)):
                self.chat(key, r["id"], "Codex", title=r.get("title") or r["id"], model=r.get("model", ""),
                    provider=r.get("model_provider", ""), workspace=r.get("cwd", ""),
                    created_at=stamp(r.get("created_at")), updated_at=stamp(r.get("updated_at")),
                    total_tokens=number(r.get("tokens_used")), source_path=r.get("rollout_path"),
                    coverage="Index lifetime total; no daily attribution. Transcript content available through snapshot import.")
                if r.get("rollout_path"):
                    self.codex_transcript(f"{key}:{r['id']}", Path(r["rollout_path"]))
            if "thread_spawn_edges" in {r[0] for r in db.execute("SELECT name FROM sqlite_master")}:
                for r in rows(db, "SELECT parent_thread_id,child_thread_id FROM thread_spawn_edges LIMIT 4000"):
                    parent, child = f"{key}:{r['parent_thread_id']}", f"{key}:{r['child_thread_id']}"
                    self.db.execute("UPDATE chats SET parent_id=?,is_subagent=1,relationship='subagent' WHERE id=?", (parent, child))
                    self.insert("relationships", source_id=child, target_id=parent, kind="subagent")
        return f"Latest {self.limit} indexed chats, including archived. Lifetime totals can overlap forks and T3."

    def codex_transcript(self, cid, path):
        try:
            data, partial = read_file(path)
        except (OSError, ValueError):
            return  # Index counters remain useful; conversation statistics are unknown.
        events, responses = {}, {}
        usage, model, workspace = None, None, None
        invalid = 0
        for index, line in enumerate(data.splitlines()):
            if not line.strip():
                continue
            p = obj(line)
            if not p:
                invalid += 1
                continue
            payload = obj(p.get("payload"))
            at = p.get("timestamp")
            kind = payload.get("type")
            if p.get("type") == "event_msg" and kind in ("user_message", "agent_message"):
                role = "user" if kind == "user_message" else "assistant"
                text = payload.get("message")
                if isinstance(text, str) and text.strip():
                    mid = payload.get("message_id") or payload.get("id") or f"event-{index}"
                    events[str(mid)] = (role, text, at)
            if p.get("type") == "response_item" and kind == "message" and payload.get("channel") != "analysis":
                role, text = payload.get("role"), visible_text(payload.get("content"))
                if role in ("user", "assistant") and text.strip():
                    mid = payload.get("id") or f"response-{index}"
                    previous = responses.get(str(mid))
                    if not previous or len(text) >= len(previous[1]):
                        responses[str(mid)] = (role, text, at)
            if kind == "token_count":
                usage = obj(payload.get("info")).get("total_token_usage") or usage
            if p.get("type") == "token_usage_record":
                usage = payload.get("thread_token_usage") or usage
            if p.get("type") in ("session_meta", "turn_context"):
                workspace = payload.get("cwd") or workspace
            if p.get("type") == "turn_context":
                model = payload.get("model") or model
        # Histories can switch formats. Pair known mirrors one-to-one rather
        # than discarding every event of a role once one response item appears.
        response_roles = {message[0] for message in responses.values()}
        mirror_index = {}
        for response_id, (role, text, at) in responses.items():
            date = stamp(at)
            if date:
                instant = datetime.fromisoformat(date.replace("Z", "+00:00")).timestamp()
                mirror_index.setdefault((role, text.strip()), []).append((response_id, instant))
        paired, unmatched = set(), []
        unresolved = False
        for mid, event in events.items():
            role, text, at = event
            match = mid if mid in responses and responses[mid][0] == role and mid not in paired else None
            if match is None:
                event_date = stamp(at)
                candidates = []
                if event_date:
                    instant = datetime.fromisoformat(event_date.replace("Z", "+00:00")).timestamp()
                    for response_id, response_instant in mirror_index.get((role, text.strip()), []):
                        if response_id not in paired:
                            distance = abs(response_instant - instant)
                            if distance <= 30:
                                candidates.append((distance, response_id))
                if candidates:
                    candidates.sort()
                    match = candidates[0][1]
                    unresolved = unresolved or len(candidates) > 1
            if match is not None:
                paired.add(match)
                if len(text) > len(responses[match][1]):
                    responses[match] = event
            else:
                unmatched.append(("event:" + mid, *event))
                unresolved = unresolved or role in response_roles
        messages = [(mid, *message) for mid, message in responses.items()] + unmatched
        messages.sort(key=lambda record: stamp(record[3]) or "")
        statistics = MessageStatistics()
        for mid, role, text, at in messages:
            statistics.add(mid, role, text, at)
        coverage = "Visible Codex messages from the first 32 MiB; event/response mirrors paired by stable ID or matching text and nearby timestamp."
        if unresolved:
            coverage += " Mixed representations have unmatched or ambiguous entries; counts can include repeated recorded messages."
        self.insert("conversation_stats", **statistics.record(cid, coverage,
            partial=partial or bool(invalid) or unresolved))
        for mid, role, text, at in messages[-200:]:
            self.message(cid, mid, role, text, at)
        if isinstance(usage, dict) and not partial:
            values = dict(zip(COUNTERS, [number(usage.get(c)) for c in ("input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens", "reasoning_output_tokens", "total_tokens")]))
            for field, value in values.items():
                if value is not None:
                    self.db.execute(f"UPDATE chats SET {field}=? WHERE id=?", (value, cid))
        if workspace:
            old = self.db.execute("SELECT workspace FROM chats WHERE id=?", (cid,)).fetchone()[0]
            if not old:
                metadata = project_metadata(workspace)
                self.db.execute("UPDATE chats SET workspace=?," + ",".join(field + "=?" for field in metadata) + " WHERE id=?",
                                (workspace, *metadata.values(), cid))
        self.db.execute("UPDATE chats SET model=COALESCE(?,model),coverage=? WHERE id=?", (model,
            ("Transcript exceeds 32 MiB; sampled beginning, index total retained. " if partial else "Local index and transcript. ") + "Lifetime counters, no daily attribution; last 200 sampled text messages.", cid))

    def read_claude(self, key, root):
        if not (root / "projects").is_dir():
            raise ValueError("Claude projects folder not found")
        files = sorted((root / "projects").glob("*/*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)[:self.limit]
        for path in files:
            data, partial = read_file(path)
            records, seen, parts = {}, {}, {}
            invalid = 0
            cid = f"{key}:{path.stem}"
            title, model, workspace, created, updated = path.stem, "", "", None, None
            for index, line in enumerate(data.splitlines()):
                p = obj(line)
                if not p and line.strip():
                    invalid += 1
                m = obj(p.get("message"))
                role = m.get("role", p.get("type"))
                at = stamp(p.get("timestamp"))
                created, updated = created or at, at or updated
                workspace = p.get("cwd") or workspace
                model = m.get("model") or model
                text = visible_text(m.get("content", ""))
                if role == "user" and text and title == path.stem:
                    title = text[:140]
                if role in ("user", "assistant") and text:
                    mid = p.get("uuid") or f"record-{index}"
                    previous = records.get(mid)
                    if not previous or len(text) >= len(previous[1]):
                        records[mid] = (role, text, at)
                    logical = m.get("id") if role == "assistant" and m.get("id") else mid
                    fragments = parts.setdefault(logical, {})
                    if mid not in fragments or len(text) >= len(fragments[mid][1]):
                        fragments[mid] = (role, text, at)
                if role == "assistant" and m.get("id") and isinstance(m.get("usage"), dict):
                    uid, u = m["id"], m["usage"]
                    old = seen.get(uid, {})
                    fields = dict(zip(COUNTERS[:4], [number(u.get(f)) for f in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")]))
                    for c, value in fields.items():
                        if value is not None:
                            old[c] = max(old.get(c, 0), value)
                    old.update(recorded_at=at or old.get("recorded_at"), model=m.get("model"))
                    seen[uid] = old
            self.chat(key, path.stem, "Claude Code", title=title, model=model, workspace=workspace,
                created_at=created, updated_at=updated or stamp(path.stat().st_mtime), source_path=str(path),
                coverage="Partial first 32 MiB of transcript" if partial else "Local top-level transcript; subagents excluded")
            statistics = MessageStatistics()
            for logical, fragments in parts.items():
                values = list(fragments.values())
                texts = list(dict.fromkeys(value[1] for value in values))
                # Streaming revisions can repeat or extend a text block; retain
                # distinct blocks and discard superseded prefixes.
                texts = [text for text in texts if not any(other != text and other.startswith(text) for other in texts)]
                statistics.add(logical, values[0][0], "\n".join(texts), max((v[2] for v in values if v[2]), default=None))
            self.insert("conversation_stats", **statistics.record(cid,
                "Logical visible Claude messages from the first 32 MiB; assistant IDs deduplicate streaming updates; subagents excluded.",
                partial=partial or bool(invalid)))
            for mid, (role, text, at) in list(records.items())[-200:]:
                self.message(cid, mid, role, text, at)
            for uid, event in seen.items():
                event["total_tokens"] = sum(event[c] for c in COUNTERS[:4] if c in event) if any(c in event for c in COUNTERS[:4]) else None
                self.insert("usage_events", id=f"{cid}:{uid}", chat_id=cid,
                    coverage="partial" if partial or any(c not in event for c in COUNTERS[:4]) else "complete", **event)
            self.db.execute("UPDATE chats SET " + ",".join(f"{c}=(SELECT sum({c}) FROM usage_events WHERE chat_id=chats.id)" for c in COUNTERS) + " WHERE id=?", (cid,))
        return f"Latest {self.limit} top-level transcripts; first 32 MiB and last 200 text messages each. Message IDs deduplicate streaming usage; event date is observed message time."

    def read_hermes(self, key, root):
        profiles = [root] + sorted((root / "profiles").glob("*"))
        found = False
        for profile in profiles:
            path = profile / "state.db"
            if not path.is_file():
                continue
            found = True
            with provider_db(path) as db:
                cols = {r[1] for r in db.execute("PRAGMA table_info(sessions)")}
                fields = [c for c in ("id", "title", "model", "cwd", "git_repo_root", "started_at", "last_activity_at", "parent_session_id", *COUNTERS[:-1]) if c in cols]
                for r in rows(db, "SELECT " + ",".join(fields) + " FROM sessions ORDER BY started_at DESC LIMIT ?", (self.limit,)):
                    native = f"{profile.name}:{r['id']}"
                    values = {c: number(r.get(c)) for c in COUNTERS[:-1]}
                    values["total_tokens"] = (values["input_tokens"] + values["output_tokens"]) if values["input_tokens"] is not None and values["output_tokens"] is not None else None
                    cid = self.chat(key, native, "Hermes", title=r.get("title") or r["id"], model=r.get("model", ""),
                        workspace=r.get("cwd") or r.get("git_repo_root", ""), created_at=stamp(r.get("started_at")), updated_at=stamp(r.get("last_activity_at") or r.get("started_at")),
                        parent_id=f"{key}:{profile.name}:{r['parent_session_id']}" if r.get("parent_session_id") else None,
                        source_path=str(path), coverage="Lifetime input + output; cache counters separate, no daily attribution", **values)
                    mcols = {r[1] for r in db.execute("PRAGMA table_info(messages)")}
                    if {"id", "session_id", "role", "content", "timestamp"} <= mcols:
                        visible = " AND COALESCE(active,1)=1" if "active" in mcols else ""
                        if "display_kind" in mcols:
                            visible += " AND COALESCE(display_kind,'')<>'hidden'"
                        for m in rows(db, f"SELECT id,role,substr(content,1,{MAX_TEXT+1}) content,timestamp FROM messages WHERE session_id=? AND role IN ('user','assistant'){visible} ORDER BY id DESC LIMIT 200", (r["id"],)):
                            self.message(cid, m["id"], m["role"], m["content"], m["timestamp"])
                        logical = "COALESCE(NULLIF(message_uid,''),CAST(id AS TEXT))" if "message_uid" in mcols else "id"
                        statistics = MessageStatistics()
                        for m in db.execute(f"SELECT {logical} AS message_key,role,content,timestamp FROM messages WHERE session_id=? AND role IN ('user','assistant'){visible} ORDER BY id", (r["id"],)):
                            text = m["content"]
                            if isinstance(text, str) and text.lstrip().startswith("["):
                                try:
                                    blocks = json.loads(text)
                                    if isinstance(blocks, list) and blocks and all(isinstance(block, dict) and "type" in block for block in blocks):
                                        text = visible_text(blocks)
                                except ValueError:
                                    pass
                            statistics.add(m["message_key"], m["role"], text, m["timestamp"])
                        self.insert("conversation_stats", **statistics.record(cid,
                            "All stored visible active Hermes user/assistant text, independent of the last-200 display sample; inactive and hidden records excluded."))
        if not found:
            raise ValueError("No Hermes root or profile state.db found")
        return f"Latest {self.limit} chats per profile; up to 200 messages each. Lifetime counters overlap continuations."

    def read_harness(self, key, root):
        if not root.is_dir():
            raise ValueError("Harness reports folder not found")
        for path in sorted(root.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)[:self.limit]:
            data, partial = read_file(path)
            if partial:
                raise ValueError("Harness report exceeds 32 MiB")
            p = obj(data)
            if not p.get("session_id"):
                continue
            u = obj(p.get("usage"))
            cid = self.chat(key, f"{p.get('namespace', 'default')}:{p['session_id']}", "Harness",
                title=p.get("title") or p["session_id"], model=p.get("model", ""), provider=p.get("provider", ""),
                workspace=p.get("cwd", ""), updated_at=stamp(p.get("observed_at")), source_path=str(path),
                coverage="Harness-reported cumulative counters; semantics defined by reporter",
                **{c: number(u.get(c)) for c in COUNTERS})
            m = obj(p.get("last_message"))
            self.message(cid, "latest", m.get("role", "assistant"), m.get("text"), m.get("recorded_at"))
        return f"Latest {self.limit} reports using the existing report_session.py contract."

    def read_snapshot(self, key, path):
        data, clipped = read_file(path)
        if clipped:
            raise ValueError("Snapshot exceeds 32 MiB")
        records = json.loads(data)
        if not isinstance(records, list):
            raise ValueError("Expected a --snapshot JSON array")
        for r in records[:self.limit]:
            u = obj(r.get("usage"))
            cid = self.chat(key, r["id"], r.get("app", "Snapshot"), title=r.get("title", r["id"]),
                model=r.get("model", ""), provider=r.get("provider", ""), workspace=r.get("workspace", ""),
                updated_at=stamp(r.get("updatedAt")), is_subagent=int(bool(r.get("isSubagent"))),
                parent_id=f"{key}:{r['parentKey']}" if r.get("parentKey") else None,
                source_path=str(path), coverage="Snapshot cumulative counters; " + u.get("coverage", "unavailable"),
                **dict(zip(COUNTERS, [number(u.get(c)) for c in ("input", "output", "cacheRead", "cacheWrite", "reasoning", "total")])))
            m = obj(r.get("lastMessage"))
            self.message(cid, "latest", m.get("role"), m.get("text"), m.get("recordedAt"), m.get("truncated", False))
            for link in r.get("relations", []):
                self.insert("relationships", source_id=cid, target_id=f"{key}:{link['id']}", kind=link["kind"])
        return f"Existing Swift --snapshot interface, up to {self.limit} records. Separate scope; may duplicate direct connections."

    def scope(self, filters=None):
        filters = normalize_filters(filters)
        matches = rows(self.db, "SELECT DISTINCT chat_id FROM messages WHERE instr(lower(text),lower(?))>0", (filters["q"],)) if filters["q"] else []
        selection = select_chats(self.enriched_chats(),
                                 rows(self.db, "SELECT * FROM relationships"), filters,
                                 (row["chat_id"] for row in matches))
        ids = {chat["id"] for chat in selection["chats"]}
        selection["events"] = [event for event in rows(self.db, "SELECT * FROM usage_events")
                               if event["chat_id"] in ids and (not selection["start"] or
                                   (event["recorded_at"] and event["recorded_at"] >= selection["start"]))]
        counts = Counter(chat["connection_id"] for chat in selection["chats"])
        selection["connections"] = [{**connection, "selected_count": counts[connection["id"]]}
                                     for connection in rows(self.db, "SELECT * FROM connections")
                                     if filters["connection"] in ("all", connection["id"])]
        selection["filters"] = filters
        return selection

    def enriched_chats(self):
        return rows(self.db, "SELECT c.*," + ",".join("s." + field for field in STAT_FIELDS)
                    + " FROM chats c LEFT JOIN conversation_stats s ON s.chat_id=c.id")

    @contextmanager
    def query_scope(self, filters):
        selection = self.scope(filters)
        views = ("chats", "messages", "usage_events", "relationships", "connections", "conversation_stats")
        self.db.execute("CREATE TEMP TABLE _scope_chat_ids(id TEXT PRIMARY KEY)")
        self.db.execute("CREATE TEMP TABLE _scope_event_ids(id TEXT PRIMARY KEY)")
        self.db.execute("CREATE TEMP TABLE _scope_connection_ids(id TEXT PRIMARY KEY)")
        self.db.execute("CREATE TEMP TABLE _scope_relationships(source_id TEXT,target_id TEXT,kind TEXT)")
        try:
            for table, records in (("_scope_chat_ids", selection["chats"]),
                                   ("_scope_event_ids", selection["events"]),
                                   ("_scope_connection_ids", selection["connections"])):
                self.db.executemany(f"INSERT INTO {table} VALUES(?)", ((record["id"],) for record in records))
            self.db.execute("CREATE TEMP VIEW chats AS SELECT c.*," + ",".join("s." + field for field in STAT_FIELDS)
                + " FROM main.chats c JOIN _scope_chat_ids selected ON selected.id=c.id LEFT JOIN main.conversation_stats s ON s.chat_id=c.id")
            self.db.execute("CREATE TEMP VIEW messages AS SELECT m.* FROM main.messages m JOIN _scope_chat_ids s ON s.id=m.chat_id")
            self.db.execute("CREATE TEMP VIEW usage_events AS SELECT e.* FROM main.usage_events e JOIN _scope_event_ids s ON s.id=e.id")
            self.db.execute("CREATE TEMP VIEW connections AS SELECT c.* FROM main.connections c JOIN _scope_connection_ids s ON s.id=c.id")
            self.db.execute("CREATE TEMP VIEW conversation_stats AS SELECT c.* FROM main.conversation_stats c JOIN _scope_chat_ids s ON s.id=c.chat_id")
            self.db.executemany("INSERT INTO _scope_relationships VALUES(?,?,?)", ((r["source_id"],r["target_id"],r["kind"]) for r in selection["relationships"]))
            self.db.execute("CREATE TEMP VIEW relationships AS SELECT * FROM _scope_relationships")
            yield selection
        finally:
            for view in views:
                self.db.execute(f"DROP VIEW IF EXISTS temp.{view}")
            for table in ("_scope_chat_ids", "_scope_event_ids", "_scope_connection_ids", "_scope_relationships"):
                self.db.execute(f"DROP TABLE temp.{table}")

    def query(self, sql, filters=None):
        if filters is not None:
            with self.query_scope(filters):
                return self._query(sql, scoped=True)
        return self._query(sql)

    def _query(self, sql, scoped=False):
        if not isinstance(sql, str) or len(sql) > 20000:
            raise ValueError("Query must be text under 20,000 characters")
        allowed = {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION, sqlite3.SQLITE_RECURSIVE}
        deadline = time.monotonic() + 2
        def authorize(action, table, column, database, source):
            if action not in allowed:
                return sqlite3.SQLITE_DENY
            if scoped and action == sqlite3.SQLITE_READ and database == "main" and source not in ("chats", "messages", "usage_events", "relationships", "connections", "conversation_stats"):
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK
        self.db.set_authorizer(authorize)
        self.db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
        try:
            cursor = self.db.execute(sql)
            result, output_size, truncated, cells_truncated = [], 0, False, False
            for row in cursor:
                if len(result) == 500:
                    truncated = True
                    break
                values = []
                for value in row:
                    if isinstance(value, bytes):
                        value = value.hex()
                    if isinstance(value, str) and len(value) > 32000:
                        value = value[:32000] + " [truncated]"
                        cells_truncated = True
                    values.append(value)
                output_size += len(json.dumps(values).encode())
                if output_size > 4 * 1024 * 1024:
                    truncated = True
                    break
                result.append(values)
            return {"columns": [c[0] for c in cursor.description or []],
                    "rows": result, "truncated": truncated, "cells_truncated": cells_truncated}
        finally:
            self.db.set_authorizer(None)
            self.db.set_progress_handler(None, 0)

    def payload(self):
        return {"refreshed_at": self.refreshed_at,
                "chats": self.enriched_chats(),
                **{table: rows(self.db, f"SELECT * FROM {table}") for table in ("connections", "relationships")}}

    def detail(self, cid):
        messages = rows(self.db, "SELECT * FROM messages WHERE chat_id=? ORDER BY recorded_at,id", (cid,))
        # Frequency is a deterministic description of sampled text, never a quality score.
        stop = set("about after again also been before being could from have into just like more only other should some than that their them then there these they this those through very want were what when where which while will with would your user assistant please using need make work file code don't does it's".split())
        words = Counter(w for m in messages if m["role"] == "user" for w in re.findall(r"[a-z][a-z0-9_-]{3,}", m["text"].lower()) if w not in stop)
        return {"messages": messages, "terms": words.most_common(16),
                "stats": next(iter(rows(self.db, "SELECT * FROM conversation_stats WHERE chat_id=?", (cid,))), None),
                "project": next(iter(rows(self.db, "SELECT project_id,project_name,project_path,project_identity FROM chats WHERE id=?", (cid,))), None),
                "usage_events": rows(self.db, "SELECT * FROM usage_events WHERE chat_id=? ORDER BY recorded_at", (cid,))}
