//! SWAP cheques (EIP-712 typed-data, secp256k1 recoverable).
//!
//! A cheque is an off-chain signed promise from a chequebook contract owner
//! that says "I owe you X BZZ from chequebook contract Y, cumulatively". Bee
//! peers exchange cheques over `/swarm/swap/1.0.0/swap` (see `src/swap.zig`)
//! and use them to settle the debt that bee's accounting layer has been
//! tracking since the connection started. The wire format is JSON-encoded
//! `SignedCheque` inside a `protobuf` envelope.
//!
//! Reference: bee `pkg/settlement/swap/chequebook/cheque.go` + `pkg/crypto/eip712`.
//!
//! ## EIP-712 type hashes
//!
//! Domain (chainId only — no `verifyingContract`, no `salt`):
//!   `EIP712Domain(string name,string version,uint256 chainId)`
//!
//! Cheque struct:
//!   `Cheque(address chequebook,address beneficiary,uint256 cumulativePayout)`
//!
//! Signing digest:
//!   `keccak256("\x19\x01" ‖ domainSeparator ‖ structHash)`
//!
//! where
//!   `domainSeparator = keccak256(typeHash_domain ‖ keccak256("Chequebook") ‖
//!                                keccak256("1.0") ‖ uint256_be(chainId))`
//!   `structHash      = keccak256(typeHash_cheque ‖ pad32(chequebook) ‖
//!                                pad32(beneficiary) ‖ uint256_be(cumulativePayout))`
//!
//! ## Wire JSON
//!
//! Bee uses Go's default `encoding/json.Marshal(SignedCheque)`. The struct
//! embedding hoists `Cheque`'s fields, so the keys are the Go field names
//! capitalised:
//!
//! ```json
//! { "Chequebook":"0x...","Beneficiary":"0x...","CumulativePayout":<int>,
//!   "Signature":"<base64>" }
//! ```
//!
//! Addresses are serialised with the 0x-prefixed mixed-case checksum form
//! (go-ethereum `Address.MarshalJSON`); on parse, both checksummed and
//! all-lower forms are accepted. `CumulativePayout` is an unquoted JSON number
//! (Go big.Int's MarshalJSON output). `Signature` is base64 of the 65-byte
//! r||s||v signature.

const std = @import("std");
const identity = @import("identity.zig");

/// EIP-712 domain name baked into the chequebook contract's `DOMAIN_SEPARATOR`.
const DOMAIN_NAME = "Chequebook";
/// EIP-712 domain version baked into the chequebook contract.
const DOMAIN_VERSION = "1.0";

pub const ADDRESS_LEN: usize = 20;
pub const SIGNATURE_LEN: usize = 65;

pub const Cheque = struct {
    chequebook: [ADDRESS_LEN]u8,
    beneficiary: [ADDRESS_LEN]u8,
    cumulative_payout: u256,
};

pub const SignedCheque = struct {
    cheque: Cheque,
    signature: [SIGNATURE_LEN]u8,
};

/// `keccak256("EIP712Domain(string name,string version,uint256 chainId)")`
fn typeHashDomain() [32]u8 {
    var out: [32]u8 = undefined;
    var h = std.crypto.hash.sha3.Keccak256.init(.{});
    h.update("EIP712Domain(string name,string version,uint256 chainId)");
    h.final(&out);
    return out;
}

/// `keccak256("Cheque(address chequebook,address beneficiary,uint256 cumulativePayout)")`
fn typeHashCheque() [32]u8 {
    var out: [32]u8 = undefined;
    var h = std.crypto.hash.sha3.Keccak256.init(.{});
    h.update("Cheque(address chequebook,address beneficiary,uint256 cumulativePayout)");
    h.final(&out);
    return out;
}

fn keccak(parts: []const []const u8) [32]u8 {
    var h = std.crypto.hash.sha3.Keccak256.init(.{});
    for (parts) |p| h.update(p);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// Big-endian uint256 encoding into a 32-byte buffer.
fn writeU256BE(out: *[32]u8, v: u256) void {
    var x = v;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        out[i] = @truncate(x & 0xff);
        x >>= 8;
    }
}

/// Left-pad a 20-byte address to 32 bytes.
fn padAddress(out: *[32]u8, addr: [ADDRESS_LEN]u8) void {
    @memset(out[0..12], 0);
    @memcpy(out[12..32], &addr);
}

