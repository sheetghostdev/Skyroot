#!/bin/bash
# A client's game crashes (killed outright) and they start it again straight
# away: they must come back as themselves, with their things, and the dead
# connection must not linger.  Exit code 0 = all checks passed.
cd "$(dirname "$0")/.."
PORT=${PORT:-7794}
GODOT=${GODOT:-godot}
OUT=${OUT:-/tmp/skyroot_mp}
mkdir -p "$OUT"
rm -f "$OUT"/crash_*.log
$GODOT --headless --path . -- --autostart=host --world=MPCrash --new --name=Host --port=$PORT --mptest=crash_host > "$OUT/crash_host.log" 2>&1 &
HOST=$!
sleep 6
$GODOT --headless --path . -- --autostart=join --ip=127.0.0.1 --port=$PORT --name=Ana --mptest=crash_a > "$OUT/crash_a.log" 2>&1 &
A=$!
for i in $(seq 1 60); do grep -q "waiting to be killed" "$OUT/crash_a.log" && break; sleep 0.5; done
kill -9 $A
sleep 1
$GODOT --headless --path . -- --autostart=join --ip=127.0.0.1 --port=$PORT --name=Ana --mptest=crash_b > "$OUT/crash_b.log" 2>&1
B=$?
wait $HOST
H=$?
grep -h "^MPT" "$OUT"/crash_*.log
grep -h "SCRIPT ERROR" -A3 "$OUT"/crash_*.log | head -20
echo "exit codes: host=$H rejoin=$B"
[ $H -eq 0 ] && [ $B -eq 0 ]
