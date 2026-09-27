#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python3 -m unittest discover -s Tests -p 'test_*.py' -v
test_dir="$(mktemp -d /tmp/routelab-checks.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc RouteLab/Localization.swift RouteLab/Models.swift RouteLab/TripMath.swift RouteLab/RouteGeometry.swift Tests/CoreChecks.swift -o "$test_dir/core-checks"
"$test_dir/core-checks"
xcodebuild -project RouteLab.xcodeproj -scheme RouteLab -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
