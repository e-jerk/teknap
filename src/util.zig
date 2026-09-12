const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");

extern "c" fn close(fd: std.posix.fd_t) c_int;

pub fn closeFd(fd: std.posix.fd_t) void {
    _ = close(fd);
}

pub fn writeFd(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = std.c.write(fd, data[written..].ptr, data.len - written);
        if (n < 0) {
            const err: std.posix.E = @enumFromInt(std.c._errno().*);
            if (err == .INTR) continue;
            if (err == .AGAIN) return error.WouldBlock;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

pub fn setNonblock(fd: std.posix.fd_t) void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL);
    if (flags < 0) return;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true })));
}

/// Accept on a non-blocking listen fd. Zig's `Io.net.Server.accept` panics on
/// `EAGAIN` in debug builds, so the poll loop must use libc accept.
pub fn acceptNonblock(listen_fd: std.posix.fd_t) ?std.posix.fd_t {
    const fd = std.c.accept(listen_fd, null, null);
    if (fd < 0) return null;
    return fd;
}

pub fn termSize() struct { rows: u16, cols: u16 } {
    var wsz: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (rc == 0 and wsz.row > 0 and wsz.col > 0) {
        return .{ .rows = wsz.row, .cols = wsz.col };
    }
    return .{ .rows = 24, .cols = 80 };
}

pub fn formatSize(n: u64, buf: *[32]u8) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n >= 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.2}G", .{f / (1024.0 * 1024.0 * 1024.0)}) catch "?";
    }
    if (n >= 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1}M", .{f / (1024.0 * 1024.0)}) catch "?";
    }
    if (n >= 1024) {
        return std.fmt.bufPrint(buf, "{d:.0}K", .{f / 1024.0}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}B", .{n}) catch "?";
}

pub fn formatDuration(secs: u32, buf: *[16]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ secs / 60, secs % 60 }) catch "?";
}

pub fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| {
        return path[i + 1 ..];
    }
    return path;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn startsWithIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(hay, needle);
}

pub fn isLocalHost(host: []const u8) bool {
    return eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]");
}

/// Only loopback skips verify. `.local` and LAN names use the system CA (`-k` to skip).
pub fn skipTlsVerify(host: []const u8) bool {
    return isLocalHost(host);
}

pub fn formatIpAddress(addr: Io.net.IpAddress, buf: *[64]u8) []const u8 {
    return switch (addr) {
        .ip4 => |a| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{
            a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3], a.port,
        }) catch "?",
        .ip6 => |a| std.fmt.bufPrint(buf, "[{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}]:{d}", .{
            a.bytes[0],  a.bytes[1],  a.bytes[2],  a.bytes[3],
            a.bytes[4],  a.bytes[5],  a.bytes[6],  a.bytes[7],
            a.bytes[8],  a.bytes[9],  a.bytes[10], a.bytes[11],
            a.bytes[12], a.bytes[13], a.bytes[14], a.bytes[15],
            a.port,
        }) catch "?",
    };
}

pub fn collectAddresses(io: Io, host: []const u8, port: u16, dest: *[8]Io.net.IpAddress) usize {
    var n: usize = 0;
    const append = struct {
        fn append(d: *[8]Io.net.IpAddress, count: *usize, addr: Io.net.IpAddress) void {
            if (count.* >= d.len) return;
            d[count.*] = addr;
            count.* += 1;
        }
    }.append;

    if (eqlIgnoreCase(host, "localhost")) {
        append(dest, &n, .{ .ip4 = .loopback(port) });
        append(dest, &n, .{ .ip6 = .loopback(port) });
        return n;
    }
    if (Io.net.Ip4Address.parse(host, port)) |ip4| {
        append(dest, &n, .{ .ip4 = ip4 });
        return n;
    } else |_| {}
    if (std.mem.startsWith(u8, host, "[") and std.mem.endsWith(u8, host, "]")) {
        if (Io.net.Ip6Address.parse(host[1 .. host.len - 1], port)) |ip6| {
            append(dest, &n, .{ .ip6 = ip6 });
            return n;
        } else |_| {}
    } else if (Io.net.Ip6Address.parse(host, port)) |ip6| {
        append(dest, &n, .{ .ip6 = ip6 });
        return n;
    } else |_| {}

    const name = Io.net.HostName.init(host) catch return n;
    var storage: [16]Io.net.HostName.LookupResult = undefined;
    var queue = Io.Queue(Io.net.HostName.LookupResult).init(&storage);
    name.lookup(io, &queue, .{ .port = port }) catch return n;
    var out: [16]Io.net.HostName.LookupResult = undefined;
    const got = queue.getUncancelable(io, &out, 0) catch 0;
    for (out[0..got]) |item| {
        switch (item) {
            .address => |addr| append(dest, &n, addr),
            .canonical_name => {},
        }
    }
    return n;
}

