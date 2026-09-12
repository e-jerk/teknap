const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const ui = @import("ui.zig");
const util = @import("util.zig");
const transfer = @import("transfer.zig");
const share = @import("share.zig");
const commands = @import("commands.zig");
const tls = @import("tls.zig");
const irc = @import("irc.zig");
const gpg = @import("gpg.zig");
const pgp = @import("pgp.zig");
const safe = @import("safe");
const owned = @import("owned.zig");

const GpgPhase = enum { idle, wait_plus, wait_challenge, done, failed };

pub const WireMode = enum { napster, irc };

pub const ChannelUser = struct {
    nick: owned.String,
    files: u32 = 0,
    speed: u32 = 0,

    fn deinit(self: *ChannelUser) void {
        self.nick.deinit();
    }
};

pub const OwnedHit = struct {
    filename: owned.String,
    checksum: owned.String,
    nick: owned.String,
    size: u64,
    bitrate: u32,
    freq: u32,
    seconds: u32,
    ip: u32,
    speed: u32,

    pub fn deinit(self: *OwnedHit) void {
        self.filename.deinit();
        self.checksum.deinit();
        self.nick.deinit();
    }

    fn from(gpa: std.mem.Allocator, hit: protocol.FileHit) !OwnedHit {
        return .{
            .filename = try owned.String.initFromSlice(gpa, hit.filename),
            .checksum = try owned.String.initFromSlice(gpa, hit.checksum),
            .nick = try owned.String.initFromSlice(gpa, hit.nick),
            .size = hit.size,
            .bitrate = hit.bitrate,
            .freq = hit.freq,
            .seconds = hit.seconds,
            .ip = hit.ip,
            .speed = hit.speed,
        };
    }
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: *config.Options,
    ui: *ui.Ui,
    running: bool = true,

    stream: ?Io.net.Stream = null,
    tls: ?safe.Box(tls.Conn) = null,
    listen: ?Io.net.Server = null,
    recv: owned.String,

    nick: owned.String,
    password: owned.String,
    connected_host: owned.String,
    connected_port: u16 = 0,
    connected_tls: bool = false,
    connected_irc: bool = false,
    wire_mode: WireMode = .napster,
    cap_phase: irc.CapPhase = .none,
    gpg: gpg.Store,
    gpg_phase: GpgPhase = .idle,
    logged_in: bool = false,
    channel: ?owned.String = null,
    topic: ?owned.String = null,

    users: std.ArrayList(ChannelUser) = .empty,
    search: std.ArrayList(OwnedHit) = .empty,
    browse: std.ArrayList(OwnedHit) = .empty,
    transfers: std.ArrayList(transfer.Transfer) = .empty,
    shares: std.ArrayList(share.SharedFile) = .empty,
    hotlist: std.ArrayList(owned.String) = .empty,
    ignores: std.ArrayList(owned.String) = .empty,

    stats_users: u32 = 0,
    stats_files: u32 = 0,
    stats_gigs: u32 = 0,
    email: ?owned.String = null,
    searching: bool = false,
    listing: bool = false,
    creating: bool = false,
    last_query: ?owned.String = null,

    pub fn init(gpa: std.mem.Allocator, io: Io, options: *config.Options, term: *ui.Ui) !App {
        const keys = gpg.load(gpa, io, options.gpg_spec, options.gpg_pass, options.home) catch gpg.Store{
            .gpa = gpa,
            .io = io,
        };
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .ui = term,
            .recv = owned.String.init(gpa),
            .nick = try owned.String.initFromSlice(gpa, options.nick),
            .password = try owned.String.initFromSlice(gpa, options.password),
            .connected_host = owned.String.init(gpa),
            .gpg = keys,
            .creating = options.create_account,
        };
    }

    pub fn channelName(self: *const App) ?[]const u8 {
        return owned.optSlice(&self.channel);
    }

    pub fn topicText(self: *const App) ?[]const u8 {
        return owned.optSlice(&self.topic);
    }

    pub fn queryNick(self: *const App) ?[]const u8 {
        return owned.optSlice(&self.last_query);
    }

    pub fn deinit(self: *App) void {
        self.disconnect();
        self.recv.deinit();
        self.nick.deinit();
        self.password.deinit();
        self.connected_host.deinit();
        self.gpg.deinit();
        owned.clearOpt(&self.channel);
        owned.clearOpt(&self.topic);
        owned.clearOpt(&self.email);
        owned.clearOpt(&self.last_query);
        for (self.users.items) |*u| u.deinit();
        self.users.deinit(self.gpa);
        for (self.search.items) |*h| h.deinit();
        self.search.deinit(self.gpa);
        for (self.browse.items) |*h| h.deinit();
        self.browse.deinit(self.gpa);
        for (self.transfers.items) |*t| t.deinit(self.gpa, self.io);
        self.transfers.deinit(self.gpa);
        for (self.shares.items) |*s| s.deinit();
        self.shares.deinit(self.gpa);
        for (self.hotlist.items) |*h| h.deinit();
        self.hotlist.deinit(self.gpa);
        for (self.ignores.items) |*h| h.deinit();
        self.ignores.deinit(self.gpa);
    }

    pub fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.ui.logLine(.info, fmt, args);
    }

    pub fn yell(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.ui.logLine(.error_msg, fmt, args);
    }

    pub fn disconnect(self: *App) void {
        if (self.tls) |box| {
            box.ptr.close();
            _ = box.deinit();
            self.tls = null;
        }
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
        }
        if (self.listen) |*l| {
            l.deinit(self.io);
            self.listen = null;
        }
        self.logged_in = false;
        self.connected_tls = false;
        self.connected_irc = false;
        self.wire_mode = .napster;
        self.cap_phase = .none;
        self.gpg_phase = .idle;
        self.recv.clear();
    }

    fn writeWire(self: *App, data: []const u8) !void {
        const stream = self.stream orelse return error.NotConnected;
        if (self.tls) |t| {
            try t.ptr.writeAll(stream.socket.handle, data);
        } else {
            try util.writeFd(stream.socket.handle, data);
        }
    }

    fn sendIrcRaw(self: *App, line: []const u8) !void {
        var buf: [protocol.max_payload + 4]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s}\r\n", .{line});
        try self.writeWire(msg);
    }

    pub fn send(self: *App, cmd: protocol.Cmd, payload: []const u8) !void {
        if (self.stream == null) {
            self.yell("Not connected. Use /server first.", .{});
            return error.NotConnected;
        }
        if (self.wire_mode == .irc) {
            var buf: [protocol.max_payload]u8 = undefined;
            const line = irc.napsterToIrc(cmd, payload, &buf) orelse {
                self.yell("Not available in IRC line mode (use plain 8888 or tls/naps:6697 for files).", .{});
                return;
            };
            try self.sendIrcRaw(line);
            return;
        }
        const stream = self.stream orelse return error.NotConnected;
        var buf: [protocol.header_size + protocol.max_payload]u8 = undefined;
        const n = try (protocol.Message{
            .command = @intFromEnum(cmd),
            .payload = payload,
        }).write(&buf);
        if (self.tls) |t| {
            t.ptr.writeAll(stream.socket.handle, buf[0..n]) catch |err| {
                self.yell("TLS write failed: {s}", .{@errorName(err)});
                return err;
            };
        } else {
            try util.writeFd(stream.socket.handle, buf[0..n]);
        }
    }

    pub fn sendFmt(self: *App, cmd: protocol.Cmd, comptime fmt: []const u8, args: anytype) !void {
        var buf: [protocol.max_payload]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, fmt, args);
        try self.send(cmd, payload);
    }

    pub fn connectEntry(self: *App, entry: config.ServerEntry) !void {
        const nick = entry.nick orelse self.options.nick;
        const pass = entry.password orelse self.options.password;
        if (!std.mem.eql(u8, nick, self.nick.slice())) {
            try owned.set(&self.nick, nick);
        }
        if (!std.mem.eql(u8, pass, self.password.slice())) {
            try owned.set(&self.password, pass);
        }
        try self.connectHost(entry.host, entry.port, entry.meta, entry.tls, entry.irc);
    }

    pub fn connectHost(self: *App, host: []const u8, port: u16, meta: bool, use_tls: bool, use_irc: bool) !void {
        const irc_mode = use_irc or self.options.force_irc;
        const tls_mode = use_tls or self.options.force_tls or irc_mode;
        const naps_tls = tls_mode and !irc_mode;
        self.disconnect();

        if (protocol.shouldQueryTlsMeta(meta, port, naps_tls, irc_mode)) {
            if (self.querySecureMeta(host, port, !meta)) |redir| {
                try self.connectViaRedirect(host, redir, tls_mode or redir.tls, irc_mode);
                return;
            } else |err| {
                if (meta) return err;
            }
            var p = port;
            if (!use_tls and p == protocol.default_port) p = protocol.default_tls_port;
            self.say("No TLS metaserver on {s}, connecting to {s}:{d} directly.", .{ host, host, p });
            try self.connectDirect(host, p, tls_mode, irc_mode);
            return;
        }

        var p = port;
        if (tls_mode and !use_tls and p == protocol.default_port)
            p = protocol.default_tls_port;
        try self.connectDirect(host, p, tls_mode, irc_mode);
    }

    /// TLS directory on 8876 first, then HTTPS `/meta` on 443, then plaintext 8875.
    fn querySecureMeta(self: *App, host: []const u8, port: u16, probe: bool) !MetaHop {
        const tls_port = if (protocol.isMetaTlsPort(port)) port else protocol.default_meta_tls_port;
        const https_port = if (protocol.isHttpsMetaPort(port)) port else protocol.default_https_meta_port;
        const https_first = protocol.isHttpsMetaPort(port) or protocol.isHttpMetaPort(port);

        if (https_first) {
            if (self.queryHttpMeta(host, https_port, true, true)) |redir|
                return redir
            else |_| {}
            if (self.queryMeta(host, tls_port, true, true)) |redir|
                return redir
            else |err| self.noteMetaTlsFail(host, tls_port, err);
        } else {
            if (self.queryMeta(host, tls_port, true, true)) |redir|
                return redir
            else |err| self.noteMetaTlsFail(host, tls_port, err);
            if (self.queryHttpMeta(host, https_port, true, true)) |redir|
                return redir
            else |_| {}
        }

        self.say("TLS metaserver unavailable, falling back to plaintext {s}:{d}.", .{
            host,
            protocol.default_port,
        });
        return self.queryMeta(host, protocol.default_port, false, probe);
    }

    const MetaHop = struct {
        host: [128]u8,
        host_len: usize,
        port: u16,
        tls: bool,

        fn hostSlice(self: *const MetaHop) []const u8 {
            return self.host[0..self.host_len];
        }
    };

    fn noteMetaTlsFail(self: *App, host: []const u8, port: u16, err: anyerror) void {
        if (err == error.CertVerify) {
            self.say("TLS metaserver {s}:{d} certificate not trusted, trying https://{s}/meta.", .{
                host, port, host,
            });
        }
    }

    fn queryMeta(self: *App, host: []const u8, port: u16, use_tls: bool, probe: bool) !MetaHop {
        if (use_tls) {
            return self.queryMetaOnce(host, port, true, probe) catch |err| switch (err) {
                error.Handshake => {
                    self.say("TLS handshake failed on {s}:{d} (not TLS?), trying plaintext.", .{ host, port });
                    return self.queryMetaOnce(host, port, false, probe);
                },
                else => return err,
            };
        }
        return self.queryMetaOnce(host, port, false, probe);
    }

    fn queryMetaOnce(self: *App, host: []const u8, port: u16, use_tls: bool, probe: bool) !MetaHop {
        if (probe) {
            self.say("Connecting to {s}:{d} ({s}metaserver)...", .{
                host,
                port,
                if (use_tls) "TLS " else "",
            });
        } else {
            self.say("Connecting to {s}:{d} (metaserver{s})...", .{
                host,
                port,
                if (use_tls) " TLS" else "",
            });
        }
        const conn = util.connectTcp(self.io, host, port) catch |err| {
            if (!probe)
                self.yell("Metaserver {s}:{d} failed: {s}", .{ host, port, @errorName(err) });
            return err;
        };
        const meta_stream = conn.stream;
        defer meta_stream.close(self.io);
        var raw: [256]u8 = undefined;
        const n = if (use_tls)
            self.readMetaTls(meta_stream.socket.handle, host, &raw, probe) catch |err| {
                if (!probe)
                    self.yell("TLS metaserver handshake failed ({s}). Try -k for a self-signed cert.", .{
                        @errorName(err),
                    });
                return err;
            }
        else
            readAllFd(meta_stream.socket.handle, &raw);
        const redir = util.parseMetaRedirect(raw[0..n]) orelse {
            if (!probe) self.yell("Metaserver returned no host", .{});
            return error.MetaFailed;
        };
        if (redir.host.len > 128) return error.MetaFailed;
        var hop: MetaHop = .{
            .host = undefined,
            .host_len = redir.host.len,
            .port = redir.port,
            .tls = redir.tls,
        };
        @memcpy(hop.host[0..redir.host.len], redir.host);
        return hop;
    }

    fn queryHttpMeta(self: *App, host: []const u8, port: u16, use_tls: bool, probe: bool) !MetaHop {
        const scheme: []const u8 = if (use_tls) "https" else "http";
        if (probe) {
            self.say("Connecting to {s}://{s}:{d}/meta (meta-1)...", .{ scheme, host, port });
        } else {
            self.say("Connecting to {s}://{s}:{d}/meta...", .{ scheme, host, port });
        }
        const conn = util.connectTcp(self.io, host, port) catch |err| {
            if (!probe)
                self.yell("{s} metaserver {s}:{d} failed: {s}", .{ scheme, host, port, @errorName(err) });
            return err;
        };
        const stream = conn.stream;
        defer stream.close(self.io);

        var box: ?safe.Box(tls.Conn) = null;
        defer if (box) |b| {
            b.ptr.close();
            _ = b.deinit();
        };

        if (use_tls) {
            const insecure = self.options.insecure or util.skipTlsVerify(host);
            if (insecure and !self.options.insecure)
                self.say("TLS: not verifying metaserver certificate ({s}).", .{host});
            box = tls.connect(self.gpa, stream.socket.handle, .{
                .server_name = host,
                .insecure = insecure,
                .mode = .http,
                .quiet = probe,
            }) catch |err| {
                if (!probe)
                    self.yell("HTTPS metaserver handshake failed ({s}). Try -k for a self-signed cert.", .{
                        @errorName(err),
                    });
                return err;
            };
        }

        var req_buf: [256]u8 = undefined;
        const req = std.fmt.bufPrint(&req_buf, "GET /meta HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{host}) catch return error.MetaFailed;
        if (box) |b| {
            b.ptr.writeAll(stream.socket.handle, req) catch |err| {
                if (!probe) self.yell("HTTPS metaserver write failed: {s}", .{@errorName(err)});
                return err;
            };
        } else {
            util.writeFd(stream.socket.handle, req) catch |err| {
                if (!probe) self.yell("HTTP metaserver write failed: {s}", .{@errorName(err)});
                return err;
            };
        }

        var raw: [4096]u8 = undefined;
        const n = if (box) |b| readAllTls(b.ptr, &raw) else readAllFd(stream.socket.handle, &raw);
        const body = httpBody(raw[0..n]) orelse {
            if (!probe) self.yell("Metaserver returned no HTTP body", .{});
            return error.MetaFailed;
        };
        const redir = util.parseMeta1(body) orelse {
            if (!probe) self.yell("Metaserver returned no meta-1 hubs", .{});
            return error.MetaFailed;
        };
        if (redir.host.len > 128) return error.MetaFailed;
        var hop: MetaHop = .{
            .host = undefined,
            .host_len = redir.host.len,
            .port = redir.port,
            .tls = redir.tls,
        };
        @memcpy(hop.host[0..redir.host.len], redir.host);
        return hop;
    }

    fn connectViaRedirect(self: *App, via_host: []const u8, redir: MetaHop, tls_mode: bool, irc_mode: bool) !void {
        const dest = redir.hostSlice();
        if (std.mem.startsWith(u8, dest, "127.") and !util.isLocalHost(via_host)) {
            self.yell("Servers are busy, try again later", .{});
            return error.ServersBusy;
        }
        if (irc_mode) {
            const irc_port = if (protocol.isTlsPort(redir.port)) redir.port else protocol.default_tls_port;
            self.say("Redirected to {s}:{d} (ircs-u)", .{ dest, irc_port });
            try self.connectDirect(dest, irc_port, true, true);
            return;
        }
        if (redir.tls) {
            self.say("Redirected to {s}:{d} (naps/1)", .{ dest, redir.port });
            try self.connectDirect(dest, redir.port, true, false);
            return;
        }
        if (tls_mode and !protocol.isTlsPort(redir.port)) {
            self.say("Directory advertised {s}:{d} (plain); trying TLS {s}:{d}.", .{
                dest,
                redir.port,
                dest,
                protocol.default_tls_port,
            });
            if (self.connectDirect(dest, protocol.default_tls_port, true, false)) |_|
                return
            else |_| {
                self.say("TLS {s}:{d} failed, using plaintext {s}:{d}.", .{
                    dest,
                    protocol.default_tls_port,
                    dest,
                    redir.port,
                });
            }
        }
        self.say("Redirected to {s}:{d}", .{ dest, redir.port });
        try self.connectDirect(dest, redir.port, false, false);
    }

    fn readMetaTls(self: *App, fd: std.posix.fd_t, host: []const u8, dest: []u8, quiet: bool) !usize {
        const insecure = self.options.insecure or util.skipTlsVerify(host);
        if (insecure and !self.options.insecure)
            self.say("TLS: not verifying metaserver certificate ({s}).", .{host});
        var box = tls.connect(self.gpa, fd, .{
            .server_name = host,
            .insecure = insecure,
            .mode = .meta,
            .quiet = quiet,
        }) catch |err| return err;
        defer {
            box.ptr.close();
            _ = box.deinit();
        }
        return readAllTls(box.ptr, dest);
    }

    fn connectDirect(self: *App, host: []const u8, port: u16, use_tls: bool, use_irc: bool) !void {
        const mode_label = if (use_irc and use_tls)
            " (TLS ircs-u)"
        else if (use_tls)
            " (TLS naps/1)"
        else
            "";
        self.say("Connecting to {s}:{d}{s}...", .{ host, port, mode_label });
        const conn = util.connectTcp(self.io, host, port) catch |err| {
            self.yell("Connect failed to {s}:{d} ({s}). Is a Napster/OpenNap server listening?", .{
                host, port, @errorName(err),
            });
            return err;
        };
        var ipbuf: [64]u8 = undefined;
        self.say("Connected via {s}", .{util.formatIpAddress(conn.addr, &ipbuf)});

        if (use_tls) {
            const insecure = self.options.insecure or util.skipTlsVerify(host);
            if (insecure and !self.options.insecure)
                self.say("TLS: not verifying certificate ({s}).", .{host});
            const tls_mode: tls.Mode = if (use_irc) .irc else .naps;
            self.tls = tls.connect(self.gpa, conn.stream.socket.handle, .{
                .server_name = host,
                .insecure = insecure,
                .mode = tls_mode,
            }) catch |err| {
                conn.stream.close(self.io);
                if (!use_irc and !protocol.isTlsPort(port)) {
                    self.say("TLS failed on {s}:{d} ({s}); retrying plaintext.", .{
                        host, port, @errorName(err),
                    });
                    return self.connectDirect(host, port, false, false);
                }
                const hint = if (use_irc)
                    "TLS ircs-u handshake failed."
                else
                    "TLS naps/1 handshake failed (need ALPN naps/1).";
                self.yell("{s} ({s}). Try -k for a self-signed cert.", .{ hint, @errorName(err) });
                return err;
            };
        }

        const stream = conn.stream;
        self.stream = stream;
        util.setNonblock(stream.socket.handle);
        try owned.set(&self.connected_host, host);
        self.connected_port = port;
        self.connected_tls = use_tls;
        self.connected_irc = use_irc;
        self.wire_mode = if (use_irc) .irc else .napster;
        self.listenData();
        const wire = if (use_irc) " ircs-u" else if (use_tls) " tls" else "";
        self.say("Connected to {s}:{d}{s}. Logging in as {s}...", .{
            host, port, wire, self.nick.slice(),
        });
        if (self.gpg.enabled) {
            self.say("GPG: {s}.", .{self.gpg.label});
        } else if (!std.mem.eql(u8, self.options.gpg_spec, "default") and
            !std.mem.eql(u8, self.options.gpg_spec, "off") and
            !std.mem.eql(u8, self.options.gpg_spec, "0"))
        {
            self.yell("GPG: could not load an Ed25519 secret from NAPGPG.", .{});
        }
        if (use_irc) {
            self.cap_phase = .wait_ls;
            self.sendIrcRaw("CAP LS 302") catch {};
        } else if (use_tls) {
            if (self.options.capability) {
                self.sendFmt(.set_capability, "{d}", .{62}) catch {};
            }
            self.beginCapLogin();
        } else {
            if (self.options.capability) {
                self.sendFmt(.set_capability, "{d}", .{62}) catch {};
            }
            if (self.creating) {
                self.sendFmt(.create_user, "{s}", .{self.nick.slice()}) catch {};
            } else {
                self.login() catch {};
            }
        }
    }

    fn beginCapLogin(self: *App) void {
        self.cap_phase = .wait_ls;
        self.sendFmt(.cap, "LS 302", .{}) catch {};
    }

    fn onCapNapster(self: *App, payload: []const u8) void {
        var p = protocol.Parser.init(payload);
        var sub = p.next() orelse return;
        if (std.mem.eql(u8, sub, "*") or std.mem.eql(u8, sub, self.nick.slice())) {
            sub = p.next() orelse return;
        }
        if (util.eqlIgnoreCase(sub, "LS")) {
            self.sendCapReq();
            if (self.gpg.enabled) {
                self.cap_phase = .wait_ack;
                return;
            }
            self.sendFmt(.cap, "END", .{}) catch {};
            self.finishPasswordLogin();
            return;
        }
        if (util.eqlIgnoreCase(sub, "ACK") and self.cap_phase == .wait_ack) {
            self.startGpgAuth();
            return;
        }
        if (util.eqlIgnoreCase(sub, "NAK")) {
            self.yell("CAP NAK: {s}", .{p.remainder()});
            self.sendFmt(.cap, "END", .{}) catch {};
            self.finishPasswordLogin();
        }
    }

    fn ircLoginAfterCap(self: *App) void {
        var buf: [256]u8 = undefined;
        const pass = self.loginPassword();
        if (pass.len != 0) {
            const line = std.fmt.bufPrint(&buf, "PASS {s}", .{pass}) catch return;
            self.sendIrcRaw(line) catch {};
        }
        const nick = std.fmt.bufPrint(&buf, "NICK {s}", .{self.nick.slice()}) catch return;
        self.sendIrcRaw(nick) catch {};
        const user = std.fmt.bufPrint(&buf, "USER {s} 0 * :{s}", .{ self.nick.slice(), self.nick.slice() }) catch return;
        self.sendIrcRaw(user) catch {};
    }

    fn sendCapReq(self: *App) void {
        const line = if (self.gpg.enabled)
            "REQ sasl draft/gpg server-time message-tags echo-message batch labeled-response account-tag away-notify chathistory"
        else
            "REQ server-time message-tags echo-message batch labeled-response account-tag away-notify chathistory";
        if (self.wire_mode == .irc) {
            var buf: [256]u8 = undefined;
            const raw = std.fmt.bufPrint(&buf, "CAP {s}", .{line}) catch return;
            self.sendIrcRaw(raw) catch {};
        } else {
            self.sendFmt(.cap, "{s}", .{line}) catch {};
        }
    }

    fn startGpgAuth(self: *App) void {
        if (!self.gpg.enabled) {
            self.endCapAndLogin();
            return;
        }
        var key_buf: [256]u8 = undefined;
        const pubhex = self.gpg.publicHex(&key_buf) catch {
            self.yell("GPG: could not export a public key.", .{});
            self.endCapAndLogin();
            return;
        };
        self.sendFmt(.key_out, "SET {s}", .{pubhex}) catch {};
        self.sendFmt(.authenticate, "GPG", .{}) catch {};
        self.gpg_phase = .wait_plus;
        self.say("GPG: SASL starting…", .{});
    }

    fn endCapAndLogin(self: *App) void {
        if (self.wire_mode == .irc) {
            self.sendIrcRaw("CAP END") catch {};
            self.ircLoginAfterCap();
        } else {
            self.sendFmt(.cap, "END", .{}) catch {};
            self.finishPasswordLogin();
        }
        self.cap_phase = .done;
    }

    fn finishPasswordLogin(self: *App) void {
        self.cap_phase = .done;
        if (self.logged_in) return;
        if (self.creating) {
            self.sendFmt(.create_user, "{s}", .{self.nick.slice()}) catch {};
        } else {
            self.login() catch {};
        }
    }

    fn loginPassword(self: *const App) []const u8 {
        if (self.gpg_phase == .done) return "*";
        return self.password.slice();
    }

    fn onAuthenticate(self: *App, payload: []const u8) void {
        const arg = std.mem.trim(u8, payload, " \t\r\n");
        if (util.eqlIgnoreCase(arg, "+")) {
            if (self.gpg.enabled and self.gpg_phase == .wait_plus) {
                self.sendFmt(.authenticate, "{s}", .{self.nick.slice()}) catch {};
                self.gpg_phase = .wait_challenge;
                return;
            }
            var plain: [256]u8 = undefined;
            const cred = std.fmt.bufPrint(&plain, "\x00{s}\x00{s}", .{ self.nick.slice(), self.loginPassword() }) catch return;
            var enc: [384]u8 = undefined;
            const b64 = std.base64.standard.Encoder.encode(enc[0..], cred);
            self.sendFmt(.authenticate, "{s}", .{b64}) catch {};
            return;
        }
        if (util.eqlIgnoreCase(arg, "SUCCESS")) {
            if (self.gpg_phase == .done) return;
            self.gpg_phase = .done;
            self.say("GPG: SASL success.", .{});
            self.endCapAndLogin();
            return;
        }
        if (util.eqlIgnoreCase(arg, "FAIL") or util.eqlIgnoreCase(arg, "ABORT")) {
            self.gpg_phase = .failed;
            self.yell("GPG: SASL failed; trying the account password.", .{});
            self.endCapAndLogin();
            return;
        }
        if (self.gpg_phase == .wait_challenge or self.gpg_phase == .wait_plus) {
            self.signAuthChallenge(arg);
        }
    }

    fn signAuthChallenge(self: *App, b64: []const u8) void {
        var doc: [512]u8 = undefined;
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(b64) catch {
            self.yell("GPG: bad SASL challenge.", .{});
            self.gpg_phase = .failed;
            self.endCapAndLogin();
            return;
        };
        if (n > doc.len) {
            self.yell("GPG: SASL challenge too large.", .{});
            self.gpg_phase = .failed;
            self.endCapAndLogin();
            return;
        }
        dec.decode(doc[0..n], b64) catch {
            self.yell("GPG: could not decode SASL challenge.", .{});
            self.gpg_phase = .failed;
            self.endCapAndLogin();
            return;
        };
        const sig = self.gpg.signHex(doc[0..n]) catch {
            self.yell("GPG: sign failed.", .{});
            self.gpg_phase = .failed;
            self.endCapAndLogin();
            return;
        };
        defer self.gpa.free(sig);
        self.sendFmt(.authenticate, "{s}", .{sig}) catch {};
    }

    fn onKeyLine(self: *App, payload: []const u8) void {
        var p = protocol.Parser.init(payload);
        var sub = p.next() orelse return;
        if (std.mem.eql(u8, sub, self.nick.slice())) {
            sub = p.next() orelse return;
        }
        if (util.eqlIgnoreCase(sub, "CHALLENGE")) {
            const nonce = p.next() orelse return;
            const server = p.next() orelse self.connected_host.slice();
            var doc_buf: [256]u8 = undefined;
            const doc = pgp.bindDocument(&doc_buf, server, self.nick.slice(), nonce);
            const sig = self.gpg.signHex(doc) catch {
                self.yell("GPG: KEY PROVE sign failed.", .{});
                return;
            };
            defer self.gpa.free(sig);
            self.sendFmt(.key_out, "PROVE {s}", .{sig}) catch {};
            self.say("GPG: proving key to {s}.", .{server});
            return;
        }
        if (util.eqlIgnoreCase(sub, "PENDING")) {
            self.say("GPG: public key offered.", .{});
            return;
        }
        if (util.eqlIgnoreCase(sub, "PUB") or util.eqlIgnoreCase(sub, "GONE") or
            util.eqlIgnoreCase(sub, "NONE"))
        {
            self.ui.logLine(.server, "KEY {s}", .{payload});
        }
    }

    fn offerKeyAfterLogin(self: *App) void {
        if (!self.gpg.enabled or self.gpg_phase == .done) return;
        var key_buf: [256]u8 = undefined;
        const pubhex = self.gpg.publicHex(&key_buf) catch return;
        self.sendFmt(.key_out, "SET {s}", .{pubhex}) catch {};
    }

    fn isKeyNotice(_: *App, text: []const u8) bool {
        return std.mem.startsWith(u8, text, "CHALLENGE ") or
            std.mem.startsWith(u8, text, "PENDING ") or
            std.mem.startsWith(u8, text, "PUB ") or
            std.mem.startsWith(u8, text, "GONE ") or
            std.mem.startsWith(u8, text, "NONE ");
    }

    fn listenData(self: *App) void {
        if (self.listen != null) return;
        const addr: Io.net.IpAddress = .{
            .ip4 = .unspecified(self.options.dataport),
        };
        self.listen = addr.listen(self.io, .{
            .reuse_address = true,
            .mode = .stream,
            .protocol = .tcp,
        }) catch |err| {
            self.say("Data port {d} unavailable ({s}); firewalled mode.", .{
                self.options.dataport, @errorName(err),
            });
            self.options.dataport = 0;
            return;
        };
        util.setNonblock(self.listen.?.socket.handle);
    }

    pub fn login(self: *App) !void {
        const info = if (self.connected_tls) "TekNap 2.1 naps/1" else protocol.client_info;
        try self.sendFmt(.login, "{s} {s} {d} \"{s}\" {d} 5201 0", .{
            self.nick.slice(),
            self.loginPassword(),
            self.options.dataport,
            info,
            self.options.speed,
        });
        for (self.hotlist.items) |n| {
            self.sendFmt(.add_hotlist_seq, "{s}", .{n.slice()}) catch {};
        }
    }

    pub fn register(self: *App, email: []const u8) !void {
        const info = if (self.connected_tls) "TekNap 2.1 naps/1" else protocol.client_info;
        try self.sendFmt(.register_info, "{s} {s} {d} \"{s}\" {d} {s}", .{
            self.nick.slice(),
            self.password.slice(),
            self.options.dataport,
            info,
            self.options.speed,
            email,
        });
    }

    pub fn handleLine(self: *App, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (trimmed[0] == '/') {
            try commands.dispatch(self, trimmed[1..]);
            return;
        }
        if (self.channelName()) |ch| {
            try self.sendFmt(.send, "{s} {s}", .{ ch, trimmed });
            self.ui.logLine(.public_msg, "<{s}> {s}", .{ self.nick.slice(), trimmed });
        } else if (self.queryNick()) |nick| {
            try self.sendFmt(.send_msg, "{s} {s}", .{ nick, trimmed });
            self.ui.logLine(.private, "-> *{s}* {s}", .{ nick, trimmed });
        } else {
            self.say("Join a channel (/join) or /msg someone first.", .{});
        }
    }

    pub fn pumpServer(self: *App) void {
        const stream = self.stream orelse return;
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = if (self.tls) |t|
                t.ptr.read(&tmp) catch |err| switch (err) {
                    error.WouldBlock => return,
                    error.Closed => {
                        self.say("Disconnected from server.", .{});
                        self.disconnect();
                        return;
                    },
                    else => {
                        self.yell("TLS read error: {s}", .{@errorName(err)});
                        self.disconnect();
                        return;
                    },
                }
            else
                std.posix.read(stream.socket.handle, &tmp) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => {
                        self.yell("Server read error: {s}", .{@errorName(err)});
                        self.disconnect();
                        return;
                    },
                };
            if (n == 0) {
                self.say("Disconnected from server.", .{});
                self.disconnect();
                return;
            }
            self.recv.append(tmp[0..n]) catch return;
            if (self.wire_mode == .irc) {
                self.consumeIrcLines();
            } else {
                self.consumeMessages();
            }
        }
    }

    fn consumeIrcLines(self: *App) void {
        while (true) {
            const rel = std.mem.indexOfScalar(u8, self.recv.slice(), '\n') orelse return;
            var raw = self.recv.slice()[0..rel];
            if (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];
            self.handleIrcLine(raw);
            owned.dropPrefix(&self.recv, rel + 1);
        }
    }

    fn nickFromPrefix(prefix: []const u8) []const u8 {
        const bang = std.mem.indexOfScalar(u8, prefix, '!') orelse return prefix;
        return prefix[0..bang];
    }

    fn handleIrcLine(self: *App, raw: []const u8) void {
        const line = irc.parseLine(raw) orelse return;
        const cmd = line.cmd;
        const params = line.params;

        if (irc.eql(cmd, "CAP")) {
            var p = protocol.Parser.init(params);
            _ = p.next();
            const sub = p.next() orelse return;
            if (util.eqlIgnoreCase(sub, "LS") and self.cap_phase == .wait_ls) {
                self.sendCapReq();
                if (self.gpg.enabled) {
                    self.cap_phase = .wait_ack;
                } else {
                    self.sendIrcRaw("CAP END") catch {};
                    self.ircLoginAfterCap();
                    self.cap_phase = .done;
                }
            } else if (util.eqlIgnoreCase(sub, "ACK") and self.cap_phase == .wait_ack) {
                self.startGpgAuth();
            } else if (util.eqlIgnoreCase(sub, "NAK")) {
                self.yell("CAP NAK: {s}", .{p.remainder()});
                self.sendIrcRaw("CAP END") catch {};
                self.ircLoginAfterCap();
                self.cap_phase = .done;
            }
            return;
        }

        if (irc.eql(cmd, "AUTHENTICATE")) {
            const p = irc.splitParams(params);
            self.onAuthenticate(if (p.head.len > 0) p.head else p.rest);
            return;
        }

        if (irc.eql(cmd, "KEY")) {
            self.onKeyLine(params);
            return;
        }

        if (irc.eql(cmd, "FAIL")) {
            if (std.mem.indexOf(u8, params, "AUTHENTICATE") != null) {
                self.onAuthenticate("FAIL");
            } else {
                self.ui.logLine(.error_msg, "FAIL {s}", .{params});
            }
            return;
        }

        if (irc.eql(cmd, "PING")) {
            const p = irc.splitParams(params);
            const token = if (p.head.len > 0) p.head else p.rest;
            var buf: [128]u8 = undefined;
            const pong = std.fmt.bufPrint(&buf, "PONG :{s}", .{token}) catch return;
            self.sendIrcRaw(pong) catch {};
            return;
        }

        if (irc.eql(cmd, "PRIVMSG") or irc.eql(cmd, "NOTICE")) {
            const p = irc.splitParams(params);
            const nick = nickFromPrefix(line.prefix);
            const text = if (p.rest.len > 0) p.rest else p.head;
            if (irc.eql(cmd, "NOTICE") and std.mem.indexOfScalar(u8, line.prefix, '!') == null and self.isKeyNotice(text)) {
                self.onKeyLine(text);
                return;
            }
            if (self.ignored(nick) or self.isOwnNick(nick)) return;
            if (irc.isPublicTarget(p.head)) {
                self.ui.logLine(.public_msg, "[{s}] <{s}> {s}", .{ p.head, nick, text });
            } else {
                self.ui.logLine(.private, "*{s}* {s}", .{ nick, text });
                owned.replaceOpt(self.gpa, &self.last_query, nick) catch {};
            }
            return;
        }

        if (irc.eql(cmd, "JOIN")) {
            const p = irc.splitParams(params);
            const chan = std.mem.trim(u8, p.head, " ");
            owned.replaceOpt(self.gpa, &self.channel, chan) catch {};
            const who = nickFromPrefix(line.prefix);
            if (util.eqlIgnoreCase(who, self.nick.slice())) {
                self.clearUsers();
                self.say("Joined channel {s}", .{chan});
            } else {
                self.ui.logLine(.info, "{s} joined {s}", .{ who, chan });
            }
            return;
        }

        if (irc.eql(cmd, "PART")) {
            const p = irc.splitParams(params);
            const chan = p.head;
            const who = nickFromPrefix(line.prefix);
            if (util.eqlIgnoreCase(who, self.nick.slice())) {
                self.say("Left channel {s}", .{chan});
                if (self.channelName()) |c| {
                    if (util.eqlIgnoreCase(c, chan)) {
                        owned.clearOpt(&self.channel);
                        self.clearUsers();
                    }
                }
            } else {
                self.ui.logLine(.info, "{s} has left {s}", .{ who, chan });
                self.removeUser(who);
            }
            return;
        }

        if (irc.eql(cmd, "TOPIC")) {
            const p = irc.splitParams(params);
            const topic = if (p.rest.len > 0) p.rest else p.head;
            owned.replaceOpt(self.gpa, &self.topic, topic) catch {};
            self.ui.logLine(.server, "Topic: {s}", .{topic});
            return;
        }

        if (irc.numericCode(cmd)) |code| {
            switch (code) {
                1 => {
                    if (!self.logged_in) {
                        self.logged_in = true;
                        self.cap_phase = .done;
                        self.creating = false;
                        self.say("Login accepted (IRC).", .{});
                        self.offerKeyAfterLogin();
                    }
                },
                900, 903 => {
                    if (self.gpg.enabled) self.onAuthenticate("SUCCESS");
                },
                904, 905, 906 => {
                    if (self.gpg_phase == .wait_plus or self.gpg_phase == .wait_challenge)
                        self.onAuthenticate("FAIL");
                },
                2, 3, 4, 5 => self.ui.logLine(.server, "{s}", .{params}),
                311, 312, 317, 318, 319, 330, 331, 335, 336, 337, 338, 369 =>
                    self.ui.logLine(.server, "WHOIS: {s}", .{params}),
                353 => {
                    var p = protocol.Parser.init(params);
                    _ = p.next();
                    _ = p.next();
                    _ = p.next();
                    var it = std.mem.splitScalar(u8, p.remainder(), ' ');
                    while (it.next()) |n| {
                        if (n.len == 0) continue;
                        self.upsertUser(n, 0, 0);
                    }
                },
                366 => self.say("End of /NAMES ({d} users)", .{self.users.items.len}),
                332 => {
                    var p = protocol.Parser.init(params);
                    _ = p.next();
                    const topic = p.remainder();
                    owned.replaceOpt(self.gpa, &self.topic, topic) catch {};
                    self.ui.logLine(.server, "Topic: {s}", .{topic});
                },
                433, 432, 464, 465 => self.ui.logLine(.error_msg, "{s} {s}", .{ cmd, params }),
                else => {
                    if (params.len > 0)
                        self.ui.logLine(.server, "{s} {s}", .{ cmd, params });
                },
            }
            self.updateStatus();
            return;
        }

        if (params.len > 0)
            self.ui.logLine(.server, "{s} {s}", .{ cmd, params });
        self.updateStatus();
    }

    fn consumeMessages(self: *App) void {
        while (self.recv.len() >= protocol.header_size) {
            const hdr = protocol.Header.decode(self.recv.slice()[0..protocol.header_size]);
            const total = protocol.header_size + @as(usize, hdr.len);
            if (self.recv.len() < total) return;
            const payload = self.recv.slice()[protocol.header_size..total];
            self.dispatch(hdr.command, payload);
            owned.dropPrefix(&self.recv, total);
        }
    }

    fn ignored(self: *App, nick: []const u8) bool {
        for (self.ignores.items) |n| {
            if (util.eqlIgnoreCase(n.slice(), nick)) return true;
        }
        return false;
    }

    fn isOwnNick(self: *const App, nick: []const u8) bool {
        return util.eqlIgnoreCase(nick, self.nick.slice());
    }

    fn dispatch(self: *App, command: u16, payload: []const u8) void {
        const cmd: protocol.Cmd = @enumFromInt(command);
        switch (cmd) {
            .error_msg, .error_text, .login_error, .illegal_nick, .create_error => {
                self.ui.logLine(.error_msg, "[{d}] {s}", .{ command, payload });
            },
            .email => {
                owned.replaceOpt(self.gpa, &self.email, payload) catch {};
                self.logged_in = true;
                self.creating = false;
                self.say("Login accepted. Email: {s}", .{payload});
                self.resendShares();
                self.offerKeyAfterLogin();
            },
            .created => {
                self.say("Nickname available. Sending registration...", .{});
                const em = if (self.options.email.len != 0) self.options.email else "user@localhost";
                self.register(em) catch {};
            },
            .motd, .motd_line => self.ui.logLine(.server, "{s}", .{payload}),
            .stats => {
                var p = protocol.Parser.init(payload);
                self.stats_users = protocol.parseU32(p.next() orelse "0") orelse 0;
                self.stats_files = protocol.parseU32(p.next() orelse "0") orelse 0;
                self.stats_gigs = protocol.parseU32(p.next() orelse "0") orelse 0;
            },
            .public_msg => {
                var p = protocol.Parser.init(payload);
                const chan = p.next() orelse return;
                const nick = p.next() orelse return;
                const text = p.remainder();
                if (self.ignored(nick) or self.isOwnNick(nick)) return;
                self.ui.logLine(.public_msg, "[{s}] <{s}> {s}", .{ chan, nick, text });
            },
            .send_msg => {
                var p = protocol.Parser.init(payload);
                const nick = p.next() orelse return;
                const text = p.remainder();
                if (self.ignored(nick) or self.isOwnNick(nick)) return;
                self.ui.logLine(.private, "*{s}* {s}", .{ nick, text });
                owned.replaceOpt(self.gpa, &self.last_query, nick) catch {};
            },
            .emote => {
                var p = protocol.Parser.init(payload);
                const chan = p.next() orelse return;
                const nick = p.next() orelse return;
                const text = p.nextQuoted() orelse p.remainder();
                if (self.ignored(nick) or self.isOwnNick(nick)) return;
                self.ui.logLine(.public_msg, "[{s}] * {s} {s}", .{ chan, nick, text });
            },
            .joined => {
                owned.replaceOpt(self.gpa, &self.channel, std.mem.trim(u8, payload, " ")) catch {};
                self.clearUsers();
                self.say("Joined channel {s}", .{payload});
            },
            .part, .parted => {
                var p = protocol.Parser.init(payload);
                const chan = p.next() orelse payload;
                const nick = p.next();
                if (nick) |n| {
                    self.ui.logLine(.info, "{s} has left {s}", .{ n, chan });
                    self.removeUser(n);
                } else {
                    self.say("Left channel {s}", .{chan});
                    if (self.channelName()) |c| {
                        if (util.eqlIgnoreCase(c, chan)) {
                            owned.clearOpt(&self.channel);
                            self.clearUsers();
                        }
                    }
                }
            },
            .names, .join_new, .nick_entry => {
                var p = protocol.Parser.init(payload);
                _ = p.next(); // channel
                const nick = p.next() orelse return;
                const files = protocol.parseU32(p.next() orelse "0") orelse 0;
                const speed = protocol.parseU32(p.next() orelse "0") orelse 0;
                self.upsertUser(nick, files, speed);
            },
            .names_end, .name => {
                self.say("End of /NAMES ({d} users)", .{self.users.items.len});
            },
            .topic => {
                owned.replaceOpt(self.gpa, &self.topic, payload) catch {};
                self.ui.logLine(.server, "Topic: {s}", .{payload});
            },
            .search_results => {
                if (protocol.parseSearchHit(payload)) |hit| {
                    if (OwnedHit.from(self.gpa, hit)) |hit_val| {
                        var oh = hit_val;
                        self.search.append(self.gpa, oh) catch oh.deinit();
                    } else |_| {}
                }
            },
            .search_end => {
                self.searching = false;
                self.printSearch();
            },
            .browse_result, .browse_result_new => {
                if (protocol.parseBrowseHit(payload)) |hit| {
                    if (OwnedHit.from(self.gpa, hit)) |hit_val| {
                        var oh = hit_val;
                        self.browse.append(self.gpa, oh) catch oh.deinit();
                    } else |_| {}
                }
            },
            .browse_end => {
                self.say("Browse complete ({d} files)", .{self.browse.items.len});
                self.printBrowse();
            },
            .file_ready => self.onFileReady(payload),
            .get_error => self.ui.logLine(.error_msg, "Get error: {s}", .{payload}),
            .file_request => self.onUploadRequest(payload),
            .file_info_fire => self.onFirewallPush(payload),
            .data_port_error => self.say("Peer cannot reach your data port: {s}", .{payload}),
            .hotlist_online => {
                var p = protocol.Parser.init(payload);
                const nick = p.next() orelse payload;
                const spd = p.next() orelse "";
                self.ui.logLine(.info, "Hotlist: {s} is online ({s})", .{ nick, spd });
            },
            .user_offline => self.ui.logLine(.info, "Hotlist: {s} is offline", .{payload}),
            .hotlist_success => self.say("Added {s} to hotlist", .{payload}),
            .hotlist_error => self.yell("Could not add {s} to hotlist", .{payload}),
            .whois_result, .whois, .whowas, .whowas_opennap => {
                self.ui.logLine(.server, "WHOIS: {s}", .{payload});
            },
            .ping => {
                var p = protocol.Parser.init(payload);
                const nick = p.next() orelse payload;
                self.sendFmt(.pong, "{s}", .{nick}) catch {};
            },
            .pong => self.say("PONG {s}", .{payload}),
            .sping => self.send(.sping, payload) catch {},
            .announce => self.ui.logLine(.server, "ANNOUNCE: {s}", .{payload}),
            .opsay => self.ui.logLine(.server, "WALLOP: {s}", .{payload}),
            .channel_entry => {
                self.ui.logLine(.server, "{s}", .{payload});
            },
            .list_channels => {
                if (self.listing) {
                    self.listing = false;
                    self.say("End of channel list", .{});
                }
            },
            .all_channels => self.ui.logLine(.server, "{s}", .{payload}),
            .show_all_channels => {
                self.listing = false;
                self.say("End of channel list", .{});
            },
            .client_redir, .cycle => {
                self.say("Server redirect: {s}", .{payload});
                var p = protocol.Parser.init(payload);
                const h = p.next() orelse return;
                const port = protocol.parseU16(p.next() orelse "8888") orelse 8888;
                const tls_r = protocol.isTlsPort(port) or self.options.force_tls;
                const irc_r = self.connected_irc or self.options.force_irc;
                self.connectHost(h, port, false, tls_r, irc_r) catch {};
            },
            .cap => self.onCapNapster(payload),
            .cap_reply => self.onCapNapster(payload),
            .memo => self.ui.logLine(.private, "MEMO: {s}", .{payload}),
            .memo_end => {},
            .isupport => self.ui.logLine(.server, "Capabilities: {s}", .{payload}),
            .away_notice, .away_set => self.ui.logLine(.info, "Away: {s}", .{payload}),
            .server_user_sharing => {},
            .account, .session_resume, .sts => {},
            .authenticate, .authenticate_challenge => self.onAuthenticate(payload),
            .key => self.onKeyLine(payload),
            .fail => {
                if (std.mem.indexOf(u8, payload, "AUTHENTICATE") != null) {
                    self.onAuthenticate("FAIL");
                } else {
                    self.ui.logLine(.error_msg, "FAIL {s}", .{payload});
                }
            },
            .batch, .batch_end, .warn, .note,
            .chathistory_line, .chathistory_end, .tagmsg, .redact, .edit =>
                self.ui.logLine(.server, "[{d}] {s}", .{ command, payload }),
            else => {
                if (payload.len != 0) {
                    self.ui.logLine(.server, "[{d}] {s}", .{ command, payload });
                }
            },
        }
        self.updateStatus();
    }

    fn onFileReady(self: *App, payload: []const u8) void {
        const ready = protocol.parseFileReady(payload) orelse {
            self.yell("Bad 204: {s}", .{payload});
            return;
        };
        var t = self.findTransfer(ready.nick, ready.filename) orelse {
            self.yell("Unexpected file ready from {s}", .{ready.nick});
            return;
        };
        t.ip = protocol.ipFromNapster(ready.ip);
        t.port = ready.port;
        if (ready.port == 0) {
            t.firewalled = true;
            self.sendFmt(.request_file_fire, "{s} \"{s}\"", .{ ready.nick, ready.filename }) catch {};
            self.ui.logLine(.transfer, "Waiting for firewalled push from {s}", .{ready.nick});
            return;
        }
        transfer.startDownload(self.io, t) catch |err| {
            self.yell("Download connect failed: {s}", .{@errorName(err)});
            return;
        };
        self.ui.logLine(.transfer, "Connecting to {s} for {s}", .{ ready.nick, util.basename(ready.filename) });
    }

    fn onUploadRequest(self: *App, payload: []const u8) void {
        var p = protocol.Parser.init(payload);
        const nick = p.next() orelse return;
        const filename = p.nextQuoted() orelse return;
        if (share.findByRemote(self.shares.items, filename) == null) {
            self.say("{s} requested unknown file {s}", .{ nick, filename });
            return;
        }
        self.sendFmt(.file_info, "{s} \"{s}\"", .{ nick, filename }) catch {};
        self.ui.logLine(.transfer, "Accepted upload of {s} to {s}", .{ util.basename(filename), nick });
    }

    fn onFirewallPush(self: *App, payload: []const u8) void {
        const ready = protocol.parseFileReady(payload) orelse return;
        var t = self.findTransfer(ready.nick, ready.filename) orelse return;
        t.ip = protocol.ipFromNapster(ready.ip);
        t.port = ready.port;
        t.firewalled = true;
        transfer.startDownload(self.io, t) catch return;
    }

    pub fn findTransfer(self: *App, nick: []const u8, filename: []const u8) ?*transfer.Transfer {
        for (self.transfers.items) |*t| {
            if (util.eqlIgnoreCase(t.nick.slice(), nick) and
                (std.mem.eql(u8, t.remote_path.slice(), filename) or
                    std.mem.eql(u8, t.filename.slice(), util.basename(filename))))
                return t;
        }
        return null;
    }

    pub fn requestGet(self: *App, hit: OwnedHit) !void {
        const local = try transfer.localPath(self.gpa, self.options.download_dir, hit.filename.slice());
        defer self.gpa.free(local);
        Io.Dir.cwd().createDirPath(self.io, self.options.download_dir) catch {};
        try self.transfers.append(self.gpa, .{
            .kind = .download,
            .nick = try owned.String.initFromSlice(self.gpa, hit.nick.slice()),
            .filename = try owned.String.initFromSlice(self.gpa, local),
            .remote_path = try owned.String.initFromSlice(self.gpa, hit.filename.slice()),
            .checksum = try owned.String.initFromSlice(self.gpa, hit.checksum.slice()),
            .size = hit.size,
            .ip = protocol.ipFromNapster(hit.ip),
            .buf = owned.String.init(self.gpa),
        });
        try self.sendFmt(.request_file, "{s} \"{s}\"", .{ hit.nick.slice(), hit.filename.slice() });
        self.ui.logLine(.transfer, "Requesting {s} from {s}", .{ util.basename(hit.filename.slice()), hit.nick.slice() });
    }

    pub fn printSearch(self: *App) void {
        if (self.search.items.len == 0) {
            self.say("No search results.", .{});
            return;
        }
        self.say("--- {d} search results ---", .{self.search.items.len});
        var hits = owned.GuardedSlice(OwnedHit).fromSlice(self.search.items);
        var i: usize = 0;
        while (hits.get(i)) |h| : (i += 1) {
            var sz: [32]u8 = undefined;
            var dur: [16]u8 = undefined;
            self.ui.logLine(.normal, "{d:>3} {s:<16} {s:>7} {d:>3}k {s} {s} {s}", .{
                i + 1,
                h.nick.slice(),
                util.formatSize(h.size, &sz),
                h.bitrate,
                util.formatDuration(h.seconds, &dur),
                protocol.speedName(h.speed),
                util.basename(h.filename.slice()),
            });
        }
    }

    pub fn printBrowse(self: *App) void {
        var hits = owned.GuardedSlice(OwnedHit).fromSlice(self.browse.items);
        var i: usize = 0;
        while (hits.get(i)) |h| : (i += 1) {
            var sz: [32]u8 = undefined;
            self.ui.logLine(.normal, "{d:>3} {s:>7} {d:>3}k  {s}", .{
                i + 1,
                util.formatSize(h.size, &sz),
                h.bitrate,
                h.filename.slice(),
            });
        }
    }

    fn upsertUser(self: *App, nick: []const u8, files: u32, speed: u32) void {
        for (self.users.items) |*u| {
            if (util.eqlIgnoreCase(u.nick.slice(), nick)) {
                u.files = files;
                u.speed = speed;
                return;
            }
        }
        var n = owned.String.initFromSlice(self.gpa, nick) catch return;
        self.users.append(self.gpa, .{ .nick = n, .files = files, .speed = speed }) catch {
            n.deinit();
        };
    }

    fn removeUser(self: *App, nick: []const u8) void {
        for (self.users.items, 0..) |u, i| {
            if (util.eqlIgnoreCase(u.nick.slice(), nick)) {
                var gone = self.users.orderedRemove(i);
                gone.deinit();
                return;
            }
        }
    }

    fn clearUsers(self: *App) void {
        for (self.users.items) |*u| u.deinit();
        self.users.clearRetainingCapacity();
    }

    pub fn resendShares(self: *App) void {
        var buf: [2048]u8 = undefined;
        for (self.shares.items) |s| {
            const ann = share.announce(s, &buf) catch continue;
            self.sendFmt(ann.cmd, "{s}", .{ann.payload}) catch {};
        }
        if (self.shares.items.len != 0) {
            self.say("Shared {d} files.", .{self.shares.items.len});
        }
    }

    pub fn updateStatus(self: *App) void {
        var clock_buf: [16]u8 = undefined;
        const clock = formatClock(self.io, &clock_buf);
        const chan = self.channelName() orelse "-";
        const host = if (self.connected_host.isEmpty()) "offline" else self.connected_host.slice();
        self.ui.setStatus("{s} | {s}:{d}{s} | {s} | {d} users | {d}f/{d}G | {d} xfer | {s}", .{
            self.nick.slice(),
            host,
            self.connected_port,
            if (self.connected_irc) " irc" else if (self.connected_tls) " tls" else "",
            chan,
            if (self.stats_users != 0) self.stats_users else self.users.items.len,
            self.stats_files,
            self.stats_gigs,
            self.transfers.items.len,
            clock,
        });
    }

    pub fn acceptPeers(self: *App) void {
        const server = if (self.listen) |*l| l else return;
        while (true) {
            const fd = util.acceptNonblock(server.socket.handle) orelse return;
            util.setNonblock(fd);
            self.handshakePeer(fd);
        }
    }

    fn handshakePeer(self: *App, fd: std.posix.fd_t) void {
        transfer.writeOne(fd) catch {};
        var scratch: [16]u8 = undefined;
        const hello = transfer.peekHello(fd, &scratch) catch {
            util.closeFd(fd);
            return;
        } orelse {
            util.closeFd(fd);
            return;
        };
        var rest_buf: [1024]u8 = undefined;
        const n = std.posix.read(fd, &rest_buf) catch 0;
        const rest = rest_buf[0..n];
        switch (hello.tag) {
            .get => {
                const req = transfer.parsePeerGet(rest) orelse {
                    util.writeFd(fd, "INVALID REQUEST") catch {};
                    util.closeFd(fd);
                    return;
                };
                self.beginUpload(fd, req.nick, req.filename, req.offset);
            },
            .send => {
                const req = transfer.parsePeerSend(rest) orelse {
                    util.closeFd(fd);
                    return;
                };
                self.beginFirewalledGet(fd, req.nick, req.filename, req.size);
            },
            .getlist => {
                self.sendShareList(fd);
                util.closeFd(fd);
            },
            else => util.closeFd(fd),
        }
    }

    fn beginUpload(self: *App, fd: std.posix.fd_t, nick: []const u8, filename: []const u8, offset: u64) void {
        const shared = share.findByRemote(self.shares.items, filename) orelse {
            util.writeFd(fd, "FILE NOT SHARED") catch {};
            util.closeFd(fd);
            return;
        };
        var size_buf: [32]u8 = undefined;
        const size_s = std.fmt.bufPrint(&size_buf, "{d}", .{shared.size}) catch "0";
        util.writeFd(fd, size_s) catch {};
        const opened = Io.Dir.cwd().openFile(self.io, shared.path.slice(), .{}) catch {
            util.closeFd(fd);
            return;
        };
        self.transfers.append(self.gpa, .{
            .kind = .upload,
            .state = .transfer,
            .nick = owned.String.initFromSlice(self.gpa, nick) catch {
                opened.close(self.io);
                util.closeFd(fd);
                return;
            },
            .filename = owned.String.initFromSlice(self.gpa, shared.path.slice()) catch {
                opened.close(self.io);
                util.closeFd(fd);
                return;
            },
            .remote_path = owned.String.initFromSlice(self.gpa, filename) catch {
                opened.close(self.io);
                util.closeFd(fd);
                return;
            },
            .checksum = owned.String.initFromSlice(self.gpa, &shared.checksum) catch {
                opened.close(self.io);
                util.closeFd(fd);
                return;
            },
            .size = shared.size,
            .offset = offset,
            .received = offset,
            .fd = fd,
            .file = owned.FileGuard().init(opened, self.io),
            .buf = owned.String.init(self.gpa),
        }) catch {
            opened.close(self.io);
            util.closeFd(fd);
        };
        self.send(.upload_start, &.{}) catch {};
        self.ui.logLine(.transfer, "Uploading {s} to {s}", .{ util.basename(filename), nick });
    }

    fn beginFirewalledGet(self: *App, fd: std.posix.fd_t, nick: []const u8, filename: []const u8, size: u64) void {
        var t = self.findTransfer(nick, filename) orelse {
            util.closeFd(fd);
            return;
        };
        t.fd = fd;
        t.size = size;
        t.state = .read_size;
        var off_buf: [32]u8 = undefined;
        const off = std.fmt.bufPrint(&off_buf, "{d}", .{t.offset}) catch "0";
        util.writeFd(fd, off) catch {};
    }

    fn sendShareList(self: *App, fd: std.posix.fd_t) void {
        var line_buf: [2200]u8 = undefined;
        const hdr = std.fmt.bufPrint(&line_buf, "{s}\n", .{self.nick.slice()}) catch return;
        util.writeFd(fd, hdr) catch return;
        for (self.shares.items) |s| {
            const ann = share.announce(s, line_buf[0..2048]) catch continue;
            const line = ann.payload;
            util.writeFd(fd, line) catch break;
            util.writeFd(fd, "\n") catch break;
        }
        util.writeFd(fd, "\n") catch {};
    }

    pub fn pumpTransfers(self: *App) void {
        var i: usize = 0;
        while (i < self.transfers.items.len) {
            const t = &self.transfers.items[i];
            const keep = self.stepTransfer(t);
            if (!keep) {
                var gone = self.transfers.orderedRemove(i);
                gone.deinit(self.gpa, self.io);
                continue;
            }
            i += 1;
        }
    }

    fn stepTransfer(self: *App, t: *transfer.Transfer) bool {
        const fd = t.fd orelse return t.state != .failed and t.state != .done;
        switch (t.state) {
            .wait_one => {
                var b: [1]u8 = undefined;
                const n = std.posix.read(fd, &b) catch |err| switch (err) {
                    error.WouldBlock => return true,
                    else => {
                        t.state = .failed;
                        return false;
                    },
                };
                if (n == 0) return false;
                if (b[0] == '1') {
                    transfer.sendGetRequest(t, self.nick.slice()) catch {
                        t.state = .failed;
                        return false;
                    };
                    if (!t.notified_start) {
                        self.send(.download_start, &.{}) catch {};
                        t.notified_start = true;
                    }
                }
            },
            .read_size => {
                var tmp: [256]u8 = undefined;
                const n = std.posix.read(fd, &tmp) catch |err| switch (err) {
                    error.WouldBlock => return true,
                    else => return false,
                };
                if (n == 0) return false;
                t.buf.append(tmp[0..n]) catch return false;
                if (t.buf.startsWith("INVALID") or t.buf.startsWith("FILE NOT")) {
                    self.yell("Peer: {s}", .{t.buf.slice()});
                    return false;
                }
                var digits: usize = 0;
                const bytes = t.buf.slice();
                while (digits < bytes.len and bytes[digits] >= '0' and bytes[digits] <= '9') {
                    digits += 1;
                }
                if (digits == bytes.len) return true;
                if (digits == 0) return true;
                t.size = protocol.parseU64(bytes[0..digits]) orelse t.size;
                const leftover = bytes[digits..];
                self.openDownloadFile(t) catch return false;
                if (leftover.len != 0) {
                    self.writeDownload(t, leftover) catch return false;
                }
                t.buf.clear();
                t.state = .transfer;
                self.ui.logLine(.transfer, "Receiving {s} ({d} bytes)", .{
                    util.basename(t.remote_path.slice()), t.size,
                });
            },
            .transfer => {
                if (t.kind == .download) {
                    var tmp: [8192]u8 = undefined;
                    const n = std.posix.read(fd, &tmp) catch |err| switch (err) {
                        error.WouldBlock => return true,
                        else => return false,
                    };
                    if (n == 0) {
                        self.finishDownload(t);
                        return false;
                    }
                    self.writeDownload(t, tmp[0..n]) catch return false;
                    if (t.size != 0 and t.received >= t.size) {
                        self.finishDownload(t);
                        return false;
                    }
                } else {
                    self.writeUpload(t) catch return false;
                    if (t.received >= t.size) {
                        self.send(.upload_end, &.{}) catch {};
                        self.ui.logLine(.transfer, "Upload to {s} complete", .{t.nick.slice()});
                        return false;
                    }
                }
            },
            .connecting, .send_get => return true,
            .done, .failed => return false,
        }
        return true;
    }

    fn openDownloadFile(self: *App, t: *transfer.Transfer) !void {
        if (t.file != null) return;
        Io.Dir.cwd().createDirPath(self.io, self.options.download_dir) catch {};
        const created = Io.Dir.cwd().createFile(self.io, t.filename.slice(), .{}) catch |err| {
            self.yell("Cannot create {s}: {s}", .{ t.filename.slice(), @errorName(err) });
            return err;
        };
        t.file = owned.FileGuard().init(created, self.io);
    }

    fn writeDownload(_: *App, t: *transfer.Transfer, data: []const u8) !void {
        var guard = if (t.file) |*g| g else return error.NoFile;
        var w = guard.writer();
        try w.interface.writeAll(data);
        try w.interface.flush();
        t.received += data.len;
    }

    fn writeUpload(_: *App, t: *transfer.Transfer) !void {
        var guard = if (t.file) |*g| g else return error.NoFile;
        const fd = t.fd orelse return error.NoSocket;
        var reader = guard.reader();
        var chunk: [4096]u8 = undefined;
        const n = reader.interface.readSliceShort(&chunk) catch {
            t.received = t.size;
            return;
        };
        if (n == 0) {
            t.received = t.size;
            return;
        }
        util.writeFd(fd, chunk[0..n]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        t.received += n;
    }

    fn finishDownload(self: *App, t: *transfer.Transfer) void {
        self.send(.download_end, &.{}) catch {};
        self.ui.logLine(.transfer, "Finished {s} ({d} bytes)", .{
            util.basename(t.filename.slice()), t.received,
        });
        t.state = .done;
    }

    pub fn collectPollFds(self: *App, fds: []std.posix.pollfd) usize {
        var n: usize = 0;
        fds[n] = .{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        n += 1;
        if (self.stream) |s| {
            var ev: i16 = std.posix.POLL.IN;
            if (self.tls) |t| {
                if (t.ptr.want_write) ev |= std.posix.POLL.OUT;
            }
            fds[n] = .{ .fd = s.socket.handle, .events = ev, .revents = 0 };
            n += 1;
        }
        if (self.listen) |l| {
            fds[n] = .{ .fd = l.socket.handle, .events = std.posix.POLL.IN, .revents = 0 };
            n += 1;
        }
        for (self.transfers.items) |t| {
            if (n >= fds.len) break;
            if (t.fd) |fd| {
                const ev: i16 = if (t.kind == .upload and t.state == .transfer)
                    std.posix.POLL.OUT
                else
                    std.posix.POLL.IN;
                fds[n] = .{ .fd = fd, .events = ev, .revents = 0 };
                n += 1;
            }
        }
        return n;
    }
};

fn readAllFd(fd: std.posix.fd_t, dest: []u8) usize {
    var total: usize = 0;
    while (total < dest.len) {
        const n = std.posix.read(fd, dest[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

fn httpBody(buf: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, buf, "\r\n\r\n")) |i| return buf[i + 4 ..];
    if (std.mem.indexOf(u8, buf, "\n\n")) |i| return buf[i + 2 ..];
    return null;
}

fn readAllTls(conn: *tls.Conn, dest: []u8) usize {
    var total: usize = 0;
    while (total < dest.len) {
        const n = conn.read(dest[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

fn formatClock(io: Io, buf: *[16]u8) []const u8 {
    const ts = Io.Clock.real.now(io);
    const epoch: i64 = @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
    const day: u64 = @intCast(@mod(epoch, 86400));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ day / 3600, (day / 60) % 60 }) catch "";
}
