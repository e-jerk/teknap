//! Resolve NAPGPG / a mounted homedir / the system default GnuPG secret key.

const std = @import("std");
const Io = std.Io;
const pgp = @import("pgp.zig");

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: Io,
    enabled: bool = false,
    seed: ?[32]u8 = null,
    x_seed: ?[32]u8 = null,
    label: []const u8 = "off",

    pub fn deinit(_: *Store) void {}

    pub fn signHex(self: *Store, data: []const u8) ![]u8 {
        const seed = self.seed orelse return error.GpgDisabled;
        const sig = try pgp.signRaw(seed, data);
        const out = try self.gpa.alloc(u8, 128);
        _ = pgp.hexBytes(&sig, out);
        return out;
    }

    pub fn publicHex(self: *Store, buf: []u8) ![]const u8 {
        const seed = self.seed orelse return error.GpgDisabled;
        const ed = try pgp.publicEd(seed);
        var x: ?[32]u8 = null;
        if (self.x_seed) |xs| {
            x = std.crypto.dh.X25519.recoverPublicKey(xs) catch null;
        }
        return pgp.encodeKeyHex(&ed, x, buf);
    }
};

/// `spec` is NAPGPG / `--gpg`: empty/`default` = system key, `0`/`off` = disabled,
/// hex seed, armored secret, file path, GnuPG homedir, or key id / email.
pub fn load(
    gpa: std.mem.Allocator,
    io: Io,
    spec: ?[]const u8,
    passphrase: []const u8,
    home: []const u8,
) !Store {
    var store: Store = .{ .gpa = gpa, .io = io };
    const raw = spec orelse "default";
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or isOff(trimmed)) return store;

    if (pgp.parseHexSeed(trimmed)) |pair| {
        store.enabled = true;
        store.seed = pair.ed;
        store.x_seed = pair.x;
        store.label = "hex seed";
        return store;
    }

    if (std.mem.indexOf(u8, trimmed, "BEGIN PGP") != null) {
        return fromMaterial(&store, trimmed, passphrase, "env/armored");
    }

    if (looksLikePath(trimmed)) {
        const path = try expandPath(gpa, trimmed, home);
        defer gpa.free(path);
        if (isDir(io, path)) {
            return fromGpg(&store, path, null, passphrase, "mounted homedir");
        }
        const body = readFile(gpa, io, path) catch return store;
        defer gpa.free(body);
        if (pgp.parseHexSeed(std.mem.trim(u8, body, " \t\r\n"))) |pair| {
            store.enabled = true;
            store.seed = pair.ed;
            store.x_seed = pair.x;
            store.label = "file seed";
            return store;
        }
        return fromMaterial(&store, body, passphrase, "file");
    }

    const key_id: ?[]const u8 = if (std.mem.eql(u8, trimmed, "default")) null else trimmed;
    const label: []const u8 = if (key_id == null) "system default" else "gpg key id";
    return fromGpg(&store, null, key_id, passphrase, label);
}

fn fromMaterial(store: *Store, src: []const u8, passphrase: []const u8, label: []const u8) Store {
    if (pgp.extractEdSeed(src, passphrase)) |seed| {
        store.enabled = true;
        store.seed = seed;
        store.label = label;
    }
    return store.*;
}

fn fromGpg(
    store: *Store,
    homedir: ?[]const u8,
    key_id: ?[]const u8,
    passphrase: []const u8,
    label: []const u8,
) Store {
    if (readAgentSeed(store, homedir, key_id)) |seed| {
        store.enabled = true;
        store.seed = seed;
        store.label = label;
        return store.*;
    }
    const armored = gpgExportSecret(store, homedir, key_id) orelse return store.*;
    defer store.gpa.free(armored);
    return fromMaterial(store, armored, passphrase, label);
}

fn gpgExportSecret(store: *Store, homedir: ?[]const u8, key_id: ?[]const u8) ?[]u8 {
    var argv_buf: [10][]const u8 = undefined;
    var n: usize = 0;
    argv_buf[n] = "gpg";
    n += 1;
    n = addHome(homedir, &argv_buf, n);
    argv_buf[n] = "--batch";
    n += 1;
    argv_buf[n] = "--armor";
    n += 1;
    argv_buf[n] = "--export-secret-keys";
    n += 1;
    if (key_id) |id| {
        argv_buf[n] = id;
        n += 1;
    }
    const result = std.process.run(store.gpa, store.io, .{
        .argv = argv_buf[0..n],
        .stdout_limit = .limited(1 << 16),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer store.gpa.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) {
            store.gpa.free(result.stdout);
            return null;
        },
        else => {
            store.gpa.free(result.stdout);
            return null;
        },
    }
    if (std.mem.indexOf(u8, result.stdout, "BEGIN PGP") == null) {
        store.gpa.free(result.stdout);
        return null;
    }
    return result.stdout;
}

