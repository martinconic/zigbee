// Mantaray — bee's binary trie format for manifests.
//
// Bee wraps single-file uploads (`POST /bzz?name=foo.txt`) and
// directory/multi-file uploads (`POST /bzz` with a tar/zip body) in a
// mantaray trie. The reference returned by bee in those cases is the
// address of the *root* mantaray chunk, not the file content. To
// retrieve the bytes a user actually uploaded, we have to:
//
//   1. fetch the root chunk,
//   2. parse it as a mantaray Node,
//   3. either look up the user-supplied path (`/bzz/<ref>/<path>`), or,
//      for a path-less request, resolve the manifest's default entry
//      (root metadata `website-index-document` → that path),
//   4. hand the resulting CAC reference to the chunk-tree joiner.
//
// Wire format (v0.2; we accept v0.1 by relaxing one offset):
//
//   [ obfuscation_key       (32) ]   — random per node; XORs the rest
//   [ version_hash          (31) ]   — first 31B of keccak("mantaray:0.2")
//   [ ref_bytes_size         (1) ]   — typically 32; can be 64 for
//                                        encrypted refs (the parser is
//                                        ref-size agnostic — it reads
//                                        `ref_size` bytes per fork.ref
//                                        and per node.entry. Loader-side
//                                        decryption of child manifest
//                                        chunks is handled in the
//                                        caller's `loader` callback;
//                                        see p2p.zig:mantarayLoaderAdapter
//                                        for the 0.5b implementation).
//   [ entry            (refSize) ]   — the node's own entry reference;
//                                        zero-filled if the node is not
//                                        a value type
//   [ forks_bitmap          (32) ]   — 256-bit bitvector; bit `i` set
//                                        means this node has a fork keyed
//                                        by byte `i`
//   For each set bit (ascending):
//       [ node_type           (1) ]
//       [ prefix_len          (1) ]
//       [ prefix             (30) ]   — padded; only first prefix_len bytes
//                                        are meaningful
//       [ child_ref     (refSize) ]
//       (if node_type & 16 — withMetadata):
//       [ metadata_len        (2) ]   — big-endian
//       [ metadata_json (metadata_len, padded to 32) ]
//
// Everything *after* the 32-byte obfuscation_key is XOR-encrypted with
// `obfuscation_key` (cycling). Decryption is just XOR again.
//
// Reference: bee/pkg/manifest/mantaray/{marshal.go,node.go,walker.go}.

const std = @import("std");
const crypto = @import("crypto.zig");

pub const NODE_HEADER_SIZE: usize = 64; // 32 obfuscation + 31 version + 1 refSize
pub const OBFUSCATION_KEY_SIZE: usize = 32;
pub const VERSION_HASH_SIZE: usize = 31;
pub const FORKS_BITMAP_SIZE: usize = 32;
pub const FORK_PRE_REF_SIZE: usize = 32; // 1 type + 1 prefix_len + 30 prefix
pub const PREFIX_MAX_SIZE: usize = 30;
pub const METADATA_LEN_SIZE: usize = 2;

/// Root path key used for root-level metadata in bee's manifests.
pub const ROOT_PATH = "/";
/// Metadata key whose value is a path suffix (typically a filename) that
/// bee resolves as the "default file" when serving `/bzz/<ref>` with no
/// explicit path.
pub const WEBSITE_INDEX_DOCUMENT_KEY = "website-index-document";

pub const Error = error{
    TooShort,
    InvalidVersionHash,
    InvalidPrefixLen,
    UnsupportedRefSize,
    PathNotFound,
};

// First 31 bytes of keccak256("mantaray:0.1") and "mantaray:0.2", computed
// once at startup. We don't want to recompute these on every parse.
var version_01_hash: [VERSION_HASH_SIZE]u8 = undefined;
var version_02_hash: [VERSION_HASH_SIZE]u8 = undefined;
var versions_initialised: bool = false;

fn ensureVersionHashes() void {
    if (versions_initialised) return;
    var full: [32]u8 = undefined;
    crypto.keccak256("mantaray:0.1", &full);
    @memcpy(&version_01_hash, full[0..VERSION_HASH_SIZE]);
    crypto.keccak256("mantaray:0.2", &full);
    @memcpy(&version_02_hash, full[0..VERSION_HASH_SIZE]);
    versions_initialised = true;
}

