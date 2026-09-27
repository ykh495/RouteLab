import copy
import importlib.util
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("analysis", ROOT / "Analysis" / "analyze.py")
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


def iso(dt):
    return dt.isoformat().replace("+00:00", "Z")


def make_trip(identifier="t1", label="Koenig", minutes=10, day=21, hour=13, reverse=False):
    start = datetime(2026, 9, day, hour, 5, tzinfo=timezone.utc)
    count = int(minutes * 6)
    points = []
    for i in range(count + 1):
        fraction = i / count
        if reverse:
            fraction = 1 - fraction
        points.append({"id": f"{identifier}-{i}", "timestamp": iso(start + timedelta(seconds=i * 10)),
                       "coordinate": {"latitude": 30.35 - 0.025 * fraction, "longitude": -97.74},
                       "speed": 6.0, "horizontalAccuracy": 5.0})
    return {"schemaVersion": 1, "id": identifier, "startedAt": iso(start),
            "endedAt": iso(start + timedelta(minutes=minutes)), "timezoneID": "America/Chicago",
            "navigator": "manual", "routeLabel": label, "points": points,
            "reviewed": True, "interrupted": False, "excluded": False, "roadFeatures": [], "confirmedReasons": {}}


class AnalysisTests(unittest.TestCase):
    def test_mean_sd_sample_counts(self):
        rows = a.summaries([make_trip("a", minutes=10), make_trip("b", minutes=12, day=22)])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["n"], 2)
        self.assertEqual(rows[0]["mean_minutes"], 11)
        self.assertAlmostEqual(rows[0]["sd_minutes"], 2 ** 0.5)
        self.assertIsNone(rows[0]["p90_minutes"])

    def test_direction_and_time_buckets_not_mixed(self):
        rows = a.summaries([make_trip("a"), make_trip("b", reverse=True), make_trip("c", hour=14), make_trip("d", day=20)])
        self.assertEqual(len(rows), 4)
        self.assertTrue(all(r["n"] == 1 for r in rows))
        self.assertEqual({r["day_type"] for r in rows}, {"工作日", "周末"})

    def test_local_time_uses_trip_timezone(self):
        row = a.summaries([make_trip()])[0]
        self.assertEqual(row["departure_bucket"], "08:00")

    def test_missing_gps_does_not_become_straight_line_distance(self):
        t = make_trip()
        full = a.metrics(t)["distance_m"]
        t["points"] = t["points"][:3] + t["points"][-3:]
        m = a.metrics(t)
        self.assertLess(m["distance_m"], full / 5)
        self.assertGreater(m["gap_seconds"], 500)
        self.assertEqual(a.exclusion_reason(t), "有效定位覆盖不足 80%")

    def test_stop_inference_is_separate_from_annotation(self):
        t = make_trip()
        coord = copy.deepcopy(t["points"][10]["coordinate"])
        for p in t["points"][10:17]:
            p["coordinate"] = coord
            p["speed"] = 0
        t["roadFeatures"] = [{"id": "signal-1", "kind": "signal", "coordinate": coord}]
        event = a.metrics(t)["events"][0]
        self.assertEqual(event["kind"], "stopped")
        self.assertEqual(event["suggested_reason"], "signal")
        self.assertEqual(event["confirmed_reason"], "")
        t["confirmedReasons"][event["id"]] = "congestion"
        reloaded = json.loads(json.dumps(t))
        event = a.metrics(reloaded)["events"][0]
        self.assertEqual(event["confirmed_reason"], "congestion")
        self.assertEqual(event["suggested_reason"], "signal")

    def test_unknown_speed_not_classified_as_stop(self):
        t = make_trip()
        for p in t["points"]:
            p["speed"] = -1
        self.assertEqual(a.metrics(t)["events"], [])

    def test_stationary_jitter_no_distance(self):
        t = make_trip()
        for i, p in enumerate(t["points"]):
            p["speed"] = 0
            p["coordinate"] = {"latitude": 30.35 + (i % 2) * 0.00004, "longitude": -97.74}
        self.assertEqual(a.metrics(t)["distance_m"], 0)

    def test_review_and_interruption_gate(self):
        t = make_trip()
        t["reviewed"] = False
        self.assertEqual(a.summaries([t]), [])
        t["reviewed"] = True
        t["interrupted"] = True
        self.assertEqual(a.summaries([t]), [])

    def test_arrival_edit_trims_metrics_but_keeps_raw_points(self):
        t = make_trip()
        original_count = len(t["points"])
        t["endedAt"] = iso(a.parse_date(t["startedAt"]) + timedelta(minutes=5))
        self.assertEqual(len(a.usable_points(t)), 31)
        self.assertEqual(len(t["points"]), original_count)
        self.assertEqual(a.metrics(t)["observed_seconds"], 300)

    def test_eta_error_based_on_capture_not_departure(self):
        t = make_trip(minutes=10)
        t["referenceEstimate"] = {"seconds": 600, "capturedAt": iso(a.parse_date(t["startedAt"]) - timedelta(minutes=1))}
        self.assertEqual(a.eta_error(t, "referenceEstimate"), 60)

    def test_import_deduplicates_and_rejects_invalid_order(self):
        t = make_trip()
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / "trips.json"
            p.write_text(json.dumps({"schemaVersion": 1, "trips": [t]}))
            self.assertEqual(len(a.load_exports([p, p])), 1)
            t["points"].reverse()
            p.write_text(json.dumps({"schemaVersion": 1, "trips": [t]}))
            with self.assertRaises(ValueError):
                a.load_exports([p])

    def test_outputs_and_csv_formula_escaping(self):
        t = make_trip(label="=SUM(1,2)")
        with tempfile.TemporaryDirectory() as directory:
            a.export_analysis([t], directory)
            self.assertEqual(len(list(Path(directory).glob("*.csv"))), 4)
            self.assertIn("'=SUM", (Path(directory) / "summary.csv").read_text(encoding="utf-8-sig"))
            self.assertTrue((Path(directory) / "report.txt").exists())

    def test_p90_only_shown_with_twenty_samples(self):
        trips = [make_trip(str(i), minutes=10 + i) for i in range(20)]
        self.assertAlmostEqual(a.summaries(trips)[0]["p90_minutes"], 27.1)

