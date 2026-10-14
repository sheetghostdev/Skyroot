#!/bin/bash
# Everything: the headless suites (crafting, survival, farming, fire,
# building, saving, ten days on the island) and the multiplayer tests
# (host + client, a solo island opened mid-session, four players, a crash).
# Exit code 0 only if every check passed.
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
OUT=${OUT:-/tmp/skyroot_tests}
mkdir -p "$OUT"
status=0

echo "== headless suites"
timeout 3600 $GODOT --headless --path . res://tests/test_main.tscn -- --suite=all > "$OUT/suites.log" 2>&1 || status=1
grep -E "^RESULT|FAIL|TESTS DID NOT START" "$OUT/suites.log"

echo "== host + client"
OUT="$OUT/mp" tools/mp_test.sh > "$OUT/mp.log" 2>&1 || status=1
grep -E "RESULT|FAIL|exit codes" "$OUT/mp.log"

echo "== solo island opened to friends mid-session"
OPEN_LATER=1 OUT="$OUT/mp_open" PORT=7793 tools/mp_test.sh > "$OUT/mp_open.log" 2>&1 || status=1
grep -E "RESULT|FAIL|exit codes" "$OUT/mp_open.log"

echo "== four players"
OUT="$OUT/crowd" tools/mp_crowd.sh > "$OUT/crowd.log" 2>&1 || status=1
grep -E "RESULT|FAIL|exit codes" "$OUT/crowd.log"

echo "== a client crashes and comes straight back"
OUT="$OUT/crash" tools/mp_crash.sh > "$OUT/crash.log" 2>&1 || status=1
grep -E "RESULT|FAIL|exit codes" "$OUT/crash.log"

if [ $status -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED (logs in $OUT)"; fi
exit $status
