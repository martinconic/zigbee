# vendored dependencies

## `secp256k1/`

Source: https://github.com/bitcoin-core/secp256k1
Pinned to commit: `ea174fe045e1832548cd3b7090958afe9573ad2b`
License: MIT (see `secp256k1/COPYING`)

zigbee uses libsecp256k1 for ECDSA recoverable signatures (Ethereum-style
65-byte `r ‖ s ‖ v` sign/recover) — used by `src/identity.zig` for the
bee handshake's BzzAddress signature, and by `src/bzz_address.zig` for
verifying signatures on hive entries.

This is the only non-Zig dependency in the project. Everything else
(ChaCha20-Poly1305, X25519, Keccak-256, SHA-256, ECDSA-P256) is from
Zig's standard library.

To pull a newer upstream, replace the directory and update the commit
hash above. The `.git` is intentionally stripped before vendoring.
