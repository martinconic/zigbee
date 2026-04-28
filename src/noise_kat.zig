// Known-Answer Tests for Noise_XX_25519_ChaChaPoly_SHA256.
//
// These tests drive SymmetricState through the canonical Noise XX handshake
// using a vector recorded by the cacophony reference implementation. They are
// the source of truth for "is our Noise primitive correct?" — if any
// assertion here fails, our state machine has diverged from the spec, and
// real-peer interop *cannot* work no matter how green our other tests look.
//
// Vector source: cacophony.txt
// https://raw.githubusercontent.com/mcginty/snow/main/tests/vectors/cacophony.txt
// (mirrored from https://github.com/centromere/cacophony test corpus)
//
// Vector chosen: protocol_name "Noise_XX_25519_ChaChaPoly_SHA256", prologue "John Galt".
// libp2p uses an *empty* prologue, but the SymmetricState math is identical
// either way — the prologue is just an opaque MixHash input. If we pass this
// vector with prologue "John Galt", the same primitives also work for empty.
//
// We deliberately bypass NoiseState.processHandshakeInitiator here and drive
// SymmetricState / X25519 directly. The point is to validate the *primitives*;
// if those are right, any remaining bug must be in the orchestration layer
// (libp2p framing, payload encoding, identity signing) — which is an easier
// problem to debug.

const std = @import("std");
const X25519 = std.crypto.dh.X25519;
const noise = @import("noise.zig");

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

fn hexAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, s);
    return out;
}

test "libp2p empty-prologue h at each step matches flynn/noise oracle" {
    // Captured by running a flynn/noise XX handshake with EMPTY prologue and
    // EMPTY payloads on each message, using these recorded ephemeral keys
    // (same secrets as the cacophony vector).
    //
    // The point of this test is to verify our orchestration of MixHash for the
    // libp2p case — empty prologue + empty msg1 payload — actually produces
    // the spec-correct intermediate h values. Two prior speculative MixHash
    // calls were added to processHandshakeInitiator on theory; this test
    // proves they're load-bearing (or busts them).
    const init_static_sk = hex("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1");
    const init_ephem_sk = hex("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a");
    const resp_static_sk = hex("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893");
    const resp_ephem_sk = hex("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b");

    const init_static_pk = try X25519.recoverPublicKey(init_static_sk);
    const init_ephem_pk = try X25519.recoverPublicKey(init_ephem_sk);
    const resp_static_pk = try X25519.recoverPublicKey(resp_static_sk);
    const resp_ephem_pk = try X25519.recoverPublicKey(resp_ephem_sk);

    // Both sides start identically: init + MixHash(empty prologue).
    var i_ss = noise.SymmetricState.init("Noise_XX_25519_ChaChaPoly_SHA256");
    var r_ss = noise.SymmetricState.init("Noise_XX_25519_ChaChaPoly_SHA256");
    i_ss.mixHash(&[_]u8{});
    r_ss.mixHash(&[_]u8{});

    // ---- msg1: -> e (no payload) ----
    // Initiator side:
    i_ss.mixHash(&init_ephem_pk);
    // EncryptAndHash(empty payload, no key) = MixHash(empty).
    var m1_dummy: [0]u8 = undefined;
    try i_ss.encryptAndHash(&[_]u8{}, &m1_dummy);

    // Responder side processes msg1 (just `e` + empty payload):
    r_ss.mixHash(&init_ephem_pk);
    var m1_pt: [0]u8 = undefined;
    try r_ss.decryptAndHash(&[_]u8{}, &m1_pt);

    const h_after_msg1 = hex("4353c8bdcd2b308bbdc80f18332315cdc636dc30a907b76758cdcb012f42977a");
    try std.testing.expectEqualSlices(u8, &h_after_msg1, &i_ss.h);
    try std.testing.expectEqualSlices(u8, &h_after_msg1, &r_ss.h);

    // ---- msg2: <- e, ee, s, es (no payload) ----
    // Responder writes msg2.
    r_ss.mixHash(&resp_ephem_pk);
    const ee_r = try X25519.scalarmult(resp_ephem_sk, init_ephem_pk);
    r_ss.mixKey(&ee_r);
    var enc_s_r: [48]u8 = undefined;
    try r_ss.encryptAndHash(&resp_static_pk, &enc_s_r);
    const es_r = try X25519.scalarmult(resp_static_sk, init_ephem_pk);
    r_ss.mixKey(&es_r);
    // EncryptAndHash(empty payload, hasKey=true) = encrypt empty + tag (16 bytes).
    var m2_pad: [16]u8 = undefined;
    try r_ss.encryptAndHash(&[_]u8{}, &m2_pad);

    // Initiator reads msg2.
    i_ss.mixHash(&resp_ephem_pk);
    const ee_i = try X25519.scalarmult(init_ephem_sk, resp_ephem_pk);
    i_ss.mixKey(&ee_i);
    var dec_s: [32]u8 = undefined;
    try i_ss.decryptAndHash(&enc_s_r, &dec_s);
    try std.testing.expectEqualSlices(u8, &resp_static_pk, &dec_s);
    const es_i = try X25519.scalarmult(init_ephem_sk, resp_static_pk);
    i_ss.mixKey(&es_i);
    var m2_dec: [0]u8 = undefined;
    try i_ss.decryptAndHash(&m2_pad, &m2_dec);

    const h_after_msg2 = hex("6460f1854a1157bebbf29cf46af1a94c6f7d19411855dd18b62da419dbf0a788");
    try std.testing.expectEqualSlices(u8, &h_after_msg2, &i_ss.h);
    try std.testing.expectEqualSlices(u8, &h_after_msg2, &r_ss.h);

    // ---- msg3: -> s, se (no payload) ----
    var enc_s_i: [48]u8 = undefined;
    try i_ss.encryptAndHash(&init_static_pk, &enc_s_i);
    const se_i = try X25519.scalarmult(init_static_sk, resp_ephem_pk);
    i_ss.mixKey(&se_i);
    var m3_pad_i: [16]u8 = undefined;
    try i_ss.encryptAndHash(&[_]u8{}, &m3_pad_i);

    var dec_s3: [32]u8 = undefined;
    try r_ss.decryptAndHash(&enc_s_i, &dec_s3);
    try std.testing.expectEqualSlices(u8, &init_static_pk, &dec_s3);
    const se_r = try X25519.scalarmult(resp_ephem_sk, init_static_pk);
    r_ss.mixKey(&se_r);
    var m3_dec: [0]u8 = undefined;
    try r_ss.decryptAndHash(&m3_pad_i, &m3_dec);

    const h_after_msg3 = hex("54e50ed49e16bf78f6d638271c44143944b387073be935ab63915c16707e9339");
    try std.testing.expectEqualSlices(u8, &h_after_msg3, &i_ss.h);
    try std.testing.expectEqualSlices(u8, &h_after_msg3, &r_ss.h);
}

