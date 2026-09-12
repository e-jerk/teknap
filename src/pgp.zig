//! OpenNap `draft/gpg` helpers: hex keys, Ed25519 signatures, bind documents,
//! and extracting an Ed25519 seed from an OpenPGP secret key.

const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Aes128 = std.crypto.core.aes.Aes128;
const Aes256 = std.crypto.core.aes.Aes256;

pub const key_only_pass = "!gpg";

const ed25519_oid = [_]u8{ 0x2b, 0x06, 0x01, 0x04, 0x01, 0xda, 0x47, 0x0f, 0x01 };
const ed25519_oid_rfc = [_]u8{ 0x2b, 0x65, 0x70 };

pub fn bindDocument(buf: []u8, server: []const u8, nick: []const u8, nonce_hex: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "opennap-gpg-bind-v1\nserver={s}\nnick={s}\nnonce={s}\n", .{
        server, nick, nonce_hex,
    }) catch buf[0..0];
}

pub fn signRaw(seed: [32]u8, data: []const u8) ![64]u8 {
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig = try pair.sign(data, null);
    return sig.toBytes();
}

pub fn publicEd(seed: [32]u8) ![32]u8 {
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    return pair.public_key.toBytes();
}

pub fn hexBytes(src: []const u8, buf: []u8) []const u8 {
    const hex = "0123456789abcdef";
    var n: usize = 0;
    for (src) |b| {
        if (n + 2 > buf.len) break;
        buf[n] = hex[b >> 4];
        buf[n + 1] = hex[b & 15];
        n += 2;
    }
    return buf[0..n];
}

pub fn encodeKeyHex(ed: *const [32]u8, x: ?[32]u8, buf: []u8) []const u8 {
    var n: usize = 0;
    const ed_hex = hexBytes(ed, buf);
    n = ed_hex.len;
    if (x) |xp| {
        const rest = hexBytes(&xp, buf[n..]);
        n += rest.len;
    }
    return buf[0..n];
}

pub fn parseHex32(src: []const u8) ?[32]u8 {
    return parseHexExact(32, src);
}

pub fn parseHex64(src: []const u8) ?[64]u8 {
    return parseHexExact(64, src);
}

