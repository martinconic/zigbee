// Chunk-tree (file) joiner.
//
// A Swarm "reference" is the address of the *root* chunk of a binary
// merkle tree that encodes a file. Each chunk in the tree carries an
// 8-byte little-endian span prefix:
//
//   chunk_data := span_le_u64 ‖ payload
//
// The span tells us the total byte length of the *subtree* rooted at this
// chunk:
//
//   * span ≤ |payload|  ⇒ leaf chunk; payload[0..span] is raw file bytes.
//   * span >  |payload| ⇒ intermediate chunk; payload is concatenated
//                          32-byte child addresses, in order. Each child
//                          subtree's span is encoded in its own header.
//
// The branching factor is uniform: ChunkSize / RefLength = 4096/32 = 128.
// File-tree depth is therefore ⌈log_128(span / 4096)⌉. We don't need to
// pre-compute branch sizes for full-file reads — we walk the tree and
// concatenate leaves in order. (Bee's joiner computes per-branch sizes
// because it supports `ReadAt(offset)` over partial ranges; we don't.)
//
// **Encrypted chunk-trees** (added 0.5b, refLength = 64). When a file is
// uploaded with `Swarm-Encrypt: true`, every chunk in the tree is
// encrypted with a fresh random key, and every reference (root and
// intermediate) is 64 bytes: `addr(32) ‖ key(32)`. Branching is then
// 4096/64 = 64. The `joinEncrypted` entry point handles this case;
// internally it goes through the same recursive walker, just with a key
// threaded through and `decryptChunk` inserted before each parse.
//
// We don't yet implement:
//   * erasure-coded redundancy (extra "parity" siblings stored at the
//     end of an intermediate chunk's child list),
//   * single-owner chunks within a tree (mostly used for feeds, not
//     plain file uploads).
// Bee's plain `/bytes`-uploaded files (encrypted or not) use only the
// simple uniform-branching layout, so this is enough for the canonical
// "upload from one bee, read from zigbee" round-trip.

const std = @import("std");
const bmt = @import("bmt.zig");
const encryption = @import("encryption.zig");

pub const CHUNK_SIZE: usize = 4096;
pub const REF_LENGTH: usize = bmt.HASH_SIZE; // 32 — unencrypted
pub const ENCRYPTED_REF_LENGTH: usize = encryption.REFERENCE_SIZE; // 64
pub const SPAN_SIZE: usize = bmt.SPAN_SIZE; // 8
pub const MAX_BRANCHING: usize = CHUNK_SIZE / REF_LENGTH; // 128

/// Generic fetch callback: given a 32-byte chunk address, return the raw
/// chunk content (i.e. `span_le_u64 ‖ payload`). Caller of this module
/// supplies whatever transport it likes (live retrieval, local store,
/// test fixture). Returned slice is owned by the implementation.
pub const FetchFn = *const fn (
    ctx: *anyopaque,
    addr: [bmt.HASH_SIZE]u8,
    chunk_data_out: *[]u8, // populated on success — caller frees with the same allocator we got handed
) anyerror!void;

pub const Error = error{
    InvalidRoot,
    InvalidIntermediateChunk,
    SpanTooLarge,
    /// Raised when the root chunk's first-8-byte "span" decodes to an
    /// implausibly large value. This typically means the reference is a
    /// Single-Owner Chunk (id ‖ sig ‖ span ‖ payload), not a CAC file root
    /// (span ‖ payload). The joiner only handles CAC trees built by bee's
    /// `/bytes` upload path.
    LikelySocReference,
};

/// Hard ceiling on a Swarm file we'll join (~1 TiB). Anything bigger is
/// almost certainly a sign that the bytes we're reading aren't actually a
/// span field (e.g. SOC chunk mistakenly used as a CAC root).
pub const MAX_REASONABLE_SPAN: u64 = 1 << 40;

/// Joins the chunk-tree rooted at `root_addr` and returns the file
/// content as a single allocator-owned buffer. The tree is unencrypted
/// (32-byte refs, branching 128). For encrypted trees use `joinEncrypted`.
pub fn join(
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    fetch: FetchFn,
    root_addr: [bmt.HASH_SIZE]u8,
) ![]u8 {
    return joinInternal(allocator, ctx, fetch, root_addr, null);
}

/// Encrypted variant of `join` (0.5b). The 32-byte `root_key` is the
/// second half of the 64-byte reference. Each intermediate chunk's
/// payload, after decryption, contains 64-byte child references where
/// the second half is the next chunk's key. The walker threads keys
/// through the recursion.
pub fn joinEncrypted(
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    fetch: FetchFn,
    root_addr: [bmt.HASH_SIZE]u8,
    root_key: [encryption.KEY_LEN]u8,
) ![]u8 {
    return joinInternal(allocator, ctx, fetch, root_addr, root_key);
}

