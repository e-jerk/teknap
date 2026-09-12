const std = @import("std");

pub const version = "TekNap-2.1.0";
pub const client_info = "TekNap 2.1";
pub const internal_version = "20000909";
pub const default_port: u16 = 8875;
/// OpenNap metaserver immediate-TLS listen (`metaserver -T`).
pub const default_meta_tls_port: u16 = 8876;
/// HTTPS `GET /meta` (`meta-1` JSON) on the OpenNap WSS listener.
pub const default_https_meta_port: u16 = 443;
/// Plain HTTP `GET /meta` on the OpenNap WebSocket listener.
pub const default_ws_meta_port: u16 = 8890;
/// RFC 7194 `ircs-u` / e-jerk opennap default TLS port.
pub const default_tls_port: u16 = 6697;
/// sbcas opennap TLS port (also accepted when inferring TLS from port alone).
pub const legacy_tls_port: u16 = 8887;
pub const alpn_id = "naps/1";
pub const default_data_port: u16 = 6699;
pub const nick_max = 15;
pub const header_size = 4;
pub const max_payload = 4096;
pub const napster_hash_bytes = 299008;

pub const Cmd = enum(u16) {
    error_msg = 0,
    unknown = 1,
    login = 2,
    email = 3,
    version_check = 4,
    auto_upgrade = 5,
    register_info = 6,
    create_user = 7,
    created = 8,
    create_error = 9,
    illegal_nick = 10,
    login_error = 13,
    options = 14,
    mstat = 15,
    request_user_speed = 89,
    send_file = 95,
    add_file = 100,
    remove_file = 102,
    get_queue = 108,
    motd = 109,
    remove_all_files = 110,
    another_user = 148,
    search = 200,
    search_results = 201,
    search_end = 202,
    request_file = 203,
    file_ready = 204,
    send_msg = 205,
    get_error = 206,
    add_hotlist = 207,
    add_hotlist_seq = 208,
    hotlist_online = 209,
    user_offline = 210,
    browse = 211,
    browse_result = 212,
    browse_end = 213,
    stats = 214,
    request_resume = 215,
    resume_success = 216,
    resume_end = 217,
    download_start = 218,
    download_end = 219,
    upload_start = 220,
    upload_end = 221,
    test_port = 300,
    hotlist_success = 301,
    hotlist_error = 302,
    hotlist_remove = 303,
    block_list = 330,
    block = 332,
    unblock = 333,
    join = 400,
    part = 401,
    send = 402,
    public_msg = 403,
    error_text = 404,
    joined = 405,
    join_new = 406,
    parted = 407,
    names = 408,
    names_end = 409,
    topic = 410,
    cban_list = 420,
    cban_entry = 421,
    cban = 422,
    cunban = 423,
    cban_clear = 424,
    request_file_fire = 500,
    file_info_fire = 501,
    request_line_speed = 600,
    line_speed = 601,
    request_size = 602,
    whois = 603,
    whois_result = 604,
    whowas = 605,
    set_user_level = 606,
    file_request = 607,
    file_info = 608,
    accept_error = 609,
    kill_user = 610,
    nuke_user = 611,
    ban_user = 612,
    set_data_port = 613,
    unban_user = 614,
    ban_list = 615,
    ban_list_ip = 616,
    list_channels = 617,
    channel_entry = 618,
    send_limit = 619,
    send_limit_ack = 620,
    motd_line = 621,
    muzzle = 622,
    unmuzzle = 623,
    unnuke = 624,
    set_line_speed = 625,
    data_port_error = 626,
    opsay = 627,
    announce = 628,
    ban_list_nick = 629,
    browse_direct_req = 640,
    browse_direct = 641,
    browse_direct_error = 642,
    cloak = 652,
    change_speed = 700,
    change_pass = 701,
    change_email = 702,
    change_data = 703,
    sping = 750,
    ping = 751,
    pong = 752,
    set_password = 753,
    reload_config = 800,
    server_version = 801,
    set_config = 810,
    clear_channel = 820,
    client_redir = 821,
    cycle = 822,
    set_chan_level = 823,
    emote = 824,
    nick_entry = 825,
    set_chan_limit = 826,
    show_all_channels = 827,
    all_channels = 828,
    kick = 829,
    name = 830,
    show_users = 831,
    show_users_list = 832,
    share_path = 870,
    set_capability = 920,
    share_file = 10300,
    browse_new = 10301,
    browse_result_new = 10302,
    server_link = 10100,
    server_unlink = 10101,
    server_kill = 10110,
    server_remove = 10111,
    server_links = 10112,
    server_usage = 10115,
    server_ping = 10116,
    server_rehash = 10117,
    client_version = 10118,
    server_mping = 10120,
    whowas_opennap = 10121,
    mkill = 10122,
    histogram = 10123,
    histogram_end = 10124,
    admin_register = 10200,
    kick_user = 10202,
    user_mode = 10203,
    create_op = 10204,
    delete_op = 10205,
    list_ops = 10206,
    drop_channel = 10207,
    opwall = 10208,
    channel_mode = 10209,
    channel_invite = 10210,
    channel_voice = 10211,
    channel_unvoice = 10212,
    channel_muzzle = 10213,
    channel_unmuzzle = 10214,
  // e-jerk / opennap extensions (classic clients may ignore)
    chathistory = 11000,
    chathistory_line = 11001,
    chathistory_end = 11002,
    away_set = 11003,
    away_notice = 11004,
    memo = 11005,
    memo_end = 11006,
    isupport = 11007,
    cap = 11010,
    cap_reply = 11011,
    authenticate = 11012,
    authenticate_challenge = 11013,
    batch = 11014,
    batch_end = 11015,
    fail = 11016,
    warn = 11017,
    note = 11018,
    tagmsg = 11019,
    redact = 11021,
    edit = 11023,
    session_resume = 11026,
    account = 11027,
    sts = 11028,
    key_out = 11029,
    key = 11030,
    server_user_sharing = 10012,
    _,
};

