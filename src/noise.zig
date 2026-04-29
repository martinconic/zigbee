const std = @import("std");
const crypto = std.crypto;
const X25519 = crypto.dh.X25519;
const ChaCha20Poly1305 = crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha256 = crypto.hash.sha2.Sha256;
const HkdfSha256 = crypto.kdf.hkdf.HkdfSha256;
const proto = @import("proto.zig");
const identity = @import("identity.zig");
const libp2p_key = @import("libp2p_key.zig");

pub const NoiseHandshakeError = error{
    InvalidKey,
    DecryptionFailed,
    HandshakeFailed,
};

/// The local Ephemeral X25519 keypair for the Noise Handshake
pub const EphemeralKeypair = struct {
    secret_key: [X25519.secret_length]u8,
    public_key: [X25519.public_length]u8,

    pub fn generate() !EphemeralKeypair {
        var kp: EphemeralKeypair = undefined;
        crypto.random.bytes(&kp.secret_key);
        const pub_key = try X25519.recoverPublicKey(kp.secret_key);
        @memcpy(&kp.public_key, &pub_key);
        return kp;
    }
};

pub const CipherState = struct {
    k: ?[32]u8 = null,
    n: u64 = 0,

    pub fn setKey(self: *CipherState, key: [32]u8) void {
        self.k = key;
        self.n = 0;
    }

    pub fn hasKey(self: *CipherState) bool {
        return self.k != null;
    }

    pub fn encryptWithAd(self: *CipherState, ad: []const u8, plaintext: []const u8, ciphertext: []u8) !void {
        if (self.k) |key| {
            var nonce: [12]u8 = [_]u8{0} ** 12;
            std.mem.writeInt(u64, nonce[4..12], self.n, .little);
            
            // ChaCha20Poly1305 encryption. Tag is appended.
            // In Zig std.crypto, encrypt takes (dst, src, ad, nonce, key)
            // Wait, ChaCha20Poly1305 in Zig: encrypt(c: []u8, tag: *[16]u8, m: []const u8, ad: []const u8, npub: [12]u8, k: [32]u8)
            var tag: [16]u8 = undefined;
            ChaCha20Poly1305.encrypt(ciphertext[0..plaintext.len], &tag, plaintext, ad, nonce, key);
            @memcpy(ciphertext[plaintext.len .. plaintext.len + 16], &tag);
            self.n += 1;
        } else {
            @memcpy(ciphertext[0..plaintext.len], plaintext);
        }
    }

    pub fn decryptWithAd(self: *CipherState, ad: []const u8, ciphertext: []const u8, plaintext: []u8) !void {
        if (self.k) |key| {
            if (ciphertext.len < 16) return error.DecryptionFailed;
            var nonce: [12]u8 = [_]u8{0} ** 12;
            std.mem.writeInt(u64, nonce[4..12], self.n, .little);
            
            var tag: [16]u8 = undefined;
            @memcpy(&tag, ciphertext[ciphertext.len - 16 ..]);
            
            try ChaCha20Poly1305.decrypt(plaintext, ciphertext[0..ciphertext.len - 16], tag, ad, nonce, key);
            self.n += 1;
        } else {
            @memcpy(plaintext[0..ciphertext.len], ciphertext);
        }
    }
};

