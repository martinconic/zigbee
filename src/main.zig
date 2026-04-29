const std = @import("std");
const crypto = @import("crypto.zig");
const bmt = @import("bmt.zig");
const identity = @import("identity.zig");
const p2p = @import("p2p.zig");
const dnsaddr = @import("dnsaddr.zig");
const multiaddr_mod = @import("multiaddr.zig");
const store_mod = @import("store.zig");
const encryption = @import("encryption.zig");
const credential_mod = @import("credential.zig");
const accounting_mod = @import("accounting.zig");
const bzz_address = @import("bzz_address.zig");

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
//     retrieve <hex> [-o f]  retrieve one chunk by content address, then exit.
//                            <hex> is 64 chars (unencrypted CAC) or 128 chars
//                            (encrypted: 32-byte addr ‖ 32-byte symmetric key,
//                            as produced by bee uploads with
//                            `Swarm-Encrypt: true`). For encrypted refs the
//                            chunk is decrypted before being written/printed.
//
// Examples:
//   zigbee
//   zigbee --peer 167.235.96.31:32491 retrieve <hex-addr> -o chunk.bin
//   zigbee --network-id 1 --peer 1.2.3.4:1634 retrieve <hex-addr>
//   zigbee --peer 1.2.3.4:1634 retrieve <128-hex-encrypted-ref> -o file.bin
//   zigbee resolve sepolia.testnet.ethswarm.org

const Args = struct {
    peer_ip: []const u8 = "127.0.0.1",
    peer_port: u16 = 1634,
    /// Whether `--peer` was explicitly passed (vs. left as default).
    /// Used to enforce mutual exclusion with `--bootnode`.
    peer_explicit: bool = false,
    /// Raw `--bootnode` value: either `/dnsaddr/<host>` or
    /// `/ip4/<x>/tcp/<y>[/p2p/...]`. Resolved into a candidate list
    /// before daemon launch. null = use --peer.
    bootnode_arg: ?[]const u8 = null,
    network_id: u64 = 10,
    subcommand: enum { none, resolve, retrieve, daemon, identity } = .none,
    /// For `resolve`: the hostname.
    /// For `retrieve`: the chunk reference, hex-encoded — either 64 chars
    /// (unencrypted CAC: 32-byte address) or 128 chars (encrypted: 32-byte
    /// address ‖ 32-byte symmetric key).
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
    /// Path to the chequebook credential JSON (0.5c). When set, zigbee
    /// signs and emits SWAP cheques to peers it owes BZZ to. When unset,
    /// per-peer accounting still tracks debt but never issues — the
    /// disconnect-threshold ceiling stays in place.
    chequebook_path: ?[]const u8 = null,
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
            a.peer_explicit = true;
        } else if (std.mem.eql(u8, arg, "--bootnode")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.bootnode_arg = argv[i];
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
        } else if (std.mem.eql(u8, arg, "--chequebook")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.chequebook_path = argv[i];
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
            } else if (std.mem.eql(u8, arg, "identity")) {
                a.subcommand = .identity;
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
    if (a.peer_explicit and a.bootnode_arg != null) {
        std.debug.print("--peer and --bootnode are mutually exclusive; pick one.\n", .{});
        return error.ConflictingPeerFlags;
    }
    return a;
}

/// One bootstrap target: an IPv4 string + TCP port. The strings are owned
/// by the parent BootnodeCandidates arena.
pub const BootnodeCandidate = struct {
    ip: []const u8,
    port: u16,
};

/// Owned list of (ip, port) bootnode candidates resolved from a
/// `--bootnode` argument. Memory is single-arena; deinit drops everything.
pub const BootnodeCandidates = struct {
    items: []const BootnodeCandidate,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *BootnodeCandidates) void {
        self.arena.deinit();
    }
};

