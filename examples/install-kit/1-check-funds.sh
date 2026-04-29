#!/usr/bin/env bash
# 1-check-funds.sh — read your zigbee identity, derive its eth address,
# and check that it has enough Sepolia ETH (for gas) and sBZZ (for the
# chequebook funding step) to proceed with 2-deploy-chequebook.sh.
#
# Run this BEFORE 2-deploy. It only reads — no transactions sent.
#
# Usage: ./1-check-funds.sh
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

need cast
need xxd
ensure_identity

ISSUER=$(issuer_address)
echo "[1-check-funds] zigbee identity → $ISSUER"
echo

# Sepolia ETH (for gas)
ETH_BAL=$(cast balance "$ISSUER" --rpc-url "$SEPOLIA_RPC")
ETH_HUMAN=$(python3 -c "print(int('$ETH_BAL') / 10**18)")
MIN_ETH_WEI=5000000000000000   # 0.005 ETH

echo "  Sepolia ETH:  $ETH_HUMAN ($ETH_BAL wei)"
if [ "$(python3 -c "print(int('$ETH_BAL') < $MIN_ETH_WEI)")" = "True" ]; then
    echo "  ↳ insufficient. Need at least 0.005 ETH for gas." >&2
    echo "    Get some from a faucet:"
    echo "      https://www.alchemy.com/faucets/ethereum-sepolia"
    echo "      https://sepolia-faucet.pk910.de"
    ETH_OK=0
else
    echo "  ↳ OK"
    ETH_OK=1
fi

echo

# Sepolia sBZZ (for chequebook fund)
GBZZ=$(cast call "$FACTORY" "ERC20Address()(address)" --rpc-url "$SEPOLIA_RPC")
DECIMALS=$(cast call "$GBZZ" "decimals()(uint8)" --rpc-url "$SEPOLIA_RPC")
BZZ_BAL=$(cast call "$GBZZ" "balanceOf(address)(uint256)" "$ISSUER" --rpc-url "$SEPOLIA_RPC")
BZZ_BAL=${BZZ_BAL%% *}   # strip cast's "[scientific]" suffix
BZZ_HUMAN=$(python3 -c "print(int('$BZZ_BAL') / 10**int('$DECIMALS'))")
NEED_WEI=$(python3 -c "print(int(float('$FUND_AMOUNT_BZZ') * 10**int('$DECIMALS')))")

echo "  Sepolia sBZZ: $BZZ_HUMAN ($BZZ_BAL raw, ${DECIMALS}-decimal token at $GBZZ)"
echo "  Required:     $FUND_AMOUNT_BZZ ($NEED_WEI raw)"
if [ "$(python3 -c "print(int('$BZZ_BAL') < $NEED_WEI)")" = "True" ]; then
    echo "  ↳ insufficient. Lower FUND_AMOUNT_BZZ in config.sh, or get more sBZZ:" >&2
    echo "      https://discord.gg/wdghaQsGq5  (#dev channel)"
    BZZ_OK=0
else
    echo "  ↳ OK"
    BZZ_OK=1
fi

echo
if [ "$ETH_OK" = "1" ] && [ "$BZZ_OK" = "1" ]; then
    echo "[1-check-funds] ready to deploy. Next: ./2-deploy-chequebook.sh"
    exit 0
else
    echo "[1-check-funds] not ready. Top up the missing balance(s) and re-run." >&2
    exit 1
fi
