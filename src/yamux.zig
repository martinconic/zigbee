// hashicorp/yamux v0 multiplexer.
//
// Single-direction encrypted byte stream → many bidirectional logical
// streams. We implement only what zigbee needs to interoperate with go-libp2p:
//
//   - Frame types: Data, WindowUpdate, Ping, GoAway.
//   - Per-stream send/receive windows; default 256 KiB.
//   - SYN to open a stream; ACK on the first response frame.
//   - FIN to close one direction; RST to abort.
//   - Pings answered with ACKed Ping frames.
//
// What we don't do (yet, all known limitations):
//   - Send proactive keepalive pings (only respond to peer pings).
//   - Read in flight while one stream's read buffer is full (we apply
//     per-stream backpressure but the session reader thread is shared, so a
//     full stream blocks all streams. Fine for the small Identify-style
//     interactions we have today; revisit if it becomes a problem).
//   - Configurable initial window — hardcoded to 256 KiB to match the spec.

const std = @import("std");
const noise = @import("noise.zig");

pub const YamuxFrameType = enum(u8) {
    Data = 0,
    WindowUpdate = 1,
    Ping = 2,
    GoAway = 3,
};

pub const YamuxFlags = packed struct {
    syn: bool = false,
    ack: bool = false,
    fin: bool = false,
    rst: bool = false,
    _padding: u12 = 0,
};

pub const YamuxHeader = struct {
    version: u8,
    frame_type: YamuxFrameType,
    flags: YamuxFlags,
    stream_id: u32,
    length: u32,

    pub fn encode(self: YamuxHeader, buffer: *[12]u8) void {
        buffer[0] = self.version;
        buffer[1] = @intFromEnum(self.frame_type);

        var flags_val: u16 = 0;
        if (self.flags.syn) flags_val |= 1;
        if (self.flags.ack) flags_val |= 2;
        if (self.flags.fin) flags_val |= 4;
        if (self.flags.rst) flags_val |= 8;

        std.mem.writeInt(u16, buffer[2..4], flags_val, .big);
        std.mem.writeInt(u32, buffer[4..8], self.stream_id, .big);
        std.mem.writeInt(u32, buffer[8..12], self.length, .big);
    }

    pub fn decode(buffer: *const [12]u8) !YamuxHeader {
        if (buffer[0] != 0) return error.UnsupportedYamuxVersion;
        const type_val = buffer[1];
        if (type_val > 3) return error.InvalidYamuxFrameType;
        const flags_val = std.mem.readInt(u16, buffer[2..4], .big);
        return YamuxHeader{
            .version = buffer[0],
            .frame_type = @enumFromInt(type_val),
            .flags = YamuxFlags{
                .syn = (flags_val & 1) != 0,
                .ack = (flags_val & 2) != 0,
                .fin = (flags_val & 4) != 0,
                .rst = (flags_val & 8) != 0,
            },
            .stream_id = std.mem.readInt(u32, buffer[4..8], .big),
            .length = std.mem.readInt(u32, buffer[8..12], .big),
        };
    }
};

pub const Error = error{
    SessionClosed,
    StreamClosed,
    StreamReset,
    UnknownStream,
    PayloadTooLarge,
    AcceptQueueClosed,
};

const INITIAL_WINDOW: u32 = 256 * 1024;
const MAX_FRAME_PAYLOAD: usize = 65535;