/// Walk a parsed multiaddr looking for an /ip4/<x>/tcp/<y> pair. On
/// success returns the four IP bytes and the u16 port. On failure
/// (no ip4, or no tcp, or malformed) returns null — caller skips
/// this multiaddr and tries the next.
fn extractIp4Tcp(ma: multiaddr_mod.Multiaddr) ?struct { ip: [4]u8, port: u16 } {
    var ip: ?[4]u8 = null;
    var port: ?u16 = null;
    var it = ma.iterator();
    while (true) {
        const next = it.next() catch return null;
        const comp = next orelse break;
        switch (comp.code) {
            .ip4 => {
                if (comp.value.len != 4) return null;
                ip = .{ comp.value[0], comp.value[1], comp.value[2], comp.value[3] };
            },
            .tcp => {
                if (comp.value.len != 2) return null;
                port = std.mem.readInt(u16, comp.value[0..2], .big);
            },
            else => {}, // skip /p2p/, /udp/, etc.
        }
    }
    if (ip == null or port == null) return null;
    return .{ .ip = ip.?, .port = port.? };
}

/// Parse a `--bootnode` value into a list of candidates. Accepts:
///   - `/dnsaddr/<host>`        — TXT-resolve, parse each result
///   - `/ip4/<x>/tcp/<y>...`    — single literal multiaddr
/// Anything else returns error.UnsupportedBootnodeForm. /dnsaddr
/// resolution may itself yield further /dnsaddr layers; the
/// resolver recurses up to dnsaddr.MAX_RESOLVE_DEPTH.
pub fn resolveBootnodeCandidates(
    parent_allocator: std.mem.Allocator,
    bootnode_arg: []const u8,
) !BootnodeCandidates {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList(BootnodeCandidate) = .{};

    if (std.mem.startsWith(u8, bootnode_arg, "/dnsaddr/")) {
        const host = bootnode_arg["/dnsaddr/".len..];
        if (host.len == 0) return error.InvalidBootnode;

        var resolved = try dnsaddr.resolve(parent_allocator, host);
        defer resolved.deinit();

        for (resolved.items) |text| {
            // Each entry is a textual multiaddr. Parse and extract.
            var ma = multiaddr_mod.Multiaddr.fromText(parent_allocator, text) catch continue;
            defer ma.deinit();
            const ipport = extractIp4Tcp(ma) orelse continue;
            const ip_str = try std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}", .{
                ipport.ip[0], ipport.ip[1], ipport.ip[2], ipport.ip[3],
            });
            try out.append(a, .{ .ip = ip_str, .port = ipport.port });
        }
    } else if (std.mem.startsWith(u8, bootnode_arg, "/ip4/")) {
        var ma = try multiaddr_mod.Multiaddr.fromText(parent_allocator, bootnode_arg);
        defer ma.deinit();
        const ipport = extractIp4Tcp(ma) orelse return error.InvalidBootnode;
        const ip_str = try std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}", .{
            ipport.ip[0], ipport.ip[1], ipport.ip[2], ipport.ip[3],
        });
        try out.append(a, .{ .ip = ip_str, .port = ipport.port });
    } else {
        return error.UnsupportedBootnodeForm;
    }

    if (out.items.len == 0) return error.NoBootnodeCandidates;

    return BootnodeCandidates{
        .items = try out.toOwnedSlice(a),
        .arena = arena,
    };
}

