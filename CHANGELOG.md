# Changelog

Per-release notes live in [`docs/release-notes/`](docs/release-notes/).

| Release | Date | Headline |
|---|---|---|
| [`0.5.1`](docs/release-notes/0.5.1.md) | 2026-04-29 | New `--bootnode` flag — accepts `/dnsaddr/<host>` or `/ip4/.../tcp/...` multiaddr; auto-resolves and tries candidates in order. |
| [`0.5.0`](docs/release-notes/0.5.0.md) | 2026-04-29 | Retrieval-maturity: local chunk store, encrypted-chunk references, SWAP cheques (issue-only) — live-verified end-to-end on Sepolia. |
| [`0.4.2`](docs/release-notes/0.4.2.md) | 2026-04-29 | Handshake-print cleanup, `POST /pingpong/<peer>`, graceful SIGINT/SIGTERM shutdown. |
| [`0.4.1`](docs/release-notes/0.4.1.md) | 2026-04-28 | Persistent libp2p identity + bzz nonce, dead-connection pruning, SOC validation in retrieval. |
| [`0.4`](docs/release-notes/0.4.md) | 2026-04-28 | Bee-compatible read-only HTTP API: `/health`, `/readiness`, `/node`, `/addresses`, `/peers`, `/topology`, `/chunks`, `/bytes`, `/bzz`. |
| [`0.3`](docs/release-notes/0.3.md) | (untagged; rolled into v0.4) | Daemon mode + multi-peer dialer + chunk-tree joiner + mantaray manifest walker. |
| [`0.1`](docs/release-notes/0.1.md) | (untagged; initial milestone) | Single-chunk retrieval over forwarding-Kademlia. |
