#!/usr/bin/env bash

set -euo pipefail

# build-iso.sh - Build a fully unattended, self-contained Proxmox VE install ISO
#
# Merges a Debian installer ISO with the Proxmox VE package set AND embeds a
# preseed file so the installer runs hands-free, with NO Ventoy and NO network
# access required.
#
# Two things are injected into the Debian ISO:
#   1. All Proxmox VE .deb packages, as an unsigned local apt suite
#      "pve-local/pve" (same scheme as inject_repo.sh). The Debian ISO's signed
#      Release/InRelease are left untouched so apt signature verification still
#      works for the base system.
#   2. The preseed file, appended into the installer's initrd as /preseed.cfg.
#      Debian's installer auto-loads a preseed found at the root of its initrd,
#      which is the most reliable method (it is read before any question is
#      asked and needs no cdrom to be mounted first).
#
# The BIOS (isolinux) and UEFI (grub) boot menus are replaced with a single
# auto-install entry that boots with "auto=true priority=critical", so the
# install starts on its own after a short timeout.
#
# Usage:
#   ./build-iso.sh <debian.iso> <proxmox-ve.iso> <preseed.cfg> <output.iso>
#
# Example:
#   ./build-iso.sh \
#       debian-13.5.0-amd64-DVD-1.iso \
#       proxmox-ve_9.2-1.iso \
#       proxmox-preseed-proxmox1.txt \
#       debian_proxmox_autoinstall.iso
#
# Requirements: xorriso dpkg-dev (dpkg-scanpackages) gzip cpio

##############################################################################
# Args
##############################################################################

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <debian.iso> <proxmox-ve.iso> <preseed.cfg> <output.iso>"
    exit 1
fi

DEBIAN_ISO="$1"
VENDOR_ISO="$2"
PRESEED_FILE="$3"
OUTPUT_ISO="$4"

PVE_LOCAL_SUITE="pve-local"
PVE_COMP="pve"

# Installer kernel / initrd paths inside a Debian amd64 installer ISO.
# These are stable across Debian releases.
INSTALL_DIR="install.amd"
KERNEL_PATH="/$INSTALL_DIR/vmlinuz"

##############################################################################
# Dependency check
##############################################################################

for cmd in xorriso dpkg-scanpackages gzip cpio; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd not found."
        [ "$cmd" = "dpkg-scanpackages" ] && echo "  Install with: sudo apt install dpkg-dev"
        [ "$cmd" = "xorriso" ]           && echo "  Install with: sudo apt install xorriso"
        exit 1
    fi
done

for f in "$DEBIAN_ISO" "$VENDOR_ISO" "$PRESEED_FILE"; do
    [ -f "$f" ] || { echo "Error: file not found: $f"; exit 1; }
done

##############################################################################
# Workspace
##############################################################################

WORK_DIR=$(mktemp -d /tmp/buildiso.XXXXXX)
trap 'echo "Cleaning up..."; rm -rf "$WORK_DIR"' EXIT

VENDOR_DIR="$WORK_DIR/vendor"
INJECT_DIR="$WORK_DIR/inject"
ISO_FILES="$WORK_DIR/isofiles"   # modified files mapped back onto the ISO
BINARY_DIR="$INJECT_DIR/dists/$PVE_LOCAL_SUITE/$PVE_COMP/binary-amd64"
mkdir -p "$VENDOR_DIR" "$BINARY_DIR" "$ISO_FILES"

##############################################################################
# 1. Collect Proxmox packages and build the pve-local suite
##############################################################################

echo "==> Extracting Proxmox ISO..."
xorriso -osirrox on -indev "$VENDOR_ISO" -extract / "$VENDOR_DIR" 2>/dev/null
chmod -R u+w "$VENDOR_DIR"

echo "==> Collecting .deb packages from Proxmox ISO..."
count=0
while IFS= read -r deb; do
    real=$(readlink -f "$deb" 2>/dev/null)
    [ -f "${real:-}" ] || real="$deb"
    [ -f "$real" ]     || { echo "    SKIP (unresolvable): $deb"; continue; }
    cp "$real" "$BINARY_DIR/"
    count=$((count + 1))
done < <(find "$VENDOR_DIR" -name "*.deb" | sort)
echo "    Collected $count packages"
[ "$count" -gt 0 ] || { echo "Error: no .deb files found in Proxmox ISO"; exit 1; }

