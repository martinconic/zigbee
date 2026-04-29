# zigbee — install kit

A small set of shell scripts that take you from a freshly-built zigbee
binary to your first SWAP-paid retrieval against the Sepolia testnet.

For the full prose walkthrough open
[`docs/install.html`](../../docs/install.html) — this README is the
script reference.

## Layout

```
examples/install-kit/
├── README.md                   # this file
├── config.example.sh           # template; copy to config.sh and edit
├── config.sh                   # YOUR overrides (gitignored — never committed)
├── _common.sh                  # sourced by every numbered script
├── 1-check-funds.sh            # verify Sepolia ETH + sBZZ on your eth address
├── 2-deploy-chequebook.sh      # one-time chain step: deploy + fund chequebook
├── 3-run-zigbee.sh             # start the daemon (foreground)
└── 4-retrieve.sh               # curl /bytes/<ref> via the daemon
```

## Configuration

Every script reads `config.sh` if it exists. To set up:

```bash
cp config.example.sh config.sh
$EDITOR config.sh        # uncomment / edit the values you want to override
```

Defaults are auto-detected from the kit's location and reasonable Sepolia
values. The most common reasons to edit `config.sh`:

- You want a private RPC URL (Alchemy / Infura) instead of the public one
- You want to fund the chequebook with less than 1 sBZZ
- Your `~/.zigbee/` lives somewhere non-standard

`config.sh` is `.gitignored` — your overrides never get committed.

## Quickstart

Once-only (per zigbee identity):

```bash
# 0. Get the zigbee binary. Two options:
#    (a) download a pre-built binary (no Zig toolchain required):
#        curl -L -o zigbee https://github.com/martinconic/zigbee/releases/latest/download/zigbee-linux-amd64-musl
#        chmod +x zigbee
#        export ZIGBEE_BIN=$PWD/zigbee     # or set in config.sh
#    (b) build from source (requires Zig 0.15.x + a C toolchain):
#        zig build -Doptimize=ReleaseSafe

./zig-out/bin/zigbee identity     # prints your eth_address — fund this on Sepolia

# 1. verify funds (Sepolia ETH for gas + sBZZ for the chequebook)
./examples/install-kit/1-check-funds.sh

# 2. deploy + fund the chequebook (one-time chain step)
./examples/install-kit/2-deploy-chequebook.sh
```

Every session:

```bash
# 3. start the daemon — leave running
./examples/install-kit/3-run-zigbee.sh

# 4. in another terminal: retrieve a file by its Swarm reference
./examples/install-kit/4-retrieve.sh <64-char-hex-ref> ./output.bin
```

## What each script does

| Script | One-line summary |
|---|---|
| `1-check-funds.sh` | Reads `~/.zigbee/identity.key`, derives the eth address, queries Sepolia for ETH and sBZZ balances. Prints OK/insufficient + faucet links. **No transactions sent.** |
| `2-deploy-chequebook.sh` | Calls `factory.deploySimpleSwap(...)`, parses the `SimpleSwapDeployed` event, transfers sBZZ into the chequebook, writes `~/.zigbee/chequebook.json` (mode 0600). Set `DRY_RUN=1` to see the plan without sending transactions; `FORCE=1` to overwrite an existing credential. |
| `3-run-zigbee.sh` | Foreground `exec` of `zigbee --bootnode <BOOTNODE> --network-id 10 --chequebook <CHEQUEBOOK> daemon --max-peers 20 --api-port 9090`. Ctrl-C to stop. |
| `4-retrieve.sh` | Times a `curl http://127.0.0.1:9090/bytes/<ref>`, writes to a file, prints HTTP status + elapsed ms. Helpful errors on 404 / 502. |

## Variables you can override

(All have sensible defaults. Set in `config.sh` or as environment variables.)

| Variable | Default | Used by |
|---|---|---|
| `ZIGBEE_REPO` | auto-detect (`../..` from kit) | all |
| `ZIGBEE_BIN` | `$ZIGBEE_REPO/zig-out/bin/zigbee` | 3, 4 |
| `SEPOLIA_RPC` | `https://ethereum-sepolia-rpc.publicnode.com` | 1, 2 |
| `BOOTNODE` | `/dnsaddr/sepolia.testnet.ethswarm.org` | 3 |
| `IDENTITY_FILE` | `$HOME/.zigbee/identity.key` | 1, 2 |
| `CHEQUEBOOK` | `$HOME/.zigbee/chequebook.json` | 2, 3 |
| `FUND_AMOUNT_BZZ` | `1` (one whole sBZZ) | 1, 2 |
| `CHAIN_ID` | `11155111` (Sepolia) | 2 |
| `NETWORK_ID` | `10` (Sepolia testnet) | 3 |
| `API_PORT` | `9090` | 3, 4 |
| `MAX_PEERS` | `20` | 3 |
| `FORCE` | `0` | 2 (overwrite existing credential) |
| `DRY_RUN` | `0` | 2 (print plan, no transactions) |

## Sensitive material — what lives where

The kit itself contains **no secrets**. The two private things zigbee needs:

- `~/.zigbee/identity.key` — your secp256k1 private key. Created by
  `zigbee identity` on first run. Back this up; if you lose it you lose
  access to your chequebook.
- `~/.zigbee/chequebook.json` — credential JSON containing the same
  private key. Written by `2-deploy-chequebook.sh` at mode 0600.
- `~/.zigbee/chequebook.state.json` — per-peer cumulative-payout state.
  Written by zigbee at runtime. **Don't delete this** — bee enforces
  strict cheque-amount monotonicity, and wiping the state file out of
  sync with bee causes "cheque cumulativePayout is not increasing"
  rejections.

The scripts read these files but never embed their contents. Your only
risk is leaving `~/.zigbee/identity.key` on a shared/insecure machine.

## Troubleshooting

| Problem | Fix |
|---|---|
| `1-check-funds.sh` says "insufficient ETH" | Use a Sepolia faucet ([alchemy](https://www.alchemy.com/faucets/ethereum-sepolia), [pk910](https://sepolia-faucet.pk910.de)) to send ETH to the printed eth address. |
| `1-check-funds.sh` says "insufficient BZZ" | Either lower `FUND_AMOUNT_BZZ` in `config.sh`, or get sBZZ from the [Swarm Discord](https://discord.gg/wdghaQsGq5) `#dev` channel. |
| `2-deploy-chequebook.sh` complains about `cast` | Install foundry: `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| `3-run-zigbee.sh` warns "$CHEQUEBOOK not found" | Run `2-deploy-chequebook.sh` first — without the credential, retrieval will stop at ~25 chunks per peer. |
| `4-retrieve.sh` says 502 after some chunks | All your connected peers gave up forwarding. Bump `MAX_PEERS` in `config.sh` and restart `3-run-zigbee.sh`. |
| zigbee log has "cheque cumulativePayout is not increasing" | `~/.zigbee/chequebook.state.json` is out of sync with what bee remembers. Recover by querying bee's `/chequebook/cheque` for your overlay and seeding the state file (see `bee-clients/scripts/12-verify-zigbee-swap.sh` for the exact code). |