fn printHelp() void {
    std.debug.print(
        \\zigbee — pure-Zig Swarm Bee client
        \\
        \\usage: zigbee [GLOBAL FLAGS] [SUBCOMMAND ...]
        \\
        \\global flags:
        \\  --peer ip:port      peer to dial (default 127.0.0.1:1634).
        \\                      Use this for a known fixed peer (e.g. a
        \\                      local bee on 127.0.0.1:1634). Mutually
        \\                      exclusive with --bootnode.
        \\  --bootnode MA       bootnode multiaddr; one of:
        \\                        /dnsaddr/<host>           DNS-resolved
        \\                        /ip4/<x>/tcp/<y>[/p2p/<id>]
        \\                      For /dnsaddr/ zigbee resolves the TXT
        \\                      records and tries each candidate in
        \\                      turn until one connects (the others
        \\                      stay in the table for hive). Use this
        \\                      when you want bootstrap fan-out — e.g.
        \\                      --bootnode /dnsaddr/sepolia.testnet.ethswarm.org.
        \\                      Mutually exclusive with --peer.
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
        \\  --chequebook P      path to a chequebook credential JSON file:
        \\                      {{ "contract": "0x..", "owner_private_key":
        \\                      "0x..", "chain_id": <int> }}. When set,
        \\                      zigbee signs SWAP cheques and emits them
        \\                      to peers we owe BZZ to (~every 20 chunks).
        \\                      Without it, accounting still tracks debt
        \\                      but never issues — bee's per-peer
        \\                      disconnect threshold (~25–30 chunks) stays
        \\                      the ceiling.
        \\
        \\subcommands:
        \\  (none)              dial the peer, do the handshake, stay connected
        \\  resolve <host>      /dnsaddr lookup, then exit
        \\  identity            print this node's eth_address, overlay,
        \\                      and network_id, then exit. Use the
        \\                      eth_address to deploy a chequebook
        \\                      contract owned by this zigbee instance
        \\                      (factory.deploySimpleSwap(eth_address, ...))
        \\                      so bee accepts cheques from us.
        \\  retrieve <hex> [-o file]
        \\                      retrieve one chunk by content address, then exit.
        \\                      <hex> is 64 chars (unencrypted) or 128 chars
        \\                      (encrypted ref = 32-byte addr ‖ 32-byte key,
        \\                      as bee returns when Swarm-Encrypt: true).
        \\  daemon [--max-peers N] [--api-port P]
        \\                      dial --peer as a bootnode, auto-connect to up to
        \\                      N peers via hive (default 4), and serve a small
        \\                      HTTP API on 127.0.0.1:P (default 9090):
        \\                        GET /retrieve/<hex>   — retrieve a chunk
        \\                                                (64-hex or 128-hex)
        \\                        GET /bytes/<hex>      — chunk-tree → raw bytes
        \\                        GET /bzz/<hex>/<path> — manifest lookup
        \\                        GET /peers            — connected-peer JSON
        \\
        \\examples:
        \\  zigbee --peer 167.235.96.31:32491 --network-id 10 retrieve <hex> -o out.bin
        \\  zigbee --peer 167.235.96.31:32491 --network-id 10 daemon --max-peers 6
        \\  curl -o file.bin http://127.0.0.1:9090/retrieve/<hex>
        \\  curl -o file.bin http://127.0.0.1:9090/bytes/<128-hex-encrypted-ref>
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

    // `identity` is purely local — load the persistent key, print all the
    // addresses derived from it (eth, overlay, peer-id), exit. Useful when
    // you need the eth address to deploy a chequebook contract owned by
    // this zigbee instance (0.5c-e). Data lines (`key=value`) go to stdout
    // so shell scripts can `eval` or pipe; status messages stay on stderr.
    if (args.subcommand == .identity) {
        var nonce_local: [bzz_address.NONCE_LEN]u8 = undefined;
        const id_local = try resolveIdentity(allocator, args.identity_file, &nonce_local);

        var eth_addr: [identity.ETHEREUM_ADDRESS_SIZE]u8 = undefined;
        id_local.ethereumAddress(&eth_addr);

        var overlay_local: [bzz_address.OVERLAY_LEN]u8 = undefined;
        id_local.overlayAddress(args.network_id, nonce_local, &overlay_local);

        var out_buf: [128]u8 = undefined;
        var stdout = std.fs.File.stdout().writer(&out_buf);
        try stdout.interface.print("eth_address=0x{s}\n", .{std.fmt.bytesToHex(eth_addr, .lower)});
        try stdout.interface.print("overlay=0x{s}\n", .{std.fmt.bytesToHex(overlay_local, .lower)});
        try stdout.interface.print("network_id={d}\n", .{args.network_id});
        try stdout.interface.flush();
        return;
    }

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
        // Accept either 64 chars (unencrypted CAC: 32-byte address) or
        // 128 chars (encrypted: 32-byte address ‖ 32-byte symmetric key,
        // produced by bee uploads with `Swarm-Encrypt: true`).
        if (args.positional.len != 64 and args.positional.len != 128) {
            std.debug.print(
                "retrieve: expected 64-char (unencrypted) or 128-char (encrypted) hex reference, got {d} chars\n",
                .{args.positional.len},
            );
            return error.InvalidArgument;
        }
        var addr_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&addr_bytes, args.positional[0..64]);
        var key_opt: ?[encryption.KEY_LEN]u8 = null;
        if (args.positional.len == 128) {
            var key_bytes: [encryption.KEY_LEN]u8 = undefined;
            _ = try std.fmt.hexToBytes(&key_bytes, args.positional[64..128]);
            key_opt = key_bytes;
        }
        action = .{ .retrieve = .{
            .address = addr_bytes,
            .key = key_opt,
            .out_path = args.out_path,
        } };
    }

    // SWAP accounting (0.5c).
    //
    // Persistence is bound to the chequebook (B2): cumulativePayout is
    // logically per-(chequebook, peer), so the state file lives next to
    // the chequebook credential — `chequebook.json` →
    // `chequebook.state.json`. When no `--chequebook` is set, accounting
    // runs in ephemeral mode (chunk counters in memory, no persistence).
    // Adding `--chequebook` later is still a one-line toggle: chunk
    // counters reset (in-memory only), persistence kicks in on first
    // cheque issued.
    const accounting_state_path: ?[]u8 = if (args.chequebook_path) |p|
        try accounting_mod.deriveStatePath(allocator, p)
    else
        null;
    defer if (accounting_state_path) |p| allocator.free(p);
    const accounting_ptr = try accounting_mod.Accounting.openOrCreate(allocator, accounting_state_path);

    // Load chequebook credential if --chequebook was passed. The credential
    // is small + immutable for the run; we capture it by value.
    const chequebook_opt: ?credential_mod.ChequebookCredential = if (args.chequebook_path) |p| blk: {
        std.debug.print("[swap] loading chequebook credential from {s}\n", .{p});
        const cred = try credential_mod.load(allocator, p);
        std.debug.print(
            "[swap] chequebook contract=0x{s} chain_id={d}\n",
            .{ std.fmt.bytesToHex(cred.contract, .lower), cred.chain_id },
        );
        if (accounting_state_path) |sp| {
            std.debug.print("[swap] cumulative-payout state file: {s}\n", .{sp});
        }
        break :blk cred;
    } else blk: {
        std.debug.print("[swap] no --chequebook; accounting tracks but does not issue cheques\n", .{});
        break :blk null;
    };

    var node = try p2p.P2PNode.init(
        allocator,
        id,
        args.network_id,
        nonce,
        store_ptr,
        accounting_ptr,
        chequebook_opt,
    );
    defer node.deinit();

    std.debug.print("Node Overlay Address: {s}\n", .{std.fmt.bytesToHex(node.overlay, .lower)});

    // Build the list of bootstrap candidates from --peer or --bootnode.
    // Default (neither flag set) is the legacy 127.0.0.1:1634 single
    // candidate, so existing invocations keep working unchanged.
    var bootnode_candidates_opt: ?BootnodeCandidates = null;
    defer if (bootnode_candidates_opt) |*bc| bc.deinit();

    const single_candidate = [_]p2p.P2PNode.BootnodeCandidate{.{ .ip = args.peer_ip, .port = args.peer_port }};
    const candidates_slice: []const p2p.P2PNode.BootnodeCandidate = single_candidate[0..];

    if (args.bootnode_arg) |raw| {
        bootnode_candidates_opt = resolveBootnodeCandidates(allocator, raw) catch |e| {
            std.debug.print("[bootnode] failed to resolve {s}: {any}\n", .{ raw, e });
            return e;
        };
        const list = bootnode_candidates_opt.?.items;
        // Re-pack into the p2p type. Same shape, different namespace.
        const p2p_list = try allocator.alloc(p2p.P2PNode.BootnodeCandidate, list.len);
        defer allocator.free(p2p_list);
        for (list, 0..) |c, i| p2p_list[i] = .{ .ip = c.ip, .port = c.port };
        std.debug.print("[bootnode] resolved {d} candidate(s) from {s}\n", .{ list.len, raw });
        for (list, 0..) |c, i| std.debug.print("  {d}. {s}:{d}\n", .{ i + 1, c.ip, c.port });

        if (args.subcommand == .daemon) {
            try node.daemonRun(.{
                .bootnodes = p2p_list,
                .max_peers = args.max_peers,
                .api_port = args.api_port,
            });
            return;
        }
        // Non-daemon: just use the first candidate for the one-shot dial.
        try node.dial(p2p_list[0].ip, p2p_list[0].port, action);
        return;
    }

    if (args.subcommand == .daemon) {
        try node.daemonRun(.{
            .bootnodes = candidates_slice,
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

test "parseArgs: --bootnode parses /dnsaddr/" {
    const argv = [_][]const u8{
        "zigbee", "--bootnode", "/dnsaddr/sepolia.testnet.ethswarm.org", "daemon",
    };
    const a = try parseArgs(&argv);
    try std.testing.expectEqualStrings("/dnsaddr/sepolia.testnet.ethswarm.org", a.bootnode_arg.?);
    try std.testing.expect(!a.peer_explicit);
}

test "parseArgs: --peer + --bootnode is rejected" {
    const argv = [_][]const u8{
        "zigbee", "--peer", "1.2.3.4:1634", "--bootnode", "/dnsaddr/example.org", "daemon",
    };
    try std.testing.expectError(error.ConflictingPeerFlags, parseArgs(&argv));
}

test "resolveBootnodeCandidates: literal /ip4/.../tcp/..." {
    const allocator = std.testing.allocator;
    var c = try resolveBootnodeCandidates(allocator, "/ip4/167.235.96.31/tcp/32491");
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 1), c.items.len);
    try std.testing.expectEqualStrings("167.235.96.31", c.items[0].ip);
    try std.testing.expectEqual(@as(u16, 32491), c.items[0].port);
}

test "resolveBootnodeCandidates: /ip4/.../tcp/.../p2p/... drops the p2p suffix" {
    const allocator = std.testing.allocator;
    // /p2p/Qm... encodes as code=0x01a5, varint-len, multihash bytes.
    // Use a literal multiaddr without /p2p/ for simplicity (Multiaddr.fromText
    // doesn't yet accept the textual /p2p/Qm... form). The test verifies
    // extractIp4Tcp picks the right pair regardless of trailing components.
    var c = try resolveBootnodeCandidates(allocator, "/ip4/95.216.91.90/tcp/30634");
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 1), c.items.len);
    try std.testing.expectEqualStrings("95.216.91.90", c.items[0].ip);
    try std.testing.expectEqual(@as(u16, 30634), c.items[0].port);
}

test "resolveBootnodeCandidates: rejects bare host:port" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.UnsupportedBootnodeForm,
        resolveBootnodeCandidates(allocator, "1.2.3.4:1234"),
    );
}

test "resolveBootnodeCandidates: rejects /dnsaddr/ with empty host" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidBootnode,
        resolveBootnodeCandidates(allocator, "/dnsaddr/"),
    );
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
    _ = @import("encryption.zig");
    _ = @import("cheque.zig");
    _ = @import("swap.zig");
    _ = @import("accounting.zig");
    _ = @import("credential.zig");
}
