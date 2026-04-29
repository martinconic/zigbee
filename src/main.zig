const std = @import("std");
const crypto = @import("crypto.zig");
const bmt = @import("bmt.zig");
const identity = @import("identity.zig");
const p2p = @import("p2p.zig");
const dnsaddr = @import("dnsaddr.zig");
const store_mod = @import("store.zig");

/// Default local-store cap. 100 MiB ≈ 25 000 chunks at 4 KiB each;
/// fits a Pi Zero comfortably and is tunable down for ESP32-class
/// devices (cross-cutting item X1 in `docs/iot-roadmap.html`).
const DEFAULT_STORE_MAX_BYTES: u64 = 100 * 1024 * 1024;

// CLI usage:
//
//   zigbee [GLOBAL FLAGS] [SUBCOMMAND ...]
//
//   global flags:
//     --peer ip:port         peer to dial (default 127.0.0.1:1634)
//     --network-id N         Swarm network id (default 10 for Sepolia testnet;
//                            mainnet is 1)
//
//   subcommands:
//     (none)                 dial the peer, complete handshake, stay in
//                            accept loop
//     resolve <hostname>     /dnsaddr lookup, then exit
//     retrieve <hex> [-o f]  retrieve one chunk by content address, then exit
//
// Examples:
//   zigbee
//   zigbee --peer 167.235.96.31:32491 retrieve <hex-addr> -o chunk.bin
//   zigbee --network-id 1 --peer 1.2.3.4:1634 retrieve <hex-addr>
//   zigbee resolve sepolia.testnet.ethswarm.org

const Args = struct {
    peer_ip: []const u8 = "127.0.0.1",
    peer_port: u16 = 1634,
    network_id: u64 = 10,
    subcommand: enum { none, resolve, retrieve, daemon } = .none,
    /// For `resolve`: the hostname.
    /// For `retrieve`: the 64-char hex chunk address.
    positional: []const u8 = "",
    out_path: ?[]const u8 = null,
    api_port: u16 = 9090,
    max_peers: usize = 4,
    /// Path to the persistent libp2p identity key. Default is computed
    /// at runtime from $HOME (see `identity.defaultIdentityPath`); the
    /// magic value `:ephemeral:` means "don't persist; generate fresh
    /// each run" (the pre-0.4.1 behaviour, useful for testing).
    identity_file: ?[]const u8 = null,
    /// Path to the local chunk-store directory (0.5a). null → default
    /// `$HOME/.zigbee/store/`.
    store_path: ?[]const u8 = null,
    /// Cap on the local chunk store, in bytes (0.5a).
    store_max_bytes: u64 = DEFAULT_STORE_MAX_BYTES,
    /// Disable the local chunk store entirely (0.5a).
    no_store: bool = false,
};

fn parseArgs(argv: []const []const u8) !Args {
    var a = Args{};
    var i: usize = 1;
    var positional_idx: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--peer")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            const peer_str = argv[i];
            const colon = std.mem.indexOfScalar(u8, peer_str, ':') orelse return error.InvalidPeer;
            a.peer_ip = peer_str[0..colon];
            a.peer_port = try std.fmt.parseInt(u16, peer_str[colon + 1 ..], 10);
        } else if (std.mem.eql(u8, arg, "--network-id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.network_id = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.out_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--api-port")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.api_port = try std.fmt.parseInt(u16, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--identity-file")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.identity_file = argv[i];
        } else if (std.mem.eql(u8, arg, "--max-peers")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.max_peers = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--store-path")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.store_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--store-max-bytes")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.store_max_bytes = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--no-store")) {
            a.no_store = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (positional_idx == 0) {
            // First positional is the subcommand.
            if (std.mem.eql(u8, arg, "resolve")) {
                a.subcommand = .resolve;
            } else if (std.mem.eql(u8, arg, "retrieve")) {
                a.subcommand = .retrieve;
            } else if (std.mem.eql(u8, arg, "daemon")) {
                a.subcommand = .daemon;
            } else {
                std.debug.print("unknown subcommand: {s}\n", .{arg});
                return error.UnknownSubcommand;
            }
            positional_idx += 1;
        } else if (positional_idx == 1) {
            a.positional = arg;
            positional_idx += 1;
        } else {
            std.debug.print("unexpected positional argument: {s}\n", .{arg});
            return error.TooManyArguments;
        }
    }
    return a;
}

