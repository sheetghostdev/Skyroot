#!/bin/bash
# Multiplayer check: a host and a client as separate game instances on this
# machine, talking over ENet on localhost.  The client plays, leaves, and
# rejoins; both sides verify what they see.  Exit code 0 = all checks passed.
cd "$(dirname "$0")/.."
PORT=${PORT:-7791}
GODOT=${GODOT:-godot}
OUT=${OUT:-/tmp/skyroot_mp}
mkdir -p "$OUT"
rm -f "$OUT"/*.log
if [ -n "$OPEN_LATER" ]; then
	# start alone and open the island to friends mid-session (pause menu: "Open to friends now")
	$GODOT --headless --path . -- --autostart=solo --world=MPTest --new --name=Host --port=$PORT --mptest=host --open_later > "$OUT/host.log" 2>&1 &
else
	$GODOT --headless --path . -- --autostart=host --world=MPTest --new --name=Host --port=$PORT --mptest=host > "$OUT/host.log" 2>&1 &
fi
HOST=$!
sleep 6
$GODOT --headless --path . -- --autostart=join --ip=127.0.0.1 --port=$PORT --name=Ana --mptest=client > "$OUT/client.log" 2>&1
C1=$?
sleep 2
$GODOT --headless --path . -- --autostart=join --ip=127.0.0.1 --port=$PORT --name=Ana --mptest=rejoin > "$OUT/rejoin.log" 2>&1
C2=$?
wait $HOST
H=$?
grep -h "^MPT" "$OUT/host.log" "$OUT/client.log" "$OUT/rejoin.log"
grep -h "SCRIPT ERROR" -A3 "$OUT"/*.log | head -20
echo "exit codes: host=$H client=$C1 rejoin=$C2"
[ $H -eq 0 ] && [ $C1 -eq 0 ] && [ $C2 -eq 0 ]
