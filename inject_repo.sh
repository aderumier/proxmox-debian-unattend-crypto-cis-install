#!/usr/bin/env bash

set -euo pipefail

# inject_repo.sh - Inject a vendor ISO's packages into a Debian ISO
#
# Strategy:
#   - The Debian ISO's signed trixie Release/InRelease/Release.gpg are left
#     completely untouched.  Modifying them would break apt-cdrom signature
#     verification and prevent grub-efi-amd64 (and everything else) from
#     being installed.
#   - ALL .deb files found anywhere in the vendor ISO (dists/, proxmox/packages/,
#     etc.) are collected and placed into a synthetic unsigned apt suite
#     "pve-local/pve/binary-amd64/" with a freshly generated Packages index.
#   - late_command adds "deb [trusted=yes] file:///media/cdrom pve-local pve"
#     and installs proxmox-ve after Debian's base system is on disk.
#
# Usage:
#   ./inject_repo.sh <debian.iso> <vendor.iso> <output.iso>
#
# Requirements: xorriso dpkg-dev (for dpkg-scanpackages)

##############################################################################
# Args
##############################################################################

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <debian.iso> <vendor.iso> <output.iso>"
    exit 1
fi

DEBIAN_ISO="$1"
VENDOR_ISO="$2"
OUTPUT_ISO="$3"

PVE_LOCAL_SUITE="pve-local"
PVE_COMP="pve"

##############################################################################
# Dependency check
##############################################################################

for cmd in xorriso dpkg-scanpackages gzip; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd not found."
        [ "$cmd" = "dpkg-scanpackages" ] && echo "  Install with: sudo apt install dpkg-dev"
        exit 1
    fi
done

for iso in "$DEBIAN_ISO" "$VENDOR_ISO"; do
    [ -f "$iso" ] || { echo "Error: ISO not found: $iso"; exit 1; }
done

##############################################################################
# Workspace
##############################################################################

WORK_DIR=$(mktemp -d /tmp/injectiso.XXXXXX)
trap 'echo "Cleaning up..."; rm -rf "$WORK_DIR"' EXIT

VENDOR_DIR="$WORK_DIR/vendor"
INJECT_DIR="$WORK_DIR/inject"
BINARY_DIR="$INJECT_DIR/dists/$PVE_LOCAL_SUITE/$PVE_COMP/binary-amd64"
mkdir -p "$VENDOR_DIR" "$BINARY_DIR"

##############################################################################
# Extract vendor ISO
##############################################################################

echo "==> Extracting vendor ISO..."
xorriso -osirrox on -indev "$VENDOR_ISO" -extract / "$VENDOR_DIR" 2>/dev/null
chmod -R u+w "$VENDOR_DIR"

##############################################################################
# Collect ALL .deb files from vendor ISO, dereferencing any symlinks
##############################################################################

echo "==> Collecting .deb packages from vendor ISO..."
count=0
while IFS= read -r deb; do
    # Resolve symlinks so we always copy the real file content
    real=$(readlink -f "$deb" 2>/dev/null)
    [ -f "${real:-}" ] || real="$deb"
    [ -f "$real" ]     || { echo "    SKIP (unresolvable): $deb"; continue; }
    cp "$real" "$BINARY_DIR/"
    count=$((count + 1))
done < <(find "$VENDOR_DIR" -name "*.deb" | sort)
echo "    Collected $count packages"

[ "$count" -gt 0 ] || { echo "Error: no .deb files found in vendor ISO"; exit 1; }

##############################################################################
# Generate Packages index
##############################################################################

echo "==> Generating Packages index..."
PVE_LOCAL_DIR="$INJECT_DIR/dists/$PVE_LOCAL_SUITE"

# dpkg-scanpackages needs to run from INJECT_DIR so Filename: paths are
# relative to the ISO root (e.g. dists/pve-local/pve/binary-amd64/pkg.deb)
(cd "$INJECT_DIR" && \
    dpkg-scanpackages "dists/$PVE_LOCAL_SUITE/$PVE_COMP/binary-amd64/" \
    > "dists/$PVE_LOCAL_SUITE/$PVE_COMP/binary-amd64/Packages")
gzip -k "$BINARY_DIR/Packages"

indexed=$(grep -c '^Package:' "$BINARY_DIR/Packages" || true)
echo "    Indexed $indexed packages (collected $count .deb files)"
echo "==> Key packages in index:"
grep '^Package:' "$BINARY_DIR/Packages" | grep -E 'proxmox-ve|pve-manager|proxmox-kernel' | sort || \
    echo "    WARNING: none of proxmox-ve / pve-manager / proxmox-kernel found in index!"

##############################################################################
# Helpers for Release checksums
##############################################################################

append_hashes() {
    local header="$1" hashcmd="$2" dist_dir="$3"
    echo "$header"
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        local rel size hash
        rel="${f#$dist_dir/}"
        size=$(stat -c %s "$f")
        hash=$("$hashcmd" "$f" | awk '{print $1}')
        printf " %s %8d %s\n" "$hash" "$size" "$rel"
    done < <(find "$dist_dir" -type f \
        ! -name "Release" ! -name "Release.gpg" ! -name "InRelease" \
        | sort)
}

##############################################################################
# Write pve-local Release (unsigned — accessed only via [trusted=yes])
##############################################################################

{
    cat <<EOF
Origin: Proxmox
Label: Proxmox VE
Suite: $PVE_LOCAL_SUITE
Codename: $PVE_LOCAL_SUITE
Components: $PVE_COMP
Architectures: amd64
Description: Proxmox VE packages injected from ISO — used by late_command only
EOF
    append_hashes "MD5Sum:"  md5sum    "$PVE_LOCAL_DIR"
    append_hashes "SHA1:"    sha1sum   "$PVE_LOCAL_DIR"
    append_hashes "SHA256:"  sha256sum "$PVE_LOCAL_DIR"
} > "$PVE_LOCAL_DIR/Release"

echo "==> Created suite '$PVE_LOCAL_SUITE/$PVE_COMP' with $count packages"

##############################################################################
# Repack: clone Debian ISO, inject pve-local suite, replay boot data
##############################################################################

echo "==> Repacking ISO..."

xorriso \
    -indev "$DEBIAN_ISO" \
    -outdev "$OUTPUT_ISO" \
    -map "$PVE_LOCAL_DIR" "/dists/$PVE_LOCAL_SUITE" \
    -boot_image any replay \
    2>&1 | grep -v "^xorriso : UPDATE" || true

echo
echo "==> Done: $OUTPUT_ISO"
echo "    Use in preseed late_command:"
echo "    deb [trusted=yes] file:///media/cdrom $PVE_LOCAL_SUITE $PVE_COMP"
