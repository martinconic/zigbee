//! Chequebook credential loader.
//!
//! For SWAP cheque issuance zigbee needs three things tied to the same
//! deployed chequebook contract:
//!
//!   * the contract's 20-byte Ethereum address (goes into every cheque as
//!     `Cheque.Chequebook` and into bee's first-cheque on-chain validation
//!     `factory.VerifyChequebook`),
//!   * the contract owner's secp256k1 private key (signs every cheque per
//!     EIP-712; bee recovers the issuer and matches it against the
//!     contract's `issuer()` view function),
//!   * the chain id (Sepolia = 11155111, Gnosis = 100, Mainnet = 1) — folds
//!     into the EIP-712 domain separator so a cheque signed for chain N
//!     is invalid on chain M.
//!
//! These come from a JSON file the user provides via `--chequebook PATH`:
//!
//! ```json
//! {
//!   "contract":          "0xfa02D396842E6e1D319E8E3D4D870338F791AA25",
//!   "owner_private_key": "0x634fb5a872396d9693e5c9f9d7233cfa93f395c093371017ff44aa9ae6564cdd",
//!   "chain_id":          11155111
//! }
//! ```
//!
//! Without `--chequebook`, accounting still tracks per-peer debt but never
//! issues — equivalent to pre-0.5c behaviour. The disconnect-threshold
//! ceiling stays in place; useful for protocol-development testing where
//! deploying a chequebook would be premature.

const std = @import("std");

pub const ADDRESS_LEN: usize = 20;
pub const PRIVKEY_LEN: usize = 32;

pub const ChequebookCredential = struct {
    contract: [ADDRESS_LEN]u8,
    owner_private_key: [PRIVKEY_LEN]u8,
    chain_id: u64,
};

pub const Error = error{
    InvalidCredentialFile,
    InvalidContract,
    InvalidPrivateKey,
    InvalidChainId,
};

/// Load a chequebook credential from a JSON file. Tolerates `0x`-prefixed and
/// raw hex for the address and private key. Returns `Error` on any malformed
/// field; the contents of the credential are not validated against an actual
/// chequebook contract — that's bee's job at receive time.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !ChequebookCredential {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(allocator, 4096);
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return Error.InvalidCredentialFile;
    defer parsed.deinit();

    if (parsed.value != .object) return Error.InvalidCredentialFile;
    const obj = parsed.value.object;

    const contract_val = obj.get("contract") orelse return Error.InvalidCredentialFile;
    const priv_val = obj.get("owner_private_key") orelse return Error.InvalidCredentialFile;
    const chain_val = obj.get("chain_id") orelse return Error.InvalidCredentialFile;

    if (contract_val != .string or priv_val != .string)
        return Error.InvalidCredentialFile;

    var out: ChequebookCredential = undefined;
    parseHex(contract_val.string, &out.contract) catch return Error.InvalidContract;
    parseHex(priv_val.string, &out.owner_private_key) catch return Error.InvalidPrivateKey;

    out.chain_id = switch (chain_val) {
        .integer => |n| if (n < 0) return Error.InvalidChainId else @intCast(n),
        else => return Error.InvalidChainId,
    };

    return out;
}

fn parseHex(s: []const u8, out: []u8) !void {
    var hex = s;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len != out.len * 2) return error.InvalidLength;
    _ = try std.fmt.hexToBytes(out, hex);
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "credential: load valid file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const body =
        \\{
        \\  "contract": "0xfa02D396842E6e1D319E8E3D4D870338F791AA25",
        \\  "owner_private_key": "0x634fb5a872396d9693e5c9f9d7233cfa93f395c093371017ff44aa9ae6564cdd",
        \\  "chain_id": 11155111
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "cb.json", .data = body });

    const path = try tmp.dir.realpathAlloc(testing.allocator, "cb.json");
    defer testing.allocator.free(path);

    const cred = try load(testing.allocator, path);

    var expected_contract: [ADDRESS_LEN]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_contract, "fa02D396842E6e1D319E8E3D4D870338F791AA25");
    try testing.expectEqualSlices(u8, &expected_contract, &cred.contract);

    var expected_priv: [PRIVKEY_LEN]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_priv, "634fb5a872396d9693e5c9f9d7233cfa93f395c093371017ff44aa9ae6564cdd");
    try testing.expectEqualSlices(u8, &expected_priv, &cred.owner_private_key);

    try testing.expectEqual(@as(u64, 11155111), cred.chain_id);
}

test "credential: missing field is rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const body =
        \\{ "contract": "0x0000000000000000000000000000000000000000", "chain_id": 1 }
    ;
    try tmp.dir.writeFile(.{ .sub_path = "cb.json", .data = body });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "cb.json");
    defer testing.allocator.free(path);

    try testing.expectError(Error.InvalidCredentialFile, load(testing.allocator, path));
}

test "credential: malformed hex rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const body =
        \\{
        \\  "contract": "0xnothex",
        \\  "owner_private_key": "0x00",
        \\  "chain_id": 1
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "cb.json", .data = body });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "cb.json");
    defer testing.allocator.free(path);

    try testing.expectError(Error.InvalidContract, load(testing.allocator, path));
}
