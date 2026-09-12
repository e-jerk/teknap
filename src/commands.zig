const std = @import("std");
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const util = @import("util.zig");
const share = @import("share.zig");
const owned = @import("owned.zig");

const App = client_mod.App;

const Handler = *const fn (*App, []const u8) anyerror!void;

const Entry = struct {
    name: []const u8,
    help: []const u8,
    func: Handler,
};

fn helpCmd(app: *App, args: []const u8) !void {
    const want = std.mem.trim(u8, args, " ");
    if (want.len != 0) {
        for (table) |e| {
            if (util.eqlIgnoreCase(e.name, want)) {
                app.say("/{s} — {s}", .{ e.name, e.help });
                return;
            }
        }
        app.say("No help for /{s}", .{want});
        return;
    }
    app.say("Commands (prefix with /). Type /help NAME for details.", .{});
    for (table) |e| {
        app.say("  /{s:<14} {s}", .{ e.name, e.help });
    }
}

fn quitCmd(app: *App, _: []const u8) !void {
    app.say("Signoff.", .{});
    app.running = false;
}

fn serverCmd(app: *App, args: []const u8) !void {
    var p = protocol.Parser.init(args);
    const first = p.next() orelse {
        if (app.options.servers.items.len == 0) {
            app.say("No servers configured.", .{});
            return;
        }
        for (app.options.servers.items, 0..) |s, i| {
            const mark: u8 = if (app.stream != null and
                std.mem.eql(u8, app.connected_host.slice(), s.host) and
                app.connected_port == s.port) '*' else ' ';
            app.say("{c}{d} {s}:{d}{s}{s}", .{
                mark,
                i,
                s.host,
                s.port,
                if (s.meta) " meta" else "",
                if (s.irc) " irc" else if (s.tls) " tls" else "",
            });
        }
        return;
    };
    if (util.eqlIgnoreCase(first, "-add")) {
        const spec = p.remainder();
        if (spec.len == 0) {
            app.say("Usage: /server -add [https:|tls:]host:port:nick:pass:meta  (8876 = TLS metaserver)", .{});
            return;
        }
        try app.options.addServer(spec);
        app.say("Added server {s}", .{spec});
        return;
    }
    if (util.eqlIgnoreCase(first, "-create")) {
        app.creating = true;
        app.say("Next login will create the account.", .{});
        const rest = p.remainder();
        if (rest.len != 0) try connectSpec(app, rest);
        return;
    }
    if (protocol.parseU32(first)) |idx| {
        if (idx >= app.options.servers.items.len) {
            app.yell("No server {d}", .{idx});
            return;
        }
        try app.connectEntry(app.options.servers.items[idx]);
        return;
    }
    var spec_buf: [512]u8 = undefined;
    const spec = if (p.done())
        first
    else
        std.fmt.bufPrint(&spec_buf, "{s} {s}", .{ first, p.remainder() }) catch first;
    try connectSpec(app, spec);
}

fn connectSpec(app: *App, spec: []const u8) !void {
    const parsed = util.parseServerSpec(spec);
    try app.connectHost(parsed.host, parsed.port, parsed.meta, parsed.tls, parsed.irc);
}

fn closeCmd(app: *App, _: []const u8) !void {
    app.disconnect();
    app.say("Disconnected.", .{});
}

fn joinCmd(app: *App, args: []const u8) !void {
    const chan = std.mem.trim(u8, args, " ");
    if (chan.len == 0) {
        if (app.channelName()) |c| app.say("On channel {s}", .{c}) else app.say("Not on a channel.", .{});
        return;
    }
    try app.sendFmt(.join, "{s}", .{chan});
}

fn partCmd(app: *App, args: []const u8) !void {
    const chan = blk: {
        const t = std.mem.trim(u8, args, " ");
        if (t.len != 0) break :blk t;
        break :blk app.channelName() orelse {
            app.say("Not on a channel.", .{});
            return;
        };
    };
    try app.sendFmt(.part, "{s}", .{chan});
}

