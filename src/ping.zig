// libp2p Ping (`/ipfs/ping/1.0.0`).
//
// Wire flow on a freshly opened stream:
//   - Multistream-select for /ipfs/ping/1.0.0 (caller's responsibility).
//   - Initiator writes 32 random bytes; responder echoes them; repeat.
//   - Either side closes the stream when done.
//
// Used as a lightweight reachability check by go-libp2p's reacher.

const std = @import("std");
const yamux = @import("yamux.zig");
const multistream = @import("multistream.zig");

pub const PROTOCOL_ID = "/ipfs/ping/1.0.0";
const PING_SIZE = 32;

pub const Error = error{
    PingMismatch,
    EndOfStream,
};

/// Responder: read PING_SIZE bytes, echo them, repeat until peer closes.
pub fn respond(stream: *yamux.Stream) !void {
    try multistream.writeMessage(stream, multistream.VERSION);
    try multistream.writeMessage(stream, PROTOCOL_ID);

    var buf: [PING_SIZE]u8 = undefined;
    while (true) {
        var read_total: usize = 0;
        while (read_total < buf.len) {
            const n = stream.read(buf[read_total..]) catch |e| switch (e) {
                error.StreamReset => return,
                else => return e,
            };
            if (n == 0) return; // peer FIN
            read_total += n;
        }
        try stream.writeAll(&buf);
    }
}

/// Initiator: send a random nonce, read it back, return the round-trip
/// duration in nanoseconds.
pub fn ping(stream: *yamux.Stream) !u64 {
    try multistream.selectOne(stream, PROTOCOL_ID);

    var nonce: [PING_SIZE]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const start = std.time.nanoTimestamp();
    try stream.writeAll(&nonce);

    var echo: [PING_SIZE]u8 = undefined;
    var read_total: usize = 0;
    while (read_total < echo.len) {
        const n = try stream.read(echo[read_total..]);
        if (n == 0) return Error.EndOfStream;
        read_total += n;
    }
    const elapsed = std.time.nanoTimestamp() - start;

    if (!std.mem.eql(u8, &nonce, &echo)) return Error.PingMismatch;
    return @intCast(elapsed);
}

// No localhost roundtrip test here: ping.respond and ping.ping are 32-byte
// echo over a Yamux stream — trivially correct given Yamux is already tested.
// The interesting failure modes (window flow, FIN propagation) are exercised
// by the noise.zig localhost test and by live bee interop. Adding a test
// here that spins up a full Yamux session pair gets tangled in deinit
// lifecycle (the reader thread blocks on the underlying socket; clean
// shutdown requires interrupting the socket from outside the session,
// which is the kind of thing a real Host wrapper handles, not a unit test).
