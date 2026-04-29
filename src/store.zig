// Local flat-file chunk store with a basic in-memory LRU cap (0.5a).
//
// Layout: <root>/<2-hex prefix>/<full-64-hex>
//   * Each file holds the chunk's wire-format `span(8 LE) ‖ payload`
//     — same shape bee returns from `GET /chunks/<addr>` so the on-disk
//     representation is inspectable with `xxd`.
//   * 2-hex sharding keeps any single dir under ~256 entries for the
//     first 65 536 chunks (saves ext4 dir-lookup time on bigger caches).
//
// Concurrency model:
//   * One mutex (`mtx`) guards the in-memory index (hashmap + DLL).
//   * Filesystem reads/writes happen WITHOUT the mutex held — multiple
//     reader threads can pull cached chunks in parallel; the only
//     contention is the index update on hit (touch) or miss-then-insert.
//   * Atomic write (tempfile + fsync + rename) means a crash mid-put
//     either leaves the old file or installs the new one — never a
//     partial chunk that would CAC-fail on read.
//
// Eviction:
//   * Head of `lru` = most-recently-used, tail = least-recently-used.
//   * `put` evicts from the tail until `cur_bytes <= max_bytes`.
//   * `get` hit → moveToFront(entry) so the entry goes to head.
//   * Restart scan walks the dir, sorts by mtime descending, populates
//     the LRU in that order — close enough to the live ordering that we
//     don't lose a meaningful number of would-be-cached entries.
//
// What's intentionally NOT here (deferred to later milestones):
//   * No content re-validation on read. Retrieval already validated CAC
//     or SOC before insert; trusting our own writes is fine.
//   * No background flush queue. fsync per put is fine at retrieval rates
//     (one chunk per network round-trip ≫ one fsync).
//   * No staging-store abstraction (that's 0.6 push work).
//   * No persistent LRU ordering — mtime-on-startup is the index seed;
//     worst case is one or two suboptimal evictions on the run after a
//     long uptime.

const std = @import("std");

pub const HASH_SIZE: usize = 32;
pub const SPAN_SIZE: usize = 8;
pub const MAX_PAYLOAD_BYTES: usize = 4096;
pub const MAX_FILE_BYTES: usize = SPAN_SIZE + MAX_PAYLOAD_BYTES;

pub const Error = error{
    BadHexFilename,
    InvalidStoreFile,
};

/// One cached chunk's metadata. Lives in the LRU and is keyed by `addr`
/// in the hashmap. The actual chunk bytes live on disk; we only hold
/// the address + size + LRU node here.
const Entry = struct {
    addr: [HASH_SIZE]u8,
    bytes_on_disk: u64,
    list_node: std.DoublyLinkedList.Node = .{},

    fn fromListNode(n: *std.DoublyLinkedList.Node) *Entry {
        // On 32-bit targets `Entry` (alignment 8 due to its u64 field) is
        // wider-aligned than `Node` (alignment 4). The Node we receive is
        // always embedded inside a heap-allocated Entry, so the underlying
        // memory is in fact 8-aligned — assert that to satisfy
        // @fieldParentPtr's alignment check on 32-bit ARM.
        return @alignCast(@fieldParentPtr("list_node", n));
    }
};