pub const speeds = [_][]const u8{
    "unknown",
    "14.4k",
    "28.8k",
    "33.6k",
    "56k",
    "64k ISDN",
    "128k ISDN",
    "Cable",
    "DSL",
    "T1",
    "T3+",
};

pub fn speedName(n: u32) []const u8 {
    if (n < speeds.len) return speeds[n];
    return "unknown";
}

/// OpenNap search/share TYPE values. `any` is rejected by the server.
pub const content_types = [_][]const u8{ "mp3", "audio", "video", "application", "image", "text" };

pub fn parseContentType(s: []const u8) ?[]const u8 {
    for (content_types) |t| {
        if (std.ascii.eqlIgnoreCase(s, t)) return t;
    }
    return null;
}

pub fn isTlsPort(port: u16) bool {
    return port == default_tls_port or port == legacy_tls_port;
}

/// Immediate TLS metaserver (no ALPN). Distinct from Napster `naps/1` ports.
pub fn isMetaTlsPort(port: u16) bool {
    return port == default_meta_tls_port;
}

pub fn isMetaPort(port: u16) bool {
    return port == default_port or port == default_meta_tls_port or
        port == default_https_meta_port or port == default_ws_meta_port;
}

pub fn isHttpsMetaPort(port: u16) bool {
    return port == default_https_meta_port;
}

pub fn isHttpMetaPort(port: u16) bool {
    return port == default_ws_meta_port;
}

pub fn isHttpishPort(port: u16) bool {
    return port == 80 or port == default_https_meta_port or port == default_ws_meta_port;
}

/// Query 8876 → 443 → 8875 before opening the hub (naps/1 or ircs-u).
pub fn shouldQueryTlsMeta(meta: bool, port: u16, naps_tls: bool, irc: bool) bool {
    if (meta or naps_tls) return true;
    return irc and (isTlsPort(port) or isMetaPort(port));
}

pub const Header = struct {
    len: u16,
    command: u16,

    pub fn encode(self: Header, out: *[header_size]u8) void {
        std.mem.writeInt(u16, out[0..2], self.len, .little);
        std.mem.writeInt(u16, out[2..4], self.command, .little);
    }

    pub fn decode(bytes: *const [header_size]u8) Header {
        return .{
            .len = std.mem.readInt(u16, bytes[0..2], .little),
            .command = std.mem.readInt(u16, bytes[2..4], .little),
        };
    }
};