/// One outgoing edge of a mantaray node.
pub const Fork = struct {
    node_type: u8,
    /// First non-branching path component (max 30 bytes).
    prefix: []u8,
    /// Address of the subtree's root chunk (or the file content if this is
    /// a leaf value node).
    ref: []u8,
    /// Optional metadata blob (JSON object, decoded as ad-hoc string map).
    metadata: ?std.StringHashMap([]const u8) = null,

    pub const NODE_TYPE_VALUE: u8 = 2;
    pub const NODE_TYPE_EDGE: u8 = 4;
    pub const NODE_TYPE_WITH_PATH_SEPARATOR: u8 = 8;
    pub const NODE_TYPE_WITH_METADATA: u8 = 16;

    pub fn isValue(self: Fork) bool {
        return (self.node_type & NODE_TYPE_VALUE) != 0;
    }
    pub fn isWithMetadata(self: Fork) bool {
        return (self.node_type & NODE_TYPE_WITH_METADATA) != 0;
    }

    fn deinit(self: *Fork, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.ref);
        if (self.metadata) |*m| {
            var it = m.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            m.deinit();
        }
    }
};

/// One mantaray trie node.
pub const Node = struct {
    obfuscation_key: [OBFUSCATION_KEY_SIZE]u8,
    ref_bytes_size: u8,
    /// Allocator-owned. May be all zeros for non-value nodes.
    entry: []u8,
    /// Forks keyed by the first byte of the prefix.
    forks: std.AutoHashMap(u8, Fork),

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Node) void {
        self.allocator.free(self.entry);
        var it = self.forks.valueIterator();
        while (it.next()) |f| f.deinit(self.allocator);
        self.forks.deinit();
    }
};

/// Detect whether `data` looks like a mantaray-encoded chunk payload.
/// Cheap: XOR-decrypts the version-hash region and compares against the
/// known v0.1 / v0.2 hashes. Used as a precondition before paying the
/// cost of full parsing.
pub fn looksLikeManifest(data: []const u8) bool {
    if (data.len < NODE_HEADER_SIZE) return false;
    ensureVersionHashes();
    var key: [OBFUSCATION_KEY_SIZE]u8 = undefined;
    @memcpy(&key, data[0..OBFUSCATION_KEY_SIZE]);
    var version: [VERSION_HASH_SIZE]u8 = undefined;
    for (data[OBFUSCATION_KEY_SIZE .. OBFUSCATION_KEY_SIZE + VERSION_HASH_SIZE], 0..) |b, i| {
        version[i] = b ^ key[i % OBFUSCATION_KEY_SIZE];
    }
    return std.mem.eql(u8, &version, &version_01_hash) or std.mem.eql(u8, &version, &version_02_hash);
}