fn sayCmd(app: *App, args: []const u8) !void {
    const chan = app.channelName() orelse {
        app.say("Join a channel first.", .{});
        return;
    };
    try app.sendFmt(.send, "{s} {s}", .{ chan, args });
    app.ui.logLine(.public_msg, "<{s}> {s}", .{ app.nick.slice(), args });
}

fn msgCmd(app: *App, args: []const u8) !void {
    var p = protocol.Parser.init(args);
    const nick = p.next() orelse {
        app.say("Usage: /msg <nick> <text>", .{});
        return;
    };
    const text = p.remainder();
    try app.sendFmt(.send_msg, "{s} {s}", .{ nick, text });
    app.ui.logLine(.private, "-> *{s}* {s}", .{ nick, text });
    try owned.replaceOpt(app.gpa, &app.last_query, nick);
}

fn queryCmd(app: *App, args: []const u8) !void {
    const nick = std.mem.trim(u8, args, " ");
    if (nick.len == 0) {
        if (app.last_query != null) {
            owned.clearOpt(&app.last_query);
            app.say("Query cleared.", .{});
        } else app.say("No query.", .{});
        return;
    }
    try owned.replaceOpt(app.gpa, &app.last_query, nick);
    app.say("Querying {s}", .{nick});
}

fn meCmd(app: *App, args: []const u8) !void {
    const chan = app.channelName() orelse {
        app.say("Join a channel first.", .{});
        return;
    };
    try app.sendFmt(.emote, "{s} \"{s}\"", .{ chan, args });
    app.ui.logLine(.public_msg, "* {s} {s}", .{ app.nick.slice(), args });
}

fn topicCmd(app: *App, args: []const u8) !void {
    const chan = app.channelName() orelse {
        app.say("Join a channel first.", .{});
        return;
    };
    const t = std.mem.trim(u8, args, " ");
    if (t.len == 0) {
        if (app.topicText()) |tp| app.say("Topic: {s}", .{tp}) else app.say("No topic.", .{});
        return;
    }
    try app.sendFmt(.topic, "{s} {s}", .{ chan, t });
}

fn namesCmd(app: *App, args: []const u8) !void {
    const chan = blk: {
        const t = std.mem.trim(u8, args, " ");
        if (t.len != 0) break :blk t;
        break :blk app.channelName() orelse {
            app.say("Usage: /names <channel>", .{});
            return;
        };
    };
    try app.sendFmt(.name, "{s}", .{chan});
}

fn listCmd(app: *App, _: []const u8) !void {
    app.listing = true;
    try app.send(.show_all_channels, &.{});
}

fn whoisCmd(app: *App, args: []const u8) !void {
    const nick = std.mem.trim(u8, args, " ");
    if (nick.len == 0) {
        app.say("Usage: /whois <nick>", .{});
        return;
    }
    try app.sendFmt(.whois, "{s}", .{nick});
}

fn pingCmd(app: *App, args: []const u8) !void {
    const nick = std.mem.trim(u8, args, " ");
    if (nick.len == 0) {
        app.say("Usage: /ping <nick>", .{});
        return;
    }
    try app.sendFmt(.ping, "{s}", .{nick});
}

fn motdCmd(app: *App, _: []const u8) !void {
    try app.send(.motd_line, &.{});
}

fn historyCmd(app: *App, args: []const u8) !void {
    const t = std.mem.trim(u8, args, " ");
    if (t.len == 0) {
        app.say("Usage: /history <target> [params]", .{});
        return;
    }
    try app.sendFmt(.chathistory, "{s}", .{t});
}

fn statsCmd(app: *App, _: []const u8) !void {
    try app.send(.stats, &.{});
    app.say("Users {d}  files {d}  ~{d} GB", .{
        app.stats_users, app.stats_files, app.stats_gigs,
    });
}

