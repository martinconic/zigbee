//! `/swarm/swap/1.0.0/swap` — protocol initiator (bee accepts cheques on this
//! stream). Issue-only: zigbee never *receives* cheques as a retrieval-only
//! client (bee never owes us BZZ), so this module does not register an
//! inbound handler. If bee ever opens a swap stream against us, the dispatcher
//! falls through to "unknown protocol" and the stream resets — bee logs and
//! moves on.
//!
//! ## Wire flow (initiator)
//!
//! After multistream-select on `/swarm/swap/1.0.0/swap`:
//!
//!   1. Initiator writes empty Headers (`0x00`) — we have no priceoracle to
//!      announce; bee's handler doesn't validate our outbound headers anyway.
//!   2. Initiator reads bee's response Headers (varint-length-prefixed protobuf
//!      `Headers { repeated Header headers = 1 }`). Bee's headler fills these
//!      from its priceoracle: `exchange` + (optional) `deduction`, both
//!      big-endian uint256 byte slices.
//!   3. Initiator writes `EmitCheque { bytes Cheque = 1 }` protobuf, where the
//!      Cheque field contains JSON-marshaled `SignedCheque` (bee's wire choice
//!      — see swapprotocol.go:229 "for simplicity we use json marshaller").
//!   4. Stream closes.
//!
//! Reference: `bee/pkg/settlement/swap/swapprotocol/swapprotocol.go`.

const std = @import("std");
const yamux = @import("yamux.zig");
const proto = @import("proto.zig");
const swarm_proto = @import("swarm_proto.zig");
const cheque = @import("cheque.zig");

pub const PROTOCOL_ID = "/swarm/swap/1.0.0/swap";

pub const Error = error{
    HeadersTooLarge,
    MalformedHeaders,
    HeadersMissingExchangeRate,
};

/// Settlement headers carried both ways on a swap stream.
///
/// `exchange_rate` is wei-per-BZZ (priceoracle output). `deduction` is a
/// per-payment fee bee sometimes claims; in practice it's zero for normal
/// retrieval-paid-by-cheque traffic. Both fields are big-endian uint256
/// on the wire.
pub const SettlementHeaders = struct {
    exchange_rate: u256,
    deduction: u256,
};

const FIELD_NAME_EXCHANGE = "exchange";
const FIELD_NAME_DEDUCTION = "deduction";

/// Parse a `Headers { repeated Header { string key, bytes value } }` protobuf
/// payload (NOT length-prefixed — caller stripped that already) into our
/// SettlementHeaders. Tolerates fields appearing in any order; missing
/// `deduction` is treated as zero (bee uses `ErrNoDeductionHeader` paths).
/// Missing `exchange` is an error — bee's protocol always sends it.
pub fn parseSettlementHeaders(buf: []const u8) !SettlementHeaders {
    var exchange: ?u256 = null;
    var deduction: u256 = 0;

    var off: usize = 0;
    while (off < buf.len) {
        const tag = try proto.readVarint(buf[off..]);
        off += tag.bytes_read;
        const wt = tag.value & 0x07;
        const fnum = tag.value >> 3;
        if (wt != 2) return Error.MalformedHeaders;

        const lr = try proto.readVarint(buf[off..]);
        off += lr.bytes_read;
        const flen: usize = @intCast(lr.value);
        if (off + flen > buf.len) return Error.MalformedHeaders;
        const field_bytes = buf[off .. off + flen];
        off += flen;

        // Each `headers` repeated entry is a Header message — recurse.
        if (fnum == 1) {
            const h = try parseHeaderEntry(field_bytes);
            if (std.mem.eql(u8, h.key, FIELD_NAME_EXCHANGE)) {
                exchange = bytesToU256BE(h.value);
            } else if (std.mem.eql(u8, h.key, FIELD_NAME_DEDUCTION)) {
                deduction = bytesToU256BE(h.value);
            }
            // Unknown keys are silently ignored — forward-compat.
        }
    }

    return .{
        .exchange_rate = exchange orelse return Error.HeadersMissingExchangeRate,
        .deduction = deduction,
    };
}

const HeaderEntry = struct { key: []const u8, value: []const u8 };

