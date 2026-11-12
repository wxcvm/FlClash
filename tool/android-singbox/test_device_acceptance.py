import json
import unittest
import tempfile
from pathlib import Path
from device_acceptance import EXPECTED, load_outbound, parse_result, summarize


def fixture():
    return [{"phase": phase, "tlsMs": 100,
             **({"dnsMs": 30, "egress": "direct"} if phase in ("singbox-1", "singbox-2") else {}),
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
        report.insert(2, {"phase": "singbox-network-handover", "tlsMs": 80,
                          "dnsMs": 20, "beforeGeneration": 1, "afterGeneration": 3})
        self.assertEqual(len(summarize(report, handover=True)), 7)
        with self.assertRaises(ValueError):
            summarize(report)

    def test_proxy_requires_explicit_egress_and_dns(self):
        report = fixture()
        with self.assertRaises(ValueError):
            summarize(report, proxy=True)
        for phase in report:
            if phase["phase"] in ("singbox-1", "singbox-2"):
                phase["egress"] = "proxy"
        self.assertEqual(len(summarize(report, proxy=True)), 6)
        del report[1]["dnsMs"]
        with self.assertRaises(ValueError):
            summarize(report, proxy=True)

    def test_soak_requires_measurements(self):
        report = fixture()
        report.insert(2, {"phase": "singbox-soak", "durationSeconds": 60,
                          "checks": [{"tlsMs": 100, "dnsMs": 10}, {"tlsMs": 120, "dnsMs": 12}]})
        self.assertEqual(len(summarize(report, soak_seconds=60)), 7)
        with self.assertRaises(ValueError):
            summarize(report, soak_seconds=120)
        report[2]["checks"].pop()
        with self.assertRaises(ValueError):
            summarize(report, soak_seconds=60)

    def test_single_outbound_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "outbound.json"
            good = {"type": "vless", "server": "example.com", "server_port": 443}
            path.write_text(json.dumps(good))
            self.assertEqual(json.loads(load_outbound(path)), good)
            for value in [{"type": "direct"}, {**good, "type": []}, {**good, "detour": "other"},
                          {**good, "server_port": True}, {"outbounds": [good]}]:
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    load_outbound(path)


if __name__ == "__main__":
    unittest.main()