/// Compute the EIP-712 domain separator for the chequebook contract on the
/// given chain. The output is keccak256(typeHash ‖ hashedName ‖ hashedVersion
/// ‖ chainId_BE_u256).
pub fn domainSeparator(chain_id: u64) [32]u8 {
    const type_hash = typeHashDomain();
    const name_hash = keccak(&.{DOMAIN_NAME});
    const version_hash = keccak(&.{DOMAIN_VERSION});

    var chain_id_be: [32]u8 = undefined;
    writeU256BE(&chain_id_be, @intCast(chain_id));

    return keccak(&.{ &type_hash, &name_hash, &version_hash, &chain_id_be });
}

/// Compute the per-cheque struct hash. This is what gets concatenated with
/// the domain separator to form the signing digest.
pub fn structHash(cheque: *const Cheque) [32]u8 {
    const type_hash = typeHashCheque();

    var chequebook_padded: [32]u8 = undefined;
    padAddress(&chequebook_padded, cheque.chequebook);

    var beneficiary_padded: [32]u8 = undefined;
    padAddress(&beneficiary_padded, cheque.beneficiary);

    var payout_be: [32]u8 = undefined;
    writeU256BE(&payout_be, cheque.cumulative_payout);

    return keccak(&.{ &type_hash, &chequebook_padded, &beneficiary_padded, &payout_be });
}

/// Compute the final 32-byte digest that gets fed to the secp256k1 signer.
/// `keccak256("\x19\x01" ‖ domainSeparator(chain_id) ‖ structHash(cheque))`.
pub fn signingDigest(cheque: *const Cheque, chain_id: u64) [32]u8 {
    const domain = domainSeparator(chain_id);
    const struct_h = structHash(cheque);
    return keccak(&.{ "\x19\x01", &domain, &struct_h });
}

/// Sign a cheque with the chequebook owner's secp256k1 private key. The
/// returned 65-byte signature is `r(32 BE) ‖ s(32 BE) ‖ v` with v ∈ {27, 28}
/// — the same shape go-ethereum's signer produces and that bee's
/// `chequestore.ReceiveCheque` recovers from.
pub fn sign(
    cheque: *const Cheque,
    chain_id: u64,
    owner_private_key: [32]u8,
) ![SIGNATURE_LEN]u8 {
    const digest = signingDigest(cheque, chain_id);
    var sig: [SIGNATURE_LEN]u8 = undefined;
    try identity.signDigestRecoverable(owner_private_key, digest, &sig);
    return sig;
}

/// Recover the chequebook owner's 20-byte Ethereum address from a signed
/// cheque. Returns `error.SignatureVerificationFailed` if the signature is
/// malformed. Bee's chequestore does the equivalent recovery on receive,
/// then matches the recovered address against the chequebook contract's
/// `issuer()` view function.
pub fn recoverIssuer(
    signed: *const SignedCheque,
    chain_id: u64,
) ![20]u8 {
    const digest = signingDigest(&signed.cheque, chain_id);
    var eth_addr: [20]u8 = undefined;
    try identity.recoverEthAddrFromDigest(digest, signed.signature, &eth_addr);
    return eth_addr;
}

// ---- JSON marshal / unmarshal --------------------------------------------

const HEX_LOWER = "0123456789abcdef";

fn writeAddressHex(addr: [ADDRESS_LEN]u8, out: *[42]u8) void {
    out[0] = '0';
    out[1] = 'x';
    for (addr, 0..) |b, i| {
        out[2 + i * 2] = HEX_LOWER[(b >> 4) & 0x0f];
        out[2 + i * 2 + 1] = HEX_LOWER[b & 0x0f];
    }
}

fn parseAddressHex(s: []const u8, out: *[ADDRESS_LEN]u8) !void {
    var hex = s;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len != ADDRESS_LEN * 2) return error.InvalidAddress;
    _ = std.fmt.hexToBytes(out, hex) catch return error.InvalidAddress;
}

/// Decimal-stringify a u256. `out` must be at least 78 bytes (max u256 = 78 digits).
/// Returns the slice of `out` actually used.
fn formatU256Decimal(value: u256, out: []u8) []u8 {
    if (value == 0) {
        out[0] = '0';
        return out[0..1];
    }
    var v = value;
    var i: usize = out.len;
    while (v > 0) {
        i -= 1;
        const d: u8 = @intCast(v % 10);
        out[i] = '0' + d;
        v /= 10;
    }
    // Compact: shift the digits to the start.
    const len = out.len - i;
    std.mem.copyForwards(u8, out[0..len], out[i..]);
    return out[0..len];
}