pub fn connectTcp(io: Io, host: []const u8, port: u16) !struct { stream: Io.net.Stream, addr: Io.net.IpAddress } {
    var addrs: [8]Io.net.IpAddress = undefined;
    const n = collectAddresses(io, host, port, &addrs);
    if (n == 0) return error.UnknownHostName;
    var last_err: anyerror = error.ConnectionRefused;
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        for (addrs[0..n]) |addr| {
            const ip4 = switch (addr) {
                .ip4 => true,
                else => false,
            };
            if (ip4 != (pass == 0)) continue;
            if (addr.connect(io, .{ .mode = .stream, .protocol = .tcp })) |stream| {
                return .{ .stream = stream, .addr = addr };
            } else |err| {
                last_err = err;
            }
        }
    }
    return last_err;
}

pub fn resolveHost(io: Io, host: []const u8, port: u16) !Io.net.IpAddress {
    var addrs: [8]Io.net.IpAddress = undefined;
    const n = collectAddresses(io, host, port, &addrs);
    if (n == 0) return error.UnknownHostName;
    return addrs[0];
}

pub fn expandHome(gpa: std.mem.Allocator, home: []const u8, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '~') {
        if (path.len == 1 or path[1] == '/') {
            const rest = if (path.len > 1) path[1..] else "";
            return std.fmt.allocPrint(gpa, "{s}{s}", .{ home, rest });
        }
    }
    return gpa.dupe(u8, path);
}

pub const ServerSpec = struct {
    host: []const u8,
    port: u16,
    nick: ?[]const u8 = null,
    password: ?[]const u8 = null,
    meta: bool,
    tls: bool = false,
    irc: bool = false,
};

const Scheme = enum { tls, irc, plain, https, none };

fn stripScheme(spec: []const u8) struct { rest: []const u8, scheme: Scheme } {
    const pairs = [_]struct { prefix: []const u8, scheme: Scheme }{
        .{ .prefix = "https://", .scheme = .https },
        .{ .prefix = "https:", .scheme = .https },
        .{ .prefix = "tls://", .scheme = .tls },
        .{ .prefix = "naps://", .scheme = .tls },
        .{ .prefix = "irc://", .scheme = .irc },
        .{ .prefix = "plain://", .scheme = .plain },
        .{ .prefix = "tls:", .scheme = .tls },
        .{ .prefix = "naps:", .scheme = .tls },
        .{ .prefix = "irc:", .scheme = .irc },
        .{ .prefix = "plain:", .scheme = .plain },
    };
    for (pairs) |p| {
        if (std.ascii.startsWithIgnoreCase(spec, p.prefix)) {
            return .{ .rest = spec[p.prefix.len..], .scheme = p.scheme };
        }
    }
    return .{ .rest = spec, .scheme = .none };
}

