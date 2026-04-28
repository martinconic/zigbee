// /dnsaddr resolver — minimal RFC 1035 DNS-over-UDP TXT lookup for the
// /dnsaddr/<host> multiaddr scheme.
//
// libp2p convention:
//   /dnsaddr/HOST  -> TXT records on _dnsaddr.HOST, each of the form
//                     "dnsaddr=/multiaddr/..."
//   The result may itself be /dnsaddr/... — recurse, with a hop limit so a
//   misconfigured zone can't loop forever.
//
// We talk DNS straight to the system resolver from /etc/resolv.conf. No
// caching, no retries beyond a single timeout — fine for bootstrap.

const std = @import("std");
const multiaddr = @import("multiaddr.zig");

pub const Error = error{
    DnsFormatError,
    DnsServerFailure,
    DnsNameError,
    DnsTruncated,
    NoNameservers,
    ResolutionTimeout,
    TooManyAnswers,
    DnsaddrLoop,
};

const MAX_RESOLVE_DEPTH = 4;
const MAX_ANSWERS = 16;
const QUERY_TIMEOUT_NS: u64 = 5 * std.time.ns_per_s;

pub const ResolvedList = struct {
    items: [][]const u8, // each entry is text-form multiaddr
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ResolvedList) void {
        self.arena.deinit();
    }
};

/// Resolves a /dnsaddr/HOST multiaddr to a flat list of multiaddrs that the
/// caller can dial. Recurses into nested /dnsaddr layers up to
/// MAX_RESOLVE_DEPTH. Returns text-form multiaddrs (each owned by the
/// returned ResolvedList's arena).
pub fn resolve(parent_allocator: std.mem.Allocator, host: []const u8) !ResolvedList {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var out: std.ArrayList([]const u8) = .{};
    try resolveInto(arena_allocator, host, 0, &out);

    return ResolvedList{
        .items = try out.toOwnedSlice(arena_allocator),
        .arena = arena,
    };
}

fn resolveInto(
    allocator: std.mem.Allocator,
    host: []const u8,
    depth: u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (depth >= MAX_RESOLVE_DEPTH) return Error.DnsaddrLoop;

    var qbuf: [256]u8 = undefined;
    const qname = std.fmt.bufPrint(&qbuf, "_dnsaddr.{s}", .{host}) catch return Error.DnsFormatError;

    var answers_buf: [MAX_ANSWERS][]const u8 = undefined;
    const n = try queryTxt(allocator, qname, &answers_buf);
    for (answers_buf[0..n]) |txt| {
        const prefix = "dnsaddr=";
        if (txt.len < prefix.len or !std.mem.startsWith(u8, txt, prefix)) continue;
        const ma_text = txt[prefix.len..];

        if (std.mem.startsWith(u8, ma_text, "/dnsaddr/")) {
            const inner = ma_text["/dnsaddr/".len..];
            try resolveInto(allocator, inner, depth + 1, out);
        } else {
            try out.append(allocator, try allocator.dupe(u8, ma_text));
        }
    }
}

/// Sends a single TXT query for `qname` to the first nameserver in
/// /etc/resolv.conf. Decoded TXT strings are placed into `out_answers` (each
/// is allocator-owned). Returns the count.
fn queryTxt(
    allocator: std.mem.Allocator,
    qname: []const u8,
    out_answers: [][]const u8,
) !usize {
    const ns_addr = try readSystemNameserver();

    var pkt: [512]u8 = undefined;
    const query = try buildQuery(qname, &pkt);

    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(sock);

    // 5-second timeout (RCVTIMEO).
    const tv = std.posix.timeval{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

    _ = std.posix.sendto(sock, query, 0, &ns_addr.any, ns_addr.getOsSockLen()) catch return Error.NoNameservers;

    var resp: [4096]u8 = undefined;
    const got = std.posix.recvfrom(sock, &resp, 0, null, null) catch |e| switch (e) {
        error.WouldBlock => return Error.ResolutionTimeout,
        else => return e,
    };

    return parseTxtResponse(allocator, resp[0..got], out_answers);
}

fn readSystemNameserver() !std.net.Address {
    const file = try std.fs.openFileAbsolute("/etc/resolv.conf", .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = try file.read(&buf);
    var it = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "nameserver")) {
            const rest = std.mem.trim(u8, trimmed["nameserver".len..], " \t");
            return std.net.Address.parseIp(rest, 53);
        }
    }
    return Error.NoNameservers;
}

