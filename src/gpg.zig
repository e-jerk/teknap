//! Resolve NAPGPG / a mounted homedir / the system default GnuPG secret key.
//!
//! Never run `gpg --export-secret-keys` without a key id. That asks pinentry
//! for every passphrase-protected secret, including old RSA keys.

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

const EdRef = struct {
    fpr: []u8,
    grip: []u8,

    fn deinit(self: EdRef, gpa: std.mem.Allocator) void {
        gpa.free(self.fpr);
        gpa.free(self.grip);
    }
};

/// `spec` is NAPGPG / `--gpg`: empty/`default` = cached system Ed25519 key,
/// `0`/`off` = disabled, hex seed, armored secret, file path, GnuPG homedir,
/// or key id / email (may unlock that one key).
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
    const keys = resolveEdKeys(store, homedir, key_id) orelse return store.*;
    defer freeEdKeys(store.gpa, keys);
    if (keys.len == 0) return store.*;

    const implicit = key_id == null;
    if (implicit and passphrase.len == 0) {
        for (keys) |key| {
            if (!agentKeyCached(store, homedir, key.grip)) continue;
            if (readAgentByGrip(store, homedir, key.grip)) |seed| {
                store.enabled = true;
                store.seed = seed;
                store.label = label;
                return store.*;
            }
        }
        return store.*;
    }

    const key = keys[0];
    if (passphrase.len != 0) {
        if (gpgExportSecret(store, homedir, key.fpr, passphrase)) |armored| {
            defer store.gpa.free(armored);
            return fromMaterial(store, armored, passphrase, label);
        }
    }

    if (readAgentByGrip(store, homedir, key.grip)) |seed| {
        store.enabled = true;
        store.seed = seed;
        store.label = label;
    }
    return store.*;
}

fn gpgExportSecret(
    store: *Store,
    homedir: ?[]const u8,
    key_id: []const u8,
    passphrase: []const u8,
) ?[]u8 {
    var argv_buf: [16][]const u8 = undefined;
    var n: usize = 0;
    argv_buf[n] = "gpg";
    n += 1;
    n = addHome(homedir, &argv_buf, n);
    argv_buf[n] = "--batch";
    n += 1;
    argv_buf[n] = "--yes";
    n += 1;
    argv_buf[n] = "--pinentry-mode";
    n += 1;
    argv_buf[n] = "loopback";
    n += 1;
    if (passphrase.len != 0) {
        argv_buf[n] = "--passphrase";
        n += 1;
        argv_buf[n] = passphrase;
        n += 1;
    }
    argv_buf[n] = "--armor";
    n += 1;
    argv_buf[n] = "--export-secret-keys";
    n += 1;
    argv_buf[n] = key_id;
    n += 1;
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

fn readAgentByGrip(store: *Store, homedir: ?[]const u8, grip: []const u8) ?[32]u8 {
    var cmd_buf: [80]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "READKEY {s}", .{grip}) catch return null;
    const stdout = agentCmd(store, homedir, cmd) orelse return null;
    defer store.gpa.free(stdout);
    return pgp.extractEdSeed(stdout, "");
}

fn agentKeyCached(store: *Store, homedir: ?[]const u8, grip: []const u8) bool {
    var cmd_buf: [80]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "KEYINFO {s}", .{grip}) catch return false;
    const stdout = agentCmd(store, homedir, cmd) orelse return false;
    defer store.gpa.free(stdout);
    return keyinfoCached(stdout);
}

fn agentCmd(store: *Store, homedir: ?[]const u8, cmd: []const u8) ?[]u8 {
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
    store.gpa.free(result.stderr);
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
    return result.stdout;
}

fn resolveEdKeys(store: *Store, homedir: ?[]const u8, key_id: ?[]const u8) ?[]EdRef {
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
    return pickEdKeys(store.gpa, result.stdout);
}

fn freeEdKeys(gpa: std.mem.Allocator, keys: []EdRef) void {
    for (keys) |k| k.deinit(gpa);
    gpa.free(keys);
}

