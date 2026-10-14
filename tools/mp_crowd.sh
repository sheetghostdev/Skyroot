#!/bin/bash
# Four players on one island (host + three clients as separate instances on
# this machine): they all grab from the same pile of stones at once, and a
# fifth player is turned away.  Exit code 0 = all checks passed.
cd "$(dirname "$0")/.."
PORT=${PORT:-7792}
GODOT=${GODOT:-godot}
OUT=${OUT:-/tmp/skyroot_mp}
mkdir -p "$OUT"
rm -f "$OUT"/crowd_*.log
$GODOT --headless --path . -- --autostart=host --world=MPCrowd --new --name=Host --port=$PORT --mptest=crowd_host > "$OUT/crowd_host.log" 2>&1 &
HOST=$!
sleep 6
PIDS=""
for NAME in Ana Bo Cy; do
	$GODOT --headless --path . -- --autostart=join --ip=127.0.0.1 --port=$PORT --name=$NAME --mptest=crowd > "$OUT/crowd_$NAME.log" 2>&1 &
	PIDS="$PIDS $!"
	sleep 1
done
sleep 12
$GODOT --headless --path . -- --autostart=join --ip=127.0.0.1 --port=$PORT --name=Dee --mptest=fifth > "$OUT/crowd_fifth.log" 2>&1
F=$?
# let the host know the fifth attempt is over (via a file the host doesn't need: it waits on chat)
RC=0
for P in $PIDS; do wait $P || RC=1; done
wait $HOST
H=$?
grep -h "^MPT" "$OUT"/crowd_*.log
grep -h "SCRIPT ERROR" -A3 "$OUT"/crowd_*.log | head -20
echo "exit codes: host=$H clients=$RC fifth=$F"
[ $H -eq 0 ] && [ $RC -eq 0 ] && [ $F -eq 0 ]
