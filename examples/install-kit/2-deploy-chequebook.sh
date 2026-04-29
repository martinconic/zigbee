#!/usr/bin/env bash
# 2-deploy-chequebook.sh — deploy a fresh Swarm chequebook owned by your
# zigbee identity, fund it with sBZZ, and write the credential JSON
# zigbee will load on startup.
#
# This is a one-time chain step per zigbee identity.
#
# What it does:
#   1. Read first 32 bytes of the identity key file as the issuer
#      private key. Derive its eth address.
#   2. Resolve the gBZZ token by calling factory.ERC20Address() — no
#      hardcoded token address.
#   3. Sanity-check ETH (for gas) and sBZZ (for funding) balances.
#   4. Generate a random nonce, call factory.deploySimpleSwap(issuer, 0, nonce).
#   5. Parse SimpleSwapDeployed(address) from the receipt.
#   6. Verify factory.deployedContracts(chequebook) returns true (this is
#      what bee's VerifyChequebook checks on the receiving side).
#   7. ERC20.transfer(FUND_AMOUNT) into the chequebook contract.
#   8. Write the credential: {contract, owner_private_key, chain_id} to
#      $CHEQUEBOOK at mode 0600.
#
# Configuration: see config.example.sh. Common overrides:
#   FUND_AMOUNT_BZZ   how much sBZZ to seed (default 1)
#   FORCE=1           overwrite an existing $CHEQUEBOOK
#   DRY_RUN=1         print plan, send no transactions
#
# Usage: ./2-deploy-chequebook.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"

need cast
need xxd
need python3
ensure_identity

if [ -e "$CHEQUEBOOK" ] && [ "$FORCE" != "1" ]; then
    echo "[2-deploy] $CHEQUEBOOK already exists. Set FORCE=1 to overwrite," >&2
    echo "             or change CHEQUEBOOK in config.sh to write somewhere else." >&2
    exit 1
fi

# Identity file is 64 bytes raw: 32-byte secp256k1 priv ‖ 32-byte bzz nonce.
PRIV_HEX=0x$(head -c 32 "$IDENTITY_FILE" | xxd -p -c 32)
ISSUER=$(cast wallet address --private-key "$PRIV_HEX")
echo "[2-deploy] issuer eth address: $ISSUER" >&2

# --- resolve token + decimals via factory ----------------------------------

GBZZ=$(cast call "$FACTORY" "ERC20Address()(address)" --rpc-url "$SEPOLIA_RPC")
DECIMALS=$(cast call "$GBZZ" "decimals()(uint8)" --rpc-url "$SEPOLIA_RPC")
echo "[2-deploy] factory $FACTORY → gBZZ: $GBZZ (${DECIMALS}-decimal)" >&2

FUND_AMOUNT_WEI=$(python3 -c "print(int(float('$FUND_AMOUNT_BZZ') * 10**int('$DECIMALS')))")
echo "[2-deploy] funding amount: $FUND_AMOUNT_BZZ BZZ = $FUND_AMOUNT_WEI raw units" >&2

# --- balance sanity --------------------------------------------------------

ETH_BAL=$(cast balance "$ISSUER" --rpc-url "$SEPOLIA_RPC")
BZZ_BAL=$(cast call "$GBZZ" "balanceOf(address)(uint256)" "$ISSUER" --rpc-url "$SEPOLIA_RPC")
BZZ_BAL=${BZZ_BAL%% *}
echo "[2-deploy] issuer ETH balance: $ETH_BAL wei" >&2
echo "[2-deploy] issuer BZZ balance: $BZZ_BAL raw units" >&2

# Deploy ~175k gas + transfer ~50k gas. Require 0.005 ETH for headroom.
MIN_ETH_WEI=5000000000000000
if [ "$(python3 -c "print(int('$ETH_BAL') < $MIN_ETH_WEI)")" = "True" ]; then
    echo "[2-deploy] insufficient ETH (< 0.005). Run ./1-check-funds.sh for guidance." >&2
    exit 1
fi
if [ "$(python3 -c "print(int('$BZZ_BAL') < $FUND_AMOUNT_WEI)")" = "True" ]; then
    echo "[2-deploy] insufficient BZZ. Lower FUND_AMOUNT_BZZ in config.sh, or top up." >&2
    exit 1
fi

# --- plan summary + dry-run gate -------------------------------------------