fn joinInternal(
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    fetch: FetchFn,
    root_addr: [bmt.HASH_SIZE]u8,
    root_key: ?[encryption.KEY_LEN]u8,
) ![]u8 {
    var root_data: []u8 = &[_]u8{};
    try fetch(ctx, root_addr, &root_data);
    defer allocator.free(root_data);

    // Decrypt the root chunk if encrypted, replacing root_data with the
    // owned decrypted view. Both branches end with `chunk_view` pointing
    // to `span(8) ‖ payload` in the same shape.
    var chunk_view: []const u8 = root_data;
    var owned_decrypted: ?[]u8 = null;
    defer if (owned_decrypted) |d| allocator.free(d);
    if (root_key) |k| {
        owned_decrypted = try encryption.decryptChunk(allocator, k, root_data);
        chunk_view = owned_decrypted.?;
    }

    if (chunk_view.len < SPAN_SIZE) return Error.InvalidRoot;
    const span = std.mem.readInt(u64, chunk_view[0..SPAN_SIZE], .little);
    if (span > MAX_REASONABLE_SPAN) return Error.LikelySocReference;
    if (span > std.math.maxInt(usize)) return Error.SpanTooLarge;

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, @intCast(span));

    try walk(allocator, ctx, fetch, chunk_view, root_key != null, &out);
    return out.toOwnedSlice(allocator);
}

/// Walks a chunk-tree node and appends its leaves to `out`. `chunk_data`
/// is `span(8 LE) ‖ payload` — already decrypted at this layer. The
/// `is_encrypted` flag tells us how to interpret the payload of an
/// intermediate chunk: as 32-byte refs (unencrypted) or 64-byte refs
/// (encrypted, second half is the child key).
fn walk(
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    fetch: FetchFn,
    chunk_data: []const u8,
    is_encrypted: bool,
    out: *std.ArrayList(u8),
) !void {
    if (chunk_data.len < SPAN_SIZE) return Error.InvalidIntermediateChunk;
    const span = std.mem.readInt(u64, chunk_data[0..SPAN_SIZE], .little);
    const payload = chunk_data[SPAN_SIZE..];

    if (span <= payload.len) {
        // Leaf chunk: the first `span` bytes of payload are the data.
        try out.appendSlice(allocator, payload[0..@intCast(span)]);
        return;
    }

    // Intermediate chunk: payload is `n` child references concatenated.
    const ref_len: usize = if (is_encrypted) ENCRYPTED_REF_LENGTH else REF_LENGTH;
    if (payload.len == 0 or payload.len % ref_len != 0) return Error.InvalidIntermediateChunk;

    var cursor: usize = 0;
    while (cursor < payload.len) : (cursor += ref_len) {
        var child_addr: [bmt.HASH_SIZE]u8 = undefined;
        @memcpy(&child_addr, payload[cursor .. cursor + bmt.HASH_SIZE]);

        var child_raw: []u8 = &[_]u8{};
        try fetch(ctx, child_addr, &child_raw);
        defer allocator.free(child_raw);

        if (is_encrypted) {
            // Second 32 bytes of the ref is the child's symmetric key.
            var child_key: [encryption.KEY_LEN]u8 = undefined;
            @memcpy(&child_key, payload[cursor + bmt.HASH_SIZE .. cursor + ref_len]);

            const child_decrypted = try encryption.decryptChunk(allocator, child_key, child_raw);
            defer allocator.free(child_decrypted);
            try walk(allocator, ctx, fetch, child_decrypted, true, out);
        } else {
            try walk(allocator, ctx, fetch, child_raw, false, out);
        }
    }
}

// ---------- tests ----------

const testing = std.testing;

