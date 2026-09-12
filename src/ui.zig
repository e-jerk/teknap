const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");
const owned = @import("owned.zig");

const max_log = 2000;
const max_input = 2048;
const max_history = 200;

pub const LineKind = enum {
    normal,
    info,
    error_msg,
    public_msg,
    private,
    server,
    transfer,
};

pub const LogLine = struct {
    kind: LineKind,
    text: owned.String,
};

pub const Ui = struct {
    gpa: std.mem.Allocator,
    io: Io,
    orig: std.posix.termios,
    raw_ok: bool = false,
    rows: u16 = 24,
    cols: u16 = 80,
    log: std.ArrayList(LogLine) = .empty,
    scroll: usize = 0, // 0 = pinned to bottom
    input: owned.String,
    cursor: usize = 0,
    history: std.ArrayList(owned.String) = .empty,
    hist_idx: ?usize = null,
    draft: owned.String,
    dirty: bool = true,
    status: owned.String,

    pub fn init(gpa: std.mem.Allocator, io: Io) !Ui {
        return initMode(gpa, io, true);
    }

    pub fn initMode(gpa: std.mem.Allocator, io: Io, want_raw: bool) !Ui {
        var self: Ui = .{
            .gpa = gpa,
            .io = io,
            .orig = undefined,
            .input = owned.String.init(gpa),
            .draft = owned.String.init(gpa),
            .status = owned.String.init(gpa),
        };
        if (want_raw) {
            if (std.posix.tcgetattr(std.posix.STDIN_FILENO)) |term| {
                self.orig = term;
                var raw = term;
                raw.lflag.ECHO = false;
                raw.lflag.ICANON = false;
                raw.lflag.ISIG = false;
                raw.lflag.IEXTEN = false;
                raw.iflag.IXON = false;
                raw.iflag.ICRNL = false;
                raw.iflag.BRKINT = false;
                raw.oflag.OPOST = false;
                raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
                raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
                std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch {};
                self.raw_ok = true;
            } else |_| {
                self.raw_ok = false;
            }
        }
        self.refreshSize();
        if (self.raw_ok) {
            try self.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J");
        }
        return self;
    }

    pub fn deinit(self: *Ui) void {
        if (self.raw_ok) {
            self.writeAll("\x1b[?25h\x1b[?1049l") catch {};
            std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.orig) catch {};
        }
        for (self.log.items) |*line| line.text.deinit();
        self.log.deinit(self.gpa);
        self.input.deinit();
        for (self.history.items) |*h| h.deinit();
        self.history.deinit(self.gpa);
        self.draft.deinit();
        self.status.deinit();
    }

    pub fn refreshSize(self: *Ui) void {
        const sz = util.termSize();
        if (sz.rows != self.rows or sz.cols != self.cols) {
            self.rows = sz.rows;
            self.cols = sz.cols;
            self.dirty = true;
        }
    }

    fn writeAll(self: *Ui, bytes: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var w: Io.File.Writer = .init(.stdout(), self.io, &buf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    pub fn logLine(self: *Ui, kind: LineKind, comptime fmt: []const u8, args: anytype) void {
        var text = owned.String.init(self.gpa);
        text.appendFmt(fmt, args) catch {
            text.deinit();
            return;
        };
        if (self.log.items.len >= max_log) {
            var old = self.log.orderedRemove(0);
            old.text.deinit();
        }
        self.log.append(self.gpa, .{ .kind = kind, .text = text }) catch {
            text.deinit();
            return;
        };
        self.dirty = true;
        if (!self.raw_ok) {
            var buf: [256]u8 = undefined;
            var w: Io.File.Writer = .init(.stdout(), self.io, &buf);
            w.interface.print("{s}\n", .{text.slice()}) catch {};
            w.interface.flush() catch {};
        }
    }

    pub fn setStatus(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        self.status.clear();
        self.status.appendFmt(fmt, args) catch {};
        self.dirty = true;
    }

    pub const Event = union(enum) {
        none,
        line: []u8,
        quit,
        resize,
    };

    /// Caller owns Event.line if present.
    pub fn readEvent(self: *Ui) !Event {
        var byte: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &byte) catch |err| switch (err) {
            error.WouldBlock, error.InputOutput => return .none,
            else => return err,
        };
        if (n == 0) return .none;
        return self.handleByte(byte[0]);
    }

    fn handleByte(self: *Ui, c: u8) !Event {
        switch (c) {
            0x03, 0x04 => return .quit, // Ctrl-C / Ctrl-D
            '\r', '\n' => {
                if (self.input.isEmpty()) return .none;
                const line = try self.gpa.dupe(u8, self.input.slice());
                try self.history.append(self.gpa, try owned.String.initFromSlice(self.gpa, self.input.slice()));
                if (self.history.items.len > max_history) {
                    var old = self.history.orderedRemove(0);
                    old.deinit();
                }
                self.input.clear();
                self.cursor = 0;
                self.hist_idx = null;
                self.dirty = true;
                return .{ .line = line };
            },
            0x7f, 0x08 => { // backspace
                if (self.cursor > 0) {
                    owned.removeByte(&self.input, self.cursor - 1);
                    self.cursor -= 1;
                    self.dirty = true;
                }
            },
            0x15 => { // Ctrl-U
                self.input.clear();
                self.cursor = 0;
                self.dirty = true;
            },
            0x0c => { // Ctrl-L
                self.dirty = true;
            },
            0x1b => {
                var seq: [8]u8 = undefined;
                const n = std.posix.read(std.posix.STDIN_FILENO, seq[0..2]) catch 0;
                if (n >= 2 and seq[0] == '[') {
                    switch (seq[1]) {
                        'A' => self.historyPrev(),
                        'B' => self.historyNext(),
                        'C' => if (self.cursor < self.input.len()) {
                            self.cursor += 1;
                            self.dirty = true;
                        },
                        'D' => if (self.cursor > 0) {
                            self.cursor -= 1;
                            self.dirty = true;
                        },
                        '5' => { // PgUp
                            _ = std.posix.read(std.posix.STDIN_FILENO, seq[2..3]) catch 0;
                            self.scrollPage(true);
                        },
                        '6' => {
                            _ = std.posix.read(std.posix.STDIN_FILENO, seq[2..3]) catch 0;
                            self.scrollPage(false);
                        },
                        else => {},
                    }
                }
            },
            else => {
                if (c >= 32 and c < 127) {
                    if (self.input.len() < max_input) {
                        try owned.insertByte(&self.input, self.cursor, c);
                        self.cursor += 1;
                        self.dirty = true;
                    }
                }
            },
        }
        return .none;
    }

    fn historyPrev(self: *Ui) void {
        if (self.history.items.len == 0) return;
        if (self.hist_idx == null) {
            self.draft.clear();
            self.draft.append(self.input.slice()) catch {};
            self.hist_idx = self.history.items.len;
        }
        if (self.hist_idx.? == 0) return;
        self.hist_idx = self.hist_idx.? - 1;
        self.input.clear();
        self.input.append(self.history.items[self.hist_idx.?].slice()) catch {};
        self.cursor = self.input.len();
        self.dirty = true;
    }

    fn historyNext(self: *Ui) void {
        if (self.hist_idx == null) return;
        if (self.hist_idx.? + 1 >= self.history.items.len) {
            self.hist_idx = null;
            self.input.clear();
            self.input.append(self.draft.slice()) catch {};
            self.cursor = self.input.len();
            self.dirty = true;
            return;
        }
        self.hist_idx = self.hist_idx.? + 1;
        self.input.clear();
        self.input.append(self.history.items[self.hist_idx.?].slice()) catch {};
        self.cursor = self.input.len();
        self.dirty = true;
    }

    fn scrollPage(self: *Ui, up: bool) void {
        const page = if (self.rows > 4) self.rows - 4 else 1;
        if (up) {
            self.scroll += page;
        } else if (self.scroll > page) {
            self.scroll -= page;
        } else {
            self.scroll = 0;
        }
        self.dirty = true;
    }

    pub fn draw(self: *Ui) !void {
        if (!self.raw_ok) return;
        self.refreshSize();
        if (!self.dirty) return;
        self.dirty = false;

        var buf: [8192]u8 = undefined;
        var w: Io.File.Writer = .init(.stdout(), self.io, &buf);
        const out = &w.interface;
        try out.writeAll("\x1b[?25l\x1b[H");

        const log_rows: usize = if (self.rows > 2) self.rows - 2 else 1;
        const total = self.log.items.len;
        var start: usize = 0;
        if (total > log_rows) {
            const max_scroll = total - log_rows;
            if (self.scroll > max_scroll) self.scroll = max_scroll;
            start = total - log_rows - self.scroll;
        } else {
            self.scroll = 0;
        }

        var row: usize = 0;
        while (row < log_rows) : (row += 1) {
            try out.print("\x1b[{d};1H\x1b[K", .{row + 1});
            const idx = start + row;
            if (idx < total) {
                const line = self.log.items[idx];
                const color: []const u8 = switch (line.kind) {
                    .normal => "\x1b[0m",
                    .info => "\x1b[36m",
                    .error_msg => "\x1b[31m",
                    .public_msg => "\x1b[37m",
                    .private => "\x1b[35m",
                    .server => "\x1b[33m",
                    .transfer => "\x1b[32m",
                };
                const vis = visibleWidth(line.text.slice(), self.cols);
                try out.print("{s}{s}\x1b[0m", .{ color, vis });
            }
        }

        const status_row = self.rows - 1;
        const input_row = self.rows;
        try out.print("\x1b[{d};1H\x1b[44;37m", .{status_row});
        const st = visibleWidth(self.status.slice(), self.cols);
        try out.writeAll(st);
        var pad = if (self.cols > st.len) self.cols - st.len else 0;
        while (pad > 0) : (pad -= 1) try out.writeByte(' ');
        try out.writeAll("\x1b[0m");

        try out.print("\x1b[{d};1H\x1b[K> {s}", .{ input_row, self.input.slice() });
        const cur_col: usize = 3 + self.cursor;
        try out.print("\x1b[{d};{d}H\x1b[?25h", .{ input_row, cur_col });
        try out.flush();
    }

    fn visibleWidth(text: []const u8, cols: u16) []const u8 {
        if (text.len <= cols) return text;
        return text[0..cols];
    }
};
