#!/usr/bin/env bash
# Regenerate Skyroot's character, crafting-item and building-piece models.
#
#   tools/blender/build_craft.sh            # build everything + Cycles previews
#   tools/blender/build_craft.sh nopreview  # build everything, skip previews
#
# Outputs:  assets/models/character/{body,fp_arm_r,fp_arm_l}.glb
#           assets/models/items/*.glb
#           assets/models/build/*.glb
# Previews: tools/blender/previews/{char_*,fp_*,items_*,build_*}.png
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLENDER="${BLENDER:-/usr/local/bin/blender}"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${LOG_DIR}"' EXIT

scripts=(
  char_body.py
  char_fp_arms.py
  items_wood.py
  items_plants.py
  items_food.py
  items_earth.py
  build_pieces.py
)

status=0
for s in "${scripts[@]}"; do
  echo "=== ${s} ==="
  log="${LOG_DIR}/${s%.py}.log"
  "${BLENDER}" -b --factory-startup --python-exit-code 1 --python "${HERE}/${s}" -- "$@" >"${log}" 2>&1
  rc=$?
  grep -E "^\[(body|fp|item|build|glb|export)\]|OVER BUDGET" "${log}" || true
  if [ ${rc} -ne 0 ] || grep -q "Traceback" "${log}"; then
    echo "!!! ${s} failed (exit ${rc}):" >&2
    grep -A 20 "Traceback" "${log}" >&2 || tail -n 30 "${log}" >&2
    status=1
  fi
done
[ ${status} -eq 0 ] && echo "done." || echo "finished with errors." >&2
exit ${status}
