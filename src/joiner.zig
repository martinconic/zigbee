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
// We don't yet implement:
//   * encrypted chunks (refLength = 64),
//   * erasure-coded redundancy (extra "parity" siblings stored at the
//     end of an intermediate chunk's child list),
//   * single-owner chunks within a tree (mostly used for feeds, not
//     plain file uploads).
// Bee's plain `/bytes`-uploaded files use only the simple branching-128
// layout, so this is enough for the canonical "upload from one bee, read
// from zigbee" round-trip.

const std = @import("std");
const bmt = @import("bmt.zig");

pub const CHUNK_SIZE: usize = 4096;
pub const REF_LENGTH: usize = bmt.HASH_SIZE; // 32
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
/// content as a single allocator-owned buffer.
pub fn join(
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    fetch: FetchFn,
    root_addr: [bmt.HASH_SIZE]u8,
) ![]u8 {
    var root_data: []u8 = &[_]u8{};
    try fetch(ctx, root_addr, &root_data);
    defer allocator.free(root_data);
    if (root_data.len < SPAN_SIZE) return Error.InvalidRoot;

    const span = std.mem.readInt(u64, root_data[0..SPAN_SIZE], .little);
    if (span > MAX_REASONABLE_SPAN) return Error.LikelySocReference;
    if (span > std.math.maxInt(usize)) return Error.SpanTooLarge;

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, @intCast(span));

    try walk(allocator, ctx, fetch, root_data, &out);
    return out.toOwnedSlice(allocator);
}

fn walk(
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    fetch: FetchFn,
    chunk_data: []const u8,
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

    // Intermediate chunk: payload is `n` child addresses concatenated.
    if (payload.len == 0 or payload.len % REF_LENGTH != 0) return Error.InvalidIntermediateChunk;

    var cursor: usize = 0;
    while (cursor < payload.len) : (cursor += REF_LENGTH) {
        var child_addr: [bmt.HASH_SIZE]u8 = undefined;
        @memcpy(&child_addr, payload[cursor .. cursor + REF_LENGTH]);

        var child_data: []u8 = &[_]u8{};
        try fetch(ctx, child_addr, &child_data);
        defer allocator.free(child_data);

        try walk(allocator, ctx, fetch, child_data, out);
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
