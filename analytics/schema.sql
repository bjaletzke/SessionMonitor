CREATE TABLE connections (
    id TEXT PRIMARY KEY, name TEXT, path TEXT, status TEXT, detail TEXT,
    chat_count INTEGER DEFAULT 0
);
CREATE TABLE chats (
    id TEXT PRIMARY KEY, connection_id TEXT, app TEXT, title TEXT, model TEXT,
    provider TEXT, workspace TEXT, created_at TEXT, updated_at TEXT,
    parent_id TEXT, relationship TEXT, host_chat_id TEXT, is_subagent INTEGER DEFAULT 0,
    input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
    cache_write_tokens INTEGER, reasoning_tokens INTEGER, total_tokens INTEGER,
    coverage TEXT, source_path TEXT,
    project_id TEXT, project_name TEXT, project_path TEXT, project_identity TEXT
);
CREATE TABLE messages (
    id TEXT PRIMARY KEY, chat_id TEXT, role TEXT, text TEXT, recorded_at TEXT,
    truncated INTEGER DEFAULT 0
);
CREATE TABLE usage_events (
    id TEXT PRIMARY KEY, chat_id TEXT, recorded_at TEXT, model TEXT,
    input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
    cache_write_tokens INTEGER, reasoning_tokens INTEGER, total_tokens INTEGER,
    coverage TEXT
);
CREATE TABLE relationships (source_id TEXT, target_id TEXT, kind TEXT,
    PRIMARY KEY (source_id, target_id, kind));
CREATE TABLE conversation_stats (
    chat_id TEXT PRIMARY KEY, user_messages INTEGER, assistant_messages INTEGER,
    total_messages INTEGER, user_characters INTEGER, assistant_characters INTEGER,
    avg_user_characters REAL, avg_assistant_characters REAL,
    first_message_at TEXT, last_message_at TEXT, span_seconds REAL,
    message_coverage TEXT, stats_partial INTEGER
);
CREATE INDEX messages_chat ON messages(chat_id, recorded_at);
CREATE INDEX events_chat ON usage_events(chat_id, recorded_at);
CREATE INDEX chats_connection ON chats(connection_id);