pub const Stream = struct {
    session: *YamuxSession,
    id: u32,

    /// Bytes received and not yet read by the application.
    recv: std.ArrayList(u8),
    /// Bytes consumed since the last WindowUpdate sent. We send a
    /// WindowUpdate once this reaches half of INITIAL_WINDOW.
    recv_consumed_since_update: u32,
    /// Capacity remaining in the peer's send buffer (i.e. how much we may
    /// still send before having to wait for a WindowUpdate from them).
    send_window: u32,

    /// The very first frame we send out on this stream needs the SYN flag
    /// (if we initiated) or the ACK flag (if peer initiated). Cleared after.
    pending_flag: enum { none, syn, ack } = .none,

    /// remote_closed: peer sent FIN — no more incoming data.
    /// local_closed: we sent FIN — no more outgoing data.
    /// reset: either side sent RST; the stream is dead.
    remote_closed: bool = false,
    local_closed: bool = false,
    reset_flag: bool = false,

    mtx: std.Thread.Mutex = .{},
    /// Fired on inbound data, FIN, or RST.
    recv_cond: std.Thread.Condition = .{},
    /// Fired on inbound WindowUpdate (send_window grew).
    send_cond: std.Thread.Condition = .{},

    _allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, session: *YamuxSession, id: u32, initiated_locally: bool) Stream {
        return .{
            .session = session,
            .id = id,
            .recv = std.ArrayList(u8){},
            .recv_consumed_since_update = 0,
            .send_window = INITIAL_WINDOW,
            .pending_flag = if (initiated_locally) .syn else .ack,
            ._allocator = allocator,
        };
    }

    fn deinit(self: *Stream) void {
        self.recv.deinit(self._allocator);
    }

    /// Reads up to `dest.len` bytes. Blocks until at least one byte is
    /// available, or the stream ends. Returns 0 on graceful FIN.
    pub fn read(self: *Stream, dest: []u8) !usize {
        self.mtx.lock();

        while (self.recv.items.len == 0) {
            if (self.reset_flag) {
                self.mtx.unlock();
                return Error.StreamReset;
            }
            if (self.remote_closed) {
                self.mtx.unlock();
                return 0;
            }
            self.recv_cond.wait(&self.mtx);
        }

        const n = @min(self.recv.items.len, dest.len);
        @memcpy(dest[0..n], self.recv.items[0..n]);
        // Drop the consumed bytes from the front.
        const remaining = self.recv.items.len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.recv.items[0..remaining], self.recv.items[n..]);
        }
        self.recv.shrinkRetainingCapacity(remaining);

        self.recv_consumed_since_update +|= @intCast(n);
        const should_update = self.recv_consumed_since_update >= INITIAL_WINDOW / 2;
        const update_delta = if (should_update) self.recv_consumed_since_update else 0;
        if (should_update) self.recv_consumed_since_update = 0;

        self.mtx.unlock();

        if (should_update) {
            self.session.writeHeader(.{
                .version = 0,
                .frame_type = .WindowUpdate,
                .flags = self.takePendingFlags(),
                .stream_id = self.id,
                .length = update_delta,
            }) catch {};
        }
        return n;
    }

    /// Writes all of `data`, splitting into frames at MAX_FRAME_PAYLOAD,
    /// blocking when the peer's window is exhausted.
    pub fn writeAll(self: *Stream, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            self.mtx.lock();
            while (self.send_window == 0 and !self.reset_flag and !self.local_closed) {
                self.send_cond.wait(&self.mtx);
            }
            if (self.reset_flag) {
                self.mtx.unlock();
                return Error.StreamReset;
            }
            if (self.local_closed) {
                self.mtx.unlock();
                return Error.StreamClosed;
            }
            const chunk_len: u32 = @intCast(@min(@min(data.len - offset, MAX_FRAME_PAYLOAD), self.send_window));
            self.send_window -= chunk_len;
            const flags = self.takePendingFlagsLocked();
            self.mtx.unlock();

            try self.session.writeFrame(.{
                .version = 0,
                .frame_type = .Data,
                .flags = flags,
                .stream_id = self.id,
                .length = chunk_len,
            }, data[offset..][0..chunk_len]);
            offset += chunk_len;
        }
    }

    /// Forcibly tears this stream down: sets the local reset flag, wakes
    /// any pending read/write, and sends RST to the peer. Used by the
    /// retrieval timeout watchdog so a hung peer can't block us forever.
    /// After cancel(), read() returns StreamReset and writeAll() / close()
    /// become no-ops.
    pub fn cancel(self: *Stream) void {
        self.mtx.lock();
        if (self.reset_flag) {
            self.mtx.unlock();
            return;
        }
        self.reset_flag = true;
        const flags_base = self.takePendingFlagsLocked();
        self.recv_cond.broadcast();
        self.send_cond.broadcast();
        self.mtx.unlock();

        // Best-effort RST to peer. If the session is dead, ignore.
        var flags = flags_base;
        flags.rst = true;
        self.session.writeHeader(.{
            .version = 0,
            .frame_type = .Data,
            .flags = flags,
            .stream_id = self.id,
            .length = 0,
        }) catch {};
    }

    /// Sends FIN on this stream. After close the stream still accepts
    /// inbound data until the peer also sends FIN.
    pub fn close(self: *Stream) !void {
        self.mtx.lock();
        if (self.local_closed or self.reset_flag) {
            self.mtx.unlock();
            return;
        }
        self.local_closed = true;
        const flags_base = self.takePendingFlagsLocked();
        self.mtx.unlock();

        var flags = flags_base;
        flags.fin = true;
        try self.session.writeHeader(.{
            .version = 0,
            .frame_type = .Data,
            .flags = flags,
            .stream_id = self.id,
            .length = 0,
        });
    }

    fn takePendingFlags(self: *Stream) YamuxFlags {
        self.mtx.lock();
        defer self.mtx.unlock();
        return self.takePendingFlagsLocked();
    }

    fn takePendingFlagsLocked(self: *Stream) YamuxFlags {
        var flags = YamuxFlags{};
        switch (self.pending_flag) {
            .syn => flags.syn = true,
            .ack => flags.ack = true,
            .none => {},
        }
        self.pending_flag = .none;
        return flags;
    }
};