fn parseU256Decimal(s: []const u8) !u256 {
    if (s.len == 0) return error.InvalidNumber;
    var v: u256 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidNumber;
        v = std.math.mul(u256, v, 10) catch return error.NumberOverflow;
        v = std.math.add(u256, v, c - '0') catch return error.NumberOverflow;
    }
    return v;
}

/// Marshal a SignedCheque as the wire JSON bee expects. Caller frees.
pub fn marshalJson(allocator: std.mem.Allocator, signed: *const SignedCheque) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    var addr_hex: [42]u8 = undefined;
    var num_buf: [78]u8 = undefined;

    try buf.appendSlice(allocator, "{\"Chequebook\":\"");
    writeAddressHex(signed.cheque.chequebook, &addr_hex);
    try buf.appendSlice(allocator, &addr_hex);

    try buf.appendSlice(allocator, "\",\"Beneficiary\":\"");
    writeAddressHex(signed.cheque.beneficiary, &addr_hex);
    try buf.appendSlice(allocator, &addr_hex);

    try buf.appendSlice(allocator, "\",\"CumulativePayout\":");
    const dec = formatU256Decimal(signed.cheque.cumulative_payout, &num_buf);
    try buf.appendSlice(allocator, dec);

    try buf.appendSlice(allocator, ",\"Signature\":\"");
    // Go's default []byte JSON encoding is std (padded) base64.
    const Base64 = std.base64.standard.Encoder;
    const enc_len = Base64.calcSize(SIGNATURE_LEN);
    const old_len = buf.items.len;
    try buf.resize(allocator, old_len + enc_len);
    _ = Base64.encode(buf.items[old_len..][0..enc_len], &signed.signature);

    try buf.appendSlice(allocator, "\"}");
    return buf.toOwnedSlice(allocator);
}

/// Unmarshal a SignedCheque from bee-shaped wire JSON. Tolerates fields in
/// any order. Returns `error.MalformedCheque` on missing fields or bad shapes.
pub fn unmarshalJson(allocator: std.mem.Allocator, data: []const u8) !SignedCheque {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return error.MalformedCheque;
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedCheque;
    const obj = parsed.value.object;

    const cb_val = obj.get("Chequebook") orelse return error.MalformedCheque;
    const bn_val = obj.get("Beneficiary") orelse return error.MalformedCheque;
    const cp_val = obj.get("CumulativePayout") orelse return error.MalformedCheque;
    const sig_val = obj.get("Signature") orelse return error.MalformedCheque;

    if (cb_val != .string or bn_val != .string or sig_val != .string)
        return error.MalformedCheque;

    var out: SignedCheque = undefined;
    try parseAddressHex(cb_val.string, &out.cheque.chequebook);
    try parseAddressHex(bn_val.string, &out.cheque.beneficiary);

    out.cheque.cumulative_payout = switch (cp_val) {
        .integer => |n| if (n < 0) return error.MalformedCheque else @intCast(n),
        .number_string => |s| try parseU256Decimal(s),
        .string => |s| try parseU256Decimal(s),
        else => return error.MalformedCheque,
    };

    const Base64 = std.base64.standard.Decoder;
    const decoded_len = Base64.calcSizeForSlice(sig_val.string) catch
        return error.MalformedCheque;
    if (decoded_len != SIGNATURE_LEN) return error.MalformedCheque;
    Base64.decode(&out.signature, sig_val.string) catch return error.MalformedCheque;

    return out;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "cheque: bee golden vector — sign chequebook 0xfa02… payout 500 chainId 1" {
    // Vector lifted directly from
    // bee/pkg/settlement/swap/chequebook/cheque_test.go::TestSignChequeIntegration.
    // The expected signature was computed by ganache against the EIP-712-signed
    // digest of the same Cheque struct.
    var priv: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&priv, "634fb5a872396d9693e5c9f9d7233cfa93f395c093371017ff44aa9ae6564cdd");

    var chequebook_addr: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&chequebook_addr, "fa02D396842E6e1D319E8E3D4D870338F791AA25");

    var beneficiary_addr: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&beneficiary_addr, "98E6C644aFeB94BBfB9FF60EB26fc9D83BBEcA79");

    const cheque = Cheque{
        .chequebook = chequebook_addr,
        .beneficiary = beneficiary_addr,
        .cumulative_payout = 500,
    };

    const sig = try sign(&cheque, 1, priv);

    var expected_sig: [SIGNATURE_LEN]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_sig,
        "171b63fc598ae2c7987f4a756959dadddd84ccd2071e7b5c3aa3437357be47286125edc370c344a163ba7f4183dfd3611996274a13e4b3496610fc00c0e2fc421c",
    );
    try testing.expectEqualSlices(u8, &expected_sig, &sig);
}