pub const SymmetricState = struct {
    cipher_state: CipherState,
    ck: [32]u8,
    h: [32]u8,

    pub fn init(protocol_name: []const u8) SymmetricState {
        var state: SymmetricState = undefined;
        state.cipher_state = CipherState{};
        
        if (protocol_name.len <= 32) {
            @memset(&state.h, 0);
            @memcpy(state.h[0..protocol_name.len], protocol_name);
        } else {
            Sha256.hash(protocol_name, &state.h, .{});
        }
        @memcpy(&state.ck, &state.h);
        return state;
    }

    pub fn mixHash(self: *SymmetricState, data: []const u8) void {
        var hasher = Sha256.init(.{});
        hasher.update(&self.h);
        hasher.update(data);
        hasher.final(&self.h);
    }

    pub fn mixKey(self: *SymmetricState, ikm: []const u8) void {
        var temp_k: [32]u8 = undefined;
        var new_ck: [32]u8 = undefined;
        // HKDF output = ck || temp_k. So we request 64 bytes total.
        const prk = HkdfSha256.extract(&self.ck, ikm);
        var okm: [64]u8 = undefined;
        HkdfSha256.expand(&okm, "", prk);
        
        @memcpy(&new_ck, okm[0..32]);
        @memcpy(&temp_k, okm[32..64]);
        
        @memcpy(&self.ck, &new_ck);
        self.cipher_state.setKey(temp_k);
    }

    pub fn mixKeyAndHash(self: *SymmetricState, ikm: []const u8) void {
        var temp_h: [32]u8 = undefined;
        var temp_k: [32]u8 = undefined;
        var new_ck: [32]u8 = undefined;
        const prk = HkdfSha256.extract(&self.ck, ikm);
        var okm: [96]u8 = undefined;
        HkdfSha256.expand(&okm, "", prk);
        
        @memcpy(&new_ck, okm[0..32]);
        @memcpy(&temp_h, okm[32..64]);
        @memcpy(&temp_k, okm[64..96]);
        
        @memcpy(&self.ck, &new_ck);
        self.mixHash(&temp_h);
        self.cipher_state.setKey(temp_k);
    }

    pub fn encryptAndHash(self: *SymmetricState, plaintext: []const u8, ciphertext: []u8) !void {
        try self.cipher_state.encryptWithAd(&self.h, plaintext, ciphertext);
        self.mixHash(ciphertext[0 .. plaintext.len + if (self.cipher_state.hasKey()) @as(usize, 16) else 0]);
    }

    pub fn decryptAndHash(self: *SymmetricState, ciphertext: []const u8, plaintext: []u8) !void {
        try self.cipher_state.decryptWithAd(&self.h, ciphertext, plaintext);
        self.mixHash(ciphertext);
    }

    pub fn split(self: *SymmetricState) struct { CipherState, CipherState } {
        const prk = HkdfSha256.extract(&self.ck, &[_]u8{});
        var okm: [64]u8 = undefined;
        HkdfSha256.expand(&okm, "", prk);
        
        var c1 = CipherState{};
        c1.setKey(okm[0..32].*);
        var c2 = CipherState{};
        c2.setKey(okm[32..64].*);
        
        return .{ c1, c2 };
    }
};

