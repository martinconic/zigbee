// libp2p multistream-select 1.0.0.
//
// Wire format: each frame is a varint length prefix followed by `length`
// bytes. The framed payload is a UTF-8 string ending in '\n'. The varint
// length includes that trailing newline.
//
// Connection-establishment flow (both initiator and responder):
//   1. Both sides send "/multistream/1.0.0\n" as the first frame.
//   2. Both sides read the peer's "/multistream/1.0.0\n" hello.
//   3. Initiator sends a protocol proposal, e.g. "/noise\n".
//   4. Responder replies with the same string on accept, or "na\n" on reject.
// The same flow runs again on each new Yamux stream (just over the
// encrypted, multiplexed transport).
//
// We implement only the bits zigbee needs:
//   - selectOne: client-side, propose a single protocol; error if peer
//     rejects it.
//   - acceptOne: server-side, expect exactly one of `supported` to be
//     proposed; reject everything else with "na" and try again. We do not
//     implement `ls` (peer asks for the protocol list) — bee never sends it
//     and supporting it would force us to know the full handler table here.

const std = @import("std");

pub const VERSION: []const u8 = "/multistream/1.0.0";
pub const NA: []const u8 = "na";

pub const Error = error{
    ProtocolMismatch,
    UnexpectedHello,
    BufferTooSmall,
    EmptyMessage,
    LineTooLong,
    EndOfStream,
};

/// Reads a uvarint from `stream`. Bounded to 10 bytes (u64).
fn readUvarint(stream: anytype) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    var byte: [1]u8 = undefined;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const n = try stream.read(&byte);
        if (n == 0) return Error.EndOfStream;
        const b = byte[0];
        result |= @as(u64, b & 0x7F) << shift;
        if ((b & 0x80) == 0) return result;
        if (shift == 63) return error.VarintTooLong;
        shift += 7;
    }
    return error.VarintTooLong;
}

fn writeUvarint(stream: anytype, value: u64) !void {
    var val = value;
    var buf: [10]u8 = undefined;
    var i: usize = 0;
    while (val >= 0x80) {
        buf[i] = @as(u8, @intCast((val & 0x7F) | 0x80));
        val >>= 7;
        i += 1;
    }
    buf[i] = @as(u8, @intCast(val));
    try stream.writeAll(buf[0 .. i + 1]);
}

fn readExact(stream: anytype, dest: []u8) !void {
    var total: usize = 0;
    while (total < dest.len) {
        const n = try stream.read(dest[total..]);
        if (n == 0) return Error.EndOfStream;
        total += n;
    }
}

/// Reads one length-prefixed multistream message into `buffer` and returns a
/// slice without the trailing newline.
pub fn readMessage(stream: anytype, buffer: []u8) ![]u8 {
    const len_u64 = try readUvarint(stream);
    if (len_u64 == 0) return Error.EmptyMessage;
    const len: usize = @intCast(len_u64);
    if (len > buffer.len) return Error.BufferTooSmall;
    try readExact(stream, buffer[0..len]);
    if (buffer[len - 1] != '\n') return Error.LineTooLong;
    return buffer[0 .. len - 1];
}

/// Writes a multistream message: varint(len(msg)+1) || msg || '\n'.
pub fn writeMessage(stream: anytype, msg: []const u8) !void {
    try writeUvarint(stream, msg.len + 1);
    try stream.writeAll(msg);
    try stream.writeAll("\n");
}

/// Client side: send our hello + protocol proposal, expect peer's hello + the
/// same protocol echoed back. Errors with ProtocolMismatch on rejection.
///
/// We send hello + proposal back-to-back (TCP coalesces them) and then read
/// hello + response. This avoids the deadlock you'd get with strict
/// write-read-write-read ordering when the peer does the same.
pub fn selectOne(stream: anytype, protocol: []const u8) !void {
    try writeMessage(stream, VERSION);
    try writeMessage(stream, protocol);

    var buf: [256]u8 = undefined;
    const peer_hello = try readMessage(stream, &buf);
    if (!std.mem.eql(u8, peer_hello, VERSION)) return Error.UnexpectedHello;

    const peer_choice = try readMessage(stream, &buf);
    if (!std.mem.eql(u8, peer_choice, protocol)) return Error.ProtocolMismatch;
}

/// Server side: complete the version handshake, then keep reading proposals
/// until one matches `supported`. Each non-matching proposal is rejected
/// with "na" and we read the next one. Returns the index of the matched
/// protocol, or errors if the peer disconnects without proposing anything we
/// support.
pub fn acceptOne(stream: anytype, supported: []const []const u8) !usize {
    try writeMessage(stream, VERSION);

    var buf: [256]u8 = undefined;
    const peer_hello = try readMessage(stream, &buf);
    if (!std.mem.eql(u8, peer_hello, VERSION)) return Error.UnexpectedHello;

    while (true) {
        const proposal = try readMessage(stream, &buf);
        for (supported, 0..) |s, i| {
            if (std.mem.eql(u8, proposal, s)) {
                try writeMessage(stream, s);
                return i;
            }
        }
        try writeMessage(stream, NA);
    }
}

