import unittest

from analytics.insights import build_insights, conversation_summary


class InsightTests(unittest.TestCase):
    def test_weighted_character_averages_and_true_chat_denominator(self):
        chats = [
            {"project_id":"repo:one", "project_name":"One", "project_path":"/one",
             "connection_id":"t3", "app":"T3 Code", "model":"m1", "total_tokens":100,
             "total_messages":4, "user_messages":2, "assistant_messages":2,
             "user_characters":40,"assistant_characters":200,"stats_partial":False},
            {"project_id":"repo:one", "project_name":"One", "project_path":"/one/worktree",
             "connection_id":"codex", "app":"Codex", "model":"m2", "total_tokens":None,
             "total_messages":12,"user_messages":2,"assistant_messages":10,
             "user_characters":80,"assistant_characters":2000,"stats_partial":True},
            {"project_id":"repo:two", "project_name":"Two", "connection_id":"hermes",
             "app":"Hermes", "model":"m1", "total_messages":None},
        ]
        result=build_insights(chats)
        stats=result["metrics"]
        self.assertEqual(stats["measured_chats"],2)
        self.assertEqual(stats["unknown_chats"],1)
        self.assertEqual(stats["partial_chats"],1)
        self.assertEqual(stats["user_messages"],4)
        self.assertEqual(stats["avg_messages_per_conversation"],8)
        self.assertEqual(stats["avg_user_messages_per_conversation"],2)
        self.assertEqual(stats["median_messages_per_conversation"],8)
        self.assertAlmostEqual(stats["avg_response_characters"],2200/12)
        self.assertEqual(stats["avg_prompt_characters"],30)
        self.assertIsNone(stats["median_response_characters"])
        one=result["projects"][0]
        self.assertEqual(one["chats"],2)
        self.assertEqual(one["total_tokens"],100)
        self.assertEqual(one["models"],["m1","m2"])
        self.assertEqual(one["paths"],["/one","/one/worktree"])

    def test_missing_values_stay_unknown_and_recorded_empty_chat_is_measured(self):
        self.assertIsNone(conversation_summary([])["avg_messages_per_conversation"])
        stats=conversation_summary([{"total_messages":0,"user_messages":0,"assistant_messages":0,
                                     "user_characters":0,"assistant_characters":0}])
        self.assertEqual(stats["measured_chats"],1)
        self.assertEqual(stats["avg_messages_per_conversation"],0)
        self.assertIsNone(stats["avg_response_characters"])
        self.assertIsNone(build_insights([{"connection_id":"x"}])["projects"][0]["total_tokens"])


if __name__ == "__main__":
    unittest.main()