fn finishSpec(
    host: []const u8,
    port_s: []const u8,
    nick: ?[]const u8,
    password: ?[]const u8,
    meta_s: ?[]const u8,
    scheme: Scheme,
) ServerSpec {
    const default_port: u16 = switch (scheme) {
        .tls, .irc => protocol.default_tls_port,
        .https => protocol.default_https_meta_port,
        .plain, .none => protocol.default_port,
    };
    const port = protocol.parseU16(port_s) orelse default_port;
    const tls = switch (scheme) {
        .tls, .irc, .https => true,
        .plain => false,
        .none => protocol.isTlsPort(port) or protocol.isMetaTlsPort(port) or protocol.isHttpsMetaPort(port),
    };
    const irc = scheme == .irc;
    const explicit_meta = if (meta_s) |m| !(m.len == 0 or std.mem.eql(u8, m, "0")) else null;
    const meta = if (irc)
        false
    else if (scheme == .https)
        true
    else
        explicit_meta orelse (protocol.isMetaTlsPort(port) or
            protocol.isHttpsMetaPort(port) or
            protocol.isHttpMetaPort(port) or
            (scheme == .tls and port == protocol.default_port) or
            (!tls and !isLocalHost(host) and port == protocol.default_port));
    return .{
        .host = host,
        .port = port,
        .nick = if (nick) |n| if (n.len == 0) null else n else null,
        .password = if (password) |p| if (p.len == 0) null else p else null,
        .meta = meta,
        .tls = tls,
        .irc = irc,
    };
}

pub fn parseServerSpec(spec: []const u8) ServerSpec {
    const raw = std.mem.trim(u8, spec, " \t");
    if (raw.len == 0) {
        return .{ .host = raw, .port = protocol.default_port, .meta = false };
    }
    const stripped = stripScheme(raw);
    const trimmed = stripped.rest;
    const scheme = stripped.scheme;
    if (trimmed.len == 0) {
        return finishSpec(trimmed, "", null, null, null, scheme);
    }

    // "host port" (what people type interactively)
    if (std.mem.indexOfScalar(u8, trimmed, ' ') != null and trimmed[0] != '[') {
        const has_colon = std.mem.indexOfScalar(u8, trimmed, ':') != null;
        if (!has_colon) {
            var it = std.mem.tokenizeAny(u8, trimmed, " \t");
            const host = it.next() orelse trimmed;
            const port_s = it.next() orelse "";
            return finishSpec(host, port_s, it.next(), it.next(), it.next(), scheme);
        }
    }

    if (trimmed[0] == '[') {
        const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse {
            return finishSpec(trimmed, "", null, null, null, scheme);
        };
        const host = trimmed[0 .. end + 1];
        const rest = trimmed[end + 1 ..];
        if (rest.len > 0 and rest[0] == ':') {
            var it = std.mem.splitScalar(u8, rest[1..], ':');
            return finishSpec(host, it.next() orelse "", it.next(), it.next(), it.next(), scheme);
        }
        return finishSpec(host, "", null, null, null, scheme);
    }

    var it = std.mem.splitScalar(u8, trimmed, ':');
    const host = it.next() orelse trimmed;
    return finishSpec(host, it.next() orelse "", it.next(), it.next(), it.next(), scheme);
}

pub const MetaRedirect = struct {
    host: []const u8,
    port: u16,
    tls: bool,
};

/// OpenNap metaserver reply: `host\nport\n` plus optional `naps/1\n`.
/// Also accepts a single `host:port` / `tls:host:port` line.
pub fn parseMetaRedirect(buf: []const u8) ?MetaRedirect {
    var lines: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitAny(u8, buf, "\r\n");
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        if (n >= lines.len) break;
        lines[n] = line;
        n += 1;
    }
    if (n == 0) return null;
    if (n == 1) {
        if (parseMeta1(lines[0])) |r| return r;
        const spec = parseServerSpec(lines[0]);
        if (spec.host.len == 0) return null;
        return .{ .host = spec.host, .port = spec.port, .tls = spec.tls };
    }
    if (std.mem.indexOf(u8, buf, "\"hubs\"") != null or std.mem.indexOf(u8, buf, "meta-1") != null) {
        if (parseMeta1(buf)) |r| return r;
    }
    const port = protocol.parseU16(lines[1]) orelse return null;
    var tls = false;
    if (n >= 3) {
        tls = std.ascii.eqlIgnoreCase(lines[2], protocol.alpn_id) or
            std.ascii.eqlIgnoreCase(lines[2], "tls");
    }
    if (!tls) tls = protocol.isTlsPort(port);
    return .{ .host = lines[0], .port = port, .tls = tls };
}

