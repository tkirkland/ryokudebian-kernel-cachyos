#!/bin/bash
# Build one CachyOS kernel with OpenZFS compiled BUILTIN (CONFIG_ZFS=y, no
# module, no dkms) as image+headers debs, plus the matching ZFS userland
# tarball from the SAME zfs tree. Same shape as tkirkland/ryokudebian-kernel;
# the difference is the source: CachyOS's pre-patched tree, its BORE patch and
# its config, built with gcc like CachyOS's own linux-cachyos-bore.
# Runs as root inside a throwaway debian:trixie container, never on a host.
# Usage: build.sh <cachyos tag, e.g. cachyos-7.2.11-1> <linux-cachyos dir, e.g. linux-cachyos-bore>
#                 <linux-cachyos commit> <kernel-patches commit> <zfs tag> <outdir>
set -euo pipefail
SRC=$1 DIR=$2 SHA=$3 PSHA=$4 ZFS_TAG=$5 OUT=$6
# Distinct from ryokudebian-kernel's -ryokudebian: linux-image-<kver>-cachyos
# installs beside linux-image-<kver>-ryokudebian instead of replacing it.
LOCALVERSION=-cachyos
W=/build KSRC=/build/linux ZSRC=/build/zfs
mkdir -p "$W" "$OUT"
# major.minor of the tree; the CachyOS patch set is published per major.
MAJOR=$(sed -E 's/^cachyos-([0-9]+\.[0-9]+).*/\1/' <<<"$SRC")

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends git ca-certificates curl \
  build-essential bc flex bison libssl-dev libelf-dev debhelper rsync cpio \
  kmod python3 libdw-dev zstd xz-utils autoconf automake libtool gettext pkg-config uuid-dev \
  libblkid-dev libtirpc-dev zlib1g-dev libaio-dev libattr1-dev libudev-dev \
  pahole rustc rust-src bindgen libclang-dev >/dev/null

# --- source: CachyOS's tree is published pre-patched (base + fixes); BORE is
# the separate scheduler patch its linux-cachyos-bore PKGBUILD applies -------
cd "$W"
curl -fsSL -o linux.tar.gz \
  "https://github.com/CachyOS/linux/releases/download/${SRC}/${SRC}.tar.gz"
mkdir -p "$KSRC" && tar -xzf linux.tar.gz -C "$KSRC" --strip-components=1
curl -fsSL -o config "https://raw.githubusercontent.com/CachyOS/linux-cachyos/${SHA}/${DIR}/config"
curl -fsSL -o bore.patch \
  "https://raw.githubusercontent.com/cachyos/kernel-patches/${PSHA}/${MAJOR}/sched/0001-bore-cachy.patch"
git clone -q --depth 1 --branch "$ZFS_TAG" https://github.com/openzfs/zfs.git "$ZSRC"

cd "$KSRC"
patch -Np1 < "$W"/bore.patch

# --- config: CachyOS's, then the PKGBUILD defaults it applies on top --------
cp "$W"/config .config
# CachyOS's config is generic x86-64 (v1); the PKGBUILD's empty
# _processor_opt would switch that to -march=native, wrong for a CI build.
scripts/config -e CACHY -e SCHED_BORE -e LTO_NONE \
  -d HZ_300 -e HZ_1000 --set-val HZ 1000 \
  -d HZ_PERIODIC -d NO_HZ_IDLE -d CONTEXT_TRACKING_FORCE -e NO_HZ_FULL_NODEF \
  -e NO_HZ_FULL -e NO_HZ -e NO_HZ_COMMON -e CONTEXT_TRACKING \
  -e PREEMPT -d PREEMPT_LAZY \
  -d CC_OPTIMIZE_FOR_PERFORMANCE -e CC_OPTIMIZE_FOR_PERFORMANCE_O3 \
  -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_ALWAYS
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
scripts/config --set-str LOCALVERSION "" --disable LOCALVERSION_AUTO
make olddefconfig
make rustavailable || echo "WARNING: Rust unavailable, Rust drivers drop out" >&2
make -j"$(nproc)" prepare

# --- graft zfs into the kernel tree ------------------------------------------
cd "$ZSRC"
sh autogen.sh
./configure --enable-linux-builtin --with-linux="$KSRC"
./copy-builtin "$KSRC"

# --- kernel debs -------------------------------------------------------------
cd "$KSRC"
scripts/config --enable ZFS
make olddefconfig
# BTF stays on (CachyOS's DWARF5 config): sched_ext, i.e. the scx schedulers,
# depends on it. The -dbg deb that DWARF implies is skipped by build profile.
for opt in ZFS=y SCHED_BORE=y CACHY=y DEBUG_INFO_BTF=y SCHED_CLASS_EXT=y; do
  grep -q "^CONFIG_$opt" .config || { echo "CONFIG_$opt did not stick" >&2; exit 1; }
done
grep -E '^CONFIG_(CC_VERSION_TEXT|RUST|HZ|X86_64_VERSION)=' .config
# What trixie's toolchain could not keep from CachyOS's (gcc 16) config.
echo "== CachyOS options dropped:"
comm -23 <(grep -E '^CONFIG_.*=[ym]$' "$W"/config | sort) <(sort .config)
# Upstream version keeps CachyOS's tag release; the Debian revision carries
# the zfs release, so a rebuild against a newer zfs still upgrades.
DEB_BUILD_PROFILES=pkg.linux-upstream.nokerneldbg \
  make -j"$(nproc)" LOCALVERSION="$LOCALVERSION" \
  KDEB_PKGVERSION="${SRC#cachyos-}-zfs${ZFS_TAG#zfs-}" \
  bindeb-pkg
cp -v "$W"/linux-{image,headers}-*"$LOCALVERSION"_*.deb "$OUT"/

# --- matching userland (tools only, no module) -------------------------------
cd "$ZSRC"
make distclean >/dev/null 2>&1 || true
# Same flags as ryokudebian-kernel; see its build.sh for why systemd is forced.
./configure --with-config=user --prefix=/usr --sysconfdir=/etc \
  --enable-systemd --disable-sysvinit \
  --with-udevdir=/usr/lib/udev --with-udevruledir=/usr/lib/udev/rules.d \
  --with-mounthelperdir=/usr/sbin \
  --with-systemdunitdir=/usr/lib/systemd/system \
  --with-systemdgeneratordir=/usr/lib/systemd/system-generators
make -j"$(nproc)"
DEST="$W/zfs-userland"
make install DESTDIR="$DEST"
tar -C "$DEST" --owner=root --group=root -czf "$OUT/zfs-userland.tar.gz" .
ls -l "$OUT"
