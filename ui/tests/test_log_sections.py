import unittest

from ui.lib.log_sections import LogSectionParser


def _collect_events(lines):
    parser = LogSectionParser()
    events = []
    for line_num, line in enumerate(lines):
        events.extend(parser.feed_line(line_num, line))
    events.extend(parser.finish(failed=False))
    return events


class LogSectionParserTests(unittest.TestCase):
    def test_repeated_play_titles_get_distinct_section_ids(self):
        events = _collect_events([
            "[env] Loading secrets",
            "PLAY [Role A] ***************************",
            "TASK [alpha] ****************************",
            "PLAY [Role B] ***************************",
            "TASK [bravo] ****************************",
            "PLAY [Role A] ***************************",
            "TASK [alpha again] **********************",
        ])

        play_starts = [
            event["data"]
            for event in events
            if event["event"] == "section-start" and event["data"]["kind"] == "play"
        ]

        self.assertEqual(
            [section["signature"] for section in play_starts],
            ["play:role-a", "play:role-b", "play:role-a"],
        )
        self.assertEqual(len({section["id"] for section in play_starts}), 3)

    def test_parser_ids_are_stable_after_priming(self):
        lines = [
            "[env] Loading secrets",
            "PLAY [Role A] ***************************",
            "TASK [alpha] ****************************",
            "PLAY [Role B] ***************************",
            "TASK [bravo] ****************************",
            "PLAY [Role A] ***************************",
        ]

        full_parser = LogSectionParser()
        full_events = []
        for line_num, line in enumerate(lines):
            full_events.extend(full_parser.feed_line(line_num, line))

        replay_parser = LogSectionParser()
        for line_num, line in enumerate(lines[:5]):
            replay_parser.feed_line(line_num, line)
        replay_events = replay_parser.feed_line(5, lines[5])

        expected = next(
            event["data"]["id"]
            for event in full_events
            if event["event"] == "section-start" and event["data"]["title"] == "Role A" and event["data"]["id"].startswith("play-0003")
        )
        actual = next(
            event["data"]["id"]
            for event in replay_events
            if event["event"] == "section-start"
        )

        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()