/// Parse a chunk payload as a mantaray node. Returns `Error.InvalidVersionHash`
/// if it's not a manifest at all.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Node {
    if (data.len < NODE_HEADER_SIZE) return Error.TooShort;
    ensureVersionHashes();

    // XOR-decrypt everything past the obfuscation key with the key
    // (cycling per 32 bytes — bee's encryptDecrypt walks 32B at a time
    // but the result is identical to a per-byte XOR with `key[i % 32]`).
    const decrypted = try allocator.alloc(u8, data.len);
    errdefer allocator.free(decrypted);
    @memcpy(decrypted[0..OBFUSCATION_KEY_SIZE], data[0..OBFUSCATION_KEY_SIZE]);
    const key = data[0..OBFUSCATION_KEY_SIZE];
    for (data[OBFUSCATION_KEY_SIZE..], OBFUSCATION_KEY_SIZE..) |b, i| {
        decrypted[i] = b ^ key[i % OBFUSCATION_KEY_SIZE];
    }
    defer allocator.free(decrypted);

    const version = decrypted[OBFUSCATION_KEY_SIZE .. OBFUSCATION_KEY_SIZE + VERSION_HASH_SIZE];
    const is_v01 = std.mem.eql(u8, version, &version_01_hash);
    const is_v02 = std.mem.eql(u8, version, &version_02_hash);
    if (!is_v01 and !is_v02) return Error.InvalidVersionHash;

    // Bee allows ref_bytes_size = 0 for terminal manifest nodes that
    // only carry metadata-on-parent-fork (no own entry, no children).
    // For nodes with set fork bits but ref_size=0, bee skips the forks.
    const ref_size_byte = decrypted[NODE_HEADER_SIZE - 1];

    var node = Node{
        .obfuscation_key = undefined,
        .ref_bytes_size = ref_size_byte,
        .entry = undefined,
        .forks = std.AutoHashMap(u8, Fork).init(allocator),
        .allocator = allocator,
    };
    errdefer node.deinit();
    @memcpy(&node.obfuscation_key, decrypted[0..OBFUSCATION_KEY_SIZE]);

    var off: usize = NODE_HEADER_SIZE;
    if (off + ref_size_byte > decrypted.len) return Error.TooShort;
    node.entry = try allocator.dupe(u8, decrypted[off .. off + ref_size_byte]);
    off += ref_size_byte;

    if (off + FORKS_BITMAP_SIZE > decrypted.len) return Error.TooShort;
    const bitmap = decrypted[off .. off + FORKS_BITMAP_SIZE];
    off += FORKS_BITMAP_SIZE;

    // Iterate bits 0..255 in ascending order; for each set bit, parse
    // the fork that follows.
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const bit_byte = @as(u8, @intCast(i));
        const set = (bitmap[bit_byte / 8] >> @as(u3, @intCast(bit_byte % 8))) & 1 == 1;
        if (!set) continue;
        // Bee's UnmarshalBinary v0.2 skips forks when refBytesSize is 0
        // (a terminal node carrying metadata only): see node.go:280.
        if (ref_size_byte == 0) continue;

        if (off + FORK_PRE_REF_SIZE + ref_size_byte > decrypted.len) return Error.TooShort;
        const node_type = decrypted[off];
        const prefix_len = decrypted[off + 1];
        if (prefix_len == 0 or prefix_len > PREFIX_MAX_SIZE) return Error.InvalidPrefixLen;
        const prefix = try allocator.dupe(u8, decrypted[off + 2 .. off + 2 + prefix_len]);
        errdefer allocator.free(prefix);
        const ref = try allocator.dupe(u8, decrypted[off + FORK_PRE_REF_SIZE .. off + FORK_PRE_REF_SIZE + ref_size_byte]);
        errdefer allocator.free(ref);

        var fork = Fork{
            .node_type = node_type,
            .prefix = prefix,
            .ref = ref,
        };
        var fork_size: usize = FORK_PRE_REF_SIZE + ref_size_byte;

        if (is_v02 and (node_type & Fork.NODE_TYPE_WITH_METADATA) != 0) {
            if (off + fork_size + METADATA_LEN_SIZE > decrypted.len) return Error.TooShort;
            const meta_len = std.mem.readInt(u16, decrypted[off + fork_size ..][0..2], .big);
            fork_size += METADATA_LEN_SIZE;
            if (off + fork_size + meta_len > decrypted.len) return Error.TooShort;
            const meta_bytes = decrypted[off + fork_size .. off + fork_size + meta_len];
            fork_size += meta_len;
            // Bee pads metadata with newlines to a multiple of 32 bytes.
            // Strip those before JSON-parsing.
            const trimmed = std.mem.trimRight(u8, meta_bytes, "\n");
            fork.metadata = parseMetadataJson(allocator, trimmed) catch null;
        }

        try node.forks.put(bit_byte, fork);
        off += fork_size;
    }

    return node;
}

/// Bee writes metadata as a JSON object of string keys to string values.
/// We parse just enough to support that — flat objects only.
fn parseMetadataJson(allocator: std.mem.Allocator, bytes: []const u8) !std.StringHashMap([]const u8) {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    var out = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = out.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        out.deinit();
    }
    if (parsed.value != .object) return out;
    var it = parsed.value.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        const k = try allocator.dupe(u8, e.key_ptr.*);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, e.value_ptr.*.string);
        try out.put(k, v);
    }
    return out;
}

// ---------- walker ----------

/// Find the entry reference for `path` in a manifest. Mirrors bee's
/// `Node.LookupNode` + `Node.Lookup`:
///   * If `path` is empty, returns this node's `entry`.
///   * Otherwise: look up forks[path[0]]; require its prefix to match
///     the head of `path`; **always recurse** into the fork's child
///     node (loaded via the caller-supplied `loader`) with the
///     remaining path. Stopping at the fork itself would return the
///     sub-manifest's *chunk address*, not the file content reference
///     stored in the child's `entry`.
///
/// Returns an allocator-owned copy of the matched node's entry bytes.
pub fn lookup(
    allocator: std.mem.Allocator,
    n: *const Node,
    path: []const u8,
    ctx: *anyopaque,
    /// Given a child reference, fetch the chunk + parse it into `out`.
    /// `out` is caller-owned and must be deinit'd.
    loader: *const fn (ctx: *anyopaque, ref: []const u8, out: *Node) anyerror!void,
) ![]u8 {
    if (path.len == 0) {
        if (n.entry.len == 0 or allZero(n.entry)) return Error.PathNotFound;
        return try allocator.dupe(u8, n.entry);
    }
    const fork_ptr = n.forks.getPtr(path[0]) orelse return Error.PathNotFound;
    if (path.len < fork_ptr.prefix.len) return Error.PathNotFound;
    if (!std.mem.eql(u8, fork_ptr.prefix, path[0..fork_ptr.prefix.len])) return Error.PathNotFound;

    var child: Node = undefined;
    try loader(ctx, fork_ptr.ref, &child);
    defer child.deinit();
    return lookup(allocator, &child, path[fork_ptr.prefix.len..], ctx, loader);
}

