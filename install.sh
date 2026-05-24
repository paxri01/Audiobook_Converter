#!/bin/bash
# shellcheck disable=SC1091

## ========================================================================================
##       Title: install.sh
##      Author: R. L. Paxton
##     Version: 2.0
##        Date: 2026-04-08
##     License: Apache 2.0
## Description: Installer for ccab — Audiobook Conversion and Archive Builder
## ========================================================================================

set -euo pipefail

INSTALL_BIN="${INSTALL_BIN:-$HOME/.local/bin}"
INSTALL_CONF="${INSTALL_CONF:-$HOME/.config}"
CCAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Colours (minimal — no config loaded yet)
# ---------------------------------------------------------------------------
C0="$(printf '\033[0;00m')"
C1="$(printf '\033[38;5;160m')"   # Red
C2="$(printf '\033[38;5;040m')"   # Green
C3="$(printf '\033[38;5;184m')"   # Yellow
C4="$(printf '\033[38;5;032m')"   # Blue
C8="$(printf '\033[38;5;237m')"   # Grey

info()  { echo -e "  ${C4}[INFO]${C0}  $*"; }
ok()    { echo -e "  ${C2}[OK]${C0}    $*"; }
warn()  { echo -e "  ${C3}[WARN]${C0}  $*"; }
error() { echo -e "  ${C1}[ERROR]${C0} $*" >&2; }

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_deps()
{
    local missing=0
    for cmd in ffmpeg ffprobe mid3v2 curl jq python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Missing required dependency: $cmd"
            ((missing++))
        fi
    done
    if [[ $missing -gt 0 ]]; then
        error "$missing required dependency/dependencies not found — install them first"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

install_ccab()
{
    echo
    echo -e "${C4}=== Installing ccab ===${C0}"
    echo

    check_deps

    # Create bin directory
    if [[ ! -d "$INSTALL_BIN" ]]; then
        mkdir -p "$INSTALL_BIN"
        ok "Created: $INSTALL_BIN"
    fi

    # Install binary
    install -m 755 "$CCAB_ROOT/bin/ccab" "$INSTALL_BIN/ccab"
    ok "Installed binary: $INSTALL_BIN/ccab"

    # Install libraries and Python parser
    local lib_dest="$HOME/.local/share/ccab/lib"
    mkdir -p "$lib_dest"
    install -m 644 "$CCAB_ROOT"/lib/*.sh   "$lib_dest/"
    install -m 644 "$CCAB_ROOT"/lib/*.py   "$lib_dest/"
    install -m 644 "$CCAB_ROOT"/lib/*.png  "$lib_dest/" 2>/dev/null || true
    ok "Installed libraries: $lib_dest"

    # Install config (don't overwrite existing)
    if [[ ! -f "$INSTALL_CONF/smart-ccab.conf" ]]; then
        cp "$CCAB_ROOT/config/smart-ccab.conf" "$INSTALL_CONF/smart-ccab.conf"
        ok "Installed config: $INSTALL_CONF/smart-ccab.conf"
    else
        warn "Config already exists — not overwritten: $INSTALL_CONF/smart-ccab.conf"
    fi

    # Log directory
    local log_dir="/var/log/ccab"
    if [[ ! -d "$log_dir" ]]; then
        if mkdir -p "$log_dir" 2>/dev/null; then
            ok "Created log directory: $log_dir"
        else
            warn "Cannot create $log_dir — update logDir in your config to a writable path"
        fi
    fi

    echo
    echo -e "${C2}Installation complete.${C0}"
    echo

    # PATH check
    if ! echo ":$PATH:" | grep -q ":$INSTALL_BIN:"; then
        warn "$INSTALL_BIN is not in your PATH"
        echo -e "  ${C8}Add this to your shell profile:${C0}"
        echo -e "    ${C3}export PATH=\"\$HOME/.local/bin:\$PATH\"${C0}"
        echo
    fi

    echo -e "  ${C8}Run:${C0} ${C4}ccab --check${C0}   to verify all dependencies"
    echo -e "  ${C8}Run:${C0} ${C4}ccab -h${C0}        for usage information"
    echo
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

uninstall_ccab()
{
    echo
    echo -e "${C4}=== Uninstalling ccab ===${C0}"
    echo

    local removed=0

    if [[ -f "$INSTALL_BIN/ccab" ]]; then
        rm -f "$INSTALL_BIN/ccab"
        ok "Removed: $INSTALL_BIN/ccab"
        ((removed++)) || true
    fi

    local lib_dest="$HOME/.local/share/ccab"
    if [[ -d "$lib_dest" ]]; then
        rm -rf "$lib_dest"
        ok "Removed: $lib_dest"
        ((removed++)) || true
    fi

    warn "Config preserved: $INSTALL_CONF/smart-ccab.conf  (remove manually if desired)"
    echo
    [[ $removed -gt 0 ]] && echo -e "${C2}Uninstall complete.${C0}" || \
        echo -e "${C3}Nothing to uninstall.${C0}"
    echo
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

case "${1:-install}" in
    install)   install_ccab ;;
    uninstall) uninstall_ccab ;;
    *)
        echo "Usage: $0 [install|uninstall]"
        exit 1
        ;;
esac
