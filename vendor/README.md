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

The C sources are compiled directly by `build.zig` (no autotools or
CMake step) — three files: `src/secp256k1.c`, `src/precomputed_ecmult.c`,
`src/precomputed_ecmult_gen.c`, plus `-DENABLE_MODULE_RECOVERY=1`. This
lets `zig build -Dtarget=...` cross-compile libsecp256k1 for any target
zig supports without external toolchains. The `secp256k1/build/` tree
that may be left over from earlier autotools-based setups is no longer
used and can be deleted.

To pull a newer upstream, replace the directory and update the commit
hash above. The `.git` is intentionally stripped before vendoring.
