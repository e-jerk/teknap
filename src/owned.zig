//! Thin wrappers around zust (`safe`) for TekNap-owned memory.
const std = @import("std");
const safe = @import("safe");

pub const String = safe.String;
pub const Box = safe.Box;
pub const Slice = safe.Slice;
pub const GuardedSlice = safe.GuardedSlice;
pub const CString = safe.CString;
pub const FileGuard = safe.FileGuard;
pub const DirGuard = safe.DirGuard;
pub const Option = safe.Option;

pub fn set(s: *String, value: []const u8) !void {
    s.clear();
    try s.append(value);
}

pub fn replaceOpt(allocator: std.mem.Allocator, dest: *?String, value: []const u8) !void {
    if (dest.*) |*s| {
        try set(s, value);
        return;
    }
    dest.* = try String.initFromSlice(allocator, value);
}

pub fn clearOpt(dest: *?String) void {
    if (dest.*) |*s| s.deinit();
    dest.* = null;
}

pub fn optSlice(s: *const ?String) ?[]const u8 {
    if (s.*) |v| return v.slice();
    return null;
}

pub fn dropPrefix(s: *String, n: usize) void {
    if (n == 0) return;
    const items = s.buffer.items;
    if (n >= items.len) {
        s.clear();
        return;
    }
    std.mem.copyForwards(u8, items, items[n..]);
    s.buffer.shrinkRetainingCapacity(items.len - n);
}

pub fn insertByte(s: *String, index: usize, byte: u8) !void {
    try s.replaceRange(index, index, &[_]u8{byte});
}

pub fn removeByte(s: *String, index: usize) void {
    if (index >= s.len()) return;
    s.replaceRange(index, index + 1, "") catch {};
}

test "string set and dropPrefix" {
    var s = try String.initFromSlice(std.testing.allocator, "abcdef");
    defer s.deinit();
    dropPrefix(&s, 2);
    try std.testing.expectEqualStrings("cdef", s.slice());
    try set(&s, "hi");
    try std.testing.expectEqualStrings("hi", s.slice());
}

test "optional string" {
    var opt: ?String = null;
    try replaceOpt(std.testing.allocator, &opt, "lobby");
    defer clearOpt(&opt);
    try std.testing.expectEqualStrings("lobby", optSlice(&opt).?);
    try replaceOpt(std.testing.allocator, &opt, "ops");
    try std.testing.expectEqualStrings("ops", optSlice(&opt).?);
}

test "box owns a value" {
    const box = try Box(u32).init(std.testing.allocator, 7);
    try std.testing.expectEqual(@as(u32, 7), box.ptr.*);
    _ = box.deinit();
}