/// OpenNap `meta-1` JSON from `GET /meta` or metaserver `-W`/`-S`.
pub fn parseMeta1(buf: []const u8) ?MetaRedirect {
    const start = std.mem.indexOf(u8, buf, "{") orelse return null;
    const json = buf[start..];
    const proto = jsonString(json, "proto") orelse {
        if (std.mem.indexOf(u8, json, "\"hubs\"") == null) return null;
        return parseFirstHub(json);
    };
    if (!eqlIgnoreCase(proto, "meta-1")) return null;
    return parseFirstHub(json);
}

fn parseFirstHub(json: []const u8) ?MetaRedirect {
    const hubs_key = std.mem.indexOf(u8, json, "\"hubs\"") orelse return null;
    const arr = std.mem.indexOfScalarPos(u8, json, hubs_key, '[') orelse return null;
    const obj = std.mem.indexOfScalarPos(u8, json, arr, '{') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, json, obj, '}') orelse return null;
    return hubToRedirect(json[obj .. end + 1]);
}

fn hubToRedirect(hub: []const u8) ?MetaRedirect {
    const host_s = jsonString(hub, "host") orelse return null;
    const split = splitHostPort(host_s);
    const naps = jsonString(hub, "naps");
    const wss = jsonString(hub, "wss");
    const json_port = if (jsonU16(hub, "port")) |p| p else split.port;
    const naps_tls = if (naps) |n|
        eqlIgnoreCase(n, protocol.alpn_id) or eqlIgnoreCase(n, "naps-1") or eqlIgnoreCase(n, "tls")
    else
        false;
    if (split.host.len == 0) return null;
    var port: u16 = undefined;
    var tls = false;
    if (json_port) |p| {
        if (protocol.isHttpishPort(p)) {
            port = if (naps_tls or wss != null) protocol.default_tls_port else protocol.default_port;
            tls = naps_tls or wss != null;
        } else {
            port = p;
            tls = naps_tls or protocol.isTlsPort(p);
        }
    } else if (naps_tls or wss != null) {
        port = protocol.default_tls_port;
        tls = true;
    } else {
        port = 8888;
        tls = false;
    }
    return .{ .host = split.host, .port = port, .tls = tls };
}

fn splitHostPort(spec: []const u8) struct { host: []const u8, port: ?u16 } {
    if (spec.len >= 2 and spec[0] == '[') {
        const end = std.mem.indexOfScalar(u8, spec, ']') orelse return .{ .host = spec, .port = null };
        if (end + 1 < spec.len and spec[end + 1] == ':') {
            return .{ .host = spec[0 .. end + 1], .port = protocol.parseU16(spec[end + 2 ..]) };
        }
        return .{ .host = spec[0 .. end + 1], .port = null };
    }
    if (std.mem.lastIndexOfScalar(u8, spec, ':')) |c| {
        if (protocol.parseU16(spec[c + 1 ..])) |p|
            return .{ .host = spec[0..c], .port = p };
    }
    return .{ .host = spec, .port = null };
}