/// Scaffold for the Noise XX Handshake State
pub const NoiseState = struct {
    local_ephemeral: EphemeralKeypair,
    local_static: EphemeralKeypair,
    remote_ephemeral: ?[X25519.public_length]u8 = null,
    remote_static: ?[X25519.public_length]u8 = null,
    sym_state: SymmetricState,

    pub fn init() !NoiseState {
        const ephem = try EphemeralKeypair.generate();
        const stat = try EphemeralKeypair.generate(); // Our local static key for Noise
        var state = NoiseState{
            .local_ephemeral = ephem,
            .local_static = stat,
            .sym_state = SymmetricState.init("Noise_XX_25519_ChaChaPoly_SHA256"),
        };
        // Per the Noise spec, InitializeHandshake calls MixHash(prologue) after
        // InitializeSymmetric. libp2p's prologue is the empty string — but that
        // is NOT a no-op: it folds another SHA256 round into h. Forgetting this
        // makes our state diverge from any spec-compliant peer (e.g. go-libp2p),
        // which surfaces as AEAD authentication failure on the very first
        // ciphertext we try to decrypt.
        state.sym_state.mixHash(&[_]u8{});
        return state;
    }

    /// Performs the XX Handshake as the Responder (Listener).
    /// Symmetric counterpart to processHandshakeInitiator: reverses DH directions.
    pub fn processHandshakeResponder(self: *NoiseState, stream: anytype, id: *const identity.Identity) !NoiseStream {
        // 1. Read `-> e` from initiator.
        var buffer: [65535]u8 = undefined;
        const msg1_len = try NoiseState.readNoiseFrame(stream, &buffer);
        if (msg1_len < 32) return error.HandshakeFailed;

        var re: [32]u8 = undefined;
        @memcpy(&re, buffer[0..32]);
        self.remote_ephemeral = re;
        self.sym_state.mixHash(&re);
        // Mirror of the initiator's trailing EncryptAndHash(empty payload) on msg1.
        self.sym_state.mixHash(&[_]u8{});

        // 2. Send `<- e, ee, s, es`.
        var msg2: [1024]u8 = undefined;
        var msg2_len: usize = 0;

        // e: our ephemeral public key, then MixHash(e).
        @memcpy(msg2[0..32], &self.local_ephemeral.public_key);
        msg2_len = 32;
        self.sym_state.mixHash(&self.local_ephemeral.public_key);

        // ee: DH(local_e, remote_e).
        const ee_shared = try X25519.scalarmult(self.local_ephemeral.secret_key, re);
        self.sym_state.mixKey(&ee_shared);

        // s: encrypt our static public key.
        try self.sym_state.encryptAndHash(&self.local_static.public_key, msg2[msg2_len .. msg2_len + 48]);
        msg2_len += 48;

        // es: from responder's view, DH(local_static, remote_e).
        const es_shared = try X25519.scalarmult(self.local_static.secret_key, re);
        self.sym_state.mixKey(&es_shared);

        // Build and encrypt our libp2p NoiseHandshakePayload (Secp256k1
        // key_type = 2, 33-byte compressed pubkey, DER ECDSA signature).
        var compressed_pub: [identity.COMPRESSED_PUBKEY_SIZE]u8 = undefined;
        try id.compressedPublicKey(&compressed_pub);

        var encoded_pubkey: [64]u8 = undefined;
        var fbs_pubkey = std.io.fixedBufferStream(&encoded_pubkey);
        try proto.writeVarint(fbs_pubkey.writer(), (1 << 3) | 0);
        try proto.writeVarint(fbs_pubkey.writer(), 2);
        try proto.writeVarint(fbs_pubkey.writer(), (2 << 3) | 2);
        try proto.writeVarint(fbs_pubkey.writer(), compressed_pub.len);
        try fbs_pubkey.writer().writeAll(&compressed_pub);

        var local_msg_to_sign: [56]u8 = undefined;
        @memcpy(local_msg_to_sign[0..24], "noise-libp2p-static-key:");
        @memcpy(local_msg_to_sign[24..56], &self.local_static.public_key);
        var local_msg_hash: [32]u8 = undefined;
        Sha256.hash(&local_msg_to_sign, &local_msg_hash, .{});

        var sig_buf: [identity.ECDSA_DER_MAX_SIZE]u8 = undefined;
        const sig_len = try identity.signDer(id.private_key, local_msg_hash, &sig_buf);

        var encoded_payload: [512]u8 = undefined;
        var fbs_payload = std.io.fixedBufferStream(&encoded_payload);
        try proto.encodeNoiseHandshakePayload(fbs_payload.writer(), .{
            .identity_key = fbs_pubkey.getWritten(),
            .identity_sig = sig_buf[0..sig_len],
            .data = &[_]u8{},
        });

        const pt_payload = fbs_payload.getWritten();
        if (msg2_len + pt_payload.len + 16 > msg2.len) return error.BufferTooSmall;
        try self.sym_state.encryptAndHash(pt_payload, msg2[msg2_len .. msg2_len + pt_payload.len + 16]);
        msg2_len += pt_payload.len + 16;

        try NoiseState.writeNoiseFrame(stream, msg2[0..msg2_len]);

        // 3. Read `-> s, se` from initiator.
        const msg3_len = try NoiseState.readNoiseFrame(stream, &buffer);
        if (msg3_len < 48) return error.HandshakeFailed;

        // Decrypt remote static key (32-byte plaintext, 16-byte AEAD tag = 48 bytes).
        var rs: [32]u8 = undefined;
        try self.sym_state.decryptAndHash(buffer[0..48], &rs);
        self.remote_static = rs;

        // se: from responder's view, DH(local_e, remote_static).
        const se_shared = try X25519.scalarmult(self.local_ephemeral.secret_key, rs);
        self.sym_state.mixKey(&se_shared);

        // Decrypt the initiator's NoiseHandshakePayload.
        const ct = buffer[48..msg3_len];
        if (ct.len < 16) return error.HandshakeFailed;
        var pt: [65535]u8 = undefined;
        try self.sym_state.decryptAndHash(ct, pt[0 .. ct.len - 16]);
        const payload = try proto.decodeNoiseHandshakePayload(pt[0 .. ct.len - 16]);

        // Verify the initiator signed their static key with the libp2p key they advertised.
        const peer_libp2p_key = try proto.decodeLibp2pPublicKey(payload.identity_key);

        var peer_msg_to_sign: [56]u8 = undefined;
        @memcpy(peer_msg_to_sign[0..24], "noise-libp2p-static-key:");
        @memcpy(peer_msg_to_sign[24..56], &rs);

        libp2p_key.verifySignature(
            peer_libp2p_key.key_type,
            peer_libp2p_key.data,
            &peer_msg_to_sign,
            payload.identity_sig,
        ) catch return error.HandshakeFailed;

        // 4. Split into transport keys. Responder rx is c1, tx is c2 (mirror of initiator).
        const keys = self.sym_state.split();
        return NoiseStream.init(stream, keys[1], keys[0]);
    }

    /// Performs the XX Handshake as the Initiator (Dialer)
    pub fn processHandshakeInitiator(self: *NoiseState, stream: anytype, id: *const identity.Identity) !NoiseStream {
        // 1. Send `-> e`. Per Noise spec, every WriteMessage finishes with
        // EncryptAndHash(payload). With an empty payload and no key yet, that
        // reduces to MixHash(empty) — which still updates h. Skipping it makes
        // our h drift by one SHA256 round vs. any spec-compliant peer.
        self.sym_state.mixHash(&self.local_ephemeral.public_key);
        self.sym_state.mixHash(&[_]u8{});
        try NoiseState.writeNoiseFrame(stream, &self.local_ephemeral.public_key);

        // 2. Read `<- e, ee, s, es`
        var buffer: [65535]u8 = undefined;
        const msg2_len = try NoiseState.readNoiseFrame(stream, &buffer);

        if (msg2_len < 32) return error.HandshakeFailed;

        // Extract remote ephemeral (re)
        var re: [32]u8 = undefined;
        @memcpy(&re, buffer[0..32]);
        self.remote_ephemeral = re;
        self.sym_state.mixHash(&re);

        // Perform DH(ee)
        const ee_shared = try X25519.scalarmult(self.local_ephemeral.secret_key, re);
        self.sym_state.mixKey(&ee_shared);
        
        // Read and decrypt `s` (48 bytes: 32 bytes + 16 bytes MAC)
        if (msg2_len < 32 + 48) return error.HandshakeFailed;
        var rs: [32]u8 = undefined;
        try self.sym_state.decryptAndHash(buffer[32..80], &rs);
        self.remote_static = rs;

        // Perform DH(es) -> Note: Initiator es is local ephemeral and remote static
        const es_shared = try X25519.scalarmult(self.local_ephemeral.secret_key, rs);
        self.sym_state.mixKey(&es_shared);
        
        // Decrypt payload
        const payload_ct_len = msg2_len - 80;
        var payload_pt: [65535]u8 = undefined;
        try self.sym_state.decryptAndHash(buffer[80..msg2_len], payload_pt[0 .. payload_ct_len - 16]);

        // Decode and verify the payload
        const payload_data = payload_pt[0 .. payload_ct_len - 16];
        const payload = try proto.decodeNoiseHandshakePayload(payload_data);
        
        const responder_libp2p_key = try proto.decodeLibp2pPublicKey(payload.identity_key);

        var msg_to_sign: [56]u8 = undefined;
        @memcpy(msg_to_sign[0..24], "noise-libp2p-static-key:");
        @memcpy(msg_to_sign[24..56], &rs);

        // libp2p verifies the responder's signature against `msg_to_sign` (the
        // raw bytes "noise-libp2p-static-key:" || rs). The signing scheme
        // hashes internally (SHA-256), so we pass the raw message — never the
        // prehash. libp2p_key.verifySignature dispatches on key_type:
        // 2 = Secp256k1 (33-byte compressed pubkey, DER signature)
        // 3 = ECDSA (X.509 SubjectPublicKeyInfo, DER signature; bee uses P-256)
        libp2p_key.verifySignature(
            responder_libp2p_key.key_type,
            responder_libp2p_key.data,
            &msg_to_sign,
            payload.identity_sig,
        ) catch return error.HandshakeFailed;

        // 3. Send `-> s, se`
        var msg3: [1024]u8 = undefined;
        var msg3_len: usize = 0;
        
        // Encrypt our static key
        try self.sym_state.encryptAndHash(&self.local_static.public_key, msg3[msg3_len..msg3_len+48]);
        msg3_len += 48;
        
        // Perform DH(se) -> Note: Initiator se is local static and remote ephemeral
        const se_shared = try X25519.scalarmult(self.local_static.secret_key, re);
        self.sym_state.mixKey(&se_shared);
        
        // Encrypt our payload
        var local_payload = proto.NoiseHandshakePayload{
            .identity_key = &[_]u8{},
            .identity_sig = &[_]u8{},
            .data = &[_]u8{},
        };

        // 1. Encode our libp2p PublicKey proto. We use key_type = 2 (Secp256k1)
        //    with the 33-byte SEC-1 compressed pubkey. (The libp2p enum is
        //    RSA=0, Ed25519=1, Secp256k1=2, ECDSA=3 — the reverse of what's
        //    intuitive from the ordering in some docs.)
        var compressed_pub: [identity.COMPRESSED_PUBKEY_SIZE]u8 = undefined;
        try id.compressedPublicKey(&compressed_pub);

        var encoded_pubkey: [64]u8 = undefined;
        var fbs_pubkey = std.io.fixedBufferStream(&encoded_pubkey);
        // field 1 (key_type), wire type 0 (varint), value = 2 (Secp256k1)
        try proto.writeVarint(fbs_pubkey.writer(), (1 << 3) | 0);
        try proto.writeVarint(fbs_pubkey.writer(), 2);
        // field 2 (data), wire type 2 (length-delimited), 33 bytes compressed
        try proto.writeVarint(fbs_pubkey.writer(), (2 << 3) | 2);
        try proto.writeVarint(fbs_pubkey.writer(), compressed_pub.len);
        try fbs_pubkey.writer().writeAll(&compressed_pub);
        local_payload.identity_key = fbs_pubkey.getWritten();

        // 2. Sign our Noise static key with our libp2p identity key, DER-encoded.
        var local_msg_to_sign: [56]u8 = undefined;
        @memcpy(local_msg_to_sign[0..24], "noise-libp2p-static-key:");
        @memcpy(local_msg_to_sign[24..56], &self.local_static.public_key);
        var local_msg_hash: [32]u8 = undefined;
        Sha256.hash(&local_msg_to_sign, &local_msg_hash, .{});

        var sig_buf: [identity.ECDSA_DER_MAX_SIZE]u8 = undefined;
        const sig_len = try identity.signDer(id.private_key, local_msg_hash, &sig_buf);
        local_payload.identity_sig = sig_buf[0..sig_len];

        // 3. Advertise our supported stream muxers via NoiseExtensions.
        //    go-libp2p uses this as the fast-path muxer negotiation: when the
        //    initiator and responder muxer lists overlap, the muxer is chosen
        //    here and inner multistream-select is skipped entirely. Without
        //    this, bee falls through a code path that resets the connection
        //    on us. With it, bee starts Yamux directly after the handshake.
        var ext_buf: [64]u8 = undefined;
        var fbs_ext = std.io.fixedBufferStream(&ext_buf);
        const our_muxers = [_][]const u8{"/yamux/1.0.0"};
        try proto.encodeNoiseExtensions(fbs_ext.writer(), .{ .stream_muxers = &our_muxers });
        local_payload.extensions_bytes = fbs_ext.getWritten();

        var encoded_payload: [512]u8 = undefined;
        var fbs_payload = std.io.fixedBufferStream(&encoded_payload);
        try proto.encodeNoiseHandshakePayload(fbs_payload.writer(), local_payload);
        
        const pt_payload = fbs_payload.getWritten();
        if (msg3_len + pt_payload.len + 16 > msg3.len) return error.BufferTooSmall;
        try self.sym_state.encryptAndHash(pt_payload, msg3[msg3_len .. msg3_len + pt_payload.len + 16]);
        msg3_len += pt_payload.len + 16;

        try NoiseState.writeNoiseFrame(stream, msg3[0..msg3_len]);

        // 4. Split SymmetricState to get Transport Keys
        const keys = self.sym_state.split();
        // For Initiator, c1 (keys[0]) is tx, c2 (keys[1]) is rx
        var ns = NoiseStream.init(stream, keys[0], keys[1]);
        if (responder_libp2p_key.data.len <= ns.peer_libp2p_key_buf.len) {
            ns.peer_libp2p_key_type = responder_libp2p_key.key_type;
            @memcpy(ns.peer_libp2p_key_buf[0..responder_libp2p_key.data.len], responder_libp2p_key.data);
            ns.peer_libp2p_key_len = responder_libp2p_key.data.len;
        }
        return ns;
    }

    pub fn readNoiseFrame(stream: anytype, buffer: []u8) !usize {
        var len_buf: [2]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < 2) {
            const n = try stream.read(len_buf[total_read..]);
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }
        const len = std.mem.readInt(u16, &len_buf, .big);
        if (len > buffer.len) return error.BufferTooSmall;
        
        total_read = 0;
        while (total_read < len) {
            const n = try stream.read(buffer[total_read..len]);
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }
        return len;
    }

    pub fn writeNoiseFrame(stream: anytype, data: []const u8) !void {
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(data.len), .big);
        try stream.writeAll(&len_buf);
        try stream.writeAll(data);
    }
};

