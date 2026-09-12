const std = @import("std");
const protocol = @import("protocol.zig");
const util = @import("util.zig");

pub const ServerEntry = struct {
    host: []u8,
    port: u16,
    nick: ?[]u8 = null,
    password: ?[]u8 = null,
    meta: bool = true,
    tls: bool = false,
    irc: bool = false,

    pub fn deinit(self: ServerEntry, gpa: std.mem.Allocator) void {
        gpa.free(self.host);
        if (self.nick) |n| gpa.free(n);
        if (self.password) |p| gpa.free(p);
    }
};

pub const Options = struct {
    gpa: std.mem.Allocator,
    nick: []u8,
    password: []u8,
    email: []u8 = &.{},
    home: []u8,
    rc_path: []u8,
    download_dir: []u8,
    share_dir: ?[]u8 = null,
    speed: u8 = 7,
    dataport: u16 = protocol.default_data_port,
    max_results: u32 = 100,
    auto_connect: bool = true,
    create_account: bool = false,
    add_servers: bool = false,
    capability: bool = false,
    force_tls: bool = false,
    force_irc: bool = false,
    insecure: bool = false,
    once: bool = false,
    gpg_spec: []u8,
    gpg_pass: []u8 = &.{},
    servers: std.ArrayList(ServerEntry) = .empty,
    start_index: usize = 0,
    extra_rc: ?[]u8 = null,

    pub fn deinit(self: *Options) void {
        self.gpa.free(self.nick);
        self.gpa.free(self.password);
        if (self.email.len != 0) self.gpa.free(self.email);
        self.gpa.free(self.home);
        self.gpa.free(self.rc_path);
        self.gpa.free(self.download_dir);
        if (self.share_dir) |s| self.gpa.free(s);
        if (self.extra_rc) |s| self.gpa.free(s);
        self.gpa.free(self.gpg_spec);
        if (self.gpg_pass.len != 0) self.gpa.free(self.gpg_pass);
        for (self.servers.items) |s| s.deinit(self.gpa);
        self.servers.deinit(self.gpa);
    }

    pub fn addServer(self: *Options, spec: []const u8) !void {
        const p = util.parseServerSpec(spec);
        if (p.host.len == 0) return;
        try self.servers.append(self.gpa, .{
            .host = try self.gpa.dupe(u8, p.host),
            .port = p.port,
            .nick = if (p.nick) |n| try self.gpa.dupe(u8, n) else null,
            .password = if (p.password) |pw| try self.gpa.dupe(u8, pw) else null,
            .meta = p.meta,
            .tls = p.tls,
            .irc = p.irc,
        });
    }
};

