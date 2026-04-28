const std = @import("std");
const crypto = @import("crypto.zig");

pub const SEGMENT_SIZE: usize = 32;
pub const BRANCHES: usize = 128;
pub const CHUNK_SIZE: usize = SEGMENT_SIZE * BRANCHES; // 4096
pub const SPAN_SIZE: usize = 8;
pub const HASH_SIZE: usize = 32;

pub const Error = error{ChunkDataTooLarge};

// Computes the BMT root over `data` zero-padded to CHUNK_SIZE bytes.
// Mirrors bee's pkg/bmt/reference RefHasher with segCount = BRANCHES.
fn bmtRoot(data: []const u8, out: *[HASH_SIZE]u8) void {
    var padded: [CHUNK_SIZE]u8 = [_]u8{0} ** CHUNK_SIZE;
    @memcpy(padded[0..data.len], data);

    var level: [BRANCHES][SEGMENT_SIZE]u8 = undefined;
    var i: usize = 0;
    while (i < BRANCHES) : (i += 1) {
        @memcpy(&level[i], padded[i * SEGMENT_SIZE ..][0..SEGMENT_SIZE]);
    }

    var count: usize = BRANCHES;
    while (count > 1) {
        const half = count / 2;
        var pair: [SEGMENT_SIZE * 2]u8 = undefined;
        var j: usize = 0;
        while (j < half) : (j += 1) {
            @memcpy(pair[0..SEGMENT_SIZE], &level[2 * j]);
            @memcpy(pair[SEGMENT_SIZE..], &level[2 * j + 1]);
            crypto.keccak256(&pair, &level[j]);
        }
        count = half;
    }

    out.* = level[0];
}

pub const Chunk = struct {
    data: []const u8,
    span: u64,

    pub fn init(data: []const u8) Chunk {
        return Chunk{ .data = data, .span = @intCast(data.len) };
    }

    // Swarm content-addressed chunk hash:
    //   address = keccak256(span_le_u64 || BMT_root(data padded to 4096))
    pub fn address(self: *const Chunk, out_hash: *[HASH_SIZE]u8) Error!void {
        if (self.data.len > CHUNK_SIZE) return Error.ChunkDataTooLarge;

        var root: [HASH_SIZE]u8 = undefined;
        bmtRoot(self.data, &root);

        var span_root: [SPAN_SIZE + HASH_SIZE]u8 = undefined;
        std.mem.writeInt(u64, span_root[0..SPAN_SIZE], self.span, .little);
        @memcpy(span_root[SPAN_SIZE..], &root);
        crypto.keccak256(&span_root, out_hash);
    }
};

test "chunk creation" {
    const chunk = Chunk.init("hello swarm");
    try std.testing.expectEqual(@as(u64, 11), chunk.span);
}

test "chunk address - foo (bee golden vector)" {
    // From bee/pkg/cac/cac_test.go TestValid
    const chunk = Chunk.init("foo");
    var addr: [HASH_SIZE]u8 = undefined;
    try chunk.address(&addr);
    var expected: [HASH_SIZE]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "2387e8e7d8a48c2a9339c97c1dc3461a9a7aa07e994c5cb8b38fd7c1b3e6ea48");
    try std.testing.expectEqualSlices(u8, &expected, &addr);
}

test "chunk address - greaterthanspan (bee golden vector)" {
    // From bee/pkg/cac/cac_test.go TestNew
    const chunk = Chunk.init("greaterthanspan");
    var addr: [HASH_SIZE]u8 = undefined;
    try chunk.address(&addr);
    var expected: [HASH_SIZE]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "27913f1bdb6e8e52cbd5a5fd4ab577c857287edf6969b41efe926b51de0f4f23");
    try std.testing.expectEqualSlices(u8, &expected, &addr);
}

test "chunk address - oversized data is rejected" {
    var data: [CHUNK_SIZE + 1]u8 = [_]u8{0} ** (CHUNK_SIZE + 1);
    const chunk = Chunk.init(&data);
    var addr: [HASH_SIZE]u8 = undefined;
    try std.testing.expectError(Error.ChunkDataTooLarge, chunk.address(&addr));
}
