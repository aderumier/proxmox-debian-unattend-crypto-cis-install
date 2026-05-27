#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/proxmox-preseed.template"

IP="" GATEWAY="" DNS="" HOSTNAME="" DOMAIN="" OUTPUT=""

usage() {
    cat <<EOF
Usage: $0 --ip <ip/prefix> --gateway <gw> --dns <dns> --hostname <name> [--domain <domain>] [--output <file>]

  --ip        IP address with prefix length (e.g. 192.168.1.10/24)
  --gateway   Default gateway IP
  --dns       DNS nameserver IP
  --hostname  Short hostname (e.g. proxmox2)
  --domain    Domain name (optional, default: cyllene.com)
  --output    Output file (default: proxmox-preseed-<hostname>.txt)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)       IP="$2";       shift 2 ;;
        --gateway)  GATEWAY="$2";  shift 2 ;;
        --dns)      DNS="$2";      shift 2 ;;
        --hostname) HOSTNAME="$2"; shift 2 ;;
        --domain)   DOMAIN="$2";   shift 2 ;;
        --output)   OUTPUT="$2";   shift 2 ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

[[ -z "$IP"       ]] && { echo "Error: --ip is required";       usage; }
[[ -z "$GATEWAY"  ]] && { echo "Error: --gateway is required";  usage; }
[[ -z "$DNS"      ]] && { echo "Error: --dns is required";      usage; }
[[ -z "$HOSTNAME" ]] && { echo "Error: --hostname is required"; usage; }
[[ -z "$DOMAIN"   ]] && DOMAIN="cyllene.com"

IP_ADDR="${IP%%/*}"
[[ -z "$OUTPUT" ]] && OUTPUT="${SCRIPT_DIR}/proxmox-preseed-${HOSTNAME}.txt"

cp "$TEMPLATE" "$OUTPUT"

sed -i \
  -e "s|__HOSTNAME__|${HOSTNAME}|g" \
  -e "s|__DOMAIN__|${DOMAIN}|g" \
  -e "s|__IP__|${IP}|g" \
  -e "s|__IP_ADDR__|${IP_ADDR}|g" \
  -e "s|__GATEWAY__|${GATEWAY}|g" \
  -e "s|__DNS__|${DNS}|g" \
  "$OUTPUT"

echo "Generated: $OUTPUT"