pub const Message = struct {
    command: u16,
    payload: []const u8,

    pub fn write(self: Message, dest: []u8) !usize {
        if (self.payload.len > std.math.maxInt(u16)) return error.PayloadTooLarge;
        if (dest.len < header_size + self.payload.len) return error.NoSpace;
        const hdr: Header = .{
            .len = @intCast(self.payload.len),
            .command = self.command,
        };
        hdr.encode(dest[0..header_size]);
        @memcpy(dest[header_size..][0..self.payload.len], self.payload);
        return header_size + self.payload.len;
    }
};

/// Napster sends IPv4 as an unsigned integer in Intel (little-endian) order.
pub fn ipFromNapster(n: u32) [4]u8 {
    return .{
        @truncate(n),
        @truncate(n >> 8),
        @truncate(n >> 16),
        @truncate(n >> 24),
    };
}

pub fn ipToNapster(bytes: [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

pub fn formatIp(bytes: [4]u8, buf: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch buf[0..0];
}

pub const Parser = struct {
    rest: []const u8,

    pub fn init(line: []const u8) Parser {
        return .{ .rest = std.mem.trim(u8, line, " \t\r\n") };
    }

    pub fn peek(self: Parser) []const u8 {
        return self.rest;
    }

    pub fn done(self: Parser) bool {
        return self.rest.len == 0;
    }

    /// Space-separated token. Does not strip quotes.
    pub fn next(self: *Parser) ?[]const u8 {
        self.skipSpaces();
        if (self.rest.len == 0) return null;
        if (self.rest[0] == '"') return self.nextQuoted();
        const end = std.mem.indexOfAny(u8, self.rest, " \t") orelse {
            const tok = self.rest;
            self.rest = &.{};
            return tok;
        };
        const tok = self.rest[0..end];
        self.rest = self.rest[end..];
        return tok;
    }

    /// Quoted string or next token. Quotes are stripped.
    pub fn nextQuoted(self: *Parser) ?[]const u8 {
        self.skipSpaces();
        if (self.rest.len == 0) return null;
        if (self.rest[0] != '"') return self.next();
        const start = self.rest[1..];
        if (std.mem.indexOfScalar(u8, start, '"')) |end| {
            const tok = start[0..end];
            self.rest = start[end + 1 ..];
            return tok;
        }
        self.rest = &.{};
        return start;
    }

    pub fn remainder(self: *Parser) []const u8 {
        self.skipSpaces();
        const r = self.rest;
        self.rest = &.{};
        return r;
    }

    fn skipSpaces(self: *Parser) void {
        while (self.rest.len > 0 and (self.rest[0] == ' ' or self.rest[0] == '\t')) {
            self.rest = self.rest[1..];
        }
    }
};

pub fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

pub fn parseU16(s: []const u8) ?u16 {
    return std.fmt.parseInt(u16, s, 10) catch null;
}

pub fn parseU64(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

pub const FileHit = struct {
    filename: []const u8 = &.{},
    checksum: []const u8 = &.{},
    size: u64 = 0,
    bitrate: u32 = 0,
    freq: u32 = 0,
    seconds: u32 = 0,
    nick: []const u8 = &.{},
    ip: u32 = 0,
    speed: u32 = 0,
};

/// Search result: `"file" md5 size bitrate freq length nick ip speed [weight]`
pub fn parseSearchHit(line: []const u8) ?FileHit {
    var p = Parser.init(line);
    var hit: FileHit = .{};
    hit.filename = p.nextQuoted() orelse return null;
    hit.checksum = p.next() orelse return null;
    hit.size = parseU64(p.next() orelse return null) orelse return null;
    hit.bitrate = parseU32(p.next() orelse "0") orelse 0;
    hit.freq = parseU32(p.next() orelse "0") orelse 0;
    hit.seconds = parseU32(p.next() orelse "0") orelse 0;
    hit.nick = p.next() orelse return null;
    hit.ip = parseU32(p.next() orelse "0") orelse 0;
    hit.speed = parseU32(p.next() orelse "0") orelse 0;
    if (hit.filename.len == 0 or hit.nick.len == 0) return null;
    return hit;
}

/// Browse result: `nick "file" md5 size bitrate freq time`
pub fn parseBrowseHit(line: []const u8) ?FileHit {
    var p = Parser.init(line);
    var hit: FileHit = .{};
    hit.nick = p.next() orelse return null;
    hit.filename = p.nextQuoted() orelse return null;
    hit.checksum = p.next() orelse return null;
    hit.size = parseU64(p.next() orelse return null) orelse return null;
    hit.bitrate = parseU32(p.next() orelse "0") orelse 0;
    hit.freq = parseU32(p.next() orelse "0") orelse 0;
    hit.seconds = parseU32(p.next() orelse "0") orelse 0;
    hit.speed = parseU32(p.remainder()) orelse 0;
    if (hit.filename.len == 0 or hit.nick.len == 0) return null;
    return hit;
}

/// File ready (204): `nick ip port "file" md5 speed`
pub const FileReady = struct {
    nick: []const u8,
    ip: u32,
    port: u16,
    filename: []const u8,
    checksum: []const u8,
    speed: u32,
};

pub fn parseFileReady(line: []const u8) ?FileReady {
    var p = Parser.init(line);
    const nick = p.next() orelse return null;
    const ip = parseU32(p.next() orelse return null) orelse return null;
    const port = parseU16(p.next() orelse return null) orelse return null;
    const filename = p.nextQuoted() orelse return null;
    const checksum = p.next() orelse "";
    const speed = parseU32(p.next() orelse "0") orelse 0;
    return .{
        .nick = nick,
        .ip = ip,
        .port = port,
        .filename = filename,
        .checksum = checksum,
        .speed = speed,
    };
}

test "header little-endian" {
    var buf: [4]u8 = undefined;
    (Header{ .len = 256, .command = 2 }).encode(&buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x02, 0x00 }, &buf);
    const h = Header.decode(&buf);
    try std.testing.expectEqual(@as(u16, 256), h.len);
    try std.testing.expectEqual(@as(u16, 2), h.command);
}

test "parser quoted" {
    var p = Parser.init("lefty \"generic song.mp3\" 128");
    try std.testing.expectEqualStrings("lefty", p.next().?);
    try std.testing.expectEqualStrings("generic song.mp3", p.nextQuoted().?);
    try std.testing.expectEqualStrings("128", p.next().?);
}

test "search hit" {
    const line = "\"random band - random song.mp3\" 7d733c1e7419674744768db71bff8bcd 2558199 128 44100 159 lefty 3437166285 4";
    const hit = parseSearchHit(line).?;
    try std.testing.expectEqualStrings("random band - random song.mp3", hit.filename);
    try std.testing.expectEqualStrings("lefty", hit.nick);
    try std.testing.expectEqual(@as(u64, 2558199), hit.size);
    try std.testing.expectEqual(@as(u32, 4), hit.speed);
}

test "is tls port" {
    try std.testing.expect(isTlsPort(6697));
    try std.testing.expect(isTlsPort(8887));
    try std.testing.expect(!isTlsPort(8888));
    try std.testing.expect(!isTlsPort(8876));
    try std.testing.expect(isMetaTlsPort(8876));
    try std.testing.expect(!isMetaTlsPort(8875));
    try std.testing.expect(isMetaPort(8875));
    try std.testing.expect(isMetaPort(8876));
    try std.testing.expect(!isMetaPort(6697));
    try std.testing.expect(isHttpsMetaPort(443));
    try std.testing.expect(isHttpMetaPort(8890));
    try std.testing.expect(isMetaPort(443));
    try std.testing.expect(shouldQueryTlsMeta(false, 6697, true, false));
    try std.testing.expect(shouldQueryTlsMeta(false, 8887, true, false));
    try std.testing.expect(shouldQueryTlsMeta(true, 8875, false, false));
    try std.testing.expect(shouldQueryTlsMeta(false, 6697, false, true));
    try std.testing.expect(shouldQueryTlsMeta(true, 8876, false, true));
    try std.testing.expect(!shouldQueryTlsMeta(false, 8888, false, false));
    try std.testing.expect(!shouldQueryTlsMeta(false, 6667, false, true));
}

test "content type" {
    try std.testing.expectEqualStrings("video", parseContentType("VIDEO").?);
    try std.testing.expect(parseContentType("any") == null);
    try std.testing.expect(parseContentType("unknown") == null);
}

test "ip intel order" {
    const bytes = ipFromNapster(0x04030201);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &bytes);
    try std.testing.expectEqual(@as(u32, 0x04030201), ipToNapster(bytes));
}