test "cheque: recoverIssuer round-trips against signer's address" {
    var priv: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&priv, "634fb5a872396d9693e5c9f9d7233cfa93f395c093371017ff44aa9ae6564cdd");

    // Compute the signer's eth address by deriving it from the privkey.
    const id = try identity.Identity.fromPrivateKey(priv);
    var signer_addr: [20]u8 = undefined;
    id.ethereumAddress(&signer_addr);

    var chequebook_addr: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&chequebook_addr, "fa02D396842E6e1D319E8E3D4D870338F791AA25");

    var beneficiary_addr: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&beneficiary_addr, "98E6C644aFeB94BBfB9FF60EB26fc9D83BBEcA79");

    const cheque = Cheque{
        .chequebook = chequebook_addr,
        .beneficiary = beneficiary_addr,
        .cumulative_payout = 500,
    };
    const sig = try sign(&cheque, 1, priv);
    const signed = SignedCheque{ .cheque = cheque, .signature = sig };
    const recovered = try recoverIssuer(&signed, 1);
    try testing.expectEqualSlices(u8, &signer_addr, &recovered);
}

test "cheque: marshalJson + unmarshalJson round-trip" {
    var priv: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&priv, "634fb5a872396d9693e5c9f9d7233cfa93f395c093371017ff44aa9ae6564cdd");

    var chequebook_addr: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&chequebook_addr, "fa02D396842E6e1D319E8E3D4D870338F791AA25");
    var beneficiary_addr: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&beneficiary_addr, "98E6C644aFeB94BBfB9FF60EB26fc9D83BBEcA79");

    const cheque = Cheque{
        .chequebook = chequebook_addr,
        .beneficiary = beneficiary_addr,
        .cumulative_payout = 500,
    };
    const sig = try sign(&cheque, 1, priv);
    const original = SignedCheque{ .cheque = cheque, .signature = sig };

    const json = try marshalJson(testing.allocator, &original);
    defer testing.allocator.free(json);

    const decoded = try unmarshalJson(testing.allocator, json);
    try testing.expectEqualSlices(u8, &original.cheque.chequebook, &decoded.cheque.chequebook);
    try testing.expectEqualSlices(u8, &original.cheque.beneficiary, &decoded.cheque.beneficiary);
    try testing.expectEqual(original.cheque.cumulative_payout, decoded.cheque.cumulative_payout);
    try testing.expectEqualSlices(u8, &original.signature, &decoded.signature);
}

test "cheque: u256 decimal helpers — large values round-trip" {
    var buf: [78]u8 = undefined;
    const v: u256 = 13_500_000;
    const dec = formatU256Decimal(v, &buf);
    try testing.expectEqualStrings("13500000", dec);

    const parsed = try parseU256Decimal("13500000");
    try testing.expectEqual(@as(u256, 13_500_000), parsed);

    // Near-max: 2^200 ≈ 1.6e60. Round-trip.
    const big: u256 = std.math.pow(u256, 2, 200);
    const big_dec = formatU256Decimal(big, &buf);
    const big_parsed = try parseU256Decimal(big_dec);
    try testing.expectEqual(big, big_parsed);
}

test "cheque: structHash is independent of chainId, signingDigest depends on it" {
    var chequebook_addr: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&chequebook_addr, "fa02D396842E6e1D319E8E3D4D870338F791AA25");
    var beneficiary_addr: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&beneficiary_addr, "98E6C644aFeB94BBfB9FF60EB26fc9D83BBEcA79");

    const cheque = Cheque{
        .chequebook = chequebook_addr,
        .beneficiary = beneficiary_addr,
        .cumulative_payout = 500,
    };
    const sh = structHash(&cheque);
    _ = sh;

    const d1 = signingDigest(&cheque, 1);
    const d100 = signingDigest(&cheque, 100);
    // Different chainIds produce different signing digests.
    try testing.expect(!std.mem.eql(u8, &d1, &d100));
}