fn searchCmd(app: *App, args: []const u8) !void {
    var rest = std.mem.trim(u8, args, " ");
    if (rest.len == 0) {
        app.printSearch();
        return;
    }
    var typ: ?[]const u8 = null;
    if (std.mem.startsWith(u8, rest, "-t ") or std.mem.startsWith(u8, rest, "--type ")) {
        var p = protocol.Parser.init(rest);
        _ = p.next();
        const t = p.next() orelse {
            app.yell("Usage: /search [-t mp3|audio|video|application|image|text] query", .{});
            return;
        };
        typ = protocol.parseContentType(t) orelse {
            app.yell("Invalid search type '{s}'. Use mp3, audio, video, application, image, or text (not any).", .{t});
            return;
        };
        rest = std.mem.trim(u8, p.remainder(), " ");
        if (rest.len == 0) {
            app.yell("Usage: /search [-t type] query", .{});
            return;
        }
    }
    if (app.searching) {
        app.say("Search already in progress. /search with no args shows results.", .{});
        return;
    }
    for (app.search.items) |*h| h.deinit();
    app.search.clearRetainingCapacity();
    app.searching = true;
    var buf: [512]u8 = undefined;
    const payload = if (typ) |t|
        try std.fmt.bufPrint(&buf, "FILENAME CONTAINS \"{s}\" MAX_RESULTS {d} TYPE {s}", .{
            rest, app.options.max_results, t,
        })
    else
        try std.fmt.bufPrint(&buf, "FILENAME CONTAINS \"{s}\" MAX_RESULTS {d}", .{
            rest, app.options.max_results,
        });
    try app.sendFmt(.search, "{s}", .{payload});
    if (typ) |t|
        app.say("Searching for \"{s}\" (type {s})...", .{ rest, t })
    else
        app.say("Searching for \"{s}\"...", .{rest});
}

fn browseCmd(app: *App, args: []const u8) !void {
    const nick = std.mem.trim(u8, args, " ");
    if (nick.len == 0) {
        app.printBrowse();
        return;
    }
    for (app.browse.items) |*h| h.deinit();
    app.browse.clearRetainingCapacity();
    try app.sendFmt(.browse, "{s}", .{nick});
    app.say("Browsing {s}...", .{nick});
}

fn getCmd(app: *App, args: []const u8) !void {
    const t = std.mem.trim(u8, args, " ");
    if (t.len == 0) {
        app.printSearch();
        return;
    }
    if (protocol.parseU32(t)) |idx| {
        if (idx == 0 or idx > app.search.items.len) {
            app.yell("No result {d}", .{idx});
            return;
        }
        try app.requestGet(app.search.items[idx - 1]);
        return;
    }
    var p = protocol.Parser.init(t);
    const nick = p.next() orelse return;
    const file = p.nextQuoted() orelse p.remainder();
    if (file.len == 0) {
        app.say("Usage: /get <index>  or  /get <nick> \"filename\"", .{});
        return;
    }
    var hit = client_mod.OwnedHit{
        .filename = try owned.String.initFromSlice(app.gpa, file),
        .checksum = try owned.String.initFromSlice(app.gpa, ""),
        .nick = try owned.String.initFromSlice(app.gpa, nick),
        .size = 0,
        .bitrate = 0,
        .freq = 0,
        .seconds = 0,
        .ip = 0,
        .speed = 0,
    };
    defer hit.deinit();
    try app.requestGet(hit);
}

fn browseGetCmd(app: *App, args: []const u8) !void {
    const idx = protocol.parseU32(std.mem.trim(u8, args, " ")) orelse {
        app.say("Usage: /bget <browse-index>", .{});
        return;
    };
    if (idx == 0 or idx > app.browse.items.len) {
        app.yell("No browse result {d}", .{idx});
        return;
    }
    try app.requestGet(app.browse.items[idx - 1]);
}

