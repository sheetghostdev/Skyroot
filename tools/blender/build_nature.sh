#!/usr/bin/env bash
# Regenerate every Skyroot nature model (assets/models/nature/*.glb) + previews.
#   tools/blender/build_nature.sh            (uses $BLENDER or /usr/local/bin/blender)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLENDER="${BLENDER:-/usr/local/bin/blender}"
SCRIPTS=(
  nature_rocks.py        # boulder_a/b/c, flat_stone, outcrop (+Loose_0..7)
  nature_tree.py         # skyroot_tree (Trunk/Roots/Stump/BranchS_*/BranchL_*/CrownLeaves)
  nature_young_trees.py  # sapling, young_tree
  nature_crops.py        # crop_tuber/grain/fiber_s0..s3
  nature_plants.py       # berry_bush, mushroom_cluster, grass_tuft, fern, flowers_a, wild_grain
  nature_misc.py         # mossy_log, hanging_roots, hanging_vines
)
for s in "${SCRIPTS[@]}"; do
  echo "=== $s"
  out="$("$BLENDER" -b --python-exit-code 1 --python "$HERE/$s" 2>&1)" || { echo "$out" | tail -40; echo "FAILED: $s"; exit 1; }
  echo "$out" | grep -E '^\[(export|tree|outcrop|flat_stone)\]' || true
done
echo "done: $(ls "$HERE/../../assets/models/nature/"*.glb | wc -l) nature models"
