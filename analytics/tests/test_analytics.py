import hashlib
from http.client import HTTPConnection
from http.server import HTTPServer
import json
import os
from pathlib import Path
import queue
import sqlite3
import tempfile
import threading
import unittest

from analytics.data import Warehouse, read_file
from analytics.server import handler_for


AT = "2026-11-01T12:00:00Z"


def t3_fixture(root):
    root.mkdir(exist_ok=True)
    path = root / "statev2.sqlite"
    db = sqlite3.connect(path)
    prefix = "orchestration_v2_projection_"
    db.executescript(f"""
        CREATE TABLE {prefix}threads(thread_id TEXT,title TEXT,project_id TEXT,created_at TEXT,updated_at TEXT,archived_at TEXT,deleted_at TEXT,payload_json TEXT);
        CREATE TABLE {prefix}messages(message_id TEXT,thread_id TEXT,role TEXT,created_at TEXT,payload_json TEXT);
        CREATE TABLE {prefix}provider_threads(provider_thread_id TEXT,thread_id TEXT,owner_node_id TEXT,payload_json TEXT);
        CREATE TABLE {prefix}provider_turns(provider_turn_id TEXT,provider_thread_id TEXT,thread_id TEXT,payload_json TEXT);
    """)
    for cid, lineage, deleted, archived in (("main", {}, None, None), ("child", {"parentThreadId":"main", "relationshipToParent":"subagent"}, None, None), ("old", {}, None, AT), ("gone", {}, AT, None)):
        db.execute(f"INSERT INTO {prefix}threads VALUES(?,?,?,?,?,?,?,?)", (cid,"Synthetic " + cid,"project",AT,AT,archived,deleted,json.dumps({"lineage":lineage,"modelSelection":{"model":"test-model"},"worktreePath":"/example"})))
    for mid, role, text in (("u", "user", "Please compare testing testing analytics"), ("a", "assistant", "<script>unsafe()</script>"), ("hidden", "tool", "private tool output")):
        db.execute(f"INSERT INTO {prefix}messages VALUES(?,?,?,?,?)", (mid,"main",role,AT,json.dumps({"text":text})))
    ref = {"nativeThreadRef":{"strength":"strong","driver":"codex","nativeId":"native"}}
    db.execute(f"INSERT INTO {prefix}provider_threads VALUES(?,?,?,?)", ("provider-main","main",None,json.dumps(ref)))
    db.execute(f"INSERT INTO {prefix}provider_threads VALUES(?,?,?,?)", ("worker","main","worker",'{}'))
    usage = {"inputTokens":100,"outputTokens":20,"cachedInputTokens":60,"cacheCreationTokens":10,"reasoningTokens":5,"usageScope":"main_agent","usageStatus":"complete"}
    for tid, provider, payload in (("turn", "provider-main", {"turnTokenUsage":usage,"completedAt":AT}),
                                   ("active", "provider-main", {"tokenUsage":{"usedTokens":9000}}),
                                   ("worker-turn", "worker", {"turnTokenUsage":usage,"completedAt":AT})):
        db.execute(f"INSERT INTO {prefix}provider_turns VALUES(?,?,?,?)", (tid,provider,"main",json.dumps(payload)))
    db.commit(); db.close()
    return path


class DataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_t3_consumption_and_source_bytes_unchanged(self):
        path = t3_fixture(self.root)
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        w = Warehouse(paths={"t3":self.root})
        chats = {r["id"]:r for r in w.payload()["chats"]}
        self.assertEqual(set(chats), {"t3:main","t3:child","t3:old"})
        main = chats["t3:main"]
        self.assertEqual(main["total_tokens"],120)
        self.assertEqual(main["cache_read_tokens"],60)
        self.assertIsNone(chats["t3:old"]["total_tokens"])
        self.assertEqual(chats["t3:child"]["parent_id"],"t3:main")
        self.assertEqual(chats["t3:child"]["is_subagent"],1)
        detail = w.detail("t3:main")
        self.assertEqual(len(detail["usage_events"]),1)
        self.assertEqual(detail["usage_events"][0]["recorded_at"],AT)
        self.assertEqual({m["role"] for m in detail["messages"]},{"user","assistant"})
        self.assertIn(("testing",2),detail["terms"])
        w.refresh()
        self.assertEqual(w.db.execute("SELECT count(*) FROM usage_events").fetchone()[0],1)
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),before)

    def test_missing_and_partial_t3_usage_stays_distinct_from_zero(self):
        path = t3_fixture(self.root)
        with sqlite3.connect(path) as db:
            db.execute("UPDATE orchestration_v2_projection_provider_turns SET payload_json=? WHERE provider_turn_id='turn'", (json.dumps({"turnTokenUsage":{"inputTokens":0,"usageStatus":"partial","usageScope":"main_agent"}}),))
        w = Warehouse(paths={"t3":self.root})
        event = w.detail("t3:main")["usage_events"][0]
        self.assertEqual(event["total_tokens"],0)
        self.assertIsNone(event["output_tokens"])
        self.assertIsNone(event["recorded_at"])
        self.assertEqual(event["coverage"],"partial")

    def test_claude_streaming_usage_deduplicates_by_message_id(self):
        folder = self.root / "projects/project"; folder.mkdir(parents=True)
        records = [{"type":"user","uuid":"u","timestamp":AT,"cwd":"/example", "message":{"role":"user","content":"Investigate caches"}}]
        for output in (5,20):
            records.append({"type":"assistant","uuid":"a","timestamp":AT,"message":{"id":"same","role":"assistant","model":"claude-test","content":[{"type":"text","text":"Answer"},{"type":"thinking","thinking":"secret"}],"usage":{"input_tokens":10,"output_tokens":output,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}})
        (folder / "chat.jsonl").write_text("\n".join(json.dumps(r) for r in records))
        w = Warehouse(paths={"claude":self.root})
        chat = w.payload()["chats"][0]
        self.assertEqual(chat["total_tokens"],100)
        detail = w.detail(chat["id"])
        self.assertEqual(len(detail["usage_events"]),1)
        self.assertEqual(len(detail["messages"]),2)
        self.assertNotIn("secret",str(detail))

    def test_codex_lifetime_counters_are_not_daily_events_and_link_to_t3(self):
        t3_fixture(self.root)
        with sqlite3.connect(self.root / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads(id,title,model,cwd,created_at,updated_at,tokens_used,rollout_path)")
            db.execute("INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)", ("native","Native chat","test","/example",1,2,500,None))
        w = Warehouse(paths={"t3":self.root,"codex":self.root})
        native = next(r for r in w.payload()["chats"] if r["id"] == "codex:native")
        self.assertEqual(native["total_tokens"],500)
        self.assertEqual(native["host_chat_id"],"t3:main")
        self.assertEqual(w.detail("codex:native")["usage_events"],[])

    def test_snapshot_preserves_provider_semantics_and_import_is_repeatable(self):
        path = self.root / "snapshot.json"
        path.write_text(json.dumps([{"id":"codex:one","app":"Codex","title":"Saved","updatedAt":AT,
            "usage":{"input":100,"output":20,"cacheRead":60,"reasoning":5,"total":120},
            "lastMessage":{"role":"assistant","text":"Saved reply","recordedAt":AT}}]))
        w = Warehouse(paths={},snapshots=[path])
        self.assertEqual(w.payload()["chats"][0]["total_tokens"],120)
        self.assertEqual(len(w.detail("snapshot-0:codex:one")["messages"]),1)
        w.refresh()
        self.assertEqual(len(w.payload()["chats"]),1)
        self.assertEqual(w.db.execute("SELECT count(*) FROM usage_events").fetchone()[0],0)

    def test_harness_existing_reporter_contract(self):
        from script.report_session import report_session
        report_session("one",directory=self.root,title="Harness test",state="ended",
                       usage={"input_tokens":2,"output_tokens":3,"total_tokens":5}, last_message="Result")
        w = Warehouse(paths={"harness":self.root})
        chat = w.payload()["chats"][0]
        self.assertEqual(chat["total_tokens"],5)
        self.assertEqual(w.detail(chat["id"])["messages"][0]["text"],"Result")

    def test_codex_transcript_counters_and_text_exclude_reasoning(self):
        rollout = self.root / "rollout.jsonl"
        records = [
            {"type":"event_msg","timestamp":AT,"payload":{"type":"user_message","message":"Check this"}},
            {"type":"response_item","timestamp":AT,"payload":{"type":"reasoning","text":"secret reasoning"}},
            {"type":"token_usage_record","payload":{"thread_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120,"cached_input_tokens":60,"reasoning_output_tokens":5}}},
        ]
        rollout.write_text("\n".join(json.dumps(r) for r in records))
        with sqlite3.connect(self.root / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads(id,title,updated_at,tokens_used,rollout_path)")
            db.execute("INSERT INTO threads VALUES(?,?,?,?,?)", ("native","Synthetic",1,500,str(rollout)))
        w = Warehouse(paths={"codex":self.root})
        chat=w.payload()["chats"][0]
        self.assertEqual(chat["total_tokens"],120)
        self.assertEqual(chat["cache_read_tokens"],60)
        self.assertEqual(len(w.detail(chat["id"])["messages"]),1)
        self.assertNotIn("secret reasoning",str(w.detail(chat["id"])))

    def test_hermes_lifetime_semantics_and_profile_identity(self):
        for profile in (self.root,self.root / "profiles/other"):
            profile.mkdir(parents=True,exist_ok=True)
            with sqlite3.connect(profile / "state.db") as db:
                db.execute("CREATE TABLE sessions(id,title,started_at,input_tokens,output_tokens,cache_read_tokens,reasoning_tokens,parent_session_id)")
                db.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?)", ("one","Hermes test",1,100,20,60,5,"parent"))
                db.execute("CREATE TABLE messages(id,session_id,role,content,timestamp)")
                db.execute("INSERT INTO messages VALUES(?,?,?,?,?)", (1,"one","assistant","Stored text",2))
        w=Warehouse(paths={"hermes":self.root})
        self.assertEqual(len(w.payload()["chats"]),2)
        self.assertEqual(len({c["id"] for c in w.payload()["chats"]}),2)
        for chat in w.payload()["chats"]:
            self.assertEqual(chat["total_tokens"],120)
            self.assertEqual(w.detail(chat["id"])["messages"][0]["text"],"Stored text")
            self.assertEqual(w.detail(chat["id"])["usage_events"],[])

    def test_queries_read_only_bounded_and_recover_after_rejection(self):
        w = Warehouse(paths={})
        for sql in ("DELETE FROM chats", "ATTACH DATABASE '/tmp/forbidden' AS external", "PRAGMA query_only=OFF", "CREATE TABLE extra(x)", "SELECT 1; SELECT 2"):
            with self.subTest(sql=sql), self.assertRaises(sqlite3.Error):
                w.query(sql)
        self.assertEqual(w.query("WITH a(x) AS (SELECT 42) SELECT * FROM a")["rows"],[[42]])
        self.assertEqual(w.query("SELECT zeroblob(2)")["rows"],[["0000"]])
        result = w.query("WITH RECURSIVE a(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM a WHERE x<1000) SELECT x FROM a")
        self.assertEqual(len(result["rows"]),500)
        self.assertTrue(result["truncated"])
        with self.assertRaises(sqlite3.Error):
            w.query("SELECT randomblob(2000000)")
        cell = w.query("SELECT hex(zeroblob(20000))")
        self.assertTrue(cell["cells_truncated"])
        self.assertIn("[truncated]",cell["rows"][0][0])
        self.assertEqual(w.query("SELECT count(*) FROM chats")["rows"],[[0]])

    def test_recursive_query_timeout_preserves_next_query(self):
        w=Warehouse(paths={})
        with self.assertRaisesRegex(sqlite3.Error,"interrupted"):
            w.query("WITH RECURSIVE a(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM a) SELECT sum(x) FROM a")
        self.assertEqual(w.query("SELECT 1")["rows"],[[1]])

    def test_source_failure_isolated_and_fifo_does_not_block(self):
        t3_fixture(self.root)
        w = Warehouse(paths={"codex":self.root / "missing","t3":self.root})
        states = {r["id"]:r["status"] for r in w.payload()["connections"]}
        self.assertEqual(states,{"codex":"unavailable","t3":"connected"})
        fifo = self.root / "pipe"; os.mkfifo(fifo)
        with self.assertRaises(ValueError):
            read_file(fifo)

    def test_combined_selection_groups_exact_identities_with_native_fallback(self):
        t3_fixture(self.root)
        with sqlite3.connect(self.root / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads(id,title,model,model_provider,updated_at,tokens_used)")
            db.execute("INSERT INTO threads VALUES(?,?,?,?,?,?)", ("native","Native copy","test-model","openai",1,500))
            db.execute("INSERT INTO threads VALUES(?,?,?,?,?,?)", ("independent","Independent chat","another-model","other-provider",1,900))
        w = Warehouse(paths={"t3":self.root,"codex":self.root})
        combined = w.scope({"days":0})
        self.assertEqual({r["id"] for r in combined["chats"]},{"t3:main","t3:old","codex:independent"})
        self.assertEqual(combined["summary"]["grouped_records"],1)
        self.assertEqual(sum(c["total_tokens"] or 0 for c in combined["chats"]),1020)
        self.assertEqual(len(w.scope({"days":0,"merge_copies":False})["chats"]),4)
        self.assertEqual(len(w.scope({"days":0,"connection":"codex"})["chats"]),2)
        self.assertEqual(w.scope({"days":0,"provider":"openai"})["chats"][0]["id"],"codex:native")
        self.assertEqual(w.scope({"days":0,"model":"another-model"})["chats"][0]["id"],"codex:independent")
        w.db.execute("DELETE FROM usage_events WHERE chat_id='t3:main'")
        w.db.execute("UPDATE chats SET total_tokens=NULL WHERE id='t3:main'")
        fallback = {r["id"] for r in w.scope({"days":0})["chats"]}
        self.assertIn("codex:native",fallback)
        self.assertNotIn("t3:main",fallback)

    def test_filtered_query_tables_match_scope_and_restore_after_failure(self):
        t3_fixture(self.root)
        w = Warehouse(paths={"t3":self.root})
        filters={"days":0,"q":"testing","model":"test-model"}
        scope=w.scope(filters)
        self.assertEqual(len(scope["chats"]),1)
        self.assertEqual(w.query("SELECT count(*) FROM chats",filters)["rows"],[[1]])
        self.assertEqual(w.query("SELECT count(*) FROM messages",filters)["rows"],[[2]])
        self.assertEqual(w.query("SELECT count(*) FROM usage_events",filters)["rows"],[[1]])
        self.assertEqual(w.query("SELECT count(*) FROM connections",filters)["rows"],[[1]])
        self.assertEqual(w.query("SELECT count(*) FROM relationships",filters)["rows"],[[len(scope["relationships"])]])
        with self.assertRaises(sqlite3.Error):
            w.query("SELECT * FROM main.chats",filters)
        with self.assertRaises(sqlite3.Error):
            w.query("DELETE FROM chats",filters)
        self.assertEqual(w.query("SELECT count(*) FROM chats")["rows"],[[3]])
        self.assertEqual(w.query("SELECT count(*) FROM chats",{"days":0,"model":"absent"})["rows"],[[0]])

    def test_filtered_dates_workers_snapshots_and_ambiguous_identity(self):
        t3_fixture(self.root)
        w=Warehouse(paths={"t3":self.root})
        w.db.execute("UPDATE chats SET updated_at='1900-01-01T00:00:00Z' WHERE id='t3:old'")
        w.db.execute("UPDATE chats SET updated_at='2999-01-01T00:00:00Z' WHERE id='t3:main'")
        w.db.execute("UPDATE usage_events SET recorded_at='1900-01-01T00:00:00Z'")
        self.assertEqual([c["id"] for c in w.scope({"days":1})["chats"]],["t3:main"])
        self.assertEqual(w.scope({"days":1})["events"],[])
        self.assertEqual(len(w.scope({"days":0,"include_subagents":True})["chats"]),3)
        w.insert("chats",id="snapshot-0:t3:main",connection_id="snapshot-0",app="T3 Code",is_subagent=0,total_tokens=120)
        self.assertEqual(len(w.scope({"days":0})["chats"]),2)
        self.assertEqual(len(w.scope({"days":0,"merge_copies":False})["chats"]),3)
        # Ambiguous native ownership must never collapse two host conversations.
        w.insert("chats",id="codex:native",connection_id="codex",app="Codex",is_subagent=0,total_tokens=300)
        w.insert("relationships",source_id="t3:old",target_id="codex:native",kind="provider session")
        self.assertEqual(len(w.scope({"days":0})["chats"]),3)

    def test_invalid_global_filters_are_rejected(self):
        w=Warehouse(paths={})
        for filters in ([],{"days":-1},{"days":"7"},{"include_subagents":"false"},{"model":[]},{"q":"x"*501}):
            with self.subTest(filters=filters),self.assertRaises(ValueError):
                w.scope(filters)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.ready = queue.Queue()
        def serve():
            warehouse = Warehouse(paths={})
            server = HTTPServer(("127.0.0.1",0), handler_for(warehouse))
            self.ready.put(server)
            try:
                server.serve_forever(poll_interval=0.02)
            finally:
                server.server_close(); warehouse.db.close()
        self.thread = threading.Thread(target=serve)
        self.thread.start(); self.server = self.ready.get(timeout=5)
        self.addCleanup(self.stop)

    def stop(self):
        self.server.shutdown(); self.thread.join(timeout=5)

    def request(self, method, path, body=None, headers=None):
        client = HTTPConnection("127.0.0.1",self.server.server_port,timeout=5)
        client.request(method,path,body=body,headers=headers or {})
        response = client.getresponse()
        result = response.status, response.read(), dict(response.getheaders())
        client.close(); return result

    def test_workspace_and_query_api(self):
        status,body,headers = self.request("GET","/")
        self.assertEqual(status,200); self.assertIn(b"Chat analytics",body)
        self.assertIn("frame-ancestors 'none'",headers["Content-Security-Policy"])
        status,body,_ = self.request("POST","/api/query",json.dumps({"sql":"SELECT 42 AS answer"}),{"Content-Type":"application/json"})
        self.assertEqual(status,200); self.assertEqual(json.loads(body)["rows"],[[42]])
        self.assertEqual(self.request("POST","/api/refresh","{}",{"Content-Type":"application/json"})[0],200)
        status,body,_=self.request("POST","/api/scope",json.dumps({"filters":{"days":0}}),{"Content-Type":"application/json"})
        self.assertEqual(status,200); self.assertEqual(json.loads(body)["summary"]["selected_chats"],0)

    def test_reject_foreign_origin_host_and_non_json(self):
        self.assertEqual(self.request("GET","/api/data",headers={"Host":"foreign.example"})[0],403)
        self.assertEqual(self.request("GET","/api/data",headers={"Origin":"https://foreign.example"})[0],403)
        self.assertEqual(self.request("POST","/api/query","sql=SELECT+1",{"Content-Type":"application/x-www-form-urlencoded"})[0],400)
        self.assertEqual(self.request("POST","/api/query","[]",{"Content-Type":"application/json"})[0],400)
        self.assertEqual(self.request("GET","/../data.py")[0],404)


if __name__ == "__main__":
    unittest.main()