test "decrypt msg2 from flynn/noise oracle (libp2p config, empty payload)" {
    // msg2 bytes captured from a flynn/noise XX handshake configured with
    // empty prologue and empty payloads on every message — exactly what
    // libp2p does when it asks to negotiate `/noise`. We initialize our
    // SymmetricState the same way zigbee's NoiseState does and walk it
    // through receiving msg2. If this decrypts, our msg2 reception path
    // matches go-libp2p's msg2 sending path.
    const allocator = std.testing.allocator;

    // Recorded keys (same as cacophony vector secrets, used by oracle).
    const init_ephem_sk = hex("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a");
    const init_ephem_pk = try X25519.recoverPublicKey(init_ephem_sk);
    // The static key isn't used for msg2 reception (only the ephemeral is).

    const msg2 = try hexAlloc(allocator, "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b90b20f024c6abdc05d618c61c13a3fe072cc58dfff9bcf82e0a1bfdb60721db50");
    defer allocator.free(msg2);
    try std.testing.expectEqual(@as(usize, 96), msg2.len);

    // ---- Initiator-side state setup (mirrors NoiseState.init + msg1 send) ----
    var ss = noise.SymmetricState.init("Noise_XX_25519_ChaChaPoly_SHA256");
    ss.mixHash(&[_]u8{}); // empty prologue (libp2p)

    // msg1 send: token e (mixHash) + EncryptAndHash(empty payload) (= mixHash(empty)).
    ss.mixHash(&init_ephem_pk);
    ss.mixHash(&[_]u8{});

    // ---- Receive msg2: e, ee, s, es + empty payload ----
    const re = msg2[0..32].*;
    ss.mixHash(&re);

    const ee = try X25519.scalarmult(init_ephem_sk, re);
    ss.mixKey(&ee);

    var rs: [32]u8 = undefined;
    try ss.decryptAndHash(msg2[32..80], &rs);
    // Decryption must succeed and yield the responder's static public key
    // (`4a3a...4893`'s pub key — we don't recompute it here, just sanity check
    // that we got 32 bytes of output without an AEAD failure).
    try std.testing.expect(!std.mem.allEqual(u8, &rs, 0));

    const resp_static_sk = hex("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893");
    const resp_static_pk = try X25519.recoverPublicKey(resp_static_sk);
    try std.testing.expectEqualSlices(u8, &resp_static_pk, &rs);

    const es = try X25519.scalarmult(init_ephem_sk, rs);
    ss.mixKey(&es);

    // Empty payload: 16-byte tag only.
    var pt: [0]u8 = undefined;
    try ss.decryptAndHash(msg2[80..96], &pt);
}

