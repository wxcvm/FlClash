import json
import unittest
from device_acceptance import EXPECTED, parse_result, summarize


def fixture():
    return [{"phase": phase, "tlsMs": 100,
             "samples": [[{"name": "com.follow.clash.dev", "pid": 1, "pssKiB": v}]
                         for v in [100, 200, 300]]}
            for phase in EXPECTED[:-1]] + [{"phase": "stopped", "pss": []}]


class AcceptanceReportTest(unittest.TestCase):
    def test_success(self):
        report = fixture()
        log = ("INSTRUMENTATION_RESULT: acceptanceJson=" + json.dumps(report)
               + "\nINSTRUMENTATION_RESULT: stream=PASS: live dual-core VPN acceptance\n"
                 "INSTRUMENTATION_CODE: -1\n")
        self.assertEqual(parse_result(log), report)
        self.assertEqual(summarize(report)[0]["medianTotalPssKiB"], 200)

    def test_failure_and_missing_phases(self):
        for log in ["INSTRUMENTATION_CODE: 0\n", "INSTRUMENTATION_CODE: -1\n"]:
            with self.assertRaises(ValueError):
                parse_result(log)
        with self.assertRaises(ValueError):
            summarize(fixture()[:-1])

    def test_zero_pss_is_not_a_measurement(self):
        report = fixture()
        report[0]["samples"][0][0]["pssKiB"] = 0
        with self.assertRaises(ValueError):
            summarize(report)

    def test_optional_handover(self):
        report = fixture()
        report.insert(2, {"phase": "singbox-network-handover", "tlsMs": 80})
        self.assertEqual(len(summarize(report)), 7)


if __name__ == "__main__":
    unittest.main()