fn buildQuery(qname: []const u8, out: []u8) ![]u8 {
    if (out.len < 12) return Error.DnsFormatError;

    // 12-byte header: ID, flags=0x0100 (RD set), QDCOUNT=1, ANCOUNT=ARCOUNT=NSCOUNT=0.
    var rng: [2]u8 = undefined;
    std.crypto.random.bytes(&rng);
    out[0] = rng[0];
    out[1] = rng[1];
    std.mem.writeInt(u16, out[2..4], 0x0100, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    std.mem.writeInt(u16, out[6..8], 0, .big);
    std.mem.writeInt(u16, out[8..10], 0, .big);
    std.mem.writeInt(u16, out[10..12], 0, .big);

    var pos: usize = 12;
    // QNAME: a sequence of <len-byte><label>...<0x00>.
    var label_it = std.mem.splitScalar(u8, qname, '.');
    while (label_it.next()) |label| {
        if (label.len == 0) continue;
        if (label.len > 63) return Error.DnsFormatError;
        if (pos + 1 + label.len + 4 + 1 > out.len) return Error.DnsFormatError; // +1 root +4 type/class
        out[pos] = @intCast(label.len);
        pos += 1;
        @memcpy(out[pos .. pos + label.len], label);
        pos += label.len;
    }
    out[pos] = 0;
    pos += 1;
    // QTYPE = TXT (16), QCLASS = IN (1).
    std.mem.writeInt(u16, out[pos..][0..2], 16, .big);
    pos += 2;
    std.mem.writeInt(u16, out[pos..][0..2], 1, .big);
    pos += 2;

    return out[0..pos];
}

fn parseTxtResponse(allocator: std.mem.Allocator, msg: []const u8, out: [][]const u8) !usize {
    if (msg.len < 12) return Error.DnsFormatError;

    const flags = std.mem.readInt(u16, msg[2..4], .big);
    const rcode: u4 = @intCast(flags & 0x000F);
    if ((flags & 0x0200) != 0) return Error.DnsTruncated;
    switch (rcode) {
        0 => {},
        1 => return Error.DnsFormatError,
        2 => return Error.DnsServerFailure,
        3 => return Error.DnsNameError,
        else => return Error.DnsServerFailure,
    }
    const qdcount = std.mem.readInt(u16, msg[4..6], .big);
    const ancount = std.mem.readInt(u16, msg[6..8], .big);

    var pos: usize = 12;
    // Skip questions.
    var qi: usize = 0;
    while (qi < qdcount) : (qi += 1) {
        pos = try skipName(msg, pos);
        if (pos + 4 > msg.len) return Error.DnsFormatError;
        pos += 4;
    }

    var produced: usize = 0;
    var ai: usize = 0;
    while (ai < ancount) : (ai += 1) {
        pos = try skipName(msg, pos);
        if (pos + 10 > msg.len) return Error.DnsFormatError;
        const rrtype = std.mem.readInt(u16, msg[pos..][0..2], .big);
        // Skip class (2) + ttl (4).
        const rdlen = std.mem.readInt(u16, msg[pos + 8 ..][0..2], .big);
        pos += 10;
        if (pos + rdlen > msg.len) return Error.DnsFormatError;
        const rdata = msg[pos .. pos + rdlen];
        pos += rdlen;

        if (rrtype != 16) continue; // not TXT

        // TXT RDATA = sequence of <length-byte><string> chunks. We
        // concatenate them into a single output string per record.
        var txt: std.ArrayList(u8) = .{};
        defer txt.deinit(allocator);

        var off: usize = 0;
        while (off < rdata.len) {
            const slen = rdata[off];
            off += 1;
            if (off + slen > rdata.len) return Error.DnsFormatError;
            try txt.appendSlice(allocator, rdata[off .. off + slen]);
            off += slen;
        }

        if (produced >= out.len) return Error.TooManyAnswers;
        out[produced] = try txt.toOwnedSlice(allocator);
        produced += 1;
    }
    return produced;
}

/// Skips a (possibly compressed) DNS name. Returns the position just past it.
fn skipName(msg: []const u8, start: usize) !usize {
    var pos = start;
    while (true) {
        if (pos >= msg.len) return Error.DnsFormatError;
        const b = msg[pos];
        if (b == 0) return pos + 1;
        if ((b & 0xC0) == 0xC0) {
            // Pointer: 2 bytes total, no further parsing of the target.
            if (pos + 2 > msg.len) return Error.DnsFormatError;
            return pos + 2;
        }
        // Standard label: <len><len bytes>.
        if (pos + 1 + b > msg.len) return Error.DnsFormatError;
        pos += 1 + b;
    }
}

// ---- tests ----

const testing = std.testing;

test "buildQuery encodes a well-formed TXT lookup" {
    var buf: [256]u8 = undefined;
    const q = try buildQuery("_dnsaddr.example.com", &buf);
    // Header is 12 bytes; QDCOUNT=1.
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, q[4..6], .big));
    // Manually walk the QNAME labels: "_dnsaddr" "example" "com" terminator.
    try testing.expectEqual(@as(u8, 8), q[12]);
    try testing.expectEqualSlices(u8, "_dnsaddr", q[13..21]);
    try testing.expectEqual(@as(u8, 7), q[21]);
    try testing.expectEqualSlices(u8, "example", q[22..29]);
    try testing.expectEqual(@as(u8, 3), q[29]);
    try testing.expectEqualSlices(u8, "com", q[30..33]);
    try testing.expectEqual(@as(u8, 0), q[33]);
    // QTYPE/QCLASS at q[34..38].
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, q[34..36], .big));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, q[36..38], .big));
}

