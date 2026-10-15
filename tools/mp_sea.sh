#!/bin/bash
# Multiplayer at sea: a host on an archipelago and a client who joins, rides the
# host's raft as it sails, paddles it, and leads a goat.  Exit 0 = all passed.
cd "$(dirname "$0")/.."
PORT=${PORT:-7793}
GODOT=${GODOT:-godot}
OUT=${OUT:-/tmp/skyroot_mp_sea}
mkdir -p "$OUT"
rm -f "$OUT"/*.log
$GODOT --headless --path . -- --autostart=host --world=MPSea --new --kind=sea --seed=12345 --name=Host --port=$PORT --mptest=sea_host > "$OUT/host.log" 2>&1 &
HOST=$!
sleep 8
$GODOT --headless --path . -- --autostart=join --ip=127.0.0.1 --port=$PORT --name=Ana --mptest=sea_client > "$OUT/client.log" 2>&1
C=$?
wait $HOST
H=$?
grep -h "^MPT" "$OUT/host.log" "$OUT/client.log"
grep -h "SCRIPT ERROR" -A3 "$OUT"/*.log | head -20
echo "exit codes: host=$H client=$C"
[ $H -eq 0 ] && [ $C -eq 0 ]
