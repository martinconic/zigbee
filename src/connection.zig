// A live, fully-handshaken connection to a bee peer.
//
// The lifecycle for outbound (initiator) connections:
//   1. dial() opens the TCP socket and runs the full upstream stack:
//      multistream-select → Noise XX → Yamux session → libp2p Identify
//      → bee `/swarm/handshake/14.0.0` → pricing announce. Returns a
//      heap-allocated *Connection.
//   2. startAcceptLoop() spawns a thread that drains peer-initiated
//      streams (libp2p Identify back, Ping, hive broadcasts, …) and
//      dispatches them to a caller-supplied handler.
//   3. openStream() lets the caller open new outbound streams on the
//      same Yamux session, e.g. for retrieval.
//   4. deinit() shuts everything down.
//
// We keep the Noise state and Yamux session on the heap because they
// hold pointers into each other and the Connection itself; moving them
// (e.g. by returning a Connection by value from dial) would invalidate
// those pointers.

const std = @import("std");
const net = std.net;

const identity = @import("identity.zig");
const noise = @import("noise.zig");
const yamux = @import("yamux.zig");
const multistream = @import("multistream.zig");
const identify = @import("identify.zig");
const bee_handshake = @import("bee_handshake.zig");
const pricing = @import("pricing.zig");
const peer_id = @import("peer_id.zig");
const bzz_address = @import("bzz_address.zig");