fn parseHexExact(comptime n: usize, src: []const u8) ?[n]u8 {
    const t = std.mem.trim(u8, src, " \t\r\n");
    if (t.len != n * 2) return null;
    var out: [n]u8 = undefined;
    var i: usize = 0;
    while (i < t.len) : (i += 2) {
        const hi = hexVal(t[i]) orelse return null;
        const lo = hexVal(t[i + 1]) orelse return null;
        out[i / 2] = @intCast((hi << 4) | lo);
    }
    return out;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Ed25519 seed plus optional X25519 seed from hex (64 or 128 hex chars).
pub fn parseHexSeed(src: []const u8) ?struct { ed: [32]u8, x: ?[32]u8 } {
    if (parseHex64(src)) |both| {
        var ed: [32]u8 = undefined;
        var x: [32]u8 = undefined;
        @memcpy(&ed, both[0..32]);
        @memcpy(&x, both[32..64]);
        return .{ .ed = ed, .x = x };
    }
    if (parseHex32(src)) |ed| return .{ .ed = ed, .x = null };
    return null;
}

/// Pull an Ed25519 seed from armored/binary OpenPGP, a hex seed, or an agent sexp.
pub fn extractEdSeed(src: []const u8, passphrase: []const u8) ?[32]u8 {
    const trimmed = std.mem.trim(u8, src, " \t\r\n");
    if (parseHexSeed(trimmed)) |pair| return pair.ed;
    if (extractFromSexp(trimmed)) |seed| return seed;

    var bin: [8192]u8 = undefined;
    const body = if (std.mem.indexOf(u8, trimmed, "BEGIN PGP") != null)
        dearmor(trimmed, &bin) orelse return null
    else if (decodeFlexible(trimmed, &bin)) |n|
        bin[0..n]
    else
        trimmed;

    return extractFromPackets(body, passphrase);
}

fn extractFromSexp(src: []const u8) ?[32]u8 {
    const needle = "(d #";
    const start = std.mem.indexOf(u8, src, needle) orelse return null;
    const rest = src[start + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '#') orelse return null;
    return parseHex32(rest[0..end]);
}

fn extractFromPackets(bin: []const u8, passphrase: []const u8) ?[32]u8 {
    var off: usize = 0;
    while (off < bin.len) {
        const pkt = nextPacket(bin, &off) orelse break;
        if (pkt.tag != 5 and pkt.tag != 7) continue;
        if (secretSeed(pkt.body, passphrase)) |seed| return seed;
    }
    return null;
}

fn secretSeed(body: []const u8, passphrase: []const u8) ?[32]u8 {
    const pub_end = skipPublic(body) orelse return null;
    if (pub_end >= body.len) return null;
    const usage = body[pub_end];
    if (usage == 0) return readSecret(body[pub_end + 1 ..]);
    if (usage == 254 or usage == 255) {
        const plain = decryptS2k(body[pub_end..], passphrase) orelse return null;
        return readSecret(plain);
    }
    return null;
}

fn skipPublic(body: []const u8) ?usize {
    if (body.len < 6 or body[0] != 4) return null;
    const algo = body[5];
    var off: usize = 6;
    if (algo == 27) {
        if (off + 32 > body.len) return null;
        return off + 32;
    }
    if (algo == 22) {
        const oid = readOid(body, off) orelse return null;
        if (!isEd25519Oid(oid.slice)) return null;
        off = oid.off;
        const mpi = readMpi(body, off) orelse return null;
        return mpi.off;
    }
    return null;
}

fn isEd25519Oid(oid: []const u8) bool {
    return std.mem.eql(u8, oid, &ed25519_oid) or std.mem.eql(u8, oid, &ed25519_oid_rfc);
}

fn readSecret(src: []const u8) ?[32]u8 {
    if (src.len >= 34 and src[0] == 0x01 and src[1] == 0x00) {
        var out: [32]u8 = undefined;
        @memcpy(&out, src[2..34]);
        return out;
    }
    if (src.len >= 32) {
        var out: [32]u8 = undefined;
        @memcpy(&out, src[0..32]);
        return out;
    }
    return null;
}

fn readOid(body: []const u8, off: usize) ?struct { slice: []const u8, off: usize } {
    if (off >= body.len) return null;
    const n = body[off];
    if (n == 0 or off + 1 + n > body.len) return null;
    return .{ .slice = body[off + 1 .. off + 1 + n], .off = off + 1 + n };
}

fn readMpi(body: []const u8, off: usize) ?struct { slice: []const u8, off: usize } {
    if (off + 2 > body.len) return null;
    const bits = std.mem.readInt(u16, body[off..][0..2], .big);
    const n = (bits + 7) / 8;
    if (off + 2 + n > body.len) return null;
    return .{ .slice = body[off + 2 .. off + 2 + n], .off = off + 2 + n };
}

fn decryptS2k(body: []const u8, passphrase: []const u8) ?[]const u8 {
    // body[0] is usage 254/255. Reuse a static buffer; callers copy the seed immediately.
    const usage = body[0];
    if (body.len < 4) return null;
    const cipher = body[1];
    var off: usize = 2;
    const spec = readS2k(body, &off) orelse return null;
    const key_len: usize = switch (cipher) {
        7 => 16,
        9 => 32,
        else => return null,
    };
    var key: [32]u8 = undefined;
    s2kKey(spec, passphrase, key[0..key_len]);
    const ct = body[off..];
    if (ct.len < 18) return null;

    var pt_buf: [4096]u8 = undefined;
    if (ct.len > pt_buf.len) return null;
    cfbDecrypt(cipher, key[0..key_len], ct, pt_buf[0..ct.len]);
    const pt = pt_buf[0..ct.len];

    if (usage == 254) {
        if (pt.len < 22) return null;
        if (pt[pt.len - 22] != 0xd3 or pt[pt.len - 21] != 0x14) return null;
        var dig: [Sha1.digest_length]u8 = undefined;
        Sha1.hash(pt[0 .. pt.len - 20], &dig, .{});
        if (!std.mem.eql(u8, &dig, pt[pt.len - 20 ..])) return null;
        const bs: usize = 16;
        if (pt.len < bs + 2 + 22) return null;
        if (pt[bs] != pt[bs - 2] or pt[bs + 1] != pt[bs - 1]) return null;
        return copyPlain(pt[bs + 2 .. pt.len - 22]);
    }
    if (pt.len < 2) return null;
    return copyPlain(pt[0 .. pt.len - 2]);
}

var plain_hold: [2048]u8 = undefined;

fn copyPlain(src: []const u8) ?[]const u8 {
    if (src.len > plain_hold.len) return null;
    @memcpy(plain_hold[0..src.len], src);
    return plain_hold[0..src.len];
}

const S2k = struct {
    kind: u8,
    hash: u8,
    salt: [8]u8 = [_]u8{0} ** 8,
    count: u32 = 0,
};

fn readS2k(body: []const u8, off: *usize) ?S2k {
    if (off.* >= body.len) return null;
    const kind = body[off.*];
    off.* += 1;
    if (off.* >= body.len) return null;
    const hash = body[off.*];
    off.* += 1;
    var spec: S2k = .{ .kind = kind, .hash = hash };
    if (kind == 1 or kind == 3) {
        if (off.* + 8 > body.len) return null;
        @memcpy(&spec.salt, body[off.* .. off.* + 8]);
        off.* += 8;
    }
    if (kind == 3) {
        if (off.* >= body.len) return null;
        const c = body[off.*];
        off.* += 1;
        spec.count = (@as(u32, 16) + (c & 15)) << @intCast((c >> 4) + 6);
    }
    return spec;
}

fn s2kKey(spec: S2k, passphrase: []const u8, out: []u8) void {
    var produced: usize = 0;
    var preload: usize = 0;
    while (produced < out.len) {
        const chunk = hashedS2k(spec, passphrase, preload);
        const n = @min(chunk.len, out.len - produced);
        @memcpy(out[produced .. produced + n], chunk[0..n]);
        produced += n;
        preload += 1;
    }
}

fn hashedS2k(spec: S2k, passphrase: []const u8, preload: usize) [64]u8 {
    var digest: [64]u8 = [_]u8{0} ** 64;
    switch (spec.hash) {
        2 => {
            const d = s2kSha1(spec, passphrase, preload);
            @memcpy(digest[0..20], &d);
        },
        8 => {
            const d = s2kSha256(spec, passphrase, preload);
            @memcpy(digest[0..32], &d);
        },
        else => {},
    }
    return digest;
}

fn s2kSha1(spec: S2k, passphrase: []const u8, preload: usize) [Sha1.digest_length]u8 {
    var h = Sha1.init(.{});
    var i: usize = 0;
    while (i < preload) : (i += 1) h.update(&[_]u8{0});
    if (spec.kind == 0) {
        h.update(passphrase);
    } else if (spec.kind == 1) {
        h.update(&spec.salt);
        h.update(passphrase);
    } else {
        var left = spec.count;
        while (left > 0) {
            const take_salt = @min(left, spec.salt.len);
            h.update(spec.salt[0..take_salt]);
            left -= take_salt;
            if (left == 0) break;
            const take_pw = @min(left, passphrase.len);
            h.update(passphrase[0..take_pw]);
            left -= take_pw;
        }
    }
    var out: [Sha1.digest_length]u8 = undefined;
    h.final(&out);
    return out;
}

fn s2kSha256(spec: S2k, passphrase: []const u8, preload: usize) [Sha256.digest_length]u8 {
    var h = Sha256.init(.{});
    var i: usize = 0;
    while (i < preload) : (i += 1) h.update(&[_]u8{0});
    if (spec.kind == 0) {
        h.update(passphrase);
    } else if (spec.kind == 1) {
        h.update(&spec.salt);
        h.update(passphrase);
    } else {
        var left = spec.count;
        while (left > 0) {
            const take_salt = @min(left, spec.salt.len);
            h.update(spec.salt[0..take_salt]);
            left -= take_salt;
            if (left == 0) break;
            const take_pw = @min(left, passphrase.len);
            h.update(passphrase[0..take_pw]);
            left -= take_pw;
        }
    }
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    return out;
}

fn cfbDecrypt(cipher: u8, key: []const u8, ct: []const u8, pt: []u8) void {
    var prev = [_]u8{0} ** 16;
    var i: usize = 0;
    var key32: [32]u8 = [_]u8{0} ** 32;
    var key16: [16]u8 = [_]u8{0} ** 16;
    if (cipher == 9 and key.len >= 32) @memcpy(&key32, key[0..32]);
    if (cipher == 7 and key.len >= 16) @memcpy(&key16, key[0..16]);
    while (i < ct.len) {
        var ks: [16]u8 = undefined;
        if (cipher == 9) {
            const ctx = Aes256.initEnc(key32);
            ctx.encrypt(&ks, &prev);
        } else {
            const ctx = Aes128.initEnc(key16);
            ctx.encrypt(&ks, &prev);
        }
        const n = @min(16, ct.len - i);
        for (0..n) |j| pt[i + j] = ct[i + j] ^ ks[j];
        @memcpy(prev[0..n], ct[i .. i + n]);
        if (n < 16) break;
        i += 16;
    }
}

fn decodeFlexible(src: []const u8, out: []u8) ?usize {
    if (src.len == 0) return null;
    if (src.len % 2 == 0) {
        if (parseAllHex(src, out)) |n| return n;
    }
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(src) catch return null;
    if (n > out.len) return null;
    dec.decode(out[0..n], src) catch return null;
    return n;
}

fn parseAllHex(src: []const u8, out: []u8) ?usize {
    if (src.len / 2 > out.len) return null;
    var i: usize = 0;
    while (i < src.len) : (i += 2) {
        const hi = hexVal(src[i]) orelse return null;
        const lo = hexVal(src[i + 1]) orelse return null;
        out[i / 2] = @intCast((hi << 4) | lo);
    }
    return src.len / 2;
}

fn dearmor(src: []const u8, out: []u8) ?[]u8 {
    const start = std.mem.indexOf(u8, src, "\n\n") orelse std.mem.indexOf(u8, src, "\r\n\r\n") orelse return null;
    var i = start;
    while (i < src.len and (src[i] == '\n' or src[i] == '\r')) i += 1;
    const end = std.mem.indexOf(u8, src[i..], "-----END") orelse return null;
    var compact: [4096]u8 = undefined;
    var n: usize = 0;
    for (src[i .. i + end]) |ch| {
        if (ch == '\n' or ch == '\r' or ch == ' ' or ch == '\t') continue;
        if (n >= compact.len) return null;
        compact[n] = ch;
        n += 1;
    }
    if (std.mem.lastIndexOfScalar(u8, compact[0..n], '=')) |eq| {
        if (eq + 5 == n) n = eq;
    }
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(compact[0..n]) catch return null;
    if (size > out.len) return null;
    dec.decode(out[0..size], compact[0..n]) catch return null;
    return out[0..size];
}

const Pkt = struct { tag: u8, body: []const u8 };

fn nextPacket(bin: []const u8, off: *usize) ?Pkt {
    if (off.* >= bin.len) return null;
    const first = bin[off.*];
    if (first & 0x80 == 0) return null;
    if (first & 0x40 != 0) {
        const tag: u8 = first & 0x3f;
        off.* += 1;
        const len = readNewLen(bin, off) orelse return null;
        if (off.* + len > bin.len) return null;
        const body = bin[off.* .. off.* + len];
        off.* += len;
        return .{ .tag = tag, .body = body };
    }
    const tag: u8 = (first >> 2) & 0x0f;
    const llen = first & 3;
    off.* += 1;
    const len: usize = switch (llen) {
        0 => blk: {
            if (off.* >= bin.len) return null;
            const n = bin[off.*];
            off.* += 1;
            break :blk n;
        },
        1 => blk: {
            if (off.* + 2 > bin.len) return null;
            const n = std.mem.readInt(u16, bin[off.*..][0..2], .big);
            off.* += 2;
            break :blk n;
        },
        2 => blk: {
            if (off.* + 4 > bin.len) return null;
            const n = std.mem.readInt(u32, bin[off.*..][0..4], .big);
            off.* += 4;
            break :blk n;
        },
        else => return null,
    };
    if (off.* + len > bin.len) return null;
    const body = bin[off.* .. off.* + len];
    off.* += len;
    return .{ .tag = tag, .body = body };
}

fn readNewLen(bin: []const u8, off: *usize) ?usize {
    if (off.* >= bin.len) return null;
    const o = bin[off.*];
    if (o < 192) {
        off.* += 1;
        return o;
    }
    if (o < 224) {
        if (off.* + 2 > bin.len) return null;
        const n = @as(usize, o - 192) << 8;
        const n2 = n + @as(usize, bin[off.* + 1]) + 192;
        off.* += 2;
        return n2;
    }
    if (o == 255) {
        if (off.* + 5 > bin.len) return null;
        const n = std.mem.readInt(u32, bin[off.* + 1 ..][0..4], .big);
        off.* += 5;
        return n;
    }
    return null;
}

test "bind document and seed sign" {
    const seed = [_]u8{1} ** 32;
    var buf: [128]u8 = undefined;
    const doc = bindDocument(&buf, "testnap", "alice", "aabb");
    const sig = try signRaw(seed, doc);
    try std.testing.expectEqual(@as(usize, 64), sig.len);
}

test "unprotected openpgp secret seed" {
    const seed = [_]u8{7} ** 32;
    const pk = try publicEd(seed);
    var body: [6 + 32 + 1 + 32 + 2]u8 = undefined;
    body[0] = 4;
    std.mem.writeInt(u32, body[1..5], 1, .big);
    body[5] = 27;
    @memcpy(body[6..38], &pk);
    body[38] = 0;
    @memcpy(body[39..71], &seed);
    var sum: u16 = 0;
    for (seed) |b| sum +%= b;
    std.mem.writeInt(u16, body[71..73], sum, .big);

    var pkt: [2 + body.len]u8 = undefined;
    pkt[0] = 0xc5;
    pkt[1] = @intCast(body.len);
    @memcpy(pkt[2..], &body);
    const got = extractEdSeed(&pkt, "") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, &seed, &got);
}

test "sexp d-hash seed" {
    const seed = "01" ** 32;
    const sexp = "(private-key(ecc(curve Ed25519)(d #" ++ seed ++ "#)))";
    const got = extractEdSeed(sexp, "") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, &(parseHex32(seed).?), &got);
}