/// What `get` returns when a chunk is in the cache. Caller calls
/// `.deinit()` to free `data`.
pub const StoredChunk = struct {
    span: u64,
    data: []u8,
    _allocator: std.mem.Allocator,

    pub fn deinit(self: StoredChunk) void {
        self._allocator.free(self.data);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    /// Owned. `<root>/<2-hex>/<64-hex>` is each chunk's path.
    root: []u8,
    max_bytes: u64,
    cur_bytes: u64 = 0,

    entries: std.AutoHashMap([HASH_SIZE]u8, *Entry),
    /// Head = most-recently-used, tail = least-recently-used.
    lru: std.DoublyLinkedList = .{},

    mtx: std.Thread.Mutex = .{},

    /// Open the store rooted at `root`. Creates the directory if
    /// missing. Walks the existing tree to seed the in-memory index;
    /// if the on-disk total exceeds `max_bytes` (e.g. operator
    /// shrunk the cap), evicts oldest-mtime entries until under cap.
    pub fn openOrCreate(
        allocator: std.mem.Allocator,
        root: []const u8,
        max_bytes: u64,
    ) !*Store {
        std.fs.cwd().makePath(root) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };

        const self = try allocator.create(Store);
        errdefer allocator.destroy(self);

        const root_owned = try allocator.dupe(u8, root);
        errdefer allocator.free(root_owned);

        self.* = .{
            .allocator = allocator,
            .root = root_owned,
            .max_bytes = max_bytes,
            .entries = std.AutoHashMap([HASH_SIZE]u8, *Entry).init(allocator),
        };

        try self.scanExistingFiles();
        // If on-disk size already exceeds the configured cap (operator
        // shrunk it, or we picked up a bigger old store), trim now.
        try self.evictDownTo(self.max_bytes);

        return self;
    }

    pub fn deinit(self: *Store) void {
        self.mtx.lock();
        var it = self.entries.iterator();
        while (it.next()) |kv| self.allocator.destroy(kv.value_ptr.*);
        self.entries.deinit();
        self.allocator.free(self.root);
        self.mtx.unlock();
        self.allocator.destroy(self);
    }

    /// Fetch a cached chunk. Returns null on miss. On hit, moves the
    /// entry to the front of the LRU.
    pub fn get(self: *Store, addr: [HASH_SIZE]u8) !?StoredChunk {
        self.mtx.lock();
        const entry_opt = self.entries.get(addr);
        if (entry_opt) |entry| {
            // Move to front (MRU).
            self.lru.remove(&entry.list_node);
            self.lru.prepend(&entry.list_node);
        }
        self.mtx.unlock();

        if (entry_opt == null) return null;

        // Read the file outside the lock — multiple readers can hit
        // different files concurrently. The lock only protects the
        // LRU index above.
        const path = try self.pathFor(addr);
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
            // Race: another caller evicted the file between our hashmap
            // lookup and our open. Treat as miss.
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size < SPAN_SIZE or stat.size > MAX_FILE_BYTES) {
            return Error.InvalidStoreFile;
        }

        const file_size: usize = @intCast(stat.size);
        const buf = try self.allocator.alloc(u8, file_size - SPAN_SIZE);
        errdefer self.allocator.free(buf);

        var span_buf: [SPAN_SIZE]u8 = undefined;
        const n_span = try file.readAll(&span_buf);
        if (n_span != SPAN_SIZE) return Error.InvalidStoreFile;
        const span = std.mem.readInt(u64, &span_buf, .little);

        const n = try file.readAll(buf);
        if (n != buf.len) return Error.InvalidStoreFile;

        return StoredChunk{
            .span = span,
            .data = buf,
            ._allocator = self.allocator,
        };
    }

    /// Insert (or replace) a chunk. Atomic write: tempfile → fsync →
    /// rename. Updates the in-memory index and evicts oldest entries
    /// until `cur_bytes <= max_bytes`.
    pub fn put(
        self: *Store,
        addr: [HASH_SIZE]u8,
        span: u64,
        data: []const u8,
    ) !void {
        if (data.len > MAX_PAYLOAD_BYTES) return Error.InvalidStoreFile;
        const file_bytes: u64 = SPAN_SIZE + data.len;

        try self.atomicWriteFile(addr, span, data);

        self.mtx.lock();
        defer self.mtx.unlock();

        if (self.entries.get(addr)) |existing| {
            // Replacing — adjust counter for the size delta and bump LRU.
            self.cur_bytes -|= existing.bytes_on_disk;
            self.cur_bytes += file_bytes;
            existing.bytes_on_disk = file_bytes;
            self.lru.remove(&existing.list_node);
            self.lru.prepend(&existing.list_node);
        } else {
            const entry = try self.allocator.create(Entry);
            entry.* = .{ .addr = addr, .bytes_on_disk = file_bytes };
            try self.entries.put(addr, entry);
            self.lru.prepend(&entry.list_node);
            self.cur_bytes += file_bytes;
        }

        // Evict oldest until under cap. Holds the lock — eviction is
        // O(evicted) which is bounded by one chunk per put in steady
        // state, so the lock isn't held long.
        try self.evictDownToLocked(self.max_bytes);
    }

    /// Total file bytes on disk, as tracked by the index. Approximate
    /// (rounding by file size, not actual block usage).
    pub fn currentBytes(self: *Store) u64 {
        self.mtx.lock();
        defer self.mtx.unlock();
        return self.cur_bytes;
    }

    pub fn entryCount(self: *Store) usize {
        self.mtx.lock();
        defer self.mtx.unlock();
        return self.entries.count();
    }

    // --- internals ---

    fn pathFor(self: *Store, addr: [HASH_SIZE]u8) ![]u8 {
        var hex: [HASH_SIZE * 2]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (addr, 0..) |b, i| {
            hex[i * 2] = hex_chars[b >> 4];
            hex[i * 2 + 1] = hex_chars[b & 0xF];
        }
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{c}{c}/{s}",
            .{ self.root, hex[0], hex[1], hex },
        );
    }

    fn atomicWriteFile(
        self: *Store,
        addr: [HASH_SIZE]u8,
        span: u64,
        data: []const u8,
    ) !void {
        const final_path = try self.pathFor(addr);
        defer self.allocator.free(final_path);

        // Ensure shard dir exists.
        if (std.fs.path.dirname(final_path)) |shard| {
            std.fs.cwd().makePath(shard) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{final_path});
        defer self.allocator.free(tmp_path);

        {
            var f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer f.close();
            var span_buf: [SPAN_SIZE]u8 = undefined;
            std.mem.writeInt(u64, &span_buf, span, .little);
            try f.writeAll(&span_buf);
            try f.writeAll(data);
            try f.sync();
        }

        try std.fs.cwd().rename(tmp_path, final_path);
    }

    /// Walks `<root>/<2-hex>/*` and seeds the in-memory index.
    /// Sorted by mtime descending so the most-recent files end up at
    /// the front of the LRU.
    fn scanExistingFiles(self: *Store) !void {
        const Found = struct {
            addr: [HASH_SIZE]u8,
            bytes: u64,
            mtime_ns: i128,
        };
        var found = std.ArrayList(Found){};
        defer found.deinit(self.allocator);

        var root_dir = std.fs.cwd().openDir(self.root, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer root_dir.close();

        var root_it = root_dir.iterate();
        while (try root_it.next()) |shard_dirent| {
            if (shard_dirent.kind != .directory) continue;
            if (shard_dirent.name.len != 2) continue;
            if (!isHexChar(shard_dirent.name[0]) or !isHexChar(shard_dirent.name[1])) continue;

            var shard_dir = try root_dir.openDir(shard_dirent.name, .{ .iterate = true });
            defer shard_dir.close();

            var shard_it = shard_dir.iterate();
            while (try shard_it.next()) |chunk_dirent| {
                if (chunk_dirent.kind != .file) continue;
                if (chunk_dirent.name.len != HASH_SIZE * 2) continue;

                var addr: [HASH_SIZE]u8 = undefined;
                _ = std.fmt.hexToBytes(&addr, chunk_dirent.name) catch continue;

                const stat = shard_dir.statFile(chunk_dirent.name) catch continue;
                if (stat.size < SPAN_SIZE or stat.size > MAX_FILE_BYTES) continue;

                try found.append(self.allocator, .{
                    .addr = addr,
                    .bytes = stat.size,
                    .mtime_ns = stat.mtime,
                });
            }
        }

        // Sort by mtime descending.
        std.mem.sort(Found, found.items, {}, struct {
            fn lessThan(_: void, a: Found, b: Found) bool {
                return a.mtime_ns > b.mtime_ns;
            }
        }.lessThan);

        // Append in order — `prepend` would put oldest at the head; we
        // want newest at the head, so we walk newest-first and prepend
        // each one, OR walk oldest-first and prepend each. Either gives
        // the same final order. We chose newest-first sort + append-tail.
        for (found.items) |f| {
            const entry = try self.allocator.create(Entry);
            entry.* = .{ .addr = f.addr, .bytes_on_disk = f.bytes };
            try self.entries.put(f.addr, entry);
            self.lru.append(&entry.list_node);
            self.cur_bytes += f.bytes;
        }
    }

    fn evictDownTo(self: *Store, target: u64) !void {
        self.mtx.lock();
        defer self.mtx.unlock();
        try self.evictDownToLocked(target);
    }

    fn evictDownToLocked(self: *Store, target: u64) !void {
        while (self.cur_bytes > target) {
            const tail = self.lru.last orelse return;
            const entry = Entry.fromListNode(tail);

            const path = try self.pathFor(entry.addr);
            defer self.allocator.free(path);

            // Best-effort delete — if the file's already gone (e.g.
            // operator manually rm'd it), we still want to drop it
            // from the index so cur_bytes stays accurate.
            std.fs.cwd().deleteFile(path) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };

            self.lru.remove(&entry.list_node);
            _ = self.entries.remove(entry.addr);
            self.cur_bytes -|= entry.bytes_on_disk;
            self.allocator.destroy(entry);
        }
    }
};

fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Default store path: `$HOME/.zigbee/store/`. Caller owns the slice.
pub fn defaultStorePath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeEnv;
    return try std.fs.path.join(allocator, &.{ home, ".zigbee", "store" });
}

// ----------------------------- tests -----------------------------

test "store: round-trip put/get a single chunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const s = try Store.openOrCreate(std.testing.allocator, root, 1024 * 1024);
    defer s.deinit();

    const addr = [_]u8{0xAB} ** HASH_SIZE;
    const data = "hello world";
    try s.put(addr, data.len, data);

    const got = (try s.get(addr)) orelse return error.TestExpectedHit;
    defer got.deinit();
    try std.testing.expectEqual(@as(u64, data.len), got.span);
    try std.testing.expectEqualStrings(data, got.data);
}

test "store: miss on unknown address returns null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const s = try Store.openOrCreate(std.testing.allocator, root, 1024 * 1024);
    defer s.deinit();

    const addr = [_]u8{0xCD} ** HASH_SIZE;
    try std.testing.expectEqual(@as(?StoredChunk, null), try s.get(addr));
}

test "store: over-cap eviction removes oldest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    // Cap = 2 chunks worth (2 × (8 span + 64 payload) = 144 bytes).
    const s = try Store.openOrCreate(std.testing.allocator, root, 144);
    defer s.deinit();

    const data = [_]u8{0xAA} ** 64;

    // Insert three chunks with distinct addresses.
    var addr_a = [_]u8{0} ** HASH_SIZE;
    addr_a[0] = 0xA1;
    var addr_b = [_]u8{0} ** HASH_SIZE;
    addr_b[0] = 0xB2;
    var addr_c = [_]u8{0} ** HASH_SIZE;
    addr_c[0] = 0xC3;

    try s.put(addr_a, 64, &data);
    try s.put(addr_b, 64, &data);
    try s.put(addr_c, 64, &data);

    // A was the oldest — should have been evicted.
    try std.testing.expectEqual(@as(?StoredChunk, null), try s.get(addr_a));

    // B and C still present.
    const got_b = (try s.get(addr_b)) orelse return error.TestExpectedHit;
    defer got_b.deinit();
    const got_c = (try s.get(addr_c)) orelse return error.TestExpectedHit;
    defer got_c.deinit();
}

