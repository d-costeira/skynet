# shellcheck shell=bash
# Shared helpers for the foundation setup scripts. Source it, don't run it.

set -euo pipefail

FOUNDATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../skynet.conf
source "${FOUNDATION_DIR}/skynet.conf"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this with sudo: sudo $0"
}

require_ubuntu_2404() {
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID}" == "ubuntu" && "${VERSION_ID}" == "24.04" ]] \
    || die "Expected Ubuntu 24.04, found ${PRETTY_NAME}."
}

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "${answer}" =~ ^[Yy]$ ]]
}
