//! Blocking-style TCP stream wrapper for Zig 0.16.
//!
//! 0.16 routes all socket I/O through `std.Io.net.Stream`'s `Reader`/`Writer`
//! (the old `std.net.Stream.read`/`.writeAll` are gone, and `Threaded`'s
//! sockets are non-blocking — readiness is managed inside the `Io` vtable, so
//! raw `posix.read`/`write` would return `WouldBlock`).
//!
//! The protocol stack (multistream-select, the Noise XX handshake, NoiseStream)
//! is written generically over a stream with `.read(dst) -> n` and
//! `.writeAll(bytes)`. `TcpStream` restores exactly that duck-typed surface on
//! top of a `std.Io.net.Stream`.
//!
//! Reader/Writer are created with empty buffers (unbuffered): every `read`
//! issues one socket read into the caller's buffer, every `writeAll` drains
//! straight to the socket. That keeps `TcpStream` free of pending buffered
//! state — handshake/muxer layers do their own buffering.

const std = @import("std");
const io_mod = @import("io.zig");

pub const TcpStream = struct {
    socket: std.Io.net.Stream,
    io: std.Io,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,

    /// Wrap an already-connected socket. The returned value is effectively a
    /// value type (the unbuffered reader/writer hold no pending bytes), but it
    /// must live at a stable address once `read`/`writeAll` are called, because
    /// the `std.Io.Reader`/`Writer` interfaces recover their parent via
    /// `@fieldParentPtr`. Connections heap-allocate it for this reason.
    pub fn init(socket: std.Io.net.Stream) TcpStream {
        const io = io_mod.get();
        return .{
            .socket = socket,
            .io = io,
            .reader = socket.reader(io, &.{}),
            .writer = socket.writer(io, &.{}),
        };
    }

    /// Reads up to `dst.len` bytes; returns the count read, or 0 at end of
    /// stream — matching the old `std.net.Stream.read` contract the protocol
    /// code relies on. One socket read per call: `readSliceShort` would loop
    /// until `dst` is full or EOF, which blocks e.g. the HTTP API forever on
    /// a request shorter than its read buffer. With the unbuffered reader,
    /// `readVec` is a single `netRead` and never returns 0 short of EOF.
    pub fn read(self: *TcpStream, dst: []u8) !usize {
        if (dst.len == 0) return 0;
        var data = [_][]u8{dst};
        return self.reader.interface.readVec(&data) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => e,
        };
    }

    pub fn writeAll(self: *TcpStream, bytes: []const u8) !void {
        return self.writer.interface.writeAll(bytes);
    }

    pub fn close(self: *TcpStream) void {
        self.socket.close(self.io);
    }
};

/// Dial an IPv4 peer over TCP and return a wrapped, ready-to-use stream.
pub fn connectIp4(ip: [4]u8, port: u16) !TcpStream {
    const io = io_mod.get();
    const addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = ip, .port = port } };
    const socket = try addr.connect(io, .{ .mode = .stream });
    return TcpStream.init(socket);
}