test "store: get bumps entry to MRU so it survives next eviction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    // Cap fits exactly two chunks of 72 bytes each.
    const s = try Store.openOrCreate(std.testing.allocator, root, 144);
    defer s.deinit();

    const data = [_]u8{0xEE} ** 64;

    var addr_a = [_]u8{0} ** HASH_SIZE;
    addr_a[0] = 0xA1;
    var addr_b = [_]u8{0} ** HASH_SIZE;
    addr_b[0] = 0xB2;
    var addr_c = [_]u8{0} ** HASH_SIZE;
    addr_c[0] = 0xC3;

    try s.put(addr_a, 64, &data);
    try s.put(addr_b, 64, &data);

    // Touch A — bumps it to MRU. B is now LRU.
    {
        const got = (try s.get(addr_a)) orelse return error.TestExpectedHit;
        got.deinit();
    }

    // Inserting C should evict B (LRU), not A.
    try s.put(addr_c, 64, &data);

    {
        const got_a = try s.get(addr_a);
        if (got_a) |x| x.deinit();
        try std.testing.expect(got_a != null);
    }
    try std.testing.expectEqual(@as(?StoredChunk, null), try s.get(addr_b));
    {
        const got_c = try s.get(addr_c);
        if (got_c) |x| x.deinit();
        try std.testing.expect(got_c != null);
    }
}

test "store: restart-resume re-loads existing chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const data = "persistence check";

    var addr = [_]u8{0} ** HASH_SIZE;
    addr[0] = 0x42;

    {
        const s1 = try Store.openOrCreate(std.testing.allocator, root, 1024 * 1024);
        defer s1.deinit();
        try s1.put(addr, data.len, data);
        try std.testing.expectEqual(@as(usize, 1), s1.entryCount());
    }

    {
        const s2 = try Store.openOrCreate(std.testing.allocator, root, 1024 * 1024);
        defer s2.deinit();
        try std.testing.expectEqual(@as(usize, 1), s2.entryCount());
        const got = (try s2.get(addr)) orelse return error.TestExpectedHit;
        defer got.deinit();
        try std.testing.expectEqualStrings(data, got.data);
    }
}

test "store: shrunken cap on reopen evicts down-to" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const data = [_]u8{0x55} ** 64;

    var addr_a = [_]u8{0} ** HASH_SIZE;
    addr_a[0] = 0xA1;
    var addr_b = [_]u8{0} ** HASH_SIZE;
    addr_b[0] = 0xB2;

    {
        const s1 = try Store.openOrCreate(std.testing.allocator, root, 1024);
        defer s1.deinit();
        try s1.put(addr_a, 64, &data);
        // Tiny sleep so b's mtime is strictly after a's — the test
        // depends on the scan's mtime-desc sort placing b ahead of a.
        std.Thread.sleep(15 * std.time.ns_per_ms);
        try s1.put(addr_b, 64, &data);
    }

    // Reopen with a cap that only fits one chunk. Newest (b) survives.
    {
        const s2 = try Store.openOrCreate(std.testing.allocator, root, 80);
        defer s2.deinit();
        try std.testing.expectEqual(@as(usize, 1), s2.entryCount());
        try std.testing.expect((try s2.get(addr_a)) == null);
        const got = (try s2.get(addr_b)) orelse return error.TestExpectedHit;
        defer got.deinit();
    }
}
