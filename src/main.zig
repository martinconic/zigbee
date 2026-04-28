const std = @import("std");
const crypto = @import("crypto.zig");
const bmt = @import("bmt.zig");
const identity = @import("identity.zig");
const p2p = @import("p2p.zig");
const dnsaddr = @import("dnsaddr.zig");

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
        } else if (std.mem.eql(u8, arg, "--max-peers")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.max_peers = try std.fmt.parseInt(usize, argv[i], 10);
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

    std.debug.print("Generating Node Identity...\n", .{});
    const id = try identity.Identity.generate();

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

    var node = try p2p.P2PNode.init(allocator, id, args.network_id);
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
    _ = @import("joiner.zig");
    _ = @import("mantaray.zig");
    _ = @import("connection.zig");
    _ = @import("proto.zig");
    _ = @import("yamux.zig");
}