test "Cacophony Noise_XX_25519_ChaChaPoly_SHA256 vector — primitives" {
    const allocator = std.testing.allocator;

    const prologue = hex("4a6f686e2047616c74"); // "John Galt"
    const init_static_sk = hex("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1");
    const init_ephem_sk = hex("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a");
    const resp_static_sk = hex("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893");
    const resp_ephem_sk = hex("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b");
    const expected_h = hex("c8e5f64e846193be2a834104c2a009868d6c9f3bd3c186299888b488b2f1f58e");

    const init_static_pk = try X25519.recoverPublicKey(init_static_sk);
    const init_ephem_pk = try X25519.recoverPublicKey(init_ephem_sk);
    const resp_static_pk = try X25519.recoverPublicKey(resp_static_sk);
    const resp_ephem_pk = try X25519.recoverPublicKey(resp_ephem_sk);

    // Both sides initialize SymmetricState and mix the prologue.
    var i_ss = noise.SymmetricState.init("Noise_XX_25519_ChaChaPoly_SHA256");
    var r_ss = noise.SymmetricState.init("Noise_XX_25519_ChaChaPoly_SHA256");
    i_ss.mixHash(&prologue);
    r_ss.mixHash(&prologue);
    try std.testing.expectEqualSlices(u8, &i_ss.h, &r_ss.h);

    // ---- Message 1: -> e + payload (no key yet) ----
    // Initiator: mixHash(e_pub); encryptAndHash(payload). With no key,
    // encryptAndHash reduces to copy-then-mixHash — wire = e_pub || payload.
    const m1_payload = hex("4c756477696720766f6e204d69736573"); // "Ludwig von Mises"

    i_ss.mixHash(&init_ephem_pk);
    var m1_ct: [16]u8 = undefined; // no key yet → ciphertext == plaintext, no tag
    try i_ss.encryptAndHash(&m1_payload, &m1_ct);

    var m1_wire: [48]u8 = undefined;
    @memcpy(m1_wire[0..32], &init_ephem_pk);
    @memcpy(m1_wire[32..48], &m1_ct);

    const m1_expected = try hexAlloc(allocator, "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573");
    defer allocator.free(m1_expected);
    try std.testing.expectEqualSlices(u8, m1_expected, &m1_wire);

    // Responder consumes msg1.
    r_ss.mixHash(&init_ephem_pk);
    var m1_pt: [16]u8 = undefined;
    try r_ss.decryptAndHash(&m1_ct, &m1_pt);
    try std.testing.expectEqualSlices(u8, &m1_payload, &m1_pt);
    // Both sides' h must match after msg1.
    try std.testing.expectEqualSlices(u8, &i_ss.h, &r_ss.h);

    // ---- Message 2: <- e, ee, s, es + payload ----
    const m2_payload = hex("4d757272617920526f746862617264"); // "Murray Rothbard"

    // Responder side.
    r_ss.mixHash(&resp_ephem_pk);
    const ee_r = try X25519.scalarmult(resp_ephem_sk, init_ephem_pk);
    r_ss.mixKey(&ee_r);

    var m2_enc_s: [48]u8 = undefined; // 32 plaintext + 16 tag
    try r_ss.encryptAndHash(&resp_static_pk, &m2_enc_s);

    const es_r = try X25519.scalarmult(resp_static_sk, init_ephem_pk);
    r_ss.mixKey(&es_r);

    var m2_enc_p: [31]u8 = undefined; // 15 plaintext + 16 tag
    try r_ss.encryptAndHash(&m2_payload, &m2_enc_p);

    var m2_wire: [32 + 48 + 31]u8 = undefined;
    @memcpy(m2_wire[0..32], &resp_ephem_pk);
    @memcpy(m2_wire[32..80], &m2_enc_s);
    @memcpy(m2_wire[80..111], &m2_enc_p);

    const m2_expected = try hexAlloc(allocator, "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b7815528f8982ffe09be9b5c412f8a0db50f8814c7194e83f23dbd8d162c9326ad");
    defer allocator.free(m2_expected);
    try std.testing.expectEqualSlices(u8, m2_expected, &m2_wire);

    // Initiator consumes msg2.
    i_ss.mixHash(&resp_ephem_pk);
    const ee_i = try X25519.scalarmult(init_ephem_sk, resp_ephem_pk);
    i_ss.mixKey(&ee_i);

    var m2_dec_s: [32]u8 = undefined;
    try i_ss.decryptAndHash(&m2_enc_s, &m2_dec_s);
    try std.testing.expectEqualSlices(u8, &resp_static_pk, &m2_dec_s);

    const es_i = try X25519.scalarmult(init_ephem_sk, resp_static_pk);
    i_ss.mixKey(&es_i);

    var m2_dec_p: [15]u8 = undefined;
    try i_ss.decryptAndHash(&m2_enc_p, &m2_dec_p);
    try std.testing.expectEqualSlices(u8, &m2_payload, &m2_dec_p);
    try std.testing.expectEqualSlices(u8, &i_ss.h, &r_ss.h);

    // ---- Message 3: -> s, se + payload ----
    const m3_payload = hex("462e20412e20486179656b"); // "F. A. Hayek"

    var m3_enc_s: [48]u8 = undefined;
    try i_ss.encryptAndHash(&init_static_pk, &m3_enc_s);

    const se_i = try X25519.scalarmult(init_static_sk, resp_ephem_pk);
    i_ss.mixKey(&se_i);

    var m3_enc_p: [27]u8 = undefined; // 11 plaintext + 16 tag
    try i_ss.encryptAndHash(&m3_payload, &m3_enc_p);

    var m3_wire: [48 + 27]u8 = undefined;
    @memcpy(m3_wire[0..48], &m3_enc_s);
    @memcpy(m3_wire[48..75], &m3_enc_p);

    const m3_expected = try hexAlloc(allocator, "c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a80ae475b9df0f169ae80a89be0865b57f58c9fea0d4ec82a286427402f113e4b6ae769a1d95941d49b25030");
    defer allocator.free(m3_expected);
    try std.testing.expectEqualSlices(u8, m3_expected, &m3_wire);

    // Responder consumes msg3.
    var m3_dec_s: [32]u8 = undefined;
    try r_ss.decryptAndHash(&m3_enc_s, &m3_dec_s);
    try std.testing.expectEqualSlices(u8, &init_static_pk, &m3_dec_s);

    const se_r = try X25519.scalarmult(resp_ephem_sk, init_static_pk);
    r_ss.mixKey(&se_r);

    var m3_dec_p: [11]u8 = undefined;
    try r_ss.decryptAndHash(&m3_enc_p, &m3_dec_p);
    try std.testing.expectEqualSlices(u8, &m3_payload, &m3_dec_p);

    // Final handshake hash must match.
    try std.testing.expectEqualSlices(u8, &expected_h, &i_ss.h);
    try std.testing.expectEqualSlices(u8, &expected_h, &r_ss.h);

    // Split into transport keys; both sides must derive identical pairs.
    const i_keys = i_ss.split();
    const r_keys = r_ss.split();
    try std.testing.expectEqualSlices(u8, &i_keys[0].k.?, &r_keys[0].k.?);
    try std.testing.expectEqualSlices(u8, &i_keys[1].k.?, &r_keys[1].k.?);

    // ---- Transport phase ----
    // Per Noise spec, Split() returns (c1, c2) where c1 = temp_k1 = HKDF output1
    // and c2 = temp_k2 = output2. For XX:
    //   - initiator sends with c1, receives with c2
    //   - responder sends with c2, receives with c1 (mirror)
    //
    // Cacophony's vector continues the natural alternation: XX's last
    // handshake message is from the initiator, so the FIRST transport message
    // is from the *responder* (encrypted with c2), the next from the
    // initiator (c1), and so on.
    var i_tx = i_keys[0]; // c1
    var i_rx = i_keys[1]; // c2
    var r_tx = r_keys[1]; // c2 mirror
    var r_rx = r_keys[0]; // c1 mirror

    // t1: responder -> initiator, "Carl Menger".
    {
        const payload = hex("4361726c204d656e676572");
        const want = try hexAlloc(allocator, "96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df");
        defer allocator.free(want);
        var ct: [27]u8 = undefined;
        try r_tx.encryptWithAd(&[_]u8{}, &payload, &ct);
        try std.testing.expectEqualSlices(u8, want, &ct);
        var pt: [11]u8 = undefined;
        try i_rx.decryptWithAd(&[_]u8{}, &ct, &pt);
        try std.testing.expectEqualSlices(u8, &payload, &pt);
    }

    // t2: initiator -> responder, "Jean-Baptiste Say".
    {
        const payload = hex("4a65616e2d426170746973746520536179");
        const want = try hexAlloc(allocator, "3e40f15f6f3a46ae446b253bf8b1d9ffb6ed9b174d272328ff91a7e2e5c79c07f5");
        defer allocator.free(want);
        var ct: [33]u8 = undefined;
        try i_tx.encryptWithAd(&[_]u8{}, &payload, &ct);
        try std.testing.expectEqualSlices(u8, want, &ct);
        var pt: [17]u8 = undefined;
        try r_rx.decryptWithAd(&[_]u8{}, &ct, &pt);
        try std.testing.expectEqualSlices(u8, &payload, &pt);
    }
}