fn parseHeaderEntry(buf: []const u8) !HeaderEntry {
    var key: []const u8 = "";
    var value: []const u8 = "";

    var off: usize = 0;
    while (off < buf.len) {
        const tag = try proto.readVarint(buf[off..]);
        off += tag.bytes_read;
        const wt = tag.value & 0x07;
        const fnum = tag.value >> 3;
        if (wt != 2) return Error.MalformedHeaders;

        const lr = try proto.readVarint(buf[off..]);
        off += lr.bytes_read;
        const flen: usize = @intCast(lr.value);
        if (off + flen > buf.len) return Error.MalformedHeaders;

        switch (fnum) {
            1 => key = buf[off .. off + flen],
            2 => value = buf[off .. off + flen],
            else => {}, // ignore unknown fields
        }
        off += flen;
    }
    return .{ .key = key, .value = value };
}

/// `bee` and `go-ethereum` encode big-int values as the minimal big-endian
/// byte slice (`big.Int.Bytes()`), with leading zeros stripped. We accept up
/// to 32 bytes (uint256); anything wider is unrepresentable in our domain.
fn bytesToU256BE(b: []const u8) u256 {
    if (b.len > 32) return 0; // truncation impossible; treat as zero (defensive)
    var v: u256 = 0;
    for (b) |byte| {
        v = (v << 8) | byte;
    }
    return v;
}

/// Initiator: exchange Headers (empty out → read bee's), return parsed
/// settlement headers. Stream stays open for the caller to send `EmitCheque`.
pub fn negotiate(allocator: std.mem.Allocator, stream: *yamux.Stream) !SettlementHeaders {
    // Empty outbound headers — we have nothing useful to announce.
    try stream.writeAll(&[_]u8{0x00});

    const buf = try swarm_proto.readDelimited(allocator, stream, 4096);
    defer allocator.free(buf);
    return parseSettlementHeaders(buf);
}

/// Build the `EmitCheque { bytes Cheque = 1 }` protobuf payload. Caller frees.
fn buildEmitChequePb(allocator: std.mem.Allocator, cheque_json: []const u8) ![]u8 {
    // Tag for field 1 (length-delimited) = (1 << 3) | 2 = 0x0A.
    // Followed by varint(len) + raw bytes. Total max ≈ json.len + 6.
    const buf = try allocator.alloc(u8, cheque_json.len + 12);
    errdefer allocator.free(buf);

    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try proto.writeVarint(w, (1 << 3) | 2);
    try proto.writeVarint(w, cheque_json.len);
    try w.writeAll(cheque_json);

    return try allocator.realloc(buf, fbs.pos);
}

/// Send a SignedCheque to bee on an already-negotiated swap stream. Caller
/// must have already called `negotiate` on the same stream.
pub fn sendCheque(
    allocator: std.mem.Allocator,
    stream: *yamux.Stream,
    signed: *const cheque.SignedCheque,
) !void {
    const json = try cheque.marshalJson(allocator, signed);
    defer allocator.free(json);

    const pb = try buildEmitChequePb(allocator, json);
    defer allocator.free(pb);

    try swarm_proto.writeDelimited(stream, pb);
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

/// Helper for tests: hand-build a Headers protobuf with an `exchange` and an
/// optional `deduction` field, both as big-endian uint256.
fn buildHeadersBuf(allocator: std.mem.Allocator, exchange: u256, deduction: ?u256) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    var inner: std.ArrayList(u8) = .{};
    defer inner.deinit(allocator);

    const writeHeader = struct {
        fn run(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, val_be: []const u8) !void {
            buf.clearRetainingCapacity();
            // field 1: key (string) — tag 0x0A
            try buf.append(alloc, 0x0A);
            try appendVarint(alloc, buf, key.len);
            try buf.appendSlice(alloc, key);
            // field 2: value (bytes) — tag 0x12
            try buf.append(alloc, 0x12);
            try appendVarint(alloc, buf, val_be.len);
            try buf.appendSlice(alloc, val_be);
        }
    }.run;

    var be_buf: [32]u8 = undefined;

    // exchange entry
    const ex_be = u256ToMinimalBE(exchange, &be_buf);
    try writeHeader(allocator, &inner, FIELD_NAME_EXCHANGE, ex_be);
    try out.append(allocator, 0x0A); // tag for headers field (repeated Header → tag 0x0A)
    try appendVarint(allocator, &out, inner.items.len);
    try out.appendSlice(allocator, inner.items);

    if (deduction) |d| {
        const d_be = u256ToMinimalBE(d, &be_buf);
        try writeHeader(allocator, &inner, FIELD_NAME_DEDUCTION, d_be);
        try out.append(allocator, 0x0A);
        try appendVarint(allocator, &out, inner.items.len);
        try out.appendSlice(allocator, inner.items);
    }

    return out.toOwnedSlice(allocator);
}

