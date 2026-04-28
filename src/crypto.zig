const std = @import("std");
const Keccak256 = std.crypto.hash.sha3.Keccak256;

pub fn keccak256(data: []const u8, out: *[32]u8) void {
    Keccak256.hash(data, out, .{});
}

test "keccak256 of empty string matches Ethereum/legacy Keccak" {
    // Sanity check that std.crypto.hash.sha3.Keccak256 is the legacy/Ethereum Keccak,
    // not standardised SHA3-256 (which differs in the padding rule and gives a
    // different output). Swarm and Bee depend on the legacy variant.
    var out: [32]u8 = undefined;
    keccak256("", &out);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}