/// Look up the metadata stored on the fork for `path` (typically `"/"`,
/// where bee parks root-level metadata like `website-index-document`).
/// Returns null if the path doesn't match a fork or the matching fork
/// has no metadata. This is the same data bee's API surfaces via
/// `manifestMetadataLoad`.
pub fn lookupForkMetadata(
    n: *const Node,
    path: []const u8,
) ?*const std.StringHashMap([]const u8) {
    if (path.len == 0) return null;
    const fork_ptr = n.forks.getPtr(path[0]) orelse return null;
    if (path.len != fork_ptr.prefix.len) return null;
    if (!std.mem.eql(u8, fork_ptr.prefix, path)) return null;
    return if (fork_ptr.metadata) |*m| m else null;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// Convenience for the `GET /bzz/<ref>` case (no explicit path):
///   1. Read metadata `website-index-document` parked on the root's
///      `"/"` fork (where bee writes single-file-upload defaults).
///      The metadata's value is the suffix bee uses as the default
///      file path; look that up from the root and return the entry.
///      Equivalent to bee's `manifestMetadataLoad("/", ...)` +
///      `manifest.Lookup(path.Join("", suffix))` flow in `bzz.go`.
///   2. Otherwise, lookup `"/"` directly — if that resolves to a
///      node with its own entry, return it (covers manifests where
///      the root carries the file reference directly).
///   3. As a last resort, return the root's own entry if non-zero.
///
/// Returns an allocator-owned copy of the file reference. Caller frees.
pub fn resolveDefaultFile(
    allocator: std.mem.Allocator,
    root: *const Node,
    ctx: *anyopaque,
    loader: *const fn (ctx: *anyopaque, ref: []const u8, out: *Node) anyerror!void,
) ![]u8 {
    // Step 1: bee's website-index-document indirection. The metadata
    // is on the root's "/" fork; the value is the suffix path to look
    // up FROM THE ROOT (path.Join("", suffix) = suffix in Go).
    if (lookupForkMetadata(root, ROOT_PATH)) |meta| {
        if (meta.get(WEBSITE_INDEX_DOCUMENT_KEY)) |suffix| {
            return try lookup(allocator, root, suffix, ctx, loader);
        }
    }

    // Step 2: the "/" fork's child has its own entry?
    if (lookup(allocator, root, ROOT_PATH, ctx, loader)) |entry| {
        return entry;
    } else |e| {
        if (e != Error.PathNotFound) return e;
    }

    // Step 3: root itself has an entry?
    if (!allZero(root.entry)) return try allocator.dupe(u8, root.entry);

    return Error.PathNotFound;
}

// ---------- tests ----------

const testing = std.testing;

test "mantaray: version hashes initialise correctly" {
    ensureVersionHashes();
    // First 4 bytes of keccak256("mantaray:0.2") = 5768b3b6 per the
    // hard-coded constant in bee/pkg/manifest/mantaray/marshal.go.
    try testing.expectEqual(@as(u8, 0x57), version_02_hash[0]);
    try testing.expectEqual(@as(u8, 0x68), version_02_hash[1]);
    try testing.expectEqual(@as(u8, 0xb3), version_02_hash[2]);
    try testing.expectEqual(@as(u8, 0xb6), version_02_hash[3]);
    try testing.expectEqual(@as(u8, 0x02), version_01_hash[0]);
    try testing.expectEqual(@as(u8, 0x51), version_01_hash[1]);
}

test "mantaray: looksLikeManifest rejects too-short input" {
    try testing.expectEqual(false, looksLikeManifest(""));
    try testing.expectEqual(false, looksLikeManifest("hello"));
}

test "mantaray: looksLikeManifest rejects random bytes" {
    var buf: [128]u8 = undefined;
    @memset(&buf, 0xAA);
    try testing.expectEqual(false, looksLikeManifest(&buf));
}
