#!/usr/bin/env bash
# _common.sh — defaults + auto-detect, sourced by every numbered script.
# Don't run this directly; the numbered scripts source it.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source user overrides, if any. Created by `cp config.example.sh config.sh`.
[ -f "$KIT_DIR/config.sh" ] && . "$KIT_DIR/config.sh"

# ---- where zigbee lives ----------------------------------------------------
# install-kit/ is at <zigbee_repo>/examples/install-kit/, so two levels up
# is the repo root. Override via ZIGBEE_REPO in config.sh if you cloned
# elsewhere or are running the kit from outside the repo.
ZIGBEE_REPO="${ZIGBEE_REPO:-$(cd "$KIT_DIR/../.." && pwd)}"
ZIGBEE_BIN="${ZIGBEE_BIN:-$ZIGBEE_REPO/zig-out/bin/zigbee}"

# ---- chain ----------------------------------------------------------------
SEPOLIA_RPC="${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}"
CHAIN_ID="${CHAIN_ID:-11155111}"
# Canonical Swarm chequebook factory on Sepolia. Public contract address;
# bee uses this same factory. Override only if Swarm itself moves it.
FACTORY="${FACTORY:-0x0fF044F6bB4F684a5A149B46D7eC03ea659F98A1}"

# ---- network --------------------------------------------------------------
NETWORK_ID="${NETWORK_ID:-10}"
BOOTNODE="${BOOTNODE:-/dnsaddr/sepolia.testnet.ethswarm.org}"

# ---- zigbee state files (sensitive — live in $HOME/.zigbee/ by default) ----
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.zigbee/identity.key}"
CHEQUEBOOK="${CHEQUEBOOK:-$HOME/.zigbee/chequebook.json}"

# ---- chequebook deploy --------------------------------------------------
FUND_AMOUNT_BZZ="${FUND_AMOUNT_BZZ:-1}"

# ---- daemon runtime --------------------------------------------------------
API_PORT="${API_PORT:-9090}"
MAX_PEERS="${MAX_PEERS:-20}"

# ---- preflight helpers ----------------------------------------------------
need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: missing required tool '$1'." >&2
        case "$1" in
            cast)
                echo "  install foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2 ;;
            zig)
                echo "  install: https://ziglang.org/download/" >&2 ;;
            *)
                echo "  install via your package manager." >&2 ;;
        esac
        exit 1
    fi
}

ensure_zigbee_built() {
    if [ ! -x "$ZIGBEE_BIN" ]; then
        echo "error: zigbee binary not found at $ZIGBEE_BIN" >&2
        echo "  either:" >&2
        echo "    (a) download a pre-built binary from https://github.com/martinconic/zigbee/releases/latest" >&2
        echo "        and point ZIGBEE_BIN at it (in config.sh or env), or" >&2
        echo "    (b) build from source: (cd $ZIGBEE_REPO && zig build -Doptimize=ReleaseSafe)" >&2
        exit 1
    fi
}

ensure_identity() {
    if [ ! -r "$IDENTITY_FILE" ]; then
        echo "error: $IDENTITY_FILE not found." >&2
        echo "  generate it first: $ZIGBEE_BIN identity" >&2
        exit 1
    fi
}

# Derive the issuer eth address from the identity key file. Needs `cast`.
issuer_address() {
    local priv_hex
    priv_hex=0x$(head -c 32 "$IDENTITY_FILE" | xxd -p -c 32)
    cast wallet address --private-key "$priv_hex"
}