pub fn parseArgs(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !Options {
    const home = env.get("HOME") orelse "/tmp";
    var opt: Options = .{
        .gpa = gpa,
        .nick = try gpa.dupe(u8, env.get("NAPNICK") orelse "TekNap"),
        .password = try gpa.dupe(u8, env.get("NAPPASS") orelse "teknap"),
        .home = try gpa.dupe(u8, home),
        .rc_path = try std.fmt.allocPrint(gpa, "{s}/.teknaprc", .{home}),
        .download_dir = try std.fmt.allocPrint(gpa, "{s}/TekNap", .{home}),
        .gpg_spec = try gpa.dupe(u8, env.get("NAPGPG") orelse "default"),
        .gpg_pass = try gpa.dupe(u8, env.get("NAPGPG_PASSPHRASE") orelse ""),
    };
    errdefer opt.deinit();

    if (env.get("NAPPORT")) |p| {
        if (protocol.parseU16(p)) |port| {
            // applied to later server specs without a port
            _ = port;
        }
    }
    if (env.get("NAPTLS")) |v| {
        opt.force_tls = !(v.len == 0 or std.mem.eql(u8, v, "0"));
    }
    if (env.get("NAPINSECURE")) |v| {
        opt.insecure = !(v.len == 0 or std.mem.eql(u8, v, "0"));
    }
    if (env.get("NAPSERVER")) |list| {
        var it = std.mem.tokenizeAny(u8, list, " \t");
        while (it.next()) |spec| try opt.addServer(spec);
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            opt.auto_connect = false;
            return opt;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--version")) {
            continue;
        } else if (std.mem.eql(u8, a, "-N")) {
            opt.auto_connect = false;
        } else if (std.mem.eql(u8, a, "-C")) {
            opt.create_account = true;
        } else if (std.mem.eql(u8, a, "-a")) {
            opt.add_servers = true;
        } else if (std.mem.eql(u8, a, "-c")) {
            opt.capability = true;
        } else if (std.mem.eql(u8, a, "-T")) {
            opt.force_tls = true;
        } else if (std.mem.eql(u8, a, "-I")) {
            opt.force_irc = true;
            opt.force_tls = true;
        } else if (std.mem.eql(u8, a, "-k") or std.mem.eql(u8, a, "--insecure")) {
            opt.insecure = true;
        } else if (std.mem.eql(u8, a, "-1") or std.mem.eql(u8, a, "--once")) {
            opt.once = true;
        } else if (std.mem.eql(u8, a, "--no-gpg")) {
            gpa.free(opt.gpg_spec);
            opt.gpg_spec = try gpa.dupe(u8, "off");
        } else if ((std.mem.eql(u8, a, "--gpg") or std.mem.eql(u8, a, "--gpg-file")) and
            i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-')
        {
            i += 1;
            gpa.free(opt.gpg_spec);
            opt.gpg_spec = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, a, "--gpg")) {
            gpa.free(opt.gpg_spec);
            opt.gpg_spec = try gpa.dupe(u8, "default");
        } else if (std.mem.eql(u8, a, "-n") and i + 1 < args.len) {
            i += 1;
            gpa.free(opt.nick);
            opt.nick = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, a, "-p") and i + 1 < args.len) {
            i += 1;
            gpa.free(opt.password);
            opt.password = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, a, "-S") and i + 1 < args.len) {
            i += 1;
            opt.start_index = protocol.parseU32(args[i]) orelse 0;
        } else if (std.mem.eql(u8, a, "-r") and i + 1 < args.len) {
            i += 1;
            if (opt.extra_rc) |s| gpa.free(s);
            opt.extra_rc = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, a, "-H") and i + 1 < args.len) {
            i += 1;
            // bind address ignored for now
        } else if (a.len > 0 and a[0] != '-') {
            if (isPortToken(a) and opt.servers.items.len != 0) {
                applyCliPort(&opt.servers.items[opt.servers.items.len - 1], a);
            } else if (isHostToken(a)) {
                try opt.addServer(a);
                if (i + 1 < args.len and isPortToken(args[i + 1])) {
                    i += 1;
                    applyCliPort(&opt.servers.items[opt.servers.items.len - 1], args[i]);
                }
            } else {
                gpa.free(opt.nick);
                opt.nick = try gpa.dupe(u8, a);
            }
        }
    }

    if (opt.servers.items.len == 0) {
        try opt.addServer("napster.barrettharber.com");
    }
    return opt;
}

fn applyCliPort(entry: *ServerEntry, port_s: []const u8) void {
    const port = protocol.parseU16(port_s) orelse return;
    entry.port = port;
    if (protocol.isMetaTlsPort(port) or protocol.isHttpsMetaPort(port)) {
        entry.meta = true;
        entry.tls = true;
        return;
    }
    if (port == protocol.default_port or protocol.isHttpMetaPort(port)) {
        entry.meta = true;
        return;
    }
    entry.meta = false;
    if (protocol.isTlsPort(port)) entry.tls = true;
}

fn isPortToken(a: []const u8) bool {
    if (a.len == 0) return false;
    for (a) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isHostToken(a: []const u8) bool {
    if (util.isLocalHost(a)) return true;
    if (std.mem.indexOfScalar(u8, a, '.') != null) return true;
    if (std.mem.indexOfScalar(u8, a, ':') != null) return true;
    return false;
}

pub const usage =
    \\Usage: teknap [switches] [nickname] [server list]
    \\  The [nickname] can be at most 15 characters long
    \\  The [server list] is a whitespace separated list of server name
    \\  The [switches] may be any or all of the following
    \\   -C              create the account
    \\   -N              do not auto-connect to the first server
    \\   -S #            starting server to use
    \\   -n nickname     nickname to use
    \\   -p password     password to use
    \\   -a              add command-line servers to the list
    \\   -r filename     use filename for extra startup commands
    \\   -c              set napster beta8 capability
    \\   -T              connect with TLS naps/1 (Napster frames, port 6697)
    \\   -I              connect with TLS ircs-u (IRC lines, port 6697)
    \\   -k              skip TLS certificate verification
    \\   -1, --once      connect, print the session log, and exit
    \\   --gpg [spec]    use a GPG / Ed25519 key (default: system GnuPG secret)
    \\   --gpg-file PATH armored secret, hex seed file, or GnuPG homedir
    \\   --no-gpg        disable GPG
    \\   -v              print the client version
    \\  Server specs: host:port  tls:host:port  naps:host:port  irc:host:port  https:host  plain:host:port
    \\  Default: napster.barrettharber.com (TLS metaserver 8876, then 443 /meta, then 8875).
    \\  Hub: 6697 naps/1 or ircs-u. Metaserver: TLS 8876, then https://host/meta (443), then 8875.
    \\  GPG: NAPGPG (armored secret, hex seed, path, key id, or 0 to disable), NAPGPG_PASSPHRASE.
    \\
;
