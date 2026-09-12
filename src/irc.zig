//! RFC 7194 `ircs-u` — IRC lines after TLS (no ALPN `naps/1`).
//! Mirrors e-jerk/opennap `ircs.zig` client-side parsing and command mapping.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const default_port: u16 = 6697;
pub const service_name = "ircs-u";

pub const Line = struct {
    tags: []const u8 = "",
    prefix: []const u8 = "",
    cmd: []const u8 = "",
    params: []const u8 = "",
};

pub fn parseLine(raw: []const u8) ?Line {
    var s = std.mem.trimEnd(u8, raw, "\r\n");
    if (s.len == 0) return null;
    var line = Line{};
    if (s[0] == '@') {
        const sp = std.mem.indexOfScalar(u8, s, ' ') orelse return null;
        line.tags = s[1..sp];
        s = std.mem.trimStart(u8, s[sp + 1 ..], " ");
        if (s.len == 0) return null;
    }
    if (s[0] == ':') {
        const sp = std.mem.indexOfScalar(u8, s, ' ') orelse return null;
        line.prefix = s[1..sp];
        s = std.mem.trimStart(u8, s[sp + 1 ..], " ");
        if (s.len == 0) return null;
    }
    const sp = std.mem.indexOfScalar(u8, s, ' ');
    if (sp) |i| {
        line.cmd = s[0..i];
        line.params = std.mem.trimStart(u8, s[i + 1 ..], " ");
    } else {
        line.cmd = s;
    }
    return line;
}

pub fn splitParams(params: []const u8) struct { head: []const u8, rest: []const u8 } {
    if (params.len == 0) return .{ .head = "", .rest = "" };
    if (params[0] == ':') return .{ .head = params[1..], .rest = "" };
    const sp = std.mem.indexOfScalar(u8, params, ' ') orelse return .{ .head = params, .rest = "" };
    var rest = std.mem.trimStart(u8, params[sp + 1 ..], " ");
    if (rest.len > 0 and rest[0] == ':') rest = rest[1..];
    return .{ .head = params[0..sp], .rest = rest };
}

pub fn formatLine(out: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    const s = std.fmt.bufPrint(out[0 .. out.len - 2], fmt, args) catch return out[0..0];
    out[s.len] = '\r';
    out[s.len + 1] = '\n';
    return out[0 .. s.len + 2];
}

pub fn privmsg(out: []u8, from: []const u8, target: []const u8, text: []const u8) []const u8 {
    return formatLine(out, ":{s} PRIVMSG {s} :{s}", .{ from, target, text });
}

pub fn isPublicTarget(target: []const u8) bool {
    return target.len > 0 and (target[0] == '#' or target[0] == '&');
}

pub fn isPublicPrivmsg(cmd: []const u8, params: []const u8) bool {
    if (!eql(cmd, "PRIVMSG") and !eql(cmd, "NOTICE")) return false;
    const p = splitParams(params);
    return isPublicTarget(p.head);
}

pub fn numericCode(cmd: []const u8) ?u16 {
    if (cmd.len == 0 or !std.ascii.isDigit(cmd[0])) return null;
    return std.fmt.parseInt(u16, cmd, 10) catch null;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Encode Napster commands as IRC lines when on `ircs-u`. Returns null if unsupported.
pub fn napsterToIrc(cmd: protocol.Cmd, payload: []const u8, buf: []u8) ?[]const u8 {
    switch (cmd) {
        .join => return std.fmt.bufPrint(buf, "JOIN {s}", .{std.mem.trim(u8, payload, " ")}) catch null,
        .part => return std.fmt.bufPrint(buf, "PART {s}", .{std.mem.trim(u8, payload, " ")}) catch null,
        .send => {
            var p = protocol.Parser.init(payload);
            const chan = p.next() orelse return null;
            const text = p.remainder();
            return std.fmt.bufPrint(buf, "PRIVMSG {s} :{s}", .{ chan, text }) catch null;
        },
        .send_msg => {
            var p = protocol.Parser.init(payload);
            const nick = p.next() orelse return null;
            const text = p.remainder();
            return std.fmt.bufPrint(buf, "PRIVMSG {s} :{s}", .{ nick, text }) catch null;
        },
        .whois => return std.fmt.bufPrint(buf, "WHOIS {s}", .{std.mem.trim(u8, payload, " ")}) catch null,
        .ping => return std.fmt.bufPrint(buf, "PING :{s}", .{std.mem.trim(u8, payload, " ")}) catch null,
        .pong => return std.fmt.bufPrint(buf, "PONG :{s}", .{std.mem.trim(u8, payload, " ")}) catch null,
        .chathistory => return std.fmt.bufPrint(buf, "CHATHISTORY {s}", .{payload}) catch null,
        .away_set => {
            const trimmed = std.mem.trim(u8, payload, " ");
            if (trimmed.len == 0) return std.fmt.bufPrint(buf, "AWAY", .{}) catch null;
            return std.fmt.bufPrint(buf, "AWAY :{s}", .{trimmed}) catch null;
        },
        .cap => return std.fmt.bufPrint(buf, "CAP {s}", .{payload}) catch null,
        .authenticate => return std.fmt.bufPrint(buf, "AUTHENTICATE {s}", .{payload}) catch null,
        .list_channels => return std.fmt.bufPrint(buf, "LIST", .{}) catch null,
        .names => return std.fmt.bufPrint(buf, "NAMES {s}", .{std.mem.trim(u8, payload, " ")}) catch null,
        else => return null,
    }
}

pub const CapPhase = enum {
    none,
    wait_ls,
    wait_ack,
    done,
};

test "parse IRC line" {
    const a = parseLine("NICK alice\r\n").?;
    try std.testing.expectEqualStrings("NICK", a.cmd);
    const b = parseLine(":server 001 alice :Welcome").?;
    try std.testing.expectEqualStrings("server", b.prefix);
    try std.testing.expectEqualStrings("001", b.cmd);
    try std.testing.expectEqual(@as(u16, 1), numericCode(b.cmd));
}

test "napster to irc join" {
    var buf: [64]u8 = undefined;
    const s = napsterToIrc(.join, "#lobby", &buf).?;
    try std.testing.expectEqualStrings("JOIN #lobby", s);
}
