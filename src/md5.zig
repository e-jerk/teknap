const std = @import("std");

/// RFC 1321 MD5. Napster hashes the first 299008 bytes after ID3v2/frame sync.
pub const Md5 = struct {
    state: [4]u32 = .{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 },
    count: u64 = 0,
    buffer: [64]u8 = undefined,
    buffer_len: usize = 0,

    pub fn update(self: *Md5, data: []const u8) void {
        var rest = data;
        self.count += rest.len;
        if (self.buffer_len != 0) {
            const need = 64 - self.buffer_len;
            const take = @min(need, rest.len);
            @memcpy(self.buffer[self.buffer_len..][0..take], rest[0..take]);
            self.buffer_len += take;
            rest = rest[take..];
            if (self.buffer_len < 64) return;
            transform(&self.state, &self.buffer);
            self.buffer_len = 0;
        }
        while (rest.len >= 64) {
            transform(&self.state, rest[0..64]);
            rest = rest[64..];
        }
        if (rest.len != 0) {
            @memcpy(self.buffer[0..rest.len], rest);
            self.buffer_len = rest.len;
        }
    }

    pub fn final(self: *Md5) [16]u8 {
        var padding: [64]u8 = @splat(0);
        padding[0] = 0x80;
        const bit_len = self.count * 8;
        const index = self.count % 64;
        const pad_len: usize = if (index < 56) 56 - index else 120 - index;
        self.update(padding[0..pad_len]);
        var len_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_bytes, bit_len, .little);
        self.update(&len_bytes);
        var out: [16]u8 = undefined;
        inline for (0..4) |i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], self.state[i], .little);
        }
        return out;
    }

    pub fn hex(digest: [16]u8, dest: *[32]u8) []const u8 {
        const digits = "0123456789abcdef";
        for (digest, 0..) |b, i| {
            dest[i * 2] = digits[b >> 4];
            dest[i * 2 + 1] = digits[b & 0xf];
        }
        return dest;
    }
};

fn F(x: u32, y: u32, z: u32) u32 {
    return (x & y) | (~x & z);
}
fn G(x: u32, y: u32, z: u32) u32 {
    return (x & z) | (y & ~z);
}
fn H(x: u32, y: u32, z: u32) u32 {
    return x ^ y ^ z;
}
fn I(x: u32, y: u32, z: u32) u32 {
    return y ^ (x | ~z);
}

fn transform(state: *[4]u32, block: *const [64]u8) void {
    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var x: [16]u32 = undefined;
    inline for (0..16) |i| {
        x[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .little);
    }

    const rounds = .{
        .{ F, 0, 7, 0xd76aa478 },  .{ F, 1, 12, 0xe8c7b756 }, .{ F, 2, 17, 0x242070db }, .{ F, 3, 22, 0xc1bdceee },
        .{ F, 4, 7, 0xf57c0faf },  .{ F, 5, 12, 0x4787c62a }, .{ F, 6, 17, 0xa8304613 }, .{ F, 7, 22, 0xfd469501 },
        .{ F, 8, 7, 0x698098d8 },  .{ F, 9, 12, 0x8b44f7af }, .{ F, 10, 17, 0xffff5bb1 }, .{ F, 11, 22, 0x895cd7be },
        .{ F, 12, 7, 0x6b901122 }, .{ F, 13, 12, 0xfd987193 }, .{ F, 14, 17, 0xa679438e }, .{ F, 15, 22, 0x49b40821 },
        .{ G, 1, 5, 0xf61e2562 },  .{ G, 6, 9, 0xc040b340 },  .{ G, 11, 14, 0x265e5a51 }, .{ G, 0, 20, 0xe9b6c7aa },
        .{ G, 5, 5, 0xd62f105d },  .{ G, 10, 9, 0x02441453 }, .{ G, 15, 14, 0xd8a1e681 }, .{ G, 4, 20, 0xe7d3fbc8 },
        .{ G, 9, 5, 0x21e1cde6 },  .{ G, 14, 9, 0xc33707d6 }, .{ G, 3, 14, 0xf4d50d87 },  .{ G, 8, 20, 0x455a14ed },
        .{ G, 13, 5, 0xa9e3e905 }, .{ G, 2, 9, 0xfcefa3f8 },  .{ G, 7, 14, 0x676f02d9 },  .{ G, 12, 20, 0x8d2a4c8a },
        .{ H, 5, 4, 0xfffa3942 },  .{ H, 8, 11, 0x8771f681 }, .{ H, 11, 16, 0x6d9d6122 }, .{ H, 14, 23, 0xfde5380c },
        .{ H, 1, 4, 0xa4beea44 },  .{ H, 4, 11, 0x4bdecfa9 }, .{ H, 7, 16, 0xf6bb4b60 },  .{ H, 10, 23, 0xbebfbc70 },
        .{ H, 13, 4, 0x289b7ec6 }, .{ H, 0, 11, 0xeaa127fa }, .{ H, 3, 16, 0xd4ef3085 },  .{ H, 6, 23, 0x04881d05 },
        .{ H, 9, 4, 0xd9d4d039 },  .{ H, 12, 11, 0xe6db99e5 }, .{ H, 15, 16, 0x1fa27cf8 }, .{ H, 2, 23, 0xc4ac5665 },
        .{ I, 0, 6, 0xf4292244 },  .{ I, 7, 10, 0x432aff97 }, .{ I, 14, 15, 0xab9423a7 }, .{ I, 5, 21, 0xfc93a039 },
        .{ I, 12, 6, 0x655b59c3 }, .{ I, 3, 10, 0x8f0ccc92 }, .{ I, 10, 15, 0xffeff47d }, .{ I, 1, 21, 0x85845dd1 },
        .{ I, 8, 6, 0x6fa87e4f },  .{ I, 15, 10, 0xfe2ce6e0 }, .{ I, 6, 15, 0xa3014314 }, .{ I, 13, 21, 0x4e0811a1 },
        .{ I, 4, 6, 0xf7537e82 },  .{ I, 11, 10, 0xbd3af235 }, .{ I, 2, 15, 0x2ad7d2bb }, .{ I, 9, 21, 0xeb86d391 },
    };

    inline for (rounds) |r| {
        const fn_ptr = r[0];
        const k = r[1];
        const s = r[2];
        const ac = r[3];
        const f = fn_ptr(b, c, d);
        const t = a +% f +% x[k] +% ac;
        a = d;
        d = c;
        c = b;
        b = b +% std.math.rotl(u32, t, s);
    }

    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
}

test "md5 empty" {
    var m = Md5{};
    const d = m.final();
    var hex: [32]u8 = undefined;
    try std.testing.expectEqualStrings("d41d8cd98f00b204e9800998ecf8427e", Md5.hex(d, &hex));
}

test "md5 abc" {
    var m = Md5{};
    m.update("abc");
    const d = m.final();
    var hex: [32]u8 = undefined;
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", Md5.hex(d, &hex));
}