fn glistCmd(app: *App, _: []const u8) !void {
    if (app.transfers.items.len == 0) {
        app.say("No transfers.", .{});
        return;
    }
    for (app.transfers.items, 0..) |t, i| {
        const pct: u64 = if (t.size == 0) 0 else t.received * 100 / t.size;
        app.ui.logLine(.transfer, "{d} {s} {s} {s} {d}% ({d}/{d})", .{
            i + 1,
            if (t.kind == .download) "GET" else "PUT",
            t.nick.slice(),
            util.basename(t.remote_path.slice()),
            pct,
            t.received,
            t.size,
        });
    }
}

fn shareCmd(app: *App, args: []const u8) !void {
    const path = std.mem.trim(u8, args, " ");
    if (path.len == 0) {
        app.say("Sharing {d} files. Usage: /share <directory>", .{app.shares.items.len});
        return;
    }
    const expanded = try util.expandHome(app.gpa, app.options.home, path);
    defer app.gpa.free(expanded);
    app.say("Scanning {s}...", .{expanded});
    const n = try share.scanDir(app.gpa, app.io, expanded, &app.shares);
    app.say("Found {d} files.", .{n});
    if (app.logged_in) app.resendShares();
}

fn hotlistCmd(app: *App, args: []const u8) !void {
    var p = protocol.Parser.init(args);
    const first = p.next() orelse {
        if (app.hotlist.items.len == 0) {
            app.say("Hotlist empty.", .{});
            return;
        }
        for (app.hotlist.items) |n| app.say("  {s}", .{n.slice()});
        return;
    };
    if (util.eqlIgnoreCase(first, "-")) {
        const nick = p.next() orelse return;
        var i: usize = 0;
        while (i < app.hotlist.items.len) : (i += 1) {
            if (util.eqlIgnoreCase(app.hotlist.items[i].slice(), nick)) {
                var gone = app.hotlist.orderedRemove(i);
                gone.deinit();
                try app.sendFmt(.hotlist_remove, "{s}", .{nick});
                app.say("Removed {s} from hotlist", .{nick});
                return;
            }
        }
        return;
    }
    const nick = first;
    try app.hotlist.append(app.gpa, try owned.String.initFromSlice(app.gpa, nick));
    try app.sendFmt(.add_hotlist, "{s}", .{nick});
}

fn ignoreCmd(app: *App, args: []const u8) !void {
    const nick = std.mem.trim(u8, args, " ");
    if (nick.len == 0) {
        for (app.ignores.items) |n| app.say("  {s}", .{n.slice()});
        return;
    }
    for (app.ignores.items, 0..) |n, i| {
        if (util.eqlIgnoreCase(n.slice(), nick)) {
            var gone = app.ignores.orderedRemove(i);
            gone.deinit();
            app.say("Unignored {s}", .{nick});
            return;
        }
    }
    try app.ignores.append(app.gpa, try owned.String.initFromSlice(app.gpa, nick));
    app.say("Ignoring {s}", .{nick});
}

fn rawCmd(app: *App, args: []const u8) !void {
    var p = protocol.Parser.init(args);
    const num = protocol.parseU16(p.next() orelse "") orelse {
        app.say("Usage: /raw <numeric> [payload]", .{});
        return;
    };
    const payload = p.remainder();
    try app.send(@enumFromInt(num), payload);
}

fn nickCmd(app: *App, args: []const u8) !void {
    const n = std.mem.trim(u8, args, " ");
    if (n.len == 0 or n.len > protocol.nick_max) {
        app.say("Current nick: {s}", .{app.nick.slice()});
        return;
    }
    try owned.set(&app.nick, n);
    app.say("Nick set to {s} (reconnect to apply)", .{n});
}