test "parseTxtResponse decodes a synthesized response" {
    // Build a minimal DNS response: 1 question, 1 answer (TXT "hello world").
    const allocator = testing.allocator;
    var msg: [128]u8 = undefined;
    var p: usize = 0;
    // Header.
    @memcpy(msg[0..2], &[_]u8{ 0xab, 0xcd });
    std.mem.writeInt(u16, msg[2..4], 0x8180, .big); // QR=1 RD=1 RA=1
    std.mem.writeInt(u16, msg[4..6], 1, .big);
    std.mem.writeInt(u16, msg[6..8], 1, .big);
    std.mem.writeInt(u16, msg[8..10], 0, .big);
    std.mem.writeInt(u16, msg[10..12], 0, .big);
    p = 12;
    // QNAME: foo.bar
    msg[p] = 3; p += 1; @memcpy(msg[p..][0..3], "foo"); p += 3;
    msg[p] = 3; p += 1; @memcpy(msg[p..][0..3], "bar"); p += 3;
    msg[p] = 0; p += 1;
    std.mem.writeInt(u16, msg[p..][0..2], 16, .big); p += 2; // type TXT
    std.mem.writeInt(u16, msg[p..][0..2], 1, .big); p += 2; // class IN
    // Answer: same name (compressed pointer to offset 12), type TXT, class IN, TTL=300, rdlen.
    std.mem.writeInt(u16, msg[p..][0..2], 0xC00C, .big); p += 2;
    std.mem.writeInt(u16, msg[p..][0..2], 16, .big); p += 2;
    std.mem.writeInt(u16, msg[p..][0..2], 1, .big); p += 2;
    std.mem.writeInt(u32, msg[p..][0..4], 300, .big); p += 4;
    const txt = "hello world";
    std.mem.writeInt(u16, msg[p..][0..2], @intCast(1 + txt.len), .big); p += 2;
    msg[p] = @intCast(txt.len); p += 1;
    @memcpy(msg[p..][0..txt.len], txt); p += txt.len;

    var answers: [4][]const u8 = undefined;
    const n = try parseTxtResponse(allocator, msg[0..p], &answers);
    defer for (answers[0..n]) |a| allocator.free(a);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualSlices(u8, txt, answers[0]);
}