fn appendVarint(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: u64) !void {
    var x = v;
    while (true) {
        var b: u8 = @truncate(x & 0x7F);
        x >>= 7;
        if (x != 0) {
            b |= 0x80;
            try buf.append(allocator, b);
        } else {
            try buf.append(allocator, b);
            break;
        }
    }
}

/// Encode a u256 as the minimal big-endian byte slice (matches Go's
/// `big.Int.Bytes()` — zero-stripping leading zeros). Returns a slice of
/// `out`. For value 0 returns a zero-length slice.
fn u256ToMinimalBE(v: u256, out: *[32]u8) []const u8 {
    if (v == 0) return out[0..0];
    var tmp: [32]u8 = undefined;
    var x = v;
    var i: usize = 32;
    while (x > 0) {
        i -= 1;
        tmp[i] = @truncate(x & 0xff);
        x >>= 8;
    }
    const len = 32 - i;
    @memcpy(out[0..len], tmp[i..32]);
    return out[0..len];
}

test "swap: parseSettlementHeaders — exchange + deduction round-trip" {
    const buf = try buildHeadersBuf(testing.allocator, 906000, 5348);
    defer testing.allocator.free(buf);

    const parsed = try parseSettlementHeaders(buf);
    try testing.expectEqual(@as(u256, 906000), parsed.exchange_rate);
    try testing.expectEqual(@as(u256, 5348), parsed.deduction);
}

test "swap: parseSettlementHeaders — missing deduction defaults to 0" {
    const buf = try buildHeadersBuf(testing.allocator, 42, null);
    defer testing.allocator.free(buf);

    const parsed = try parseSettlementHeaders(buf);
    try testing.expectEqual(@as(u256, 42), parsed.exchange_rate);
    try testing.expectEqual(@as(u256, 0), parsed.deduction);
}

test "swap: parseSettlementHeaders — missing exchange is an error" {
    // Build a Headers buf containing only `deduction` — bee never does this
    // in practice but we should still reject it.
    var inner: std.ArrayList(u8) = .{};
    defer inner.deinit(testing.allocator);
    try inner.append(testing.allocator, 0x0A);
    try appendVarint(testing.allocator, &inner, FIELD_NAME_DEDUCTION.len);
    try inner.appendSlice(testing.allocator, FIELD_NAME_DEDUCTION);
    try inner.append(testing.allocator, 0x12);
    try appendVarint(testing.allocator, &inner, 1);
    try inner.append(testing.allocator, 0x07);

    var outer: std.ArrayList(u8) = .{};
    defer outer.deinit(testing.allocator);
    try outer.append(testing.allocator, 0x0A);
    try appendVarint(testing.allocator, &outer, inner.items.len);
    try outer.appendSlice(testing.allocator, inner.items);

    try testing.expectError(Error.HeadersMissingExchangeRate, parseSettlementHeaders(outer.items));
}

test "swap: buildEmitChequePb wraps json in tag-1 length-delimited field" {
    const json = "{\"Chequebook\":\"0xfa02D396842E6e1D319E8E3D4D870338F791AA25\"}";
    const pb = try buildEmitChequePb(testing.allocator, json);
    defer testing.allocator.free(pb);

    // First byte: tag for field 1, wire type 2 = 0x0A.
    try testing.expectEqual(@as(u8, 0x0A), pb[0]);
    // Followed by varint(len). For a 56-byte json this is one byte (56 < 128).
    try testing.expectEqual(@as(u8, json.len), pb[1]);
    // Then the raw json.
    try testing.expectEqualSlices(u8, json, pb[2..]);
}

test "swap: bytesToU256BE — minimal encoding round-trips" {
    try testing.expectEqual(@as(u256, 0), bytesToU256BE(""));
    try testing.expectEqual(@as(u256, 1), bytesToU256BE(&[_]u8{0x01}));
    try testing.expectEqual(@as(u256, 0xff_00), bytesToU256BE(&[_]u8{ 0xff, 0x00 }));
    // Max practical: 13_500_000 wei = 0xCDFE60.
    try testing.expectEqual(@as(u256, 13_500_000), bytesToU256BE(&[_]u8{ 0xCD, 0xFE, 0x60 }));
}
