#!/bin/bash
# Keep the newest $KEEP releases (current + previous, for rollback) and delete
# the rest with their git tags. Run only after <rel> was published; refuses
# unless <rel> lists <n> uploaded assets, so a failed build never prunes.
# Usage: prune.sh <rel> <n>
set -euo pipefail
KEEP=${KEEP:-2}
rel=$1 want=$2
have=$(gh release view "$rel" --json assets -q '.assets | map(select(.state == "uploaded")) | length')
[[ $have -eq $want ]] || { echo "$rel has $have/$want assets, not pruning" >&2; exit 1; }
# Newest first by publish time, not version: an lts fallback (6.x) published
# after a bore build (7.x) is still the current one. <rel> itself never goes.
gh release list --limit 200 --json tagName,createdAt \
  -q 'sort_by(.createdAt) | reverse | .[].tagName' |
  { grep -- '-zfs-' | grep -vxF "$rel" || true; } |
  tail -n +"$KEEP" |
  while read -r old; do
    echo "deleting $old (keeping $KEEP)"
    gh release delete "$old" --cleanup-tag -y
  done