fn setCmd(app: *App, args: []const u8) !void {
    var p = protocol.Parser.init(args);
    const key = p.next() orelse {
        app.say("dataport={d} speed={d} max_results={d} download={s}", .{
            app.options.dataport,
            app.options.speed,
            app.options.max_results,
            app.options.download_dir,
        });
        return;
    };
    const val = p.remainder();
    if (util.eqlIgnoreCase(key, "dataport")) {
        app.options.dataport = protocol.parseU16(val) orelse app.options.dataport;
    } else if (util.eqlIgnoreCase(key, "speed")) {
        app.options.speed = @intCast(@min(protocol.parseU32(val) orelse 7, 10));
    } else if (util.eqlIgnoreCase(key, "max_results")) {
        app.options.max_results = protocol.parseU32(val) orelse 100;
    } else if (util.eqlIgnoreCase(key, "download")) {
        app.gpa.free(app.options.download_dir);
        app.options.download_dir = try util.expandHome(app.gpa, app.options.home, val);
    } else {
        app.say("Unknown set variable: {s}", .{key});
        return;
    }
    app.say("Set {s}", .{key});
}

fn clearCmd(app: *App, _: []const u8) !void {
    for (app.ui.log.items) |*line| line.text.deinit();
    app.ui.log.clearRetainingCapacity();
    app.ui.dirty = true;
}

fn versionCmd(app: *App, _: []const u8) !void {
    app.say("{s}  (internal {s})", .{ protocol.version, protocol.internal_version });
}

fn usersCmd(app: *App, _: []const u8) !void {
    if (app.users.items.len == 0) {
        app.say("No channel users (try /names).", .{});
        return;
    }
    for (app.users.items) |u| {
        app.say("  {s:<16} {d} files  {s}", .{ u.nick.slice(), u.files, protocol.speedName(u.speed) });
    }
}

fn kickCmd(app: *App, args: []const u8) !void {
    const chan = app.channelName() orelse return app.say("Join a channel first.", .{});
    var p = protocol.Parser.init(args);
    const nick = p.next() orelse return app.say("Usage: /kick <nick> [reason]", .{});
    const reason = p.remainder();
    if (reason.len != 0)
        try app.sendFmt(.kick, "{s} {s} \"{s}\"", .{ chan, nick, reason })
    else
        try app.sendFmt(.kick, "{s} {s}", .{ chan, nick });
}

fn adminSend(comptime cmd: protocol.Cmd) Handler {
    return struct {
        fn f(app: *App, args: []const u8) anyerror!void {
            try app.sendFmt(cmd, "{s}", .{std.mem.trim(u8, args, " ")});
        }
    }.f;
}

fn echoCmd(app: *App, args: []const u8) !void {
    app.ui.logLine(.normal, "{s}", .{args});
}

