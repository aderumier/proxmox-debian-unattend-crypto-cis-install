# Proxmox VE Unattended Install

Tooling to build a self-contained ISO that installs Proxmox VE fully unattended via a Debian preseed file. No network access is required during installation — all packages are embedded in the ISO.

## Overview

```
debian.iso + proxmox-ve.iso  ──►  inject_repo.sh  ──►  debian_proxmox.iso
                                                              │
proxmox-preseed.template  ──►  generate-preseed.sh  ──►  preseed.cfg
                                                              │
                                    USB key (Ventoy)  ◄──────┘
                                    └── debian_proxmox.iso
                                    └── ventoy/ventoy.json  (preseed path)
```

---

## 1. Build the ISO — `inject_repo.sh`

Injects all Proxmox VE `.deb` packages from the Proxmox ISO into the Debian installer ISO as a local unsigned apt suite (`pve-local/pve`). The Debian ISO's signed metadata is left untouched so apt signature verification still passes.

### Requirements

```bash
sudo apt install xorriso dpkg-dev
```

### Usage

```bash
./inject_repo.sh <debian.iso> <proxmox-ve.iso> <output.iso>
```

**Example:**

```bash
./inject_repo.sh \
  debian-13.5.0-amd64-DVD-1.iso \
  proxmox-ve_9.2-1.iso \
  debian_proxmox_ve_9.2-1.iso
```

The script:
1. Extracts all `.deb` files from the Proxmox ISO
2. Generates a `Packages` index with `dpkg-scanpackages`
3. Writes an unsigned `Release` file for the `pve-local` suite
4. Clones the Debian ISO and injects the suite, preserving all boot data

The resulting ISO is bootable and contains both the Debian installer and the full Proxmox VE package set.

---

## 2. Generate a preseed file — `generate-preseed.sh`

Produces a ready-to-use preseed file from `proxmox-preseed.template` by substituting per-host network parameters.

### Usage

```bash
./generate-preseed.sh \
  --ip       <ip/prefix> \
  --gateway  <gw> \
  --dns      <dns> \
  --hostname <name> \
  [--domain  <domain>] \
  [--output  <file>]
```

| Option | Required | Description |
|--------|----------|-------------|
| `--ip` | yes | IP address with prefix length, e.g. `192.168.1.10/24` |
| `--gateway` | yes | Default gateway IP |
| `--dns` | yes | DNS nameserver IP |
| `--hostname` | yes | Short hostname, e.g. `proxmox2` |
| `--domain` | no | Domain name (default: `cyllene.com`) |
| `--output` | no | Output path (default: `proxmox-preseed-<hostname>.txt`) |

**Example:**

```bash
./generate-preseed.sh \
  --ip 192.168.1.10/24 \
  --gateway 192.168.1.1 \
  --dns 192.168.1.1 \
  --hostname proxmox1 \
  --domain example.com
# → proxmox-preseed-proxmox1.txt
```

### Template placeholders

| Placeholder | Replaced by |
|-------------|-------------|
| `__HOSTNAME__` | `--hostname` value |
| `__DOMAIN__` | `--domain` value |
| `__IP__` | `--ip` value (full CIDR) |
| `__IP_ADDR__` | IP part only, without prefix |
| `__GATEWAY__` | `--gateway` value |
| `__DNS__` | `--dns` value |

### What the preseed configures

- Locale: `fr_FR.UTF-8`, keyboard `fr`
- Network: skipped during install (configured in `late_command`)
- Disk: encrypted LVM on `/dev/sda` with separate logical volumes for `/`, `/home`, `/var`, `/var/log`, `/var/log/audit`, `/var/tmp`, `/tmp`, swap
- Users: `root` with preconfigured password + `ansible` user
- `late_command`:
  - Installs Proxmox VE kernel, GRUB (EFI), and `proxmox-ve` from the embedded local repo
  - Pins NIC names to `nic1`, `nic2`, … via systemd `.link` files
  - Writes `/etc/network/interfaces` with a `bond0` (LACP 802.3ad) + `vmbr0` bridge
  - Sets `/etc/hosts` and `/etc/resolv.conf`

---

## 3. Deploy with Ventoy

[Ventoy](https://www.ventoy.net) turns a USB key into a multi-boot drive. It can pass a preseed file to the Debian installer automatically.

### 3.1 Install Ventoy on the USB key

> **Warning:** this erases all data on the USB key.

**Download Ventoy:**

```bash
# Check latest release at https://github.com/ventoy/Ventoy/releases
wget https://github.com/ventoy/Ventoy/releases/download/v1.0.99/ventoy-1.0.99-linux.tar.gz
tar -xf ventoy-1.0.99-linux.tar.gz
cd ventoy-1.0.99/
```

**Identify your USB device:**

```bash
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL
# Look for a disk with TRAN=usb, e.g. /dev/sdb
```

**Format the USB key with Ventoy:**

```bash
sudo ./Ventoy2Disk.sh -I /dev/sdX   # replace /dev/sdX with your USB device
```

`-I` performs a clean install (use `-U` to upgrade an existing Ventoy installation without erasing the data partition).

Ventoy creates two partitions:
- `VTOYEFI` — small EFI/boot partition (do not touch)
- `Ventoy` — large data partition formatted as exFAT (copy ISOs and scripts here)

**Mount the data partition:**

```bash
# It may auto-mount, otherwise:
sudo mount /dev/sdX2 /mnt/ventoy
```

### 3.2 Copy the ISO

Copy the ISO to the Ventoy data partition:

```bash
cp debian_proxmox_ve_9.2-1.iso /mnt/ventoy/
```

### 3.3 Add the preseed file

Copy the generated preseed file into the `/script/` directory on the Ventoy partition:

```bash
mkdir -p /mnt/ventoy/script
cp proxmox-preseed-proxmox1.txt /mnt/ventoy/script/
```

### 3.4 Configure Ventoy to inject the preseed

Create `/mnt/ventoy/ventoy/ventoy.json` to tell Ventoy which preseed file to use for the ISO:

```json
{
    "auto_install": [
        {
            "image": "/debian_proxmox_ve_9.2-1.iso",
            "template": [
                "/script/proxmox-preseed-proxmox1.txt"
            ]
        }
    ]
}
```

Ventoy injects the preseed path as a kernel parameter (`preseed/file`) so the Debian installer finds it automatically on boot.

### 3.5 Boot and install

1. Insert the USB key and boot from it
2. Select the ISO in the Ventoy menu
3. The installation runs fully unattended and reboots when done

### Final USB layout

```
Ventoy (data partition)
├── debian_proxmox_ve_9.2-1.iso
├── script/
│   └── proxmox-preseed-proxmox1.txt
└── ventoy/
    └── ventoy.json
```