const TestStore = struct {
    map: std.AutoHashMap([bmt.HASH_SIZE]u8, []const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TestStore {
        return .{
            .map = std.AutoHashMap([bmt.HASH_SIZE]u8, []const u8).init(allocator),
            .allocator = allocator,
        };
    }
    fn deinit(self: *TestStore) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.map.deinit();
    }
    /// Stores a chunk, returning its content address (BMT hash of span ‖ payload).
    fn putLeaf(self: *TestStore, payload: []const u8) ![bmt.HASH_SIZE]u8 {
        var span: [SPAN_SIZE]u8 = undefined;
        std.mem.writeInt(u64, &span, payload.len, .little);
        const data = try self.allocator.alloc(u8, SPAN_SIZE + payload.len);
        @memcpy(data[0..SPAN_SIZE], &span);
        @memcpy(data[SPAN_SIZE..], payload);
        const c = bmt.Chunk.init(payload);
        var addr: [bmt.HASH_SIZE]u8 = undefined;
        try c.address(&addr);
        try self.map.put(addr, data);
        return addr;
    }
    /// Stores an intermediate chunk built over child addresses.
    /// Span = sum of child spans (caller passes the recovered total).
    fn putIntermediate(
        self: *TestStore,
        children: []const [bmt.HASH_SIZE]u8,
        total_span: u64,
    ) ![bmt.HASH_SIZE]u8 {
        var span_bytes: [SPAN_SIZE]u8 = undefined;
        std.mem.writeInt(u64, &span_bytes, total_span, .little);
        const payload = try self.allocator.alloc(u8, children.len * REF_LENGTH);
        for (children, 0..) |c, i| {
            @memcpy(payload[i * REF_LENGTH ..][0..REF_LENGTH], &c);
        }
        defer self.allocator.free(payload);

        const data = try self.allocator.alloc(u8, SPAN_SIZE + payload.len);
        @memcpy(data[0..SPAN_SIZE], &span_bytes);
        @memcpy(data[SPAN_SIZE..], payload);

        // Address: BMT over payload, using total_span (not payload.len).
        var c = bmt.Chunk.init(payload);
        c.span = total_span;
        var addr: [bmt.HASH_SIZE]u8 = undefined;
        try c.address(&addr);
        try self.map.put(addr, data);
        return addr;
    }
};

fn testFetch(ctx: *anyopaque, addr: [bmt.HASH_SIZE]u8, out: *[]u8) anyerror!void {
    const store: *TestStore = @ptrCast(@alignCast(ctx));
    const data = store.map.get(addr) orelse return error.NotFound;
    out.* = try store.allocator.dupe(u8, data);
}

test "joiner: single leaf chunk round-trips" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();

    const file = "hello world from zigbee";
    const root = try store.putLeaf(file);

    const out = try join(testing.allocator, @ptrCast(&store), &testFetch, root);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, file, out);
}

test "joiner: two-leaf intermediate root" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();

    var leaf1_buf: [CHUNK_SIZE]u8 = undefined;
    var leaf2_buf: [200]u8 = undefined;
    for (&leaf1_buf, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    for (&leaf2_buf, 0..) |*b, i| b.* = @intCast((i + 7) & 0xFF);

    const a1 = try store.putLeaf(&leaf1_buf);
    const a2 = try store.putLeaf(&leaf2_buf);
    const total = leaf1_buf.len + leaf2_buf.len;
    const root = try store.putIntermediate(&[_][bmt.HASH_SIZE]u8{ a1, a2 }, total);

    const out = try join(testing.allocator, @ptrCast(&store), &testFetch, root);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, total), out.len);
    try testing.expectEqualSlices(u8, &leaf1_buf, out[0..leaf1_buf.len]);
    try testing.expectEqualSlices(u8, &leaf2_buf, out[leaf1_buf.len..]);
}

// --- encrypted-tree (0.5b) tests ---

/// Encrypts a wire chunk in place: span(8) gets keystream init_ctr=128,
/// data gets init_ctr=0. Returns the input pointer for chaining.
fn encryptChunkInPlace(buf: []u8, key: [encryption.KEY_LEN]u8) void {
    encryption.transform(key, buf[0..SPAN_SIZE], encryption.SPAN_INIT_CTR);
    encryption.transform(key, buf[SPAN_SIZE..], 0);
}

/// Builds an encrypted leaf chunk: pads payload to CHUNK_SIZE with zeros
/// (real bee uses random padding, but our walker doesn't read past
/// `span`, so zeros are fine for tests). Stores it under the BMT hash
/// of the *encrypted* bytes (which is what bee uses for the on-wire
/// chunk address). Returns 64-byte ref `addr ‖ key`.
fn putEncryptedLeaf(
    store: *TestStore,
    payload: []const u8,
    key: [encryption.KEY_LEN]u8,
) ![ENCRYPTED_REF_LENGTH]u8 {
    var wire = try store.allocator.alloc(u8, SPAN_SIZE + CHUNK_SIZE);
    defer store.allocator.free(wire); // we'll dupe into the store
    @memset(wire, 0);
    std.mem.writeInt(u64, wire[0..SPAN_SIZE], payload.len, .little);
    @memcpy(wire[SPAN_SIZE..][0..payload.len], payload);
    encryptChunkInPlace(wire, key);

    // Address: BMT over the encrypted bytes (bee hashes the ciphertext).
    var c = bmt.Chunk.init(wire[SPAN_SIZE..]);
    c.span = std.mem.readInt(u64, wire[0..SPAN_SIZE], .little);
    var addr: [bmt.HASH_SIZE]u8 = undefined;
    try c.address(&addr);

    const stored = try store.allocator.dupe(u8, wire);
    try store.map.put(addr, stored);

    var ref: [ENCRYPTED_REF_LENGTH]u8 = undefined;
    @memcpy(ref[0..bmt.HASH_SIZE], &addr);
    @memcpy(ref[bmt.HASH_SIZE..], &key);
    return ref;
}