cat <<EOF >&2
[2-deploy] plan:
  1. factory.deploySimpleSwap(issuer=$ISSUER, hardDepositTimeout=0, nonce=<random>)
     → emits SimpleSwapDeployed(<chequebook-addr>)
  2. factory.deployedContracts(<chequebook>) must return true
  3. gBZZ.transfer(<chequebook>, $FUND_AMOUNT_WEI) from issuer EOA
  4. write credential to: $CHEQUEBOOK
EOF

if [ "$DRY_RUN" = "1" ]; then
    echo "[2-deploy] DRY_RUN=1 set; stopping before any chain transactions." >&2
    exit 0
fi

# --- 1. deploy chequebook --------------------------------------------------

NONCE=0x$(head -c 32 /dev/urandom | xxd -p -c 32)
echo "[2-deploy] deploy nonce: $NONCE" >&2

DEPLOY_JSON=$(cast send "$FACTORY" \
    "deploySimpleSwap(address,uint256,bytes32)" "$ISSUER" 0 "$NONCE" \
    --private-key "$PRIV_HEX" --rpc-url "$SEPOLIA_RPC" --json)
DEPLOY_TX=$(echo "$DEPLOY_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["transactionHash"])')
echo "[2-deploy] deploy tx: $DEPLOY_TX" >&2

# Parse SimpleSwapDeployed(address) from receipt logs.
TOPIC0=$(cast keccak "SimpleSwapDeployed(address)")
DEPLOYED_ADDR=$(echo "$DEPLOY_JSON" | python3 -c "
import sys, json
r = json.load(sys.stdin)
factory = '$FACTORY'.lower()
topic0 = '$TOPIC0'.lower()
for log in r.get('logs', []):
    if log['address'].lower() != factory:
        continue
    if not log.get('topics') or log['topics'][0].lower() != topic0:
        continue
    data = log['data']
    print('0x' + data[-40:])
    sys.exit(0)
sys.stderr.write('SimpleSwapDeployed log not found in receipt\n')
sys.exit(1)
")
echo "[2-deploy] chequebook deployed: $DEPLOYED_ADDR" >&2

# --- 2. verify factory remembers it ----------------------------------------

DEPLOYED=$(cast call "$FACTORY" "deployedContracts(address)(bool)" "$DEPLOYED_ADDR" --rpc-url "$SEPOLIA_RPC")
if [ "$DEPLOYED" != "true" ]; then
    echo "[2-deploy] factory.deployedContracts($DEPLOYED_ADDR) returned $DEPLOYED — bee will reject." >&2
    exit 1
fi
echo "[2-deploy] factory.deployedContracts → true (bee's VerifyChequebook will accept)" >&2

# --- 3. fund chequebook ----------------------------------------------------

FUND_JSON=$(cast send "$GBZZ" \
    "transfer(address,uint256)" "$DEPLOYED_ADDR" "$FUND_AMOUNT_WEI" \
    --private-key "$PRIV_HEX" --rpc-url "$SEPOLIA_RPC" --json)
FUND_TX=$(echo "$FUND_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["transactionHash"])')
echo "[2-deploy] fund tx: $FUND_TX" >&2

CB_BAL=$(cast call "$GBZZ" "balanceOf(address)(uint256)" "$DEPLOYED_ADDR" --rpc-url "$SEPOLIA_RPC")
CB_BAL=${CB_BAL%% *}
if [ "$CB_BAL" != "$FUND_AMOUNT_WEI" ]; then
    echo "[2-deploy] chequebook balance is $CB_BAL, expected $FUND_AMOUNT_WEI — manual check needed" >&2
fi
echo "[2-deploy] chequebook BZZ balance: $CB_BAL raw units" >&2

# --- 4. write credential JSON ----------------------------------------------

mkdir -p "$(dirname "$CHEQUEBOOK")"
cat > "$CHEQUEBOOK" <<JSON
{
  "contract":          "$DEPLOYED_ADDR",
  "owner_private_key": "$PRIV_HEX",
  "chain_id":          $CHAIN_ID
}
JSON
chmod 600 "$CHEQUEBOOK"
echo "[2-deploy] wrote $CHEQUEBOOK (mode 0600)" >&2

cat <<EOF >&2

[2-deploy] DONE. Summary:
  issuer EOA       : $ISSUER
  chequebook       : $DEPLOYED_ADDR
  factory          : $FACTORY
  gBZZ token       : $GBZZ
  funded with      : $FUND_AMOUNT_WEI raw units ($FUND_AMOUNT_BZZ BZZ)
  credential       : $CHEQUEBOOK
  chain_id         : $CHAIN_ID

Next step: ./3-run-zigbee.sh — start the daemon.
EOF