pub const NoiseStream = struct {
    stream: std.net.Stream,
    tx_cipher: CipherState,
    rx_cipher: CipherState,
    read_buf: [65535]u8 = undefined,
    read_pos: usize = 0,
    read_len: usize = 0,

    /// libp2p PublicKey type advertised by the peer (one of 0=RSA, 1=Ed25519,
    /// 2=Secp256k1, 3=ECDSA). Set by processHandshakeInitiator/Responder
    /// after verification. Used by upper layers (e.g. bee handshake) to
    /// derive the peer's libp2p PeerID multihash.
    peer_libp2p_key_type: u64 = 0,
    /// libp2p PublicKey `data` field bytes for the peer. Owned: copied into
    /// `peer_libp2p_key_buf`; access via `peerLibp2pKeyData()` (we can't
    /// store a slice that points into our own struct because the struct gets
    /// memcpy'd on return).
    peer_libp2p_key_buf: [128]u8 = undefined,
    peer_libp2p_key_len: usize = 0,

    pub fn peerLibp2pKeyData(self: *const NoiseStream) []const u8 {
        return self.peer_libp2p_key_buf[0..self.peer_libp2p_key_len];
    }

    pub fn init(stream: std.net.Stream, tx: CipherState, rx: CipherState) NoiseStream {
        return NoiseStream{
            .stream = stream,
            .tx_cipher = tx,
            .rx_cipher = rx,
        };
    }

    pub fn writeAll(self: *NoiseStream, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk_len = @min(data.len - offset, 65535 - 16);
            var frame: [65535]u8 = undefined;
            
            // encryptWithAd takes ad, plaintext, ciphertext
            try self.tx_cipher.encryptWithAd(&[_]u8{}, data[offset .. offset + chunk_len], frame[0 .. chunk_len + 16]);
            
            try NoiseState.writeNoiseFrame(self.stream, frame[0 .. chunk_len + 16]);
            offset += chunk_len;
        }
    }

    pub fn read(self: *NoiseStream, dest: []u8) !usize {
        if (self.read_pos < self.read_len) {
            const avail = self.read_len - self.read_pos;
            const to_copy = @min(avail, dest.len);
            @memcpy(dest[0..to_copy], self.read_buf[self.read_pos .. self.read_pos + to_copy]);
            self.read_pos += to_copy;
            return to_copy;
        }

        // Buffer empty, read next frame
        var frame: [65535]u8 = undefined;
        const frame_len = try NoiseState.readNoiseFrame(self.stream, &frame);
        
        if (frame_len < 16) return error.InvalidEncryptedFrame;
        
        // Decrypt
        const pt_len = frame_len - 16;
        try self.rx_cipher.decryptWithAd(&[_]u8{}, frame[0..frame_len], self.read_buf[0..pt_len]);
        self.read_pos = 0;
        self.read_len = pt_len;

        return self.read(dest);
    }
};