fn pickEdKeys(gpa: std.mem.Allocator, listing: []const u8) ?[]EdRef {
    var secs: std.ArrayList(EdRef) = .empty;
    var ssbs: std.ArrayList(EdRef) = .empty;
    errdefer {
        for (secs.items) |k| k.deinit(gpa);
        for (ssbs.items) |k| k.deinit(gpa);
        secs.deinit(gpa);
        ssbs.deinit(gpa);
    }

    var want_ed = false;
    var want_sec = false;
    var fpr: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "sec:") or std.mem.startsWith(u8, line, "ssb:")) {
            want_ed = isEdColon(line);
            want_sec = std.mem.startsWith(u8, line, "sec:");
            fpr = null;
            continue;
        }
        if (!want_ed) continue;
        if (std.mem.startsWith(u8, line, "fpr:")) {
            fpr = colonField(line, 9);
            continue;
        }
        if (!std.mem.startsWith(u8, line, "grp:")) continue;
        const grip = colonField(line, 9) orelse continue;
        const fp = fpr orelse continue;
        if (fp.len < 40 or grip.len < 40) continue;
        const fpr_copy = gpa.dupe(u8, fp) catch continue;
        const grip_copy = gpa.dupe(u8, grip[0..40]) catch {
            gpa.free(fpr_copy);
            continue;
        };
        const ref = EdRef{ .fpr = fpr_copy, .grip = grip_copy };
        const dest = if (want_sec) &secs else &ssbs;
        dest.append(gpa, ref) catch {
            ref.deinit(gpa);
            continue;
        };
        want_ed = false;
    }

    const total = secs.items.len + ssbs.items.len;
    if (total == 0) {
        secs.deinit(gpa);
        ssbs.deinit(gpa);
        return null;
    }
    const out = gpa.alloc(EdRef, total) catch {
        for (secs.items) |k| k.deinit(gpa);
        for (ssbs.items) |k| k.deinit(gpa);
        secs.deinit(gpa);
        ssbs.deinit(gpa);
        return null;
    };
    @memcpy(out[0..secs.items.len], secs.items);
    @memcpy(out[secs.items.len..], ssbs.items);
    secs.deinit(gpa);
    ssbs.deinit(gpa);
    return out;
}

fn pickEdKey(gpa: std.mem.Allocator, listing: []const u8) ?EdRef {
    const keys = pickEdKeys(gpa, listing) orelse return null;
    const first = keys[0];
    if (keys.len > 1) {
        for (keys[1..]) |k| k.deinit(gpa);
    }
    gpa.free(keys);
    return first;
}

fn colonField(line: []const u8, index: usize) ?[]const u8 {
    var f = std.mem.splitScalar(u8, line, ':');
    var i: usize = 0;
    while (f.next()) |field| : (i += 1) {
        if (i == index and field.len != 0) return field;
    }
    return null;
}

fn isEdColon(line: []const u8) bool {
    const algo = colonField(line, 3) orelse return false;
    return std.mem.eql(u8, algo, "22") or std.mem.eql(u8, algo, "27") or
        std.mem.indexOf(u8, line, "ed25519") != null;
}

fn keyinfoCached(stdout: []const u8) bool {
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "S KEYINFO ")) continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        while (f.next()) |tok| {
            if (!tokenLooksLikeFlags(tok)) continue;
            if (std.mem.indexOfScalar(u8, tok, 'C') != null) return true;
        }
    }
    return false;
}

fn tokenLooksLikeFlags(tok: []const u8) bool {
    if (tok.len == 0 or tok.len > 8) return false;
    for (tok) |c| {
        switch (c) {
            'C', 'D', 'P', 'S', 'R', '-' => {},
            else => return false,
        }
    }
    return true;
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

test "pick Ed25519 primary over RSA and subkey" {
    const listing =
        \\sec:u:4096:1:AAAABBBBCCCCDDDD:1000:::
        \\fpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:
        \\grp:::::::::1111111111111111111111111111111111111111:
        \\ssb:u:255:22:EEEEFFFF00001111:1001:::
        \\fpr:::::::::BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB:
        \\grp:::::::::2222222222222222222222222222222222222222:
        \\sec:u:255:22:1234567890ABCDEF:2000:::
        \\fpr:::::::::CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC:
        \\grp:::::::::3333333333333333333333333333333333333333:
        \\
    ;
    const key = pickEdKey(std.testing.allocator, listing) orelse return error.TestExpectedEqual;
    defer key.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", key.fpr);
    try std.testing.expectEqualStrings("3333333333333333333333333333333333333333", key.grip);
}

test "pick Ed25519 subkey when that is all there is" {
    const listing =
        \\sec:u:4096:1:AAAABBBBCCCCDDDD:1000:::
        \\fpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:
        \\grp:::::::::1111111111111111111111111111111111111111:
        \\ssb:u:255:22:EEEEFFFF00001111:1001:::
        \\fpr:::::::::BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB:
        \\grp:::::::::2222222222222222222222222222222222222222:
        \\
    ;
    const key = pickEdKey(std.testing.allocator, listing) orelse return error.TestExpectedEqual;
    defer key.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", key.fpr);
    try std.testing.expectEqualStrings("2222222222222222222222222222222222222222", key.grip);
}

test "keyinfo cached flag" {
    try std.testing.expect(keyinfoCached("S KEYINFO ABC D - - - C - - -\nOK\n"));
    try std.testing.expect(keyinfoCached("S KEYINFO ABC D - - - PC - - -\nOK\n"));
    try std.testing.expect(!keyinfoCached("S KEYINFO ABC D - - - P - - -\nOK\n"));
    try std.testing.expect(!keyinfoCached("ERR 67108949 No secret key\n"));
}
