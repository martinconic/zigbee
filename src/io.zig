//! Process-wide blocking I/O provider.
//!
//! Zig 0.16 ("Writergate" + the `Io` interface) routes every filesystem,
//! socket, and synchronisation operation through a `std.Io` value that must
//! be passed explicitly. zigbee is a single blocking daemon: one shared
//! `std.Io.Threaded` is sufficient and avoids threading an `io` parameter
//! through every function signature. Call sites that perform I/O fetch it
//! here with `io.get()`.
//!
//! `Threaded` only uses its backing allocator for `io.async` / concurrent
//! spawning, which zigbee does not use (it spawns OS threads directly via
//! `std.Thread`), so `page_allocator` is a safe, threadsafe backing store.
//!
//! Initialisation is lazy so unit tests — which never call `main()` — get a
//! working `Io` on first use. `main()` calls `get()` once at startup, before
//! any worker threads exist, so the unguarded first-init is race-free in
//! practice (the Zig test runner is single-threaded at test entry too).

const std = @import("std");

var threaded: std.Io.Threaded = undefined;
var ready: bool = false;

/// Returns the process-wide blocking `Io`. Lazily initialises on first call.
/// The returned value points back at the stable global `threaded`, so it is
/// cheap to call repeatedly and safe to copy.
pub fn get() std.Io {
    if (!ready) {
        threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        ready = true;
    }
    return threaded.io();
}

/// Fill `buffer` with cryptographically secure random bytes. Replaces
/// 0.15's `std.crypto.random.bytes`, removed in 0.16. `Io.random` is seeded
/// from the OS CSPRNG (`getrandom`) on real targets and is infallible.
pub fn randomBytes(buffer: []u8) void {
    get().random(buffer);
}

/// Blocking sleep for `ns` nanoseconds. Replaces 0.15's `std.Thread.sleep`,
/// removed in 0.16. Uses the monotonic (`.awake`) clock; cancellation is
/// ignored (zigbee never cancels these blocking waits).
pub fn sleepNs(ns: u64) void {
    get().sleep(std.Io.Duration.fromNanoseconds(ns), .awake) catch {};
}

/// Wall-clock seconds since the Unix epoch. Replaces 0.15's
/// `std.time.timestamp`. Only for values peers compare against their own
/// clocks (e.g. the bzz address timestamp); use `nowNs` for intervals.
pub fn unixSeconds() i64 {
    return std.Io.Timestamp.now(get(), .real).toSeconds();
}

/// Monotonic timestamp in nanoseconds. Replaces 0.15's `std.time.nanoTimestamp`,
/// removed in 0.16. Uses the monotonic (`.awake`) clock — correct for interval
/// timing (round-trips, manage-tick deltas).
pub fn nowNs() i128 {
    return std.Io.Timestamp.now(get(), .awake).nanoseconds;
}