fn printHelp() void {
    std.debug.print(
        \\zigbee — pure-Zig Swarm Bee client
        \\
        \\usage: zigbee [GLOBAL FLAGS] [SUBCOMMAND ...]
        \\
        \\global flags:
        \\  --peer ip:port      peer to dial (default 127.0.0.1:1634)
        \\  --network-id N      Swarm network id (default 10 = Sepolia testnet,
        \\                      mainnet = 1)
        \\  --identity-file P   path to persistent libp2p identity key
        \\                      (default $HOME/.zigbee/identity.key).
        \\                      File is created on first run and reused
        \\                      on every subsequent run — bee's per-peer
        \\                      accounting state survives restarts.
        \\                      Mode follows your umask; for strict 0600
        \\                      use umask 0077 or chmod after first run.
        \\                      Pass ":ephemeral:" to generate fresh
        \\                      each run (the pre-0.4.1 behaviour, for
        \\                      tests).
        \\  --store-path P      path to the local chunk-store directory
        \\                      (default $HOME/.zigbee/store/). Files
        \\                      are <root>/<2-hex-prefix>/<64-hex-addr>
        \\                      with `span(8 LE) ‖ payload` payload —
        \\                      same shape bee returns from /chunks/<addr>.
        \\  --store-max-bytes N cap the local store at N bytes (default
        \\                      100 MiB). Eviction is LRU. Bumping a hit
        \\                      to MRU happens on every successful get.
        \\  --no-store          disable the local chunk store entirely;
        \\                      every retrieval hits the network.
        \\
        \\subcommands:
        \\  (none)              dial the peer, do the handshake, stay connected
        \\  resolve <host>      /dnsaddr lookup, then exit
        \\  retrieve <hex> [-o file]
        \\                      retrieve one chunk by content address, then exit
        \\  daemon [--max-peers N] [--api-port P]
        \\                      dial --peer as a bootnode, auto-connect to up to
        \\                      N peers via hive (default 4), and serve a small
        \\                      HTTP API on 127.0.0.1:P (default 9090):
        \\                        GET /retrieve/<hex>   — retrieve a chunk
        \\                        GET /peers            — connected-peer JSON
        \\
        \\examples:
        \\  zigbee --peer 167.235.96.31:32491 --network-id 10 retrieve <hex> -o out.bin
        \\  zigbee --peer 167.235.96.31:32491 --network-id 10 daemon --max-peers 6
        \\  curl -o file.bin http://127.0.0.1:9090/retrieve/<hex>
        \\  zigbee resolve sepolia.testnet.ethswarm.org
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const args = parseArgs(argv) catch |e| switch (e) {
        error.HelpRequested => {
            printHelp();
            return;
        },
        else => |err| {
            printHelp();
            return err;
        },
    };

    // `resolve` is purely local — no network setup needed.
    if (args.subcommand == .resolve) {
        if (args.positional.len == 0) {
            std.debug.print("resolve: missing <hostname>\n", .{});
            return error.MissingArgument;
        }
        var resolved = try dnsaddr.resolve(allocator, args.positional);
        defer resolved.deinit();
        std.debug.print("resolved {d} multiaddrs for {s}:\n", .{ resolved.items.len, args.positional });
        for (resolved.items) |ma| std.debug.print("  {s}\n", .{ma});
        return;
    }

    std.debug.print("Initializing ZigBee Node...\n", .{});

    const sample = "Swarm Bee Client in Zig";
    var hash: [32]u8 = undefined;
    crypto.keccak256(sample, &hash);
    std.debug.print("Keccak256(\"{s}\"): {s}\n", .{ sample, std.fmt.bytesToHex(hash, .lower) });

    const sample_chunk = bmt.Chunk.init(sample);
    var sample_chunk_hash: [32]u8 = undefined;
    try sample_chunk.address(&sample_chunk_hash);
    std.debug.print("Chunk Hash: {s}\n", .{std.fmt.bytesToHex(sample_chunk_hash, .lower)});

    // Identity + bzz overlay nonce: persistent by default (0.4.1+) —
    // load from disk if the file exists, otherwise generate a fresh
    // pair and persist atomically. The file is 64 bytes: 32-byte
    // libp2p secp256k1 key + 32-byte bzz overlay nonce. Both must
    // persist together — without the nonce, the overlay changes on
    // every restart even with the same libp2p key, and bee's
    // per-peer accounting (keyed on overlay) resets.
    //
    // `--identity-file :ephemeral:` generates fresh values each run
    // (the pre-0.4.1 behaviour, useful for tests).
    var nonce: [32]u8 = undefined;
    const id = try resolveIdentity(allocator, args.identity_file, &nonce);

    // Local chunk store (0.5a). Opened before P2PNode.init so a
    // failure here (permission denied, disk full, corrupted index)
    // surfaces before we waste a TCP handshake.
    const store_ptr: ?*store_mod.Store = blk: {
        if (args.no_store) {
            std.debug.print("[store] --no-store: caching disabled\n", .{});
            break :blk null;
        }
        const path = if (args.store_path) |p|
            try allocator.dupe(u8, p)
        else
            try store_mod.defaultStorePath(allocator);
        defer allocator.free(path);

        std.debug.print("[store] root={s} max_bytes={d}\n", .{ path, args.store_max_bytes });
        break :blk try store_mod.Store.openOrCreate(allocator, path, args.store_max_bytes);
    };

    var action: p2p.PostHandshakeAction = .none;
    if (args.subcommand == .retrieve) {
        if (args.positional.len != 64) {
            std.debug.print("retrieve: expected 64-char hex address, got {d} chars\n", .{args.positional.len});
            return error.InvalidArgument;
        }
        var addr_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&addr_bytes, args.positional);
        action = .{ .retrieve = .{ .address = addr_bytes, .out_path = args.out_path } };
    }

    var node = try p2p.P2PNode.init(allocator, id, args.network_id, nonce, store_ptr);
    defer node.deinit();

    std.debug.print("Node Overlay Address: {s}\n", .{std.fmt.bytesToHex(node.overlay, .lower)});

    if (args.subcommand == .daemon) {
        try node.daemonRun(.{
            .bootnode_ip = args.peer_ip,
            .bootnode_port = args.peer_port,
            .max_peers = args.max_peers,
            .api_port = args.api_port,
        });
        return;
    }

    try node.dial(args.peer_ip, args.peer_port, action);
}