echo "==> Generating Packages index..."
PVE_LOCAL_DIR="$INJECT_DIR/dists/$PVE_LOCAL_SUITE"
(cd "$INJECT_DIR" && \
    dpkg-scanpackages "dists/$PVE_LOCAL_SUITE/$PVE_COMP/binary-amd64/" \
    > "dists/$PVE_LOCAL_SUITE/$PVE_COMP/binary-amd64/Packages")
gzip -k "$BINARY_DIR/Packages"

indexed=$(grep -c '^Package:' "$BINARY_DIR/Packages" || true)
echo "    Indexed $indexed packages"
echo "==> Key packages in index:"
grep '^Package:' "$BINARY_DIR/Packages" | grep -E 'proxmox-ve|pve-manager|proxmox-kernel' | sort || \
    echo "    WARNING: none of proxmox-ve / pve-manager / proxmox-kernel found in index!"

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
# 2. Embed the preseed into the installer initrd(s)
##############################################################################

# Debian auto-loads a preseed named "preseed.cfg" at the root of the initrd.
PRESEED_STAGE="$WORK_DIR/preseed"
mkdir -p "$PRESEED_STAGE"
cp "$PRESEED_FILE" "$PRESEED_STAGE/preseed.cfg"

embed_preseed() {
    # $1 = initrd path inside the ISO (e.g. /install.amd/initrd.gz)
    local iso_path="$1"
    local dest="$ISO_FILES$iso_path"

    echo "==> Extracting initrd $iso_path ..."
    mkdir -p "$(dirname "$dest")"
    if ! xorriso -osirrox on -indev "$DEBIAN_ISO" \
            -extract "$iso_path" "$dest" 2>/dev/null; then
        echo "    (not present on ISO — skipping)"
        rm -f "$dest"
        return 1
    fi

    echo "    Appending preseed.cfg to $(basename "$iso_path") ..."
    # Files extracted from the ISO are read-only; make them writable so
    # gunzip can replace them and cpio can append to the archive.
    chmod -R u+w "$(dirname "$dest")"
    gunzip -f "$dest"                       # initrd.gz -> initrd
    local plain="${dest%.gz}"
    chmod u+w "$plain"
    if ! ( cd "$PRESEED_STAGE" && \
           echo "preseed.cfg" | cpio --quiet -H newc -o -A -F "$plain" ); then
        echo "Error: failed to append preseed.cfg to $iso_path" >&2
        exit 1
    fi
    gzip -f "$plain"                        # initrd -> initrd.gz
    return 0
}

embedded=0
for initrd in "/$INSTALL_DIR/initrd.gz" "/$INSTALL_DIR/gtk/initrd.gz"; do
    if embed_preseed "$initrd"; then
        embedded=$((embedded + 1))
    fi
done
[ "$embedded" -gt 0 ] || { echo "Error: no installer initrd found on Debian ISO"; exit 1; }
echo "    Preseed embedded into $embedded initrd image(s)"

##############################################################################
# 3. Replace boot menus with a single auto-install entry
##############################################################################

echo "==> Writing auto-install boot menus..."

# --- BIOS / isolinux ---
mkdir -p "$ISO_FILES/isolinux"
cat > "$ISO_FILES/isolinux/isolinux.cfg" <<EOF
default auto
prompt 0
timeout 50

label auto
  kernel $KERNEL_PATH
  append initrd=/$INSTALL_DIR/initrd.gz auto=true priority=critical vga=788 ---
EOF

# --- UEFI / grub ---
mkdir -p "$ISO_FILES/boot/grub"
cat > "$ISO_FILES/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

menuentry "Automated Proxmox VE install" {
    linux  $KERNEL_PATH auto=true priority=critical ---
    initrd /$INSTALL_DIR/initrd.gz
}
EOF

##############################################################################
# 4. Repack: clone Debian ISO, inject suite + modified files, replay boot
##############################################################################

echo "==> Repacking ISO..."

MAP_ARGS=(-map "$PVE_LOCAL_DIR" "/dists/$PVE_LOCAL_SUITE")
# Map every modified file under $ISO_FILES back to its ISO path.
while IFS= read -r f; do
    iso_path="${f#$ISO_FILES}"
    MAP_ARGS+=(-map "$f" "$iso_path")
done < <(find "$ISO_FILES" -type f | sort)

xorriso \
    -indev "$DEBIAN_ISO" \
    -outdev "$OUTPUT_ISO" \
    "${MAP_ARGS[@]}" \
    -boot_image any replay \
    2>&1 | grep -v "^xorriso : UPDATE" || true

echo
echo "==> Done: $OUTPUT_ISO"
echo "    Boot it (BIOS or UEFI) and the Proxmox VE install runs unattended."
echo "    Preseed source: $PRESEED_FILE"