class ModernInferenceTests(unittest.TestCase):
    def modern_stop(self, seconds, feature="junction"):
        t = make_trip()
        t["stopRuleVersion"] = 2
        start = a.parse_date(t["startedAt"])
        coord = t["points"][0]["coordinate"]
        t["points"] = [{"id": f"p{i}", "timestamp": iso(start + timedelta(seconds=i)), "coordinate": coord,
                        "speed": 0, "horizontalAccuracy": 5} for i in range(seconds + 1)]
        t["endedAt"] = t["points"][-1]["timestamp"]
        t["roadFeatures"] = [] if feature is None else [{"id": "f", "kind": feature, "coordinate": coord}]
        return t

    def test_three_seconds_does_not_qualify_four_does(self):
        self.assertEqual(a.metrics(self.modern_stop(3))["events"], [])
        event = a.metrics(self.modern_stop(4))["events"][0]
        self.assertEqual((event["seconds"], event["suggested_reason"], event["evidence"]), (4, "signal", "intersection_only"))
        self.assertEqual(event["confirmed_reason"], "")

    def test_rail_threshold_is_fifteen_seconds(self):
        self.assertEqual(a.metrics(self.modern_stop(14, "rail"))["events"][0]["suggested_reason"], "unknown")
        self.assertEqual(a.metrics(self.modern_stop(15, "rail"))["events"][0]["suggested_reason"], "rail")

    def test_no_context_no_invented_signal(self):
        self.assertEqual(a.metrics(self.modern_stop(30, None))["events"][0]["suggested_reason"], "unknown")

    def test_two_low_speed_samples_required(self):
        t = self.modern_stop(4)
        t["points"][0]["speed"] = 8
        self.assertEqual(a.metrics(t)["events"], [])

    def test_relative_speed_limit(self):
        t = make_trip()
        t["stopRuleVersion"] = 2
        t["roadMatches"] = [{"pointID": p["id"], "speedLimitMPS": 20} for p in t["points"]]
        event = a.metrics(t)["events"][0]
        self.assertEqual((event["suggested_reason"], event["evidence"]), ("congestion", "relative_to_limit"))
        t["roadMatches"] = []
        self.assertEqual(a.metrics(t)["events"], [])

    def test_auto_route_key_replaces_manual_name(self):
        t = make_trip(label="")
        t.update(autoRouteKey="route-a", autoRouteNumber=1)
        self.assertEqual(a.exclusion_reason(t), "")
        t2 = copy.deepcopy(t)
        t2.update(id="second", autoRouteKey="route-b")
        rows = a.summaries([t, t2])
        self.assertEqual(len(rows), 2)
        self.assertEqual({r["route_key"] for r in rows}, {"route-a", "route-b"})

    def test_legacy_event_ids_are_preserved(self):
        t = self.modern_stop(20, "signal")
        del t["stopRuleVersion"]
        legacy = a.metrics(t)["events"][0]
        t["confirmedReasons"][legacy["id"]] = "other"
        reloaded = a.metrics(json.loads(json.dumps(t)))["events"][0]
        self.assertEqual(reloaded["confirmed_reason"], "other")
        self.assertEqual(legacy["id"], reloaded["id"])

    def test_long_gap_does_not_count_as_wait(self):
        t = self.modern_stop(3)
        t["points"][-1]["timestamp"] = iso(a.parse_date(t["startedAt"]) + timedelta(seconds=60))
        t["endedAt"] = t["points"][-1]["timestamp"]
        self.assertEqual(a.metrics(t)["events"], [])
        self.assertEqual(a.metrics(t)["gap_seconds"], 58)


if __name__ == "__main__":
    unittest.main()