const table = [_]Entry{
    .{ .name = "help", .help = "list commands", .func = helpCmd },
    .{ .name = "quit", .help = "exit TekNap", .func = quitCmd },
    .{ .name = "exit", .help = "exit TekNap", .func = quitCmd },
    .{ .name = "server", .help = "[-add spec | index | [tls:]host[:port]]", .func = serverCmd },
    .{ .name = "close", .help = "disconnect from server", .func = closeCmd },
    .{ .name = "disconnect", .help = "disconnect from server", .func = closeCmd },
    .{ .name = "join", .help = "<channel>", .func = joinCmd },
    .{ .name = "part", .help = "[channel]", .func = partCmd },
    .{ .name = "leave", .help = "[channel]", .func = partCmd },
    .{ .name = "l", .help = "leave current channel", .func = partCmd },
    .{ .name = "say", .help = "<text>", .func = sayCmd },
    .{ .name = "msg", .help = "<nick> <text>", .func = msgCmd },
    .{ .name = "m", .help = "<nick> <text>", .func = msgCmd },
    .{ .name = "query", .help = "[nick]", .func = queryCmd },
    .{ .name = "me", .help = "<action>", .func = meCmd },
    .{ .name = "topic", .help = "[new topic]", .func = topicCmd },
    .{ .name = "names", .help = "[channel]", .func = namesCmd },
    .{ .name = "list", .help = "list channels", .func = listCmd },
    .{ .name = "whois", .help = "<nick>", .func = whoisCmd },
    .{ .name = "w", .help = "<nick>", .func = whoisCmd },
    .{ .name = "ping", .help = "<nick>", .func = pingCmd },
    .{ .name = "motd", .help = "request message of the day", .func = motdCmd },
    .{ .name = "history", .help = "<target> [params] — CHATHISTORY", .func = historyCmd },
    .{ .name = "stats", .help = "server library stats", .func = statsCmd },
    .{ .name = "search", .help = "[-t type] <query>  (no args: show results)", .func = searchCmd },
    .{ .name = "s", .help = "alias for /search", .func = searchCmd },
    .{ .name = "browse", .help = "<nick>", .func = browseCmd },
    .{ .name = "get", .help = "<index> | <nick> \"file\"", .func = getCmd },
    .{ .name = "request", .help = "<nick> \"file\"", .func = getCmd },
    .{ .name = "bget", .help = "<browse-index>", .func = browseGetCmd },
    .{ .name = "glist", .help = "show transfers", .func = glistCmd },
    .{ .name = "share", .help = "<directory>", .func = shareCmd },
    .{ .name = "scan", .help = "<directory>", .func = shareCmd },
    .{ .name = "hotlist", .help = "[nick] or - <nick>", .func = hotlistCmd },
    .{ .name = "ignore", .help = "[nick]", .func = ignoreCmd },
    .{ .name = "raw", .help = "<numeric> [payload]", .func = rawCmd },
    .{ .name = "nick", .help = "[newnick]", .func = nickCmd },
    .{ .name = "set", .help = "[var [value]]", .func = setCmd },
    .{ .name = "clear", .help = "clear scrollback", .func = clearCmd },
    .{ .name = "version", .help = "show client version", .func = versionCmd },
    .{ .name = "users", .help = "channel user list", .func = usersCmd },
    .{ .name = "kick", .help = "<nick> [reason]", .func = kickCmd },
    .{ .name = "echo", .help = "<text>", .func = echoCmd },
    .{ .name = "ban", .help = "<nick|ip> [reason]", .func = adminSend(.ban_user) },
    .{ .name = "unban", .help = "<nick|ip>", .func = adminSend(.unban_user) },
    .{ .name = "kill", .help = "<nick> [reason]", .func = adminSend(.kill_user) },
    .{ .name = "muzzle", .help = "<nick>", .func = adminSend(.muzzle) },
    .{ .name = "unmuzzle", .help = "<nick>", .func = adminSend(.unmuzzle) },
    .{ .name = "opsay", .help = "<text>", .func = adminSend(.opsay) },
    .{ .name = "announce", .help = "<text>", .func = adminSend(.announce) },
    .{ .name = "cloak", .help = "toggle cloak", .func = adminSend(.cloak) },
};

pub fn dispatch(app: *App, line: []const u8) !void {
    var p = protocol.Parser.init(line);
    const name = p.next() orelse return;
    const args = p.remainder();
    var matches: usize = 0;
    var found: ?Entry = null;
    for (table) |e| {
        if (util.startsWithIgnoreCase(e.name, name) and e.name.len >= name.len) {
            matches += 1;
            found = e;
            if (util.eqlIgnoreCase(e.name, name)) {
                matches = 1;
                break;
            }
        }
    }
    if (found == null or matches != 1) {
        if (matches > 1) app.say("Ambiguous command: {s}", .{name}) else app.say("Unknown command: {s}  (/help)", .{name});
        return;
    }
    found.?.func(app, args) catch |err| switch (err) {
        error.NotConnected => {},
        else => app.yell("Command error: {s}", .{@errorName(err)}),
    };
}

pub fn loadRc(app: *App, path: []const u8) void {
    const src = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 20)) catch return;
    defer app.gpa.free(src);
    app.say("Loading {s}", .{path});
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const cmd = if (line[0] == '/') line[1..] else line;
        dispatch(app, cmd) catch {};
    }
}
