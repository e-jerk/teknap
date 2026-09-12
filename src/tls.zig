//! TLS for OpenNap: `naps/1` (Napster frames), RFC 7194 `ircs-u` (IRC lines,
//! no ALPN), metaserver redirect (no ALPN), or HTTPS `GET /meta` (`http/1.1`).

const std = @import("std");
const protocol = @import("protocol.zig");
const safe = @import("safe");
const owned = @import("owned.zig");

pub const ossl = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/x509.h");
    @cInclude("openssl/x509v3.h");
    @cInclude("openssl/x509_vfy.h");
});

pub const alpn_id = "naps/1";
pub const alpn_wire = "\x06naps/1";
pub const alpn_http = "http/1.1";
pub const alpn_http_wire = "\x08http/1.1";
pub const default_port: u16 = protocol.default_tls_port;

pub const Mode = enum {
    /// ALPN `naps/1` — Napster frames after handshake.
    naps,
    /// No ALPN — IRC lines (`ircs-u` on port 6697).
    irc,
    /// No ALPN — OpenNap metaserver redirect after handshake.
    meta,
    /// ALPN `http/1.1` — HTTPS `GET /meta` (`meta-1` JSON).
    http,
};

pub const Options = struct {
    server_name: []const u8,
    insecure: bool = false,
    mode: Mode = .naps,
    quiet: bool = false,
};

pub const Conn = struct {
    ssl: *ossl.SSL,
    want_write: bool = false,
    naps_alpn: bool = false,

    /// Close the SSL session. The `safe.Box` frees the `Conn` itself.
    pub fn close(self: *Conn) void {
        _ = ossl.SSL_shutdown(self.ssl);
        ossl.SSL_free(self.ssl);
    }

    pub fn read(self: *Conn, buf: []u8) !usize {
        const n = ossl.SSL_read(self.ssl, buf.ptr, intLen(buf.len));
        if (n > 0) {
            self.want_write = false;
            return @intCast(n);
        }
        return switch (self.mapWant(n)) {
            .want_read => error.WouldBlock,
            .want_write => error.WouldBlock,
            .closed => error.Closed,
            .fail => error.ReadFailed,
        };
    }

    pub fn writeAll(self: *Conn, fd: std.posix.fd_t, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            const n = ossl.SSL_write(self.ssl, data[off..].ptr, intLen(data.len - off));
            if (n > 0) {
                self.want_write = false;
                off += @intCast(n);
                continue;
            }
            switch (self.mapWant(n)) {
                .want_read => try wait(fd, std.posix.POLL.IN),
                .want_write => try wait(fd, std.posix.POLL.OUT),
                .closed, .fail => return error.WriteFailed,
            }
        }
    }

    pub fn pending(self: *Conn) usize {
        const n = ossl.SSL_pending(self.ssl);
        return if (n > 0) @intCast(n) else 0;
    }

    const Want = enum { want_read, want_write, closed, fail };

    fn mapWant(self: *Conn, n: c_int) Want {
        const e = ossl.SSL_get_error(self.ssl, n);
        if (e == ossl.SSL_ERROR_WANT_READ) {
            self.want_write = false;
            return .want_read;
        }
        if (e == ossl.SSL_ERROR_WANT_WRITE) {
            self.want_write = true;
            return .want_write;
        }
        if (e == ossl.SSL_ERROR_ZERO_RETURN) return .closed;
        return .fail;
    }
};