/// Builds an encrypted intermediate chunk over child refs (each 64 B).
fn putEncryptedIntermediate(
    store: *TestStore,
    children: []const [ENCRYPTED_REF_LENGTH]u8,
    total_span: u64,
    key: [encryption.KEY_LEN]u8,
) ![ENCRYPTED_REF_LENGTH]u8 {
    var wire = try store.allocator.alloc(u8, SPAN_SIZE + CHUNK_SIZE);
    defer store.allocator.free(wire);
    @memset(wire, 0);
    std.mem.writeInt(u64, wire[0..SPAN_SIZE], total_span, .little);
    for (children, 0..) |c, i| {
        @memcpy(wire[SPAN_SIZE + i * ENCRYPTED_REF_LENGTH ..][0..ENCRYPTED_REF_LENGTH], &c);
    }
    encryptChunkInPlace(wire, key);

    var c = bmt.Chunk.init(wire[SPAN_SIZE..]);
    c.span = total_span;
    var addr: [bmt.HASH_SIZE]u8 = undefined;
    try c.address(&addr);

    const stored = try store.allocator.dupe(u8, wire);
    try store.map.put(addr, stored);

    var ref: [ENCRYPTED_REF_LENGTH]u8 = undefined;
    @memcpy(ref[0..bmt.HASH_SIZE], &addr);
    @memcpy(ref[bmt.HASH_SIZE..], &key);
    return ref;
}

test "joiner: encrypted single-leaf round-trips" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();

    var key: [encryption.KEY_LEN]u8 = undefined;
    @memset(&key, 0x37);

    const file = "encrypted hello from zigbee";
    const ref = try putEncryptedLeaf(&store, file, key);

    var addr: [bmt.HASH_SIZE]u8 = undefined;
    @memcpy(&addr, ref[0..bmt.HASH_SIZE]);
    var root_key: [encryption.KEY_LEN]u8 = undefined;
    @memcpy(&root_key, ref[bmt.HASH_SIZE..]);

    const out = try joinEncrypted(testing.allocator, @ptrCast(&store), &testFetch, addr, root_key);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(file, out);
}

test "joiner: encrypted two-leaf intermediate round-trips" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();

    var k_root: [encryption.KEY_LEN]u8 = undefined;
    @memset(&k_root, 0x11);
    var k_a: [encryption.KEY_LEN]u8 = undefined;
    @memset(&k_a, 0x22);
    var k_b: [encryption.KEY_LEN]u8 = undefined;
    @memset(&k_b, 0x33);

    var leaf_a: [CHUNK_SIZE]u8 = undefined;
    var leaf_b: [200]u8 = undefined;
    for (&leaf_a, 0..) |*x, i| x.* = @intCast(i & 0xFF);
    for (&leaf_b, 0..) |*x, i| x.* = @intCast((i + 7) & 0xFF);

    const ref_a = try putEncryptedLeaf(&store, &leaf_a, k_a);
    const ref_b = try putEncryptedLeaf(&store, &leaf_b, k_b);
    const total = leaf_a.len + leaf_b.len;
    const ref_root = try putEncryptedIntermediate(
        &store,
        &[_][ENCRYPTED_REF_LENGTH]u8{ ref_a, ref_b },
        total,
        k_root,
    );

    var root_addr: [bmt.HASH_SIZE]u8 = undefined;
    @memcpy(&root_addr, ref_root[0..bmt.HASH_SIZE]);
    var root_key: [encryption.KEY_LEN]u8 = undefined;
    @memcpy(&root_key, ref_root[bmt.HASH_SIZE..]);

    const out = try joinEncrypted(testing.allocator, @ptrCast(&store), &testFetch, root_addr, root_key);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, total), out.len);
    try testing.expectEqualSlices(u8, &leaf_a, out[0..leaf_a.len]);
    try testing.expectEqualSlices(u8, &leaf_b, out[leaf_a.len..]);
}