/// Resolve identity + bzz overlay nonce according to `--identity-file`:
///   * null              → default `$HOME/.zigbee/identity.key`, persistent.
///   * `:ephemeral:`     → no persistence; fresh keypair AND fresh
///                          nonce each run (the pre-0.4.1 behaviour,
///                          useful for tests that want a clean libp2p
///                          identity + fresh bee-side debt counter).
///   * any other string  → use that exact path; persist there.
///
/// The `nonce_out` parameter is filled with the 32-byte bzz overlay
/// nonce — either loaded from disk or freshly randomised.
fn resolveIdentity(
    allocator: std.mem.Allocator,
    override: ?[]const u8,
    nonce_out: *[32]u8,
) !identity.Identity {
    if (override) |p| {
        if (std.mem.eql(u8, p, ":ephemeral:")) {
            std.debug.print("[identity] ephemeral mode — generating fresh keypair + nonce (no persistence)\n", .{});
            std.crypto.random.bytes(nonce_out);
            return try identity.Identity.generate();
        }
        std.debug.print("[identity] using key file: {s}\n", .{p});
        return try identity.Identity.loadOrCreate(allocator, p, nonce_out);
    }
    const default_path = try identity.defaultIdentityPath(allocator);
    defer allocator.free(default_path);
    std.debug.print("[identity] using default key file: {s}\n", .{default_path});
    return try identity.Identity.loadOrCreate(allocator, default_path, nonce_out);
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}

test "parseArgs: defaults" {
    const argv = [_][]const u8{"zigbee"};
    const a = try parseArgs(&argv);
    try std.testing.expectEqualStrings("127.0.0.1", a.peer_ip);
    try std.testing.expectEqual(@as(u16, 1634), a.peer_port);
    try std.testing.expectEqual(@as(u64, 10), a.network_id);
    try std.testing.expectEqual(@as(@TypeOf(a.subcommand), .none), a.subcommand);
}

test "parseArgs: --peer + --network-id + retrieve" {
    const argv = [_][]const u8{
        "zigbee",
        "--peer",          "1.2.3.4:5678",
        "--network-id",    "1",
        "retrieve",        "abc123",
        "-o",              "out.bin",
    };
    const a = try parseArgs(&argv);
    try std.testing.expectEqualStrings("1.2.3.4", a.peer_ip);
    try std.testing.expectEqual(@as(u16, 5678), a.peer_port);
    try std.testing.expectEqual(@as(u64, 1), a.network_id);
    try std.testing.expectEqual(@as(@TypeOf(a.subcommand), .retrieve), a.subcommand);
    try std.testing.expectEqualStrings("abc123", a.positional);
    try std.testing.expectEqualStrings("out.bin", a.out_path.?);
}

test "parseArgs: rejects unknown subcommand" {
    const argv = [_][]const u8{ "zigbee", "wat" };
    try std.testing.expectError(error.UnknownSubcommand, parseArgs(&argv));
}

test {
    _ = @import("crypto.zig");
    _ = @import("bmt.zig");
    _ = @import("identity.zig");
    _ = @import("p2p.zig");
    _ = @import("noise.zig");
    _ = @import("noise_kat.zig");
    _ = @import("libp2p_key.zig");
    _ = @import("multistream.zig");
    _ = @import("identify.zig");
    _ = @import("ping.zig");
    _ = @import("multiaddr.zig");
    _ = @import("dnsaddr.zig");
    _ = @import("peer_id.zig");
    _ = @import("bee_handshake.zig");
    _ = @import("pricing.zig");
    _ = @import("hive.zig");
    _ = @import("swarm_proto.zig");
    _ = @import("bzz_address.zig");
    _ = @import("peer_table.zig");
    _ = @import("retrieval.zig");
    _ = @import("soc.zig");
    _ = @import("joiner.zig");
    _ = @import("mantaray.zig");
    _ = @import("connection.zig");
    _ = @import("proto.zig");
    _ = @import("yamux.zig");
    _ = @import("store.zig");
}