/// Owns the TLS session in a zust `Box` so double-free is a compile error.
pub fn connect(allocator: std.mem.Allocator, fd: std.posix.fd_t, opt: Options) !safe.Box(Conn) {
    _ = ossl.OPENSSL_init_ssl(0, null);
    const ssl = blk: {
        const raw = ossl.SSL_CTX_new(ossl.TLS_client_method()) orelse return error.SslCtx;
        errdefer ossl.SSL_CTX_free(raw);
        _ = ossl.SSL_CTX_ctrl(raw, ossl.SSL_CTRL_SET_MIN_PROTO_VERSION, ossl.TLS1_2_VERSION, null);

        if (opt.insecure) {
            ossl.SSL_CTX_set_verify(raw, ossl.SSL_VERIFY_NONE, null);
        } else {
            ossl.SSL_CTX_set_verify(raw, ossl.SSL_VERIFY_PEER, null);
            _ = ossl.SSL_CTX_set_default_verify_paths(raw);
        }

        const s = ossl.SSL_new(raw) orelse return error.Ssl;
        // Drop our CTX ref; `s` keeps the last one. Scoped errdefer must not run.
        ossl.SSL_CTX_free(raw);
        break :blk s;
    };
    errdefer ossl.SSL_free(ssl);

    if (ossl.SSL_set_fd(ssl, fd) != 1) return error.Ssl;
    if (opt.mode == .naps) {
        if (ossl.SSL_set_alpn_protos(ssl, alpn_wire.ptr, @intCast(alpn_wire.len)) != 0)
            return error.Alpn;
    } else if (opt.mode == .http) {
        if (ossl.SSL_set_alpn_protos(ssl, alpn_http_wire.ptr, @intCast(alpn_http_wire.len)) != 0)
            return error.Alpn;
    }

    if (!isIpLiteral(opt.server_name)) {
        var name_z = try owned.CString.fromSlice(allocator, opt.server_name);
        defer name_z.deinit();
        _ = ossl.SSL_ctrl(
            ssl,
            ossl.SSL_CTRL_SET_TLSEXT_HOSTNAME,
            ossl.TLSEXT_NAMETYPE_host_name,
            @ptrCast(@constCast(name_z.asPtr())),
        );
        if (!opt.insecure) _ = ossl.SSL_set1_host(ssl, name_z.asPtr());
    }

    ossl.SSL_set_connect_state(ssl);
    if (ossl.SSL_connect(ssl) != 1) {
        if (!opt.insecure) {
            const v = ossl.SSL_get_verify_result(ssl);
            if (v != ossl.X509_V_OK) {
                if (!opt.quiet) logVerify(v);
                return error.CertVerify;
            }
        }
        if (!opt.quiet) logErr("tls handshake");
        return error.Handshake;
    }
    if (!opt.insecure) {
        const v = ossl.SSL_get_verify_result(ssl);
        if (v != ossl.X509_V_OK) {
            if (!opt.quiet) logVerify(v);
            return error.CertVerify;
        }
    }

    const naps_alpn = selectedAlpn(ssl);
    if (opt.mode == .naps and !naps_alpn) return error.Alpn;

    return try safe.Box(Conn).init(allocator, .{ .ssl = ssl, .naps_alpn = naps_alpn });
}

pub fn isIpLiteral(host: []const u8) bool {
    if (host.len == 0) return false;
    const h = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        host[1 .. host.len - 1]
    else
        host;
    if (std.mem.indexOfScalar(u8, h, ':') != null) return true;
    var dots: usize = 0;
    for (h) |c| {
        if (c == '.') {
            dots += 1;
        } else if (!std.ascii.isDigit(c)) {
            return false;
        }
    }
    return dots == 3;
}

fn selectedAlpn(ssl: *ossl.SSL) bool {
    var data: [*c]const u8 = undefined;
    var len: c_uint = 0;
    ossl.SSL_get0_alpn_selected(ssl, &data, &len);
    return len == alpn_id.len and std.mem.eql(u8, data[0..len], alpn_id);
}

fn intLen(n: usize) c_int {
    return @intCast(@min(n, std.math.maxInt(c_int)));
}

fn wait(fd: std.posix.fd_t, events: i16) !void {
    var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    const n = std.posix.poll(&pfd, 5000) catch return error.WriteFailed;
    if (n == 0) return error.WouldBlock;
}

fn logErr(prefix: []const u8) void {
    var buf: [256]u8 = undefined;
    const e = ossl.ERR_get_error();
    if (e == 0) {
        std.log.err("{s}", .{prefix});
        return;
    }
    _ = ossl.ERR_error_string_n(e, &buf, buf.len);
    std.log.err("{s}: {s}", .{ prefix, std.mem.sliceTo(&buf, 0) });
}

fn logVerify(result: c_long) void {
    const msg = ossl.X509_verify_cert_error_string(result);
    if (msg == null) {
        std.log.err("tls certificate: verify error {d}", .{result});
        return;
    }
    std.log.err("tls certificate: {s}", .{std.mem.span(msg)});
}

test "naps/1 alpn wire" {
    try std.testing.expectEqual(@as(u8, 6), alpn_wire[0]);
    try std.testing.expectEqualStrings(alpn_id, alpn_wire[1..]);
}

test "ip literal" {
    try std.testing.expect(isIpLiteral("127.0.0.1"));
    try std.testing.expect(isIpLiteral("::1"));
    try std.testing.expect(isIpLiteral("[::1]"));
    try std.testing.expect(!isIpLiteral("localhost"));
    try std.testing.expect(!isIpLiteral("nap.example"));
}
