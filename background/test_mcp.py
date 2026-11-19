import json
import time
import unittest
from unittest.mock import patch

import mcp


class BackgroundTests(unittest.TestCase):
    def test_read_only_server_has_no_input_tools(self):
        server = mcp.Server(False)
        self.assertEqual({t["name"] for t in server.tools}, {"factorio_status", "factorio_observe"})
        self.assertTrue(server.dispatch("tools/call", {"name": "factorio_act"})["isError"])

    def test_frame_consumed_after_input(self):
        server = mcp.Server(True)
        server.frame = ("ticket", time.monotonic())
        args = {"frameId": "ticket", "actions": [{"type": "key", "key": "w+d"}]}
        with patch.object(mcp, "execute") as execute:
            result = server.call("factorio_act", args)
            self.assertEqual(json.loads(result["content"][0]["text"])["completed"], 1)
            execute.assert_called_once_with("key", ("w", "d"), [], 70)
            with self.assertRaisesRegex(ValueError, "Observe again"):
                server.call("factorio_act", args)

    def test_all_actions_validated_before_input(self):
        server = mcp.Server(True)
        server.frame = ("ticket", time.monotonic())
        with patch.object(mcp, "execute") as execute:
            with self.assertRaises(ValueError):
                server.call("factorio_act", {"frameId": "ticket", "actions": [
                    {"type": "key", "key": "e"},
                    {"type": "click", "at": {"x": -1, "y": 500}},
                ]})
            execute.assert_not_called()

    def test_releases_held_keys_when_focus_is_lost(self):
        with patch.object(mcp, "require_focus"), patch.object(mcp, "x") as x, \
             patch.object(mcp, "hold", side_effect=ValueError("focus lost")):
            with self.assertRaisesRegex(ValueError, "focus lost"):
                mcp.execute("key", ("w", "d"), [], 80)
            self.assertEqual([call.args for call in x.call_args_list],
                             [("keydown", "w"), ("keydown", "d"), ("keyup", "d"), ("keyup", "w")])


if __name__ == "__main__":
    unittest.main()
