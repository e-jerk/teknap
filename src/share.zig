const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const transfer = @import("transfer.zig");
const util = @import("util.zig");
const owned = @import("owned.zig");

pub const SharedFile = struct {
    path: owned.String,
    display: owned.String,
    checksum: [32]u8,
    size: u64,
    bitrate: u32,
    freq: u32,
    seconds: u32,
    /// Non-MP3 OpenNap type (`audio`, `video`, …). Null → classic `add_file`.
    content_type: ?owned.String = null,

    pub fn deinit(self: *SharedFile) void {
        self.path.deinit();
        self.display.deinit();
        owned.clearOpt(&self.content_type);
    }
};

pub fn scanDir(
    gpa: std.mem.Allocator,
    io: Io,
    root: []const u8,
    out: *std.ArrayList(SharedFile),
) !usize {
    const opened = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return 0,
        else => return err,
    };
    var dir_guard = owned.DirGuard().init(opened, io);
    defer dir_guard.deinit();
    const dir = dir_guard.get();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var added: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = entry.path;
        var full = try owned.String.initFromSlice(gpa, root);
        errdefer full.deinit();
        try full.append("/");
        try full.append(rel);

        const stat = Io.Dir.cwd().statFile(io, full.slice(), .{}) catch {
            full.deinit();
            continue;
        };
        const hex = transfer.hashPrefix(io, Io.Dir.cwd(), full.slice()) catch {
            full.deinit();
            continue;
        };
        const mp3 = transfer.probeMp3(io, Io.Dir.cwd(), full.slice(), stat.size);
        var display = try napsterPath(gpa, full.slice());
        errdefer display.deinit();
        const content_type = try contentTypeForPath(gpa, rel);
        try out.append(gpa, .{
            .path = full,
            .display = display,
            .checksum = hex,
            .size = stat.size,
            .bitrate = mp3.bitrate,
            .freq = mp3.freq,
            .seconds = mp3.seconds,
            .content_type = content_type,
        });
        added += 1;
        if (added >= 5000) break;
    }
    return added;
}

fn napsterPath(gpa: std.mem.Allocator, unix: []const u8) !owned.String {
    const copy = try owned.String.initFromSlice(gpa, unix);
    for (copy.buffer.items) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    return copy;
}

pub fn findByRemote(shares: []const SharedFile, remote: []const u8) ?*const SharedFile {
    const want = util.basename(remote);
    for (shares) |*s| {
        if (std.mem.eql(u8, s.display.slice(), remote)) return s;
        if (std.mem.eql(u8, util.basename(s.path.slice()), want)) return s;
        if (std.mem.eql(u8, util.basename(s.display.slice()), want)) return s;
    }
    return null;
}

pub fn shareLine(s: SharedFile, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "\"{s}\" {s} {d} {d} {d} {d}", .{
        s.display.slice(),
        s.checksum,
        s.size,
        s.bitrate,
        s.freq,
        s.seconds,
    });
}

/// OpenNap `client_share_file` (10300): `"name" size hash type`
pub fn shareFileLine(s: SharedFile, typ: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "\"{s}\" {d} {s} {s}", .{
        s.display.slice(),
        s.size,
        s.checksum,
        typ,
    });
}

pub const Announce = struct {
    cmd: protocol.Cmd,
    payload: []const u8,
};

pub fn announce(s: SharedFile, buf: []u8) !Announce {
    if (s.content_type) |t| {
        return .{
            .cmd = .share_file,
            .payload = try shareFileLine(s, t.slice(), buf),
        };
    }
    return .{
        .cmd = .add_file,
        .payload = try shareLine(s, buf),
    };
}

fn contentTypeForPath(gpa: std.mem.Allocator, path: []const u8) !?owned.String {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    if (dot + 1 >= path.len) return null;
    const ext = path[dot + 1 ..];
    const typ: []const u8 = blk: {
        if (util.eqlIgnoreCase(ext, "mp3")) return null;
        if (matches(ext, &.{ "ogg", "flac", "wav", "wma", "m4a", "aac", "opus" })) break :blk "audio";
        if (matches(ext, &.{ "mp4", "mkv", "avi", "mov", "webm", "m4v" })) break :blk "video";
        if (matches(ext, &.{ "jpg", "jpeg", "png", "gif", "webp", "bmp" })) break :blk "image";
        if (matches(ext, &.{ "txt", "md", "html", "htm", "rtf" })) break :blk "text";
        if (matches(ext, &.{ "zip", "gz", "bz2", "xz", "7z", "rar", "exe", "dmg", "pkg", "deb" })) break :blk "application";
        return null;
    };
    return try owned.String.initFromSlice(gpa, typ);
}

fn matches(ext: []const u8, list: []const []const u8) bool {
    for (list) |e| {
        if (util.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}