fn readAgentSeed(store: *Store, homedir: ?[]const u8, key_id: ?[]const u8) ?[32]u8 {
    const grip = firstEdKeygrip(store, homedir, key_id) orelse return null;
    defer store.gpa.free(grip);
    var cmd_buf: [80]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "READKEY {s}", .{grip}) catch return null;
    var argv_buf: [8][]const u8 = undefined;
    var n: usize = 0;
    argv_buf[n] = "gpg-connect-agent";
    n += 1;
    n = addHome(homedir, &argv_buf, n);
    argv_buf[n] = cmd;
    n += 1;
    argv_buf[n] = "/bye";
    n += 1;
    const result = std.process.run(store.gpa, store.io, .{
        .argv = argv_buf[0..n],
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(2048),
    }) catch return null;
    defer store.gpa.free(result.stdout);
    defer store.gpa.free(result.stderr);
    return pgp.extractEdSeed(result.stdout, "");
}

fn firstEdKeygrip(store: *Store, homedir: ?[]const u8, key_id: ?[]const u8) ?[]u8 {
    var argv_buf: [12][]const u8 = undefined;
    var n: usize = 0;
    argv_buf[n] = "gpg";
    n += 1;
    n = addHome(homedir, &argv_buf, n);
    argv_buf[n] = "--batch";
    n += 1;
    argv_buf[n] = "--with-colons";
    n += 1;
    argv_buf[n] = "--with-keygrip";
    n += 1;
    argv_buf[n] = "--list-secret-keys";
    n += 1;
    if (key_id) |id| {
        argv_buf[n] = id;
        n += 1;
    }
    const result = std.process.run(store.gpa, store.io, .{
        .argv = argv_buf[0..n],
        .stdout_limit = .limited(16384),
        .stderr_limit = .limited(2048),
    }) catch return null;
    defer store.gpa.free(result.stdout);
    defer store.gpa.free(result.stderr);
    return pickEdKeygrip(store.gpa, result.stdout);
}

fn pickEdKeygrip(gpa: std.mem.Allocator, listing: []const u8) ?[]u8 {
    var want_grip = false;
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "sec:") or std.mem.startsWith(u8, line, "ssb:")) {
            want_grip = isEdColon(line);
            continue;
        }
        if (want_grip and std.mem.startsWith(u8, line, "grp:")) {
            var f = std.mem.splitScalar(u8, line, ':');
            _ = f.next();
            var i: usize = 1;
            while (f.next()) |field| : (i += 1) {
                if (i == 9 and field.len >= 40) {
                    return gpa.dupe(u8, field[0..40]) catch return null;
                }
            }
        }
    }
    return null;
}

fn isEdColon(line: []const u8) bool {
    var f = std.mem.splitScalar(u8, line, ':');
    _ = f.next();
    _ = f.next();
    _ = f.next();
    const algo = f.next() orelse return false;
    return std.mem.eql(u8, algo, "22") or std.mem.eql(u8, algo, "27") or
        std.mem.indexOf(u8, line, "ed25519") != null;
}

fn addHome(homedir: ?[]const u8, argv: [][]const u8, start: usize) usize {
    var n = start;
    if (homedir) |h| {
        argv[n] = "--homedir";
        n += 1;
        argv[n] = h;
        n += 1;
    }
    return n;
}

fn isOff(s: []const u8) bool {
    return std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "off") or
        std.ascii.eqlIgnoreCase(s, "none") or std.ascii.eqlIgnoreCase(s, "false");
}

fn looksLikePath(s: []const u8) bool {
    return s[0] == '/' or s[0] == '.' or s[0] == '~' or
        std.mem.indexOfScalar(u8, s, '/') != null;
}

fn expandPath(gpa: std.mem.Allocator, path: []const u8, home: []const u8) ![]u8 {
    if (path.len >= 2 and path[0] == '~' and path[1] == '/') {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, path[2..] });
    }
    if (std.mem.eql(u8, path, "~")) return gpa.dupe(u8, home);
    return gpa.dupe(u8, path);
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn readFile(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
}

test "hex seed loads without gpg" {
    const seed = "01" ** 32;
    var store = try load(std.testing.allocator, std.testing.io, seed, "", "/tmp");
    defer store.deinit();
    try std.testing.expect(store.enabled);
    try std.testing.expect(store.seed != null);
    const sig = try store.signHex("hello");
    defer std.testing.allocator.free(sig);
    try std.testing.expectEqual(@as(usize, 128), sig.len);
}

test "off disables gpg" {
    var store = try load(std.testing.allocator, std.testing.io, "off", "", "/tmp");
    defer store.deinit();
    try std.testing.expect(!store.enabled);
}