// ---- tests ----

const testing = std.testing;

const Pipe = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    read_pos: usize = 0,

    pub fn read(self: *Pipe, dest: []u8) !usize {
        const avail = self.len - self.read_pos;
        if (avail == 0) return 0;
        const n = @min(avail, dest.len);
        @memcpy(dest[0..n], self.buf[self.read_pos..][0..n]);
        self.read_pos += n;
        return n;
    }

    pub fn writeAll(self: *Pipe, data: []const u8) !void {
        if (self.len + data.len > self.buf.len) return error.PipeFull;
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
    }
};

test "writeMessage produces varint-prefixed UTF-8 with trailing newline" {
    var pipe = Pipe{};
    try writeMessage(&pipe, "/noise");
    // varint(7) || "/noise" || "\n" = 0x07 0x2f 0x6e 0x6f 0x69 0x73 0x65 0x0a
    const expected = [_]u8{ 0x07, '/', 'n', 'o', 'i', 's', 'e', '\n' };
    try testing.expectEqualSlices(u8, &expected, pipe.buf[0..pipe.len]);
}

test "readMessage round-trips" {
    var pipe = Pipe{};
    try writeMessage(&pipe, VERSION);
    var buf: [64]u8 = undefined;
    const got = try readMessage(&pipe, &buf);
    try testing.expectEqualSlices(u8, VERSION, got);
}

test "selectOne against an in-memory accepting peer" {
    // Two pipes: c2s = bytes from client to server, s2c = bytes from server to client.
    // selectOne writes its hello+proposal into c2s; we then drive the
    // server side manually to put hello+ack into s2c, and read s2c back as
    // selectOne's input.
    //
    // To keep the test single-threaded, we pre-stage server's response
    // (hello + accept) before calling selectOne. selectOne writes hello +
    // proposal into c2s and reads from s2c (already populated).

    var s2c = Pipe{};
    var c2s = Pipe{};

    // Stage server's responses.
    try writeMessage(&s2c, VERSION);
    try writeMessage(&s2c, "/yamux/1.0.0");

    // Client wants both directions; wrap into one duplex.
    const Duplex = struct {
        in: *Pipe,
        out: *Pipe,
        pub fn read(self: @This(), dest: []u8) !usize {
            return self.in.read(dest);
        }
        pub fn writeAll(self: @This(), data: []const u8) !void {
            try self.out.writeAll(data);
        }
    };
    const dx = Duplex{ .in = &s2c, .out = &c2s };

    try selectOne(dx, "/yamux/1.0.0");

    // Verify what client wrote.
    var rdr = Pipe{ .buf = c2s.buf, .len = c2s.len };
    var buf: [64]u8 = undefined;
    const sent_hello = try readMessage(&rdr, &buf);
    try testing.expectEqualSlices(u8, VERSION, sent_hello);
    const sent_proposal = try readMessage(&rdr, &buf);
    try testing.expectEqualSlices(u8, "/yamux/1.0.0", sent_proposal);
}

test "selectOne rejection surfaces ProtocolMismatch" {
    var s2c = Pipe{};
    var c2s = Pipe{};

    try writeMessage(&s2c, VERSION);
    try writeMessage(&s2c, NA);

    const Duplex = struct {
        in: *Pipe,
        out: *Pipe,
        pub fn read(self: @This(), dest: []u8) !usize {
            return self.in.read(dest);
        }
        pub fn writeAll(self: @This(), data: []const u8) !void {
            try self.out.writeAll(data);
        }
    };
    const dx = Duplex{ .in = &s2c, .out = &c2s };

    try testing.expectError(Error.ProtocolMismatch, selectOne(dx, "/yamux/1.0.0"));
}

test "acceptOne rejects unsupported then accepts supported" {
    var c2s = Pipe{};
    var s2c = Pipe{};

    // Stage what the client (peer) sends to the server: hello, then a bad
    // proposal, then a good one.
    try writeMessage(&c2s, VERSION);
    try writeMessage(&c2s, "/something-we-do-not-support");
    try writeMessage(&c2s, "/yamux/1.0.0");

    const Duplex = struct {
        in: *Pipe,
        out: *Pipe,
        pub fn read(self: @This(), dest: []u8) !usize {
            return self.in.read(dest);
        }
        pub fn writeAll(self: @This(), data: []const u8) !void {
            try self.out.writeAll(data);
        }
    };
    const dx = Duplex{ .in = &c2s, .out = &s2c };

    const supported = [_][]const u8{ "/yamux/1.0.0", "/mplex/6.7.0" };
    const idx = try acceptOne(dx, &supported);
    try testing.expectEqual(@as(usize, 0), idx);

    // Server should have written: hello, "na", then "/yamux/1.0.0".
    var rdr = Pipe{ .buf = s2c.buf, .len = s2c.len };
    var buf: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, VERSION, try readMessage(&rdr, &buf));
    try testing.expectEqualSlices(u8, NA, try readMessage(&rdr, &buf));
    try testing.expectEqualSlices(u8, "/yamux/1.0.0", try readMessage(&rdr, &buf));
}
