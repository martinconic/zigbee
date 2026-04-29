#!/usr/bin/env bash
# install-kit configuration template.
#
# Copy this file to `config.sh` (in the same directory) and edit any values
# you want to override. The numbered scripts (1-, 2-, 3-, 4-) source
# `config.sh` automatically. Anything not set here uses the auto-detected
# default.
#
#   cp config.example.sh config.sh
#   $EDITOR config.sh
#
# `config.sh` is .gitignored so your private RPC URL / paths / overrides
# never accidentally get committed.

# ---------------------------------------------------------------------------
# Where zigbee lives.
# ---------------------------------------------------------------------------
# Auto-detect: the install-kit lives at <zigbee>/examples/install-kit/, so
# walking up two levels from the kit directory gets us the zigbee repo. If
# you cloned zigbee somewhere weird, set ZIGBEE_REPO explicitly.
#
# ZIGBEE_REPO=/opt/zigbee
# ZIGBEE_BIN="$ZIGBEE_REPO/zig-out/bin/zigbee"

# ---------------------------------------------------------------------------
# Sepolia testnet endpoints.
# ---------------------------------------------------------------------------
# Default RPC is publicnode (no API key, rate-limited but adequate). Swap
# in your own Alchemy / Infura / etc. URL for higher throughput.
#
# SEPOLIA_RPC=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
# SEPOLIA_RPC=https://sepolia.infura.io/v3/YOUR_KEY

# Bootnode the daemon dials. /dnsaddr/ form is recommended — zigbee
# resolves the TXT records and tries each candidate in turn until one
# handshakes. Replace with /ip4/<x>/tcp/<y> if you want a fixed peer.
#
# BOOTNODE=/dnsaddr/sepolia.testnet.ethswarm.org
# BOOTNODE=/ip4/167.235.96.31/tcp/32491

# ---------------------------------------------------------------------------
# zigbee identity + chequebook (sensitive — these stay in $HOME/.zigbee/).
# ---------------------------------------------------------------------------
# These files are created on first run / by 2-deploy-chequebook.sh.
# Override only if you keep zigbee state somewhere other than $HOME/.zigbee/.
#
# IDENTITY_FILE="$HOME/.zigbee/identity.key"
# CHEQUEBOOK="$HOME/.zigbee/chequebook.json"

# ---------------------------------------------------------------------------
# Funding amounts.
# ---------------------------------------------------------------------------
# How much sBZZ to seed the chequebook with on deploy. 1 BZZ = 10^16 raw
# units; bee's disconnect threshold is ~1.35e7 raw, so 1 BZZ covers
# ~7×10^8 cheques worth of credit. Lower it (e.g. 0.1) if you have less.
#
# FUND_AMOUNT_BZZ=1

# Sepolia chain id. Don't change unless you really know why.
#
# CHAIN_ID=11155111

# Swarm network id. 10 = Sepolia testnet, 1 = mainnet.
#
# NETWORK_ID=10

# ---------------------------------------------------------------------------
# zigbee daemon runtime.
# ---------------------------------------------------------------------------
# HTTP API port. /retrieve/<hex>, /bytes/<hex>, /bzz/<hex>, /peers, etc.
#
# API_PORT=9090

# How many peers to connect to via hive discovery. Bigger = more options
# for retrieval (each chunk asks the XOR-closest connected peer); also
# more concurrent libp2p sessions to keep healthy. 20 is a good default.
#
# MAX_PEERS=20
