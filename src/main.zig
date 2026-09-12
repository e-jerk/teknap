const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const config = @import("config.zig");
const ui_mod = @import("ui.zig");
const client_mod = @import("client.zig");
const commands = @import("commands.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len >= 2 and (std.mem.eql(u8, args[1], "-v") or std.mem.eql(u8, args[1], "--version"))) {
        var buf: [128]u8 = undefined;
        var w: Io.File.Writer = .init(.stdout(), io, &buf);
        try w.interface.print("{s}\n", .{protocol.version});
        try w.interface.flush();
        return;
    }
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        var buf: [64]u8 = undefined;
        var w: Io.File.Writer = .init(.stdout(), io, &buf);
        try w.interface.writeAll(config.usage);
        try w.interface.flush();
        return;
    }

    var options = try config.parseArgs(gpa, init.environ_map, args);
    defer options.deinit();

    var term = ui_mod.Ui.initMode(gpa, io, !options.once) catch |err| {
        std.debug.print("Failed to initialize terminal: {s}\n", .{@errorName(err)});
        return err;
    };
    defer term.deinit();

    var app = try client_mod.App.init(gpa, io, &options, &term);
    defer app.deinit();

    app.say("{s} — Napster / OpenNap client", .{protocol.version});
    app.say("Type /help for commands. Environment: NAPNICK NAPPASS NAPSERVER NAPGPG.", .{});
    app.updateStatus();

    commands.loadRc(&app, options.rc_path);
    if (options.extra_rc) |p| commands.loadRc(&app, p);

    if (options.auto_connect and options.servers.items.len != 0) {
        const idx = @min(options.start_index, options.servers.items.len - 1);
        app.connectEntry(options.servers.items[idx]) catch |err| {
            if (options.once)
                std.debug.print("connect failed: {s}\n", .{@errorName(err)});
        };
    }

    if (app.stream == null) {
        app.say("Not connected. Use /server host[:port] to connect.", .{});
    }

    if (options.once) {
        try runOnce(&app);
        return;
    }

    var fds: [64]std.posix.pollfd = undefined;
    while (app.running) {
        app.updateStatus();
        term.draw() catch {};

        const nfds = app.collectPollFds(&fds);
        _ = std.posix.poll(fds[0..nfds], 250) catch {};

        const stdin_ready = fds[0].revents & std.posix.POLL.IN != 0;
        if (stdin_ready or !term.raw_ok) {
            if (term.raw_ok) {
                const ev = term.readEvent() catch .none;
                switch (ev) {
                    .none => {},
                    .quit => app.running = false,
                    .resize => term.dirty = true,
                    .line => |line| {
                        defer gpa.free(line);
                        app.handleLine(line) catch {};
                    },
                }
            } else {
                try cookedInput(&app);
            }
        }

        app.pumpServer();
        app.acceptPeers();
        app.pumpTransfers();
    }
}

fn runOnce(app: *client_mod.App) !void {
    var fds: [64]std.posix.pollfd = undefined;
    const start = Io.Clock.real.now(app.io);
    const limit = Io.Duration.fromSeconds(12);
    while (app.running) {
        const now = Io.Clock.real.now(app.io);
        if (start.durationTo(now).nanoseconds >= limit.nanoseconds) break;
        if (app.logged_in) break;
        app.updateStatus();
        const nfds = app.collectPollFds(&fds);
        _ = std.posix.poll(fds[0..nfds], 200) catch {};
        app.pumpServer();
        app.acceptPeers();
        app.pumpTransfers();
    }

    var buf: [256]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), app.io, &buf);
    if (app.stream != null) {
        try w.interface.print(
            "RESULT: connected {s}:{d} tls={s} irc={s} logged_in={s}\n",
            .{
                app.connected_host.slice(),
                app.connected_port,
                if (app.connected_tls) "yes" else "no",
                if (app.connected_irc) "yes" else "no",
                if (app.logged_in) "yes" else "no",
            },
        );
        try w.interface.flush();
        return;
    }
    try w.interface.writeAll("RESULT: not connected\n");
    try w.interface.flush();
    return error.ConnectFailed;
}

fn cookedInput(app: *client_mod.App) !void {
    var buf: [1024]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
    if (n == 0) {
        app.running = false;
        return;
    }
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        app.handleLine(line) catch {};
    }
}

test {
    _ = @import("protocol.zig");
    _ = @import("md5.zig");
    _ = @import("util.zig");
    _ = @import("tls.zig");
    _ = @import("irc.zig");
    _ = @import("owned.zig");
    _ = @import("pgp.zig");
    _ = @import("gpg.zig");
}
