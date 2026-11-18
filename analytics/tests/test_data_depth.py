import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from analytics.data import Warehouse
from analytics.projects import project_metadata
from analytics.tests.test_analytics import AT, t3_fixture


class DataDepthTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def test_t3_statistics_are_independent_of_preview_count_and_text_limits(self):
        path=t3_fixture(self.root)
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE projection_projects(project_id,title,workspace_root)")
            db.execute("INSERT INTO projection_projects VALUES('project','Recorded project name','/example')")
            db.execute("ALTER TABLE orchestration_v2_projection_messages ADD COLUMN streaming INTEGER DEFAULT 0")
            db.execute("INSERT INTO orchestration_v2_projection_messages VALUES(?,?,?,?,?,?)",("long","main","user",AT,json.dumps({"text":"x"*70000}),0))
            db.execute("INSERT INTO orchestration_v2_projection_messages VALUES(?,?,?,?,?,?)",("stream","main","assistant",AT,json.dumps({"text":"y"*1000}),1))
        with patch('analytics.data.MAX_MESSAGES',1):
            w=Warehouse(paths={"t3":self.root})
        detail=w.detail("t3:main")
        stats=detail["stats"]
        self.assertEqual(len(detail["messages"]),1)
        self.assertEqual(stats["total_messages"],4)
        self.assertEqual(stats["user_messages"],2)
        self.assertEqual(stats["user_characters"],70000+len("Please compare testing testing analytics"))
        self.assertEqual(stats["assistant_characters"],1000+len("<script>unsafe()</script>"))
        self.assertTrue(stats["stats_partial"])
        chat=next(c for c in w.payload()["chats"] if c["id"]=="t3:main")
        self.assertEqual(chat["project_name"],"Recorded project name")
        self.assertEqual(chat["total_messages"],4)
        scope=w.scope({"days":0,"project":chat["project_id"]})
        self.assertEqual(len(scope["chats"]),2)
        result=w.query("SELECT SUM(user_messages),SUM(assistant_messages) FROM conversation_stats",{"days":0,"project":chat["project_id"]})
        self.assertEqual(result["rows"],[[2,2]])

    def test_codex_statistics_cover_more_than_displayed_messages(self):
        path=self.root / "rollout.jsonl"
        records=[]
        for i in range(205):
            for kind,text in (("user_message","hi"),("agent_message","response")):
                records.append({"type":"event_msg","timestamp":AT,"payload":{"type":kind,"message":text,"id":f"{kind}-{i}"}})
        path.write_text("\n".join(json.dumps(r) for r in records))
        with sqlite3.connect(self.root / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads(id,title,updated_at,rollout_path)")
            db.execute("INSERT INTO threads VALUES('chat','Test',1,?)",(str(path),))
        w=Warehouse(paths={"codex":self.root})
        detail=w.detail("codex:chat")
        self.assertEqual(len(detail["messages"]),200)
        self.assertEqual(detail["stats"]["total_messages"],410)
        self.assertEqual(detail["stats"]["user_messages"],205)
        self.assertEqual(detail["stats"]["avg_assistant_characters"],8)

    def test_mixed_codex_histories_keep_older_messages_and_deduplicate_mirrors(self):
        path=self.root / "mixed.jsonl"
        records=[
            {"type":"event_msg","timestamp":"2026-10-01T00:00:00Z","payload":{"type":"user_message","message":"Earlier prompt"}},
            {"type":"event_msg","timestamp":AT,"payload":{"type":"user_message","message":"New prompt","id":"mirror"}},
            {"type":"response_item","timestamp":AT,"payload":{"type":"message","role":"user","id":"mirror","content":[{"type":"input_text","text":"New prompt"}]}}]
        path.write_text("\n".join(json.dumps(r) for r in records))
        with sqlite3.connect(self.root / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads(id,title,updated_at,rollout_path)")
            db.execute("INSERT INTO threads VALUES('mixed','Mixed history',1,?)",(str(path),))
        w=Warehouse(paths={"codex":self.root})
        stats=w.detail("codex:mixed")["stats"]
        self.assertEqual(stats["user_messages"],2)
        self.assertEqual(stats["user_characters"],len("Earlier promptNew prompt"))
        self.assertTrue(stats["stats_partial"])

    def test_jsonl_read_bound_marks_statistics_partial(self):
        folder=self.root / "projects/example";folder.mkdir(parents=True)
        record={"type":"user","uuid":"one","timestamp":AT,"message":{"role":"user","content":"First prompt"}}
        line=json.dumps(record)+"\n"
        (folder / "chat.jsonl").write_text(line+line.replace('"one"','"two"'))
        with patch('analytics.data.MAX_FILE',len(line.encode())):
            w=Warehouse(paths={"claude":self.root})
        stats=w.detail("claude:chat")["stats"]
        self.assertEqual(stats["user_messages"],1)
        self.assertTrue(stats["stats_partial"])

    def test_claude_streaming_revisions_count_once_before_truncation(self):
        folder=self.root / "projects/example";folder.mkdir(parents=True)
        records=[{"type":"user","uuid":"user","timestamp":AT,"message":{"role":"user","content":"short"}}]
        for uid,text in (("one","hello"),("two","hello world")):
            records.append({"type":"assistant","uuid":uid,"timestamp":AT,"message":{"id":"same","role":"assistant","content":[{"type":"text","text":text},{"type":"thinking","thinking":"SECRET"}]}})
        (folder / "chat.jsonl").write_text("\n".join(json.dumps(r) for r in records))
        w=Warehouse(paths={"claude":self.root})
        stats=w.detail("claude:chat")["stats"]
        self.assertEqual(stats["total_messages"],2)
        self.assertEqual(stats["assistant_characters"],11)
        self.assertEqual(stats["avg_assistant_characters"],11)

    def test_hermes_full_records_exclude_inactive_and_hidden_messages(self):
        with sqlite3.connect(self.root / "state.db") as db:
            db.execute("CREATE TABLE sessions(id,title,started_at)")
            db.execute("INSERT INTO sessions VALUES('chat','Test',1)")
            db.execute("CREATE TABLE messages(id,session_id,role,content,timestamp,active,display_kind)")
            db.executemany("INSERT INTO messages VALUES(?,?,?,?,?,?,?)", [(i,"chat","user" if i%2==0 else "assistant","long"*4000,i,1,"normal") for i in range(205)])
            db.execute("INSERT INTO messages VALUES(206,'chat','assistant','secret',206,0,'normal')")
            db.execute("INSERT INTO messages VALUES(207,'chat','assistant','secret',207,1,'hidden')")
        w=Warehouse(paths={"hermes":self.root})
        detail=w.detail(w.payload()["chats"][0]["id"])
        self.assertEqual(len(detail["messages"]),200)
        self.assertEqual(detail["stats"]["total_messages"],205)
        self.assertEqual(detail["stats"]["avg_assistant_characters"],16000)
        self.assertEqual(detail["stats"]["span_seconds"],204)

    def test_git_worktrees_share_identity_but_equal_folder_names_do_not(self):
        main=self.root / "main/repository";git=main / ".git";git.mkdir(parents=True)
        worktree=self.root / "worktree";worktree.mkdir()
        admin=git / "worktrees/branch";admin.mkdir(parents=True)
        (admin / "commondir").write_text("../..")
        (worktree / ".git").write_text(f"gitdir: {admin}")
        other=self.root / "other/repository";(other / ".git").mkdir(parents=True)
        a=project_metadata(str(main))
        b=project_metadata(str(worktree),recorded_id="source-project",recorded_name="Preferred name")
        c=project_metadata(str(other))
        self.assertEqual(a["project_id"],b["project_id"])
        self.assertEqual(b["project_name"],"Preferred name")
        self.assertNotEqual(a["project_id"],c["project_id"])

    def test_deleted_worktree_keeps_recorded_project_identity_across_sources(self):
        path=t3_fixture(self.root)
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE projection_projects(project_id,title,workspace_root)")
            db.execute("INSERT INTO projection_projects VALUES('project','Historical project','/deleted/repository')")
            db.execute("UPDATE orchestration_v2_projection_threads SET payload_json=? WHERE thread_id='main'",(json.dumps({"worktreePath":"/deleted/worktrees/feature"}),))
        with sqlite3.connect(self.root / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads(id,title,cwd,updated_at)")
            db.execute("INSERT INTO threads VALUES('native','Native chat','/deleted/worktrees/feature',1)")
            db.execute("INSERT INTO threads VALUES('other','Unrelated chat','/unrelated/worktrees/feature',1)")
        w=Warehouse(paths={"t3":self.root,"codex":self.root})
        chats={c["id"]:c for c in w.payload()["chats"]}
        self.assertEqual(chats["codex:native"]["project_id"],chats["t3:main"]["project_id"])
        self.assertEqual(chats["codex:native"]["project_name"],"Historical project")
        self.assertNotEqual(chats["codex:other"]["project_id"],chats["t3:main"]["project_id"])


if __name__ == "__main__":
    unittest.main()