pub const YamuxSession = struct {
    underlying: *noise.NoiseStream,
    allocator: std.mem.Allocator,
    is_client: bool,

    streams: std.AutoHashMap(u32, *Stream),
    accept_queue: std.ArrayList(*Stream),
    next_stream_id: u32,

    /// Guards: streams, accept_queue, next_stream_id, shutdown.
    mtx: std.Thread.Mutex = .{},
    accept_cond: std.Thread.Condition = .{},

    /// Serializes writes to the underlying NoiseStream. Held only across
    /// individual frame writes; never held across blocking operations.
    write_mtx: std.Thread.Mutex = .{},

    reader_thread: ?std.Thread = null,
    shutdown_flag: bool = false,

    pub fn init(allocator: std.mem.Allocator, underlying: *noise.NoiseStream, is_client: bool) !*YamuxSession {
        const self = try allocator.create(YamuxSession);
        self.* = .{
            .underlying = underlying,
            .allocator = allocator,
            .is_client = is_client,
            .streams = std.AutoHashMap(u32, *Stream).init(allocator),
            .accept_queue = std.ArrayList(*Stream){},
            // Client uses odd IDs starting at 1; server uses even starting at 2.
            .next_stream_id = if (is_client) 1 else 2,
        };
        return self;
    }

    pub fn deinit(self: *YamuxSession) void {
        self.shutdown();
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();
        self.accept_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn start(self: *YamuxSession) !void {
        self.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{self});
    }

    /// Blocks until a peer-initiated stream becomes available.
    pub fn accept(self: *YamuxSession) !*Stream {
        self.mtx.lock();
        defer self.mtx.unlock();
        while (self.accept_queue.items.len == 0 and !self.shutdown_flag) {
            self.accept_cond.wait(&self.mtx);
        }
        if (self.accept_queue.items.len == 0) return Error.AcceptQueueClosed;
        return self.accept_queue.orderedRemove(0);
    }

    /// Opens a new outbound stream. The SYN is piggybacked on the first
    /// frame the caller sends (so this call doesn't itself emit any bytes).
    pub fn open(self: *YamuxSession) !*Stream {
        self.mtx.lock();
        const id = self.next_stream_id;
        self.next_stream_id += 2;
        const s = try self.allocator.create(Stream);
        s.* = Stream.init(self.allocator, self, id, true);
        try self.streams.put(id, s);
        self.mtx.unlock();
        return s;
    }

    fn shutdown(self: *YamuxSession) void {
        self.mtx.lock();
        self.shutdown_flag = true;
        self.mtx.unlock();
        self.accept_cond.broadcast();
    }

    fn writeHeader(self: *YamuxSession, hdr: YamuxHeader) !void {
        self.write_mtx.lock();
        defer self.write_mtx.unlock();
        var buf: [12]u8 = undefined;
        hdr.encode(&buf);
        try self.underlying.writeAll(&buf);
    }

    fn writeFrame(self: *YamuxSession, hdr: YamuxHeader, body: []const u8) !void {
        self.write_mtx.lock();
        defer self.write_mtx.unlock();
        var buf: [12]u8 = undefined;
        hdr.encode(&buf);
        try self.underlying.writeAll(&buf);
        if (body.len > 0) try self.underlying.writeAll(body);
    }

    fn readExact(stream: *noise.NoiseStream, buffer: []u8) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = try stream.read(buffer[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }

    fn getOrCreateStream(self: *YamuxSession, id: u32, syn: bool) !?*Stream {
        // Returns null if a frame targeting an unknown stream without SYN
        // arrived (we should send a RST in that case).
        self.mtx.lock();
        defer self.mtx.unlock();
        if (self.streams.get(id)) |s| return s;
        if (!syn) return null;
        const s = try self.allocator.create(Stream);
        s.* = Stream.init(self.allocator, self, id, false);
        try self.streams.put(id, s);
        try self.accept_queue.append(self.allocator, s);
        self.accept_cond.signal();
        return s;
    }

    fn readerLoop(self: *YamuxSession) void {
        self.runReaderLoop() catch |e| {
            std.debug.print("[yamux] reader loop exited: {any}\n", .{e});
        };
        self.shutdown();
        // Wake any pending stream reads so they unblock.
        self.mtx.lock();
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            const s = entry.value_ptr.*;
            s.mtx.lock();
            s.reset_flag = true;
            s.mtx.unlock();
            s.recv_cond.broadcast();
            s.send_cond.broadcast();
        }
        self.mtx.unlock();
    }

    fn runReaderLoop(self: *YamuxSession) !void {
        while (true) {
            self.mtx.lock();
            const stop = self.shutdown_flag;
            self.mtx.unlock();
            if (stop) return;

            var hdr_buf: [12]u8 = undefined;
            try readExact(self.underlying, &hdr_buf);
            const hdr = try YamuxHeader.decode(&hdr_buf);

            switch (hdr.frame_type) {
                .Ping => {
                    if (hdr.flags.syn) {
                        try self.writeHeader(.{
                            .version = 0,
                            .frame_type = .Ping,
                            .flags = .{ .ack = true },
                            .stream_id = 0,
                            .length = hdr.length,
                        });
                    }
                },
                .GoAway => return, // bee asked us to disconnect

                .WindowUpdate, .Data => {
                    var body: [MAX_FRAME_PAYLOAD]u8 = undefined;
                    const body_len: usize = if (hdr.frame_type == .Data) hdr.length else 0;
                    if (body_len > body.len) return Error.PayloadTooLarge;
                    if (body_len > 0) try readExact(self.underlying, body[0..body_len]);

                    const stream_opt = try self.getOrCreateStream(hdr.stream_id, hdr.flags.syn);
                    const s = stream_opt orelse {
                        // Unknown stream + no SYN ⇒ send RST.
                        try self.writeHeader(.{
                            .version = 0,
                            .frame_type = .WindowUpdate,
                            .flags = .{ .rst = true },
                            .stream_id = hdr.stream_id,
                            .length = 0,
                        });
                        continue;
                    };

                    s.mtx.lock();
                    if (hdr.flags.rst) {
                        s.reset_flag = true;
                        s.mtx.unlock();
                        s.recv_cond.broadcast();
                        s.send_cond.broadcast();
                        continue;
                    }
                    if (hdr.frame_type == .WindowUpdate) {
                        // Peer granted us more send-window.
                        s.send_window +|= hdr.length;
                        s.mtx.unlock();
                        s.send_cond.broadcast();
                        continue;
                    }
                    // Data frame.
                    if (body_len > 0) {
                        s.recv.appendSlice(self.allocator, body[0..body_len]) catch |e| {
                            s.mtx.unlock();
                            return e;
                        };
                    }
                    if (hdr.flags.fin) s.remote_closed = true;
                    s.mtx.unlock();
                    s.recv_cond.broadcast();
                },
            }
        }
    }
};