fn jsonString(obj: []const u8, key: []const u8) ?[]const u8 {
    var needle: [32]u8 = undefined;
    const q = std.fmt.bufPrint(&needle, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, obj, q) orelse return null;
    var i = at + q.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t' or obj[i] == ':')) : (i += 1) {}
    if (i >= obj.len or obj[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < obj.len) : (i += 1) {
        if (obj[i] == '\\') {
            i += 1;
            continue;
        }
        if (obj[i] == '"') return obj[start..i];
    }
    return null;
}

fn jsonU16(obj: []const u8, key: []const u8) ?u16 {
    var needle: [32]u8 = undefined;
    const q = std.fmt.bufPrint(&needle, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, obj, q) orelse return null;
    var i = at + q.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t' or obj[i] == ':')) : (i += 1) {}
    const start = i;
    while (i < obj.len and std.ascii.isDigit(obj[i])) : (i += 1) {}
    if (i == start) return null;
    return protocol.parseU16(obj[start..i]);
}

test "skip tls verify only for loopback" {
    try std.testing.expect(skipTlsVerify("localhost"));
    try std.testing.expect(skipTlsVerify("127.0.0.1"));
    try std.testing.expect(!skipTlsVerify("pi0.local"));
    try std.testing.expect(!skipTlsVerify("napster.example"));
}

test "parse localhost 8888" {
    const a = parseServerSpec("localhost 8888");
    try std.testing.expectEqualStrings("localhost", a.host);
    try std.testing.expectEqual(@as(u16, 8888), a.port);
    try std.testing.expect(!a.meta);
    try std.testing.expect(!a.tls);

    const b = parseServerSpec("localhost:8888");
    try std.testing.expectEqualStrings("localhost", b.host);
    try std.testing.expectEqual(@as(u16, 8888), b.port);
    try std.testing.expect(!b.meta);
    try std.testing.expect(!b.tls);

    const c = parseServerSpec("127.0.0.1:8888");
    try std.testing.expectEqualStrings("127.0.0.1", c.host);
    try std.testing.expectEqual(@as(u16, 8888), c.port);
    try std.testing.expect(!c.meta);
    try std.testing.expect(!c.tls);
}

test "parse tls and naps schemes" {
    const a = parseServerSpec("tls:127.0.0.1:6697");
    try std.testing.expectEqualStrings("127.0.0.1", a.host);
    try std.testing.expectEqual(@as(u16, 6697), a.port);
    try std.testing.expect(a.tls);
    try std.testing.expect(!a.meta);

    const b = parseServerSpec("naps:localhost");
    try std.testing.expectEqualStrings("localhost", b.host);
    try std.testing.expectEqual(@as(u16, 6697), b.port);
    try std.testing.expect(b.tls);

    const c = parseServerSpec("tls:localhost 6697");
    try std.testing.expectEqualStrings("localhost", c.host);
    try std.testing.expectEqual(@as(u16, 6697), c.port);
    try std.testing.expect(c.tls);

    const d = parseServerSpec("127.0.0.1:6697");
    try std.testing.expect(d.tls);

    const e = parseServerSpec("plain:127.0.0.1:6697");
    try std.testing.expectEqual(@as(u16, 6697), e.port);
    try std.testing.expect(!e.tls);

    const f = parseServerSpec("tls:[::1]:6697");
    try std.testing.expectEqualStrings("[::1]", f.host);
    try std.testing.expectEqual(@as(u16, 6697), f.port);
    try std.testing.expect(f.tls);

    const g = parseServerSpec("127.0.0.1:8887");
    try std.testing.expect(g.tls);
}

test "parse metaserver tls port 8876" {
    const a = parseServerSpec("127.0.0.1:8876");
    try std.testing.expectEqualStrings("127.0.0.1", a.host);
    try std.testing.expectEqual(@as(u16, 8876), a.port);
    try std.testing.expect(a.tls);
    try std.testing.expect(a.meta);
    try std.testing.expect(!a.irc);

    const b = parseServerSpec("tls:nap.example:8876");
    try std.testing.expectEqualStrings("nap.example", b.host);
    try std.testing.expect(b.tls);
    try std.testing.expect(b.meta);

    const c = parseServerSpec("localhost:8876");
    try std.testing.expect(c.tls);
    try std.testing.expect(c.meta);

    const d = parseServerSpec("tls:remote.example:8875");
    try std.testing.expectEqual(@as(u16, 8875), d.port);
    try std.testing.expect(d.tls);
    try std.testing.expect(d.meta);

    const e = parseServerSpec("server.napster.com:8875");
    try std.testing.expect(!e.tls);
    try std.testing.expect(e.meta);

    const f = parseServerSpec("tls:127.0.0.1:6697");
    try std.testing.expect(f.tls);
    try std.testing.expect(!f.meta);

    const h = parseServerSpec("https:nap.example");
    try std.testing.expectEqualStrings("nap.example", h.host);
    try std.testing.expectEqual(@as(u16, 443), h.port);
    try std.testing.expect(h.tls);
    try std.testing.expect(h.meta);

    const i = parseServerSpec("https://127.0.0.1:8876");
    try std.testing.expectEqualStrings("127.0.0.1", i.host);
    try std.testing.expectEqual(@as(u16, 8876), i.port);
    try std.testing.expect(i.tls);
    try std.testing.expect(i.meta);

    const j = parseServerSpec("pi0.local:443");
    try std.testing.expect(j.tls);
    try std.testing.expect(j.meta);

    const k = parseServerSpec("napster.barrettharber.com");
    try std.testing.expectEqualStrings("napster.barrettharber.com", k.host);
    try std.testing.expectEqual(@as(u16, 8875), k.port);
    try std.testing.expect(k.meta);
    try std.testing.expect(!k.tls);
    try std.testing.expect(!k.irc);

    const l = parseServerSpec("irc:napster.barrettharber.com");
    try std.testing.expectEqualStrings("napster.barrettharber.com", l.host);
    try std.testing.expectEqual(@as(u16, 6697), l.port);
    try std.testing.expect(l.tls);
    try std.testing.expect(l.irc);
    try std.testing.expect(!l.meta);
}

test "parse metaserver redirect" {
    const a = parseMetaRedirect("127.0.0.1\n8888\n").?;
    try std.testing.expectEqualStrings("127.0.0.1", a.host);
    try std.testing.expectEqual(@as(u16, 8888), a.port);
    try std.testing.expect(!a.tls);

    const b = parseMetaRedirect("nap.example\n6697\nnaps/1\n").?;
    try std.testing.expectEqualStrings("nap.example", b.host);
    try std.testing.expectEqual(@as(u16, 6697), b.port);
    try std.testing.expect(b.tls);

    const c = parseMetaRedirect("tls:10.0.0.2:6697\n").?;
    try std.testing.expectEqualStrings("10.0.0.2", c.host);
    try std.testing.expect(c.tls);

    const d = parseMetaRedirect("legacy\n8887\nnaps/1\n").?;
    try std.testing.expectEqual(@as(u16, 8887), d.port);
    try std.testing.expect(d.tls);
}

test "parse meta-1 json" {
    const a = parseMeta1(
        \\{"proto":"meta-1","hubs":[{"host":"pi0.local","wss":"wss://pi0.local/","naps":"naps-1"}]}
    ).?;
    try std.testing.expectEqualStrings("pi0.local", a.host);
    try std.testing.expectEqual(@as(u16, 6697), a.port);
    try std.testing.expect(a.tls);

    const b = parseMeta1(
        \\{"proto":"meta-1","hubs":[{"host":"pi0.local:443","wss":"wss://pi0.local:443/","naps":"naps-1"}]}
    ).?;
    try std.testing.expectEqualStrings("pi0.local", b.host);
    try std.testing.expectEqual(@as(u16, 6697), b.port);
    try std.testing.expect(b.tls);

    const c = parseMeta1(
        \\{"proto":"meta-1","hubs":[{"host":"nap.example","port":6697,"naps":"naps/1"}]}
    ).?;
    try std.testing.expectEqualStrings("nap.example", c.host);
    try std.testing.expectEqual(@as(u16, 6697), c.port);
    try std.testing.expect(c.tls);

    const d = parseMeta1(
        \\{"proto":"meta-1","hubs":[{"host":"plain.example","port":8888}]}
    ).?;
    try std.testing.expectEqual(@as(u16, 8888), d.port);
    try std.testing.expect(!d.tls);
}

pub fn sanitizeFilename(name: []const u8, dest: []u8) []const u8 {
    const src = basename(name);
    var i: usize = 0;
    for (src) |c| {
        if (i >= dest.len) break;
        dest[i] = switch (c) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => '_',
            else => c,
        };
        i += 1;
    }
    return dest[0..i];
}
