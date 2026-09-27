#!/usr/bin/env python3
"""Analyze RouteLab JSON exports. Python 3.9+, standard library only.

No network requests. Keeps actual GPS observations separate from inferred causes.
Run: python3 Analysis/analyze.py RouteLab-trips.json --out results
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

MAX_GAP = 30


def parse_date(value):
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        raise ValueError("Timestamp must include timezone")
    return dt


def distance(a, b):
    lat1, lat2 = math.radians(a["latitude"]), math.radians(b["latitude"])
    dlat = lat2 - lat1
    dlon = math.radians(b["longitude"] - a["longitude"])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 6_371_000 * 2 * math.asin(min(1, math.sqrt(max(0, h))))


def usable_points(trip):
    start = parse_date(trip["startedAt"])
    end = parse_date(trip["endedAt"]) if trip.get("endedAt") else datetime.max.replace(tzinfo=timezone.utc)
    return [p for p in trip.get("points", []) if start <= parse_date(p["timestamp"]) <= end]


def metrics(trip):
    points = usable_points(trip)
    start = parse_date(trip["startedAt"])
    end = parse_date(trip.get("endedAt") or trip["startedAt"])
    elapsed = max(0, (end - start).total_seconds())
    result = {"distance_m": 0.0, "observed_seconds": 0.0, "gap_seconds": elapsed, "events": []}
    run = None
    modern = (trip.get("stopRuleVersion") or 1) >= 2
    limits = {m["pointID"]: m["speedLimitMPS"] for m in (trip.get("roadMatches") or []) if m.get("speedLimitMPS")}

    def flush():
        nonlocal run
        if run:
            seconds = (run["end"] - run["start"]).total_seconds()
            if seconds >= ((4 if modern else 15) if run["kind"] == "stopped" else 30):
                if modern:
                    nearby = {f["kind"] for f in trip.get("roadFeatures", []) if distance(f["coordinate"], run["coordinate"]) <= 40}
                    if run["kind"] == "stopped":
                        if seconds >= 15 and "rail" in nearby:
                            run["suggested_reason"], run["evidence"] = "rail", "mapped_crossing"
                        elif "signal" in nearby:
                            run["suggested_reason"], run["evidence"] = "signal", "mapped_signal"
                        elif "junction" in nearby:
                            run["suggested_reason"], run["evidence"] = "signal", "intersection_only"
                        else:
                            run["suggested_reason"], run["evidence"] = "unknown", "no_context"
                    else:
                        run["suggested_reason"] = "congestion"
                run["seconds"] = seconds
                run["confirmed_reason"] = trip.get("confirmedReasons", {}).get(run["id"], "")
                result["events"].append(run)
        run = None

    for a, b in zip(points, points[1:]):
        ta, tb = parse_date(a["timestamp"]), parse_date(b["timestamp"])
        dt = (tb - ta).total_seconds()
        if not 0 < dt <= MAX_GAP:
            flush()
            continue
        meters = distance(a["coordinate"], b["coordinate"])
        if meters / dt > 60:
            flush()
            continue
        result["observed_seconds"] += dt
        reported = b.get("speed", -1)
        speed = reported if reported >= 0 else meters / dt
        if speed >= 1.2 and meters >= 2:
            result["distance_m"] += meters
        threshold = min(8.33, limits.get(b.get("id"), 3 / 0.35) * 0.35) if modern else 3
        kind = None if reported < 0 else ("stopped" if speed < 0.8 else ("slow" if speed < threshold else None))
        previous_speed = a.get("speed", -1)
        if modern and (previous_speed < 0 or (kind == "stopped" and previous_speed >= 0.8)
                       or (kind == "slow" and (previous_speed < 0.8 or previous_speed >= threshold))):
            kind = None
        if kind is None:
            flush()
            continue
        if run is None or run["kind"] != kind:
            flush()
            nearby = [(distance(f["coordinate"], b["coordinate"]), f) for f in trip.get("roadFeatures", [])]
            nearby = [item for item in nearby if item[0] <= 45]
            feature = min(nearby, key=lambda x: x[0])[1] if nearby else None
            reason = feature["kind"] if kind == "stopped" and feature and feature["kind"] in ("signal", "rail") else "unknown"
            run = {"id": f"{kind}-{int(ta.timestamp())}", "start": ta, "end": tb,
                   "coordinate": b["coordinate"], "kind": kind, "suggested_reason": reason,
                   "evidence": ("relative_to_limit" if b.get("id") in limits else "low_speed") if kind == "slow" else "unknown"}
        else:
            run["end"] = tb
    flush()
    result["gap_seconds"] = max(0, elapsed - result["observed_seconds"])
    result["stopped_seconds"] = sum(e["seconds"] for e in result["events"] if e["kind"] == "stopped")
    result["slow_seconds"] = sum(e["seconds"] for e in result["events"] if e["kind"] == "slow")
    return result


def exclusion_reason(trip, m=None):
    if not trip.get("endedAt"):
        return "行程未结束"
    if trip.get("excluded"):
        return "用户排除"
    if trip.get("interrupted"):
        return "记录中断"
    if not trip.get("reviewed"):
        return "尚未确认实际路线和到达时间"
    if not trip.get("autoRouteKey") and not trip.get("routeLabel", "").strip():
        return "缺少路线名称"
    elapsed = (parse_date(trip["endedAt"]) - parse_date(trip["startedAt"])).total_seconds()
    if elapsed < 60:
        return "行程不足 1 分钟"
    if len(usable_points(trip)) < 3:
        return "定位点不足"
    m = metrics(trip) if m is None else m
    if m["observed_seconds"] / max(1, elapsed) < 0.8:
        return "有效定位覆盖不足 80%"
    return ""


def quantile(values, p):
    xs = sorted(values)
    if not xs:
        return None
    x = (len(xs) - 1) * p
    i, j = int(x), min(len(xs) - 1, int(x) + 1)
    return xs[i] + (xs[j] - xs[i]) * (x - i)


def route_title(trip):
    return f"路线 {trip['autoRouteNumber']}" if trip.get("autoRouteNumber") is not None else trip.get("routeLabel", "")


def summaries(trips):
    anchors, groups, labels = [], defaultdict(list), {}
    for trip in sorted(trips, key=lambda t: parse_date(t["startedAt"])):
        if exclusion_reason(trip):
            continue
        ps = usable_points(trip)
        origin, destination = ps[0]["coordinate"], ps[-1]["coordinate"]
        od = next((i for i, (a, b) in enumerate(anchors) if distance(a, origin) <= 250 and distance(b, destination) <= 250), None)
        if od is None:
            anchors.append((origin, destination))
            od = len(anchors) - 1
        timezone_id = trip.get("timezoneID", "UTC")
        try:
            zone = ZoneInfo(timezone_id)
        except ZoneInfoNotFoundError:
            zone = timezone.utc
        start = parse_date(trip["startedAt"]).astimezone(zone)
        day_type = "周末" if start.weekday() >= 5 else "工作日"
        bucket = f"{start.hour:02}:{0 if start.minute < 30 else 30:02}"
        key = (od + 1, timezone_id, day_type, bucket, trip.get("autoRouteKey") or trip["routeLabel"].strip())
        labels[key] = route_title(trip)
        groups[key].append((parse_date(trip["endedAt"]) - parse_date(trip["startedAt"])).total_seconds() / 60)
    output = []
    for key, xs in groups.items():
        od, zone, day_type, bucket, route_key = key
        label = labels[key]
        output.append({"od_group": od, "timezone": zone, "day_type": day_type, "departure_bucket": bucket,
                       "route": label, "route_key": route_key, "n": len(xs), "mean_minutes": statistics.mean(xs),
                       "median_minutes": statistics.median(xs),
                       "sd_minutes": statistics.stdev(xs) if len(xs) > 1 else None,
                       "p90_minutes": quantile(xs, 0.9) if len(xs) >= 20 else None,
                       "small_sample": len(xs) < 5})
    return sorted(output, key=lambda r: (r["od_group"], r["day_type"], r["departure_bucket"], r["mean_minutes"]))


def eta_error(trip, field):
    estimate = trip.get(field)
    if not estimate or not trip.get("endedAt"):
        return ""
    return (parse_date(trip["endedAt"]) - parse_date(estimate["capturedAt"])).total_seconds() - estimate["seconds"]


def validate_trip(trip):
    if trip.get("schemaVersion", 1) != 1:
        raise ValueError("Unsupported trip schemaVersion")
    for key in ["id", "startedAt", "timezoneID", "navigator", "routeLabel", "points"]:
        if key not in trip:
            raise ValueError(f"Missing trip field: {key}")
    parse_date(trip["startedAt"])
    if trip.get("endedAt"):
        if parse_date(trip["endedAt"]) < parse_date(trip["startedAt"]):
            raise ValueError("Trip ends before it starts")
    last = None
    for point in trip["points"]:
        ts = parse_date(point["timestamp"])
        coord = point["coordinate"]
        lat, lon = coord["latitude"], coord["longitude"]
        if not (math.isfinite(lat) and math.isfinite(lon) and -90 <= lat <= 90 and -180 <= lon <= 180):
            raise ValueError("Invalid coordinate")
        if last and ts <= last:
            raise ValueError("GPS timestamps are not strictly increasing")
        if not math.isfinite(point["speed"]) or point["speed"] > 60:
            raise ValueError("Invalid speed")
        if not 0 <= point["horizontalAccuracy"] <= 35:
            raise ValueError("Unfiltered GPS accuracy")
        last = ts


def load_exports(paths):
    by_id = {}
    for path in paths:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        if data.get("schemaVersion") != 1 or not isinstance(data.get("trips"), list):
            raise ValueError(f"{path}: not a RouteLab v1 export")
        for trip in data["trips"]:
            validate_trip(trip)
            by_id[trip["id"]] = trip  # Later input file wins when re-exported records overlap.
    return list(by_id.values())


def safe_cell(value):
    # Protect spreadsheet apps from interpreting user-entered route labels or notes as formulas.
    if isinstance(value, str) and value.startswith(("=", "+", "-", "@", "\t", "\r")):
        return "'" + value
    return value


def write_csv(path, rows, fields):
    with Path(path).open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: safe_cell(row.get(key, "")) for key in fields})


def export_analysis(trips, out):
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    trip_rows, event_rows, point_rows = [], [], []
    for trip in trips:
        m = metrics(trip)
        duration = (parse_date(trip["endedAt"]) - parse_date(trip["startedAt"])).total_seconds() if trip.get("endedAt") else ""
        trip_rows.append({"trip_id": trip["id"], "route": route_title(trip), "route_key": trip.get("autoRouteKey", ""),
                          "road_names": " → ".join(trip.get("roadNames") or []),
                          "road_match_coverage": trip.get("roadMatchCoverage", ""),
                          "construction_reported": trip.get("constructionReported", ""), "started_at": trip["startedAt"],
                          "ended_at": trip.get("endedAt", ""), "timezone": trip["timezoneID"], "navigator": trip["navigator"],
                          "duration_seconds": duration, "gps_distance_m": m["distance_m"],
                          "observed_seconds": m["observed_seconds"], "gap_seconds": m["gap_seconds"],
                          "stopped_seconds": m["stopped_seconds"], "slow_seconds": m["slow_seconds"],
                          "mapkit_reference_eta_seconds": (trip.get("referenceEstimate") or {}).get("seconds", ""),
                          "external_eta_seconds": (trip.get("externalEstimate") or {}).get("seconds", ""),
                          "external_eta_source": (trip.get("externalEstimate") or {}).get("source", ""),
                          "mapkit_arrival_error_seconds": eta_error(trip, "referenceEstimate"),
                          "external_arrival_error_seconds": eta_error(trip, "externalEstimate"),
                          "end_method": trip.get("endMethod", ""), "exclusion_reason": exclusion_reason(trip, m),
                          "notes": trip.get("notes", "")})
        for e in m["events"]:
            event_rows.append({"trip_id": trip["id"], "event_id": e["id"], "start": e["start"].isoformat(),
                               "end": e["end"].isoformat(), "seconds": e["seconds"], "motion_kind": e["kind"],
                               "suggested_reason": e["suggested_reason"], "confirmed_reason": e["confirmed_reason"], "evidence": e["evidence"],
                               "latitude": e["coordinate"]["latitude"], "longitude": e["coordinate"]["longitude"]})
        for p in trip["points"]:
            point_rows.append({"trip_id": trip["id"], "timestamp": p["timestamp"], **p["coordinate"],
                               "speed_mps": p["speed"], "horizontal_accuracy_m": p["horizontalAccuracy"],
                               "within_arrival_time": parse_date(p["timestamp"]) <= parse_date(trip.get("endedAt") or p["timestamp"])})
    stats = summaries(trips)
    write_csv(out / "trips.csv", trip_rows, ["trip_id", "route", "route_key", "road_names", "road_match_coverage", "construction_reported", "started_at", "ended_at", "timezone", "navigator", "duration_seconds", "gps_distance_m", "observed_seconds", "gap_seconds", "stopped_seconds", "slow_seconds", "mapkit_reference_eta_seconds", "external_eta_seconds", "external_eta_source", "mapkit_arrival_error_seconds", "external_arrival_error_seconds", "end_method", "exclusion_reason", "notes"])
    write_csv(out / "events.csv", event_rows, ["trip_id", "event_id", "start", "end", "seconds", "motion_kind", "suggested_reason", "confirmed_reason", "evidence", "latitude", "longitude"])
    write_csv(out / "points.csv", point_rows, ["trip_id", "timestamp", "latitude", "longitude", "speed_mps", "horizontal_accuracy_m", "within_arrival_time"])
    write_csv(out / "summary.csv", stats, ["od_group", "timezone", "day_type", "departure_bucket", "route", "route_key", "n", "mean_minutes", "median_minutes", "sd_minutes", "p90_minutes", "small_sample"])
    report = ["RouteLab 通勤记录分析", "", f"共 {len(trips)} 次记录；{sum(not exclusion_reason(t) for t in trips)} 次进入比较。", "",
              "同组路线按历史平均耗时排序；这些数据不证明某条路线在同一时刻必然最快。",
              "标准差为样本标准差。P90 仅在每组至少 20 次时显示，也不是未来到达保证。", ""]
    for row in stats:
        sd = f"{row['sd_minutes']:.1f}" if row["sd_minutes"] is not None else "不足 2 次"
        report.append(f"OD {row['od_group']} | {row['day_type']} {row['departure_bucket']} | {row['route']} | n={row['n']} | 平均 {row['mean_minutes']:.1f} 分钟 | 标准差 {sd}")
    (out / "report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    return stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exports", nargs="+", help="One or more RouteLab JSON exports; later file wins for duplicate IDs")
    parser.add_argument("--out", default="RouteLab-results", help="Output folder")
    args = parser.parse_args()
    try:
        trips = load_exports(args.exports)
        stats = export_analysis(trips, args.out)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"无法分析：{error}\n")
    print(f"已分析 {len(trips)} 次行程，生成 {len(stats)} 个比较分组。")
    print(f"结果保存在：{Path(args.out).resolve()}")


if __name__ == "__main__":
    main()
