#!/bin/bash
# Decide what to build: the CachyOS BORE kernel (linux-cachyos-bore, else the
# linux-cachyos-lts fallback, also built with BORE) whose major OpenZFS declares support for,
# against the latest OpenZFS release. Skips anything already published.
# Prints GITHUB_OUTPUT lines: zfs=<tag> and matrix=<json>.
set -euo pipefail
ZFS_GIT=https://github.com/openzfs/zfs.git
PKG_GIT=https://github.com/CachyOS/linux-cachyos.git
PATCH_GIT=https://github.com/CachyOS/kernel-patches.git

# .99 tags are master placeholders that outrank real releases in a sort.
zfs=$(git ls-remote --tags --refs "$ZFS_GIT" 'zfs-*' | awk -F/ '{print $NF}' |
  grep -E '^zfs-[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '\.99$' | sort -V | tail -1)
max=$(curl -fsSL "https://raw.githubusercontent.com/openzfs/zfs/${zfs}/META" |
  awk '/^Linux-Maximum:/{print $2}')
# Pin the packaging commit so the config and the version it names agree.
sha=$(git ls-remote "$PKG_GIT" refs/heads/master | cut -f1)
psha=$(git ls-remote "$PATCH_GIT" refs/heads/master | cut -f1)
[[ -n $zfs && -n $max && -n $sha && -n $psha ]] || { echo "cannot resolve zfs / Linux-Maximum / linux-cachyos" >&2; exit 1; }

matrix=()
for dir in linux-cachyos-bore linux-cachyos-lts; do
  pkgbuild=$(curl -fsSL "https://raw.githubusercontent.com/CachyOS/linux-cachyos/${sha}/${dir}/PKGBUILD")
  get() { sed -n "s/^$1=//p" <<<"$pkgbuild" | head -1; }
  major=$(get _major) minor=$(get _minor) tagrel=$(get _tagrel)
  [[ -n $major && -n $minor && -n $tagrel ]] || { echo "cannot parse $dir/PKGBUILD" >&2; exit 1; }
  if [[ $(printf '%s\n' "$major" "$max" | sort -V | tail -1) != "$max" ]]; then
    echo "skip $dir $major (OpenZFS $zfs supports up to $max)" >&2
    continue
  fi
  src="cachyos-${major}.${minor}-${tagrel}"
  rel="${major}.${minor}-${tagrel}-${zfs}"
  if gh release view "$rel" >/dev/null 2>&1; then
    echo "skip $rel (published)" >&2
  else
    matrix+=("{\"src\":\"$src\",\"dir\":\"$dir\",\"sha\":\"$sha\",\"psha\":\"$psha\",\"rel\":\"$rel\"}")
  fi
  break   # one kernel: the newest CachyOS line OpenZFS supports
done
echo "zfs=$zfs"
echo "matrix=[$(IFS=,; echo "${matrix[*]}")]"
