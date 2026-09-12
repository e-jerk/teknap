const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const util = @import("util.zig");
const md5 = @import("md5.zig");
const owned = @import("owned.zig");

pub const Kind = enum { download, upload };

pub const State = enum {
    connecting,
    wait_one,
    send_get,
    read_size,
    transfer,
    done,
    failed,
};

pub const Transfer = struct {
    kind: Kind,
    state: State = .connecting,
    nick: owned.String,
    filename: owned.String,
    remote_path: owned.String,
    checksum: owned.String,
    size: u64 = 0,
    offset: u64 = 0,
    received: u64 = 0,
    fd: ?std.posix.fd_t = null,
    file: ?owned.FileGuard() = null,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    port: u16 = 0,
    buf: owned.String,
    notified_start: bool = false,
    firewalled: bool = false,

    pub fn deinit(self: *Transfer, _: std.mem.Allocator, _: Io) void {
        if (self.fd) |fd| {
            util.closeFd(fd);
            self.fd = null;
        }
        if (self.file) |*g| {
            g.deinit();
            self.file = null;
        }
        self.nick.deinit();
        self.filename.deinit();
        self.remote_path.deinit();
        self.checksum.deinit();
        self.buf.deinit();
    }
};

pub fn localPath(gpa: std.mem.Allocator, download_dir: []const u8, remote: []const u8) ![]u8 {
    var name_buf: [256]u8 = undefined;
    const name = util.sanitizeFilename(remote, &name_buf);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ download_dir, name });
}

pub fn startDownload(
    io: Io,
    t: *Transfer,
) !void {
    const addr: Io.net.IpAddress = .{ .ip4 = .{ .bytes = t.ip, .port = t.port } };
    const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch {
        t.state = .failed;
        return error.ConnectFailed;
    };
    t.fd = stream.socket.handle;
    util.setNonblock(stream.socket.handle);
    t.state = .wait_one;
}

pub fn sendGetRequest(t: *Transfer, mynick: []const u8) !void {
    const fd = t.fd orelse return error.NoSocket;
    var payload_buf: [2048]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{s} \"{s}\" {d}", .{
        mynick,
        t.remote_path.slice(),
        t.offset,
    });
    try util.writeFd(fd, "GET");
    try util.writeFd(fd, payload);
    t.state = .read_size;
}

pub fn sendSendHeader(t: *Transfer, mynick: []const u8) !void {
    const fd = t.fd orelse return error.NoSocket;
    var payload_buf: [2048]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{s} \"{s}\" {d}", .{
        mynick,
        t.remote_path.slice(),
        t.size,
    });
    try util.writeFd(fd, "SEND");
    try util.writeFd(fd, payload);
}

pub fn writeOne(fd: std.posix.fd_t) !void {
    try util.writeFd(fd, "1");
}

/// Read incoming peer handshake. Returns command tag if complete.
pub const PeerHello = enum { get, send, getlist, sendlist, one, unknown };

pub fn peekHello(fd: std.posix.fd_t, scratch: *[16]u8) !?struct { tag: PeerHello, consumed: usize } {
    const n = std.posix.read(fd, scratch) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    if (n == 0) return error.EndOfStream;
    const got = scratch[0..n];
    if (got.len >= 1 and got[0] == '1') return .{ .tag = .one, .consumed = 1 };
    if (std.mem.startsWith(u8, got, "GETL")) return .{ .tag = .getlist, .consumed = 7 };
    if (std.mem.startsWith(u8, got, "SENDL")) return .{ .tag = .sendlist, .consumed = 5 };
    if (std.mem.startsWith(u8, got, "GET")) return .{ .tag = .get, .consumed = 3 };
    if (std.mem.startsWith(u8, got, "SEND")) return .{ .tag = .send, .consumed = 4 };
    return .{ .tag = .unknown, .consumed = n };
}

pub fn parsePeerGet(rest: []const u8) ?struct { nick: []const u8, filename: []const u8, offset: u64 } {
    var p = protocol.Parser.init(rest);
    const nick = p.next() orelse return null;
    const filename = p.nextQuoted() orelse return null;
    const offset = protocol.parseU64(p.next() orelse "0") orelse 0;
    return .{ .nick = nick, .filename = filename, .offset = offset };
}

pub fn parsePeerSend(rest: []const u8) ?struct { nick: []const u8, filename: []const u8, size: u64 } {
    var p = protocol.Parser.init(rest);
    const nick = p.next() orelse return null;
    const filename = p.nextQuoted() orelse return null;
    const size = protocol.parseU64(p.next() orelse "0") orelse 0;
    return .{ .nick = nick, .filename = filename, .size = size };
}

pub fn hashPrefix(io: Io, dir: Io.Dir, path: []const u8) ![32]u8 {
    const opened = try dir.openFile(io, path, .{});
    var guard = owned.FileGuard().init(opened, io);
    defer guard.deinit();
    var reader = guard.reader();
    var hasher = md5.Md5{};
    var remaining: usize = protocol.napster_hash_bytes;
    var tmp: [4096]u8 = undefined;
    while (remaining > 0) {
        const want = @min(remaining, tmp.len);
        const n = reader.interface.readSliceShort(tmp[0..want]) catch break;
        if (n == 0) break;
        hasher.update(tmp[0..n]);
        remaining -= n;
    }
    const digest = hasher.final();
    var hex: [32]u8 = undefined;
    _ = md5.Md5.hex(digest, &hex);
    return hex;
}

/// Crude MPEG frame header probe for bitrate / sample rate / duration.
pub const Mp3Info = struct {
    bitrate: u32 = 128,
    freq: u32 = 44100,
    seconds: u32 = 0,
};

const bitrate_table = [16]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
const freq_table = [4]u32{ 44100, 48000, 32000, 0 };

pub fn probeMp3(io: Io, dir: Io.Dir, path: []const u8, filesize: u64) Mp3Info {
    var info: Mp3Info = .{};
    const opened = dir.openFile(io, path, .{}) catch return info;
    var guard = owned.FileGuard().init(opened, io);
    defer guard.deinit();
    var reader = guard.reader();
    var chunk: [1024]u8 = undefined;
    const n = reader.interface.readSliceShort(&chunk) catch return info;
    var off: usize = 0;
    if (n >= 10 and std.mem.eql(u8, chunk[0..3], "ID3")) {
        const skip = 10 + (@as(usize, chunk[6] & 0x7f) << 21) + (@as(usize, chunk[7] & 0x7f) << 14) +
            (@as(usize, chunk[8] & 0x7f) << 7) + (chunk[9] & 0x7f);
        if (skip < n) off = skip;
    }
    if (off + 4 > n) return info;
    const frame = chunk[off..][0..4];
    if (frame[0] != 0xff or (frame[1] & 0xe0) != 0xe0) return info;
    const br_idx = (frame[2] >> 4) & 0x0f;
    const sr_idx = (frame[2] >> 2) & 0x03;
    info.bitrate = bitrate_table[br_idx];
    info.freq = freq_table[sr_idx];
    if (info.bitrate > 0) {
        info.seconds = @intCast(@min(filesize * 8 / (@as(u64, info.bitrate) * 1000), std.math.maxInt(u32)));
    }
    return info;
}