pub const Error = error{
    HandshakeFailed,
    PeerProtocolMismatch,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,

    // Underlying transport. tcp owns the fd; noise_stream is heap because
    // YamuxSession holds a stable pointer to it.
    tcp: net.Stream,
    noise_stream: *noise.NoiseStream,
    session: *yamux.YamuxSession,

    // Peer details. peer_ip/peer_port are what we dialed.
    peer_ip: [4]u8,
    peer_port: u16,
    peer_overlay: [bzz_address.OVERLAY_LEN]u8,
    peer_eth_address: [bzz_address.ETH_ADDR_LEN]u8,
    peer_full_node: bool,
    /// Welcome string from bee. Allocator-owned.
    peer_welcome_message: []u8,
    /// libp2p PublicKey type bee advertised (2=Secp256k1, 3=ECDSA).
    peer_libp2p_key_type: u64,

    accept_thread: ?std.Thread = null,
    shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Dials `ip:port`, runs the full upstream stack, returns a fully
    /// established Connection. Caller owns the result; call `deinit` to
    /// tear it down.
    pub fn dial(
        allocator: std.mem.Allocator,
        id: *const identity.Identity,
        network_id: u64,
        nonce: [bzz_address.NONCE_LEN]u8,
        ip: [4]u8,
        port: u16,
    ) !*Connection {
        const addr = net.Address.initIp4(ip, port);
        const tcp = try net.tcpConnectToAddress(addr);
        errdefer tcp.close();

        // 1. Outer multistream-select: negotiate /noise over raw TCP.
        try multistream.selectOne(tcp, "/noise");

        // 2. Noise XX handshake (initiator). NoiseExtensions tells bee we
        //    speak Yamux, which lets bee skip inner multistream-select for
        //    the muxer.
        var state = try noise.NoiseState.init();
        const ns_ptr = try allocator.create(noise.NoiseStream);
        errdefer allocator.destroy(ns_ptr);
        ns_ptr.* = try state.processHandshakeInitiator(tcp, id);

        // 3. Yamux session. Owns the noise stream pointer for its lifetime.
        const session = try yamux.YamuxSession.init(allocator, ns_ptr, true);
        errdefer session.deinit();
        try session.start();

        // 4. Identify (we open the stream, decode bee's response).
        const identify_stream = try session.open();
        var info = identify.request(allocator, identify_stream) catch |e| {
            identify_stream.close() catch {};
            return e;
        };
        defer info.deinit();
        identify_stream.close() catch {};

        if (!info.supports(bee_handshake.PROTOCOL_ID)) return Error.PeerProtocolMismatch;

        // 5. Bee bzz handshake — opens its own stream.
        var our_underlay_buf: [128]u8 = undefined;
        const our_underlay = try peer_id.buildIp4TcpP2pMultiaddr(
            &our_underlay_buf,
            id,
            .{ 0, 0, 0, 0 },
            0,
        );
        const underlays = [_][]const u8{our_underlay};

        // Build observed_underlay (peer's address with peer's PeerID derived
        // from its libp2p key — bee verifies this in its `Handshake` for
        // outbound flows).
        const peer_key = ns_ptr.peerLibp2pKeyData();
        if (peer_key.len == 0) return Error.HandshakeFailed;
        var peer_pid_buf: [128]u8 = undefined;
        const peer_pid = try peer_id.peerIdFromLibp2pKey(&peer_pid_buf, ns_ptr.peer_libp2p_key_type, peer_key);
        var observed_buf: [256]u8 = undefined;
        const observed = try peer_id.buildIp4TcpP2pMultiaddrFromPeerId(&observed_buf, ip, port, peer_pid);

        const hs_stream = try session.open();
        try multistream.selectOne(hs_stream, bee_handshake.PROTOCOL_ID);
        const hs_info = bee_handshake.initiate(
            allocator,
            hs_stream,
            id,
            .{
                .network_id = network_id,
                .full_node = false,
                .nonce = nonce,
                .underlays = &underlays,
            },
            observed,
        ) catch |e| {
            hs_stream.close() catch {};
            return e;
        };
        // Copy welcome before tearing down hs_info.
        const welcome = try allocator.dupe(u8, hs_info.welcome_message);
        errdefer allocator.free(welcome);
        const peer_overlay = hs_info.overlay;
        const peer_eth = hs_info.eth_address;
        const peer_full = hs_info.full_node;
        var hs_info_mut = hs_info;
        hs_info_mut.deinit();
        hs_stream.close() catch {};

        // 6. Allow bee's per-peer state to settle, then announce our
        //    payment threshold so bee's accounting can credit our
        //    retrieval requests. See README "known issues" — this is
        //    a race window with bee's ConnectIn loop.
        std.Thread.sleep(2 * std.time.ns_per_s);
        announceThreshold(allocator, session) catch |e| {
            std.debug.print("[connection] threshold announce failed: {any}\n", .{e});
        };

        const conn = try allocator.create(Connection);
        conn.* = .{
            .allocator = allocator,
            .tcp = tcp,
            .noise_stream = ns_ptr,
            .session = session,
            .peer_ip = ip,
            .peer_port = port,
            .peer_overlay = peer_overlay,
            .peer_eth_address = peer_eth,
            .peer_full_node = peer_full,
            .peer_welcome_message = welcome,
            .peer_libp2p_key_type = ns_ptr.peer_libp2p_key_type,
        };
        return conn;
    }

    pub fn deinit(self: *Connection) void {
        self.shutdown_flag.store(true, .release);
        // session.deinit shuts down its reader thread; that may take a
        // moment if it's blocked on the underlying TCP read.
        // Closing the TCP first wakes it.
        self.tcp.close();
        if (self.accept_thread) |t| t.join();
        self.session.deinit();
        self.allocator.destroy(self.noise_stream);
        self.allocator.free(self.peer_welcome_message);
        self.allocator.destroy(self);
    }

    pub const StreamHandler = *const fn (ctx: *anyopaque, conn: *Connection, stream: *yamux.Stream) void;

    /// Spawns the accept loop in a thread. It keeps draining
    /// peer-initiated streams and calls `handler(ctx, self, stream)` for
    /// each one. The handler owns the stream (must close/reset it).
    pub fn startAcceptLoop(self: *Connection, ctx: *anyopaque, handler: StreamHandler) !void {
        self.accept_thread = try std.Thread.spawn(
            .{},
            runAcceptLoop,
            .{ self, ctx, handler },
        );
    }

    fn runAcceptLoop(self: *Connection, ctx: *anyopaque, handler: StreamHandler) void {
        while (!self.shutdown_flag.load(.acquire)) {
            const stream = self.session.accept() catch |e| {
                if (!self.shutdown_flag.load(.acquire)) {
                    std.debug.print("[conn {x}…] accept ended: {any}\n", .{
                        self.peer_overlay[0..4].*, e,
                    });
                }
                return;
            };
            handler(ctx, self, stream);
        }
    }

    /// Open a new outbound stream on this connection's Yamux session.
    pub fn openStream(self: *Connection) !*yamux.Stream {
        return self.session.open();
    }
};

fn announceThreshold(
    allocator: std.mem.Allocator,
    session: *yamux.YamuxSession,
) !void {
    const stream = try session.open();
    defer stream.close() catch {};
    try multistream.selectOne(stream, pricing.PROTOCOL_ID);
    // 13_500_000 = 0xCDFE60 — bee's full-node default. Anything below
    // 9_000_000 (= 2*refreshRate) is rejected with "threshold too low".
    const threshold_be = [_]u8{ 0xCD, 0xFE, 0x60 };
    try pricing.announce(allocator, stream, &threshold_be);
}