test "noise keypair" {
    const kp = try EphemeralKeypair.generate();
    try std.testing.expect(kp.public_key.len == 32);
}

const TestRoundtripCtx = struct {
    server: *std.net.Server,
    err: ?anyerror = null,
    received: [16]u8 = undefined,
    received_len: usize = 0,
};

fn runTestResponder(ctx: *TestRoundtripCtx) void {
    const conn = ctx.server.accept() catch |e| {
        ctx.err = e;
        return;
    };
    defer conn.stream.close();

    const id_resp = identity.Identity.generate() catch |e| {
        ctx.err = e;
        return;
    };
    var state = NoiseState.init() catch |e| {
        ctx.err = e;
        return;
    };
    var ns = state.processHandshakeResponder(conn.stream, &id_resp) catch |e| {
        ctx.err = e;
        return;
    };

    // Read 16 bytes plaintext over the encrypted stream.
    var total: usize = 0;
    while (total < ctx.received.len) {
        const n = ns.read(ctx.received[total..]) catch |e| {
            ctx.err = e;
            return;
        };
        if (n == 0) {
            ctx.err = error.EndOfStream;
            return;
        }
        total += n;
    }
    ctx.received_len = total;

    // Echo back so the initiator can confirm decryption works in the other direction too.
    ns.writeAll(ctx.received[0..total]) catch |e| {
        ctx.err = e;
        return;
    };
}

test "noise XX handshake initiator <-> responder over localhost" {
    // Bind an ephemeral port on the loopback interface.
    const listen_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    var ctx = TestRoundtripCtx{ .server = &server };
    var thread = try std.Thread.spawn(.{}, runTestResponder, .{&ctx});

    const id_init = try identity.Identity.generate();
    var stream = try std.net.tcpConnectToAddress(server.listen_address);
    defer stream.close();

    var state = try NoiseState.init();
    var ns = try state.processHandshakeInitiator(stream, &id_init);

    const message = "swarm-zig-rocks!"; // 16 bytes
    try ns.writeAll(message);

    // Read the echo back through our own decryption path.
    var echo: [16]u8 = undefined;
    var total: usize = 0;
    while (total < echo.len) {
        const n = try ns.read(echo[total..]);
        if (n == 0) return error.EndOfStream;
        total += n;
    }

    thread.join();

    if (ctx.err) |e| return e;
    try std.testing.expectEqualSlices(u8, message, ctx.received[0..ctx.received_len]);
    try std.testing.expectEqualSlices(u8, message, echo[0..total]);
}