// ---- tests ----

test "yamux header encode/decode" {
    const hdr = YamuxHeader{
        .version = 0,
        .frame_type = .Data,
        .flags = .{ .syn = true, .ack = false, .fin = false, .rst = false },
        .stream_id = 42,
        .length = 1024,
    };
    var buf: [12]u8 = undefined;
    hdr.encode(&buf);
    const decoded = try YamuxHeader.decode(&buf);
    try std.testing.expectEqual(hdr.version, decoded.version);
    try std.testing.expectEqual(hdr.frame_type, decoded.frame_type);
    try std.testing.expect(decoded.flags.syn);
    try std.testing.expect(!decoded.flags.ack);
    try std.testing.expectEqual(hdr.stream_id, decoded.stream_id);
    try std.testing.expectEqual(hdr.length, decoded.length);
}

test "yamux WindowUpdate header round-trip with non-zero length-as-delta" {
    const hdr = YamuxHeader{
        .version = 0,
        .frame_type = .WindowUpdate,
        .flags = .{ .ack = true },
        .stream_id = 7,
        .length = 256 * 1024,
    };
    var buf: [12]u8 = undefined;
    hdr.encode(&buf);
    const decoded = try YamuxHeader.decode(&buf);
    try std.testing.expectEqual(YamuxFrameType.WindowUpdate, decoded.frame_type);
    try std.testing.expectEqual(@as(u32, 256 * 1024), decoded.length);
}

test "yamux Ping header round-trip" {
    const hdr = YamuxHeader{
        .version = 0,
        .frame_type = .Ping,
        .flags = .{ .syn = true },
        .stream_id = 0,
        .length = 0xDEADBEEF,
    };
    var buf: [12]u8 = undefined;
    hdr.encode(&buf);
    const decoded = try YamuxHeader.decode(&buf);
    try std.testing.expectEqual(YamuxFrameType.Ping, decoded.frame_type);
    try std.testing.expect(decoded.flags.syn);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), decoded.length);
}
