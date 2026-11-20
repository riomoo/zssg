// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Go (BSD-3-Clause, Copyright The Go Authors) image/jpeg, image/draw and image/png.
// The original notices and licences are kept in NOTICE and licenses/.
//! Image codecs and pixel operations implemented from scratch:
//! PNG (decode/encode), JPEG (baseline + progressive decode, baseline encode),
//! GIF (first-frame decode), resampling, cropping, rotation and colour filters.
//! WebP lives in webp.zig.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");

pub threadlocal var err_msg: []const u8 = "";
fn fail(comptime f: []const u8, args: anytype) anyerror {
    err_msg = v.fmt(f, args);
    return error.ImageError;
}

pub const Image = struct {
    w: u32,
    h: u32,
    px: []u8, // RGBA, 8 bits per channel, not premultiplied
    orientation: u8 = 1, // EXIF orientation of the source (1 = upright)
    /// palette (NRGBA) of an indexed PNG source; Hugo re-applies it to PNG output
    palette: ?[]const [4]u8 = null,
    /// the Go image type the source decodes to (decides gift's pixel access)
    kind: Kind = .nrgba,
    /// YCbCr planes of a JPEG (Go's *image.YCbCr), read directly by gift
    ycc: ?Ycc = null,
    /// decoded from a >8-bit AVIF (see imgops.smartCrop)
    hdr_avif: bool = false,
    /// 16-bit straight-alpha RGBA (Go's NRGBA64) of a >8-bit AVIF; `px` then
    /// holds the same pixels reduced to 8 bits
    px16: ?[]u16 = null,
    /// AVIF bit depth and colour properties carried to the output (Hugo keeps
    /// them for >8-bit images)
    avif: AvifProps = .{},

    pub fn init(w: u32, h: u32) !Image {
        const px = try sys.A.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        return .{ .w = w, .h = h, .px = px };
    }
    pub fn opaque_(img: *const Image) bool {
        var i: usize = 3;
        while (i < img.px.len) : (i += 4) if (img.px[i] != 255) return false;
        return true;
    }
};

pub const Kind = enum { nrgba, rgba, gray, paletted };
pub const AvifProps = struct { depth: u32 = 0, cp: i32 = 0, tc: i32 = 0, mc: i32 = 0, max_cll: i32 = 0, max_pall: i32 = 0 };
pub const Ycc = struct { y: []const u8, cb: []const u8, cr: []const u8, ystride: usize, cstride: usize, hdiv: usize, vdiv: usize };

pub const Format = enum { png, jpeg, gif, webp, bmp, tiff, avif, unknown };

pub fn sniff(b: []const u8) Format {
    if (b.len > 8 and v.startsWith(b, "\x89PNG")) return .png;
    if (b.len > 3 and b[0] == 0xFF and b[1] == 0xD8) return .jpeg;
    if (b.len > 6 and v.startsWith(b, "GIF8")) return .gif;
    if (b.len > 12 and v.startsWith(b, "RIFF") and v.eq(b[8..12], "WEBP")) return .webp;
    if (b.len > 2 and b[0] == 'B' and b[1] == 'M') return .bmp;
    if (b.len > 4 and (v.startsWith(b, "II*\x00") or v.startsWith(b, "MM\x00*"))) return .tiff;
    if (@import("avif.zig").isAvif(b)) return .avif;
    return .unknown;
}

pub fn decode(b: []const u8) anyerror!Image {
    return switch (sniff(b)) {
        .png => decodePng(b),
        .jpeg => decodeJpeg(b),
        .gif => decodeGif(b),
        .webp => @import("webp.zig").decode(b),
        .bmp => fail("BMP images are not supported", .{}),
        .tiff => fail("TIFF images are not supported", .{}),
        .avif => @import("avif.zig").decode(b),
        .unknown => fail("unknown image format", .{}),
    };
}

// ================================================================ inflate

const BitReader = struct {
    s: []const u8,
    pos: usize = 0,
    bit: u64 = 0,
    cnt: u7 = 0,

    inline fn refill(r: *BitReader) void {
        while (r.cnt <= 56) {
            if (r.pos >= r.s.len) return;
            r.bit |= @as(u64, r.s[r.pos]) << @intCast(r.cnt);
            r.pos += 1;
            r.cnt += 8;
        }
    }
    fn need(r: *BitReader, n: u7) !void {
        if (r.cnt < n) {
            r.refill();
            if (r.cnt < n) return error.ImageError;
        }
    }
    fn bits(r: *BitReader, n: u7) !u32 {
        if (n == 0) return 0;
        try r.need(n);
        const val: u32 = @intCast(r.bit & ((@as(u64, 1) << @intCast(n)) - 1));
        r.bit >>= @intCast(n);
        r.cnt -= n;
        return val;
    }
    /// discard the bits of a partial byte (stored blocks), returning whole
    /// buffered bytes to the input
    fn alignByte(r: *BitReader) void {
        const drop: u7 = r.cnt % 8;
        r.bit >>= @intCast(drop);
        r.cnt -= drop;
        r.pos -= r.cnt / 8;
        r.bit = 0;
        r.cnt = 0;
    }
};

const fast_bits = 10;

const Huff = struct {
    count: [16]u16 = @as([16]u16, @splat(0)),
    symbol: [320]u16 = undefined,
    /// LSB-first lookup of codes up to fast_bits long: (symbol << 4) | length
    fast: [1 << fast_bits]u16 = undefined,

    fn build(h: *Huff, lengths: []const u8) void {
        h.count = @as([16]u16, @splat(0));
        for (lengths) |l| h.count[l] += 1;
        h.count[0] = 0;
        var offs: [16]u16 = undefined;
        offs[1] = 0;
        var i: usize = 1;
        while (i < 15) : (i += 1) offs[i + 1] = offs[i] + h.count[i];
        for (lengths, 0..) |l, sym| if (l != 0) {
            h.symbol[offs[l]] = @intCast(sym);
            offs[l] += 1;
        };
        @memset(&h.fast, 0);
        // canonical codes, then bit-reversed for LSB-first reading
        var next: [16]u32 = undefined;
        next[0] = 0;
        var code: u32 = 0;
        for (1..16) |l| {
            code = (code + h.count[l - 1]) << 1;
            next[l] = code;
        }
        for (lengths, 0..) |l, sym| {
            if (l == 0) continue;
            const c = next[l];
            next[l] += 1;
            if (l > fast_bits) continue;
            var rev: u32 = 0;
            for (0..l) |k| rev |= ((c >> @intCast(k)) & 1) << @intCast(l - 1 - k);
            var j: u32 = rev;
            while (j < (1 << fast_bits)) : (j += @as(u32, 1) << @intCast(l)) h.fast[j] = @intCast((sym << 4) | l);
        }
    }
    fn decode(h: *const Huff, r: *BitReader) !u16 {
        if (r.cnt < 15) r.refill();
        const e = h.fast[@intCast(r.bit & ((1 << fast_bits) - 1))];
        if (e != 0) {
            const l: u7 = @intCast(e & 15);
            if (l <= r.cnt) {
                r.bit >>= @intCast(l);
                r.cnt -= l;
                return e >> 4;
            }
        }
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        var len: usize = 1;
        while (len <= 15) : (len += 1) {
            code |= @intCast(try r.bits(1));
            const count: i32 = h.count[len];
            if (code - count < first) return h.symbol[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.ImageError;
    }
};

const len_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const clen_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// Inflate a zlib stream (2-byte header + raw deflate).
pub fn inflateZlib(src: []const u8, size_hint: usize) ![]u8 {
    if (src.len < 2) return error.ImageError;
    var r: BitReader = .{ .s = src[2..] };
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(sys.A, size_hint + 16);
    var lit: Huff = .{};
    var dst: Huff = .{};
    while (true) {
        const final = try r.bits(1);
        const typ = try r.bits(2);
        if (typ == 0) {
            r.alignByte();
            if (r.pos + 4 > r.s.len) return error.ImageError;
            const n = @as(usize, r.s[r.pos]) | (@as(usize, r.s[r.pos + 1]) << 8);
            r.pos += 4;
            if (r.pos + n > r.s.len) return error.ImageError;
            try out.appendSlice(sys.A, r.s[r.pos .. r.pos + n]);
            r.pos += n;
        } else if (typ == 1 or typ == 2) {
            var lengths: [320]u8 = undefined;
            if (typ == 1) {
                for (lengths[0..144]) |*l| l.* = 8;
                for (lengths[144..256]) |*l| l.* = 9;
                for (lengths[256..280]) |*l| l.* = 7;
                for (lengths[280..288]) |*l| l.* = 8;
                lit.build(lengths[0..288]);
                for (lengths[0..30]) |*l| l.* = 5;
                dst.build(lengths[0..30]);
            } else {
                const nlen = (try r.bits(5)) + 257;
                const ndist = (try r.bits(5)) + 1;
                const ncode = (try r.bits(4)) + 4;
                var cl = @as([19]u8, @splat(0));
                var i: usize = 0;
                while (i < ncode) : (i += 1) cl[clen_order[i]] = @intCast(try r.bits(3));
                var ch: Huff = .{};
                ch.build(&cl);
                i = 0;
                while (i < nlen + ndist) {
                    const sym = try ch.decode(&r);
                    if (sym < 16) {
                        lengths[i] = @intCast(sym);
                        i += 1;
                    } else {
                        var prev: u8 = 0;
                        var rep: usize = 0;
                        if (sym == 16) {
                            if (i == 0) return error.ImageError;
                            prev = lengths[i - 1];
                            rep = 3 + (try r.bits(2));
                        } else if (sym == 17) {
                            rep = 3 + (try r.bits(3));
                        } else rep = 11 + (try r.bits(7));
                        if (i + rep > nlen + ndist) return error.ImageError;
                        while (rep > 0) : (rep -= 1) {
                            lengths[i] = prev;
                            i += 1;
                        }
                    }
                }
                lit.build(lengths[0..nlen]);
                dst.build(lengths[nlen .. nlen + ndist]);
            }
            while (true) {
                const sym = try lit.decode(&r);
                if (sym < 256) {
                    if (out.items.len == out.capacity) try out.ensureUnusedCapacity(sys.A, out.items.len / 2 + 64);
                    out.appendAssumeCapacity(@intCast(sym));
                } else if (sym == 256) {
                    break;
                } else {
                    const li = sym - 257;
                    if (li >= 29) return error.ImageError;
                    const len = len_base[li] + (try r.bits(len_extra[li]));
                    const ds = try dst.decode(&r);
                    if (ds >= 30) return error.ImageError;
                    const dist = dist_base[ds] + (try r.bits(dist_extra[ds]));
                    if (dist > out.items.len) return error.ImageError;
                    try out.ensureUnusedCapacity(sys.A, len);
                    const start = out.items.len - dist;
                    if (dist >= len) {
                        out.appendSliceAssumeCapacity(out.items[start .. start + len]);
                    } else {
                        var k: usize = 0;
                        while (k < len) : (k += 1) out.appendAssumeCapacity(out.items[start + k]);
                    }
                }
            }
        } else return error.ImageError;
        if (final == 1) break;
    }
    return out.items;
}

// ================================================================ deflate

const BitWriter = struct {
    out: std.ArrayList(u8) = .empty,
    acc: u64 = 0,
    n: u6 = 0,

    fn put(w: *BitWriter, val: u32, bits: u6) void {
        w.acc |= @as(u64, val) << w.n;
        w.n += bits;
        while (w.n >= 8) {
            w.out.append(sys.A, @truncate(w.acc)) catch {};
            w.acc >>= 8;
            w.n -= 8;
        }
    }
    fn flush(w: *BitWriter) void {
        if (w.n > 0) {
            w.out.append(sys.A, @truncate(w.acc)) catch {};
            w.acc = 0;
            w.n = 0;
        }
    }
};

/// Length-limited Huffman code lengths for the given frequencies.
pub fn huffLengths(freq: []const u32, lens: []u8, max_len: u8) void {
    const n = freq.len;
    @memset(lens, 0);
    const Node = struct { f: u64, l: i32, r: i32 };
    var nodes = sys.A.alloc(Node, n * 2 + 2) catch return;
    var active: std.ArrayList(u32) = .empty;
    var cnt: usize = 0;
    for (freq, 0..) |f, i| if (f > 0) {
        nodes[cnt] = .{ .f = f, .l = -1, .r = @intCast(i) };
        active.append(sys.A, @intCast(cnt)) catch return;
        cnt += 1;
    };
    if (cnt == 0) return;
    if (cnt == 1) {
        lens[@intCast(nodes[0].r)] = 1;
        return;
    }
    // simple O(n^2) tree construction; n <= 288
    while (active.items.len > 1) {
        var a: usize = 0;
        var b: usize = 1;
        if (nodes[active.items[b]].f < nodes[active.items[a]].f) std.mem.swap(usize, &a, &b);
        var k: usize = 2;
        while (k < active.items.len) : (k += 1) {
            const f = nodes[active.items[k]].f;
            if (f < nodes[active.items[a]].f) {
                b = a;
                a = k;
            } else if (f < nodes[active.items[b]].f) b = k;
        }
        const ia = active.items[a];
        const ib = active.items[b];
        nodes[cnt] = .{ .f = nodes[ia].f + nodes[ib].f, .l = @intCast(ia), .r = @intCast(ib) };
        const hi = @max(a, b);
        const lo = @min(a, b);
        _ = active.swapRemove(hi);
        _ = active.swapRemove(lo);
        active.append(sys.A, @intCast(cnt)) catch return;
        cnt += 1;
    }
    // depths
    var depth_count = @as([64]u32, @splat(0));
    const Stack = struct { node: u32, d: u8 };
    var stack: std.ArrayList(Stack) = .empty;
    stack.append(sys.A, .{ .node = active.items[0], .d = 0 }) catch return;
    var leaves: std.ArrayList(struct { sym: u32, f: u64 }) = .empty;
    while (stack.pop()) |it| {
        const nd = nodes[it.node];
        if (nd.l < 0) {
            depth_count[@min(it.d, 63)] += 1;
            leaves.append(sys.A, .{ .sym = @intCast(nd.r), .f = nd.f }) catch return;
        } else {
            stack.append(sys.A, .{ .node = @intCast(nd.l), .d = it.d + 1 }) catch return;
            stack.append(sys.A, .{ .node = @intCast(nd.r), .d = it.d + 1 }) catch return;
        }
    }
    // enforce the maximum code length (as in miniz)
    var d: usize = max_len + 1;
    while (d < 64) : (d += 1) {
        depth_count[max_len] += depth_count[d];
        depth_count[d] = 0;
    }
    var total: u64 = 0;
    d = max_len;
    while (d > 0) : (d -= 1) total += @as(u64, depth_count[d]) << @intCast(max_len - d);
    while (total > (@as(u64, 1) << @intCast(max_len))) {
        depth_count[max_len] -= 1;
        d = max_len - 1;
        while (d > 0) : (d -= 1) if (depth_count[d] > 0) {
            depth_count[d] -= 1;
            depth_count[d + 1] += 2;
            break;
        };
        total -= 1;
    }
    // assign lengths: most frequent symbols get the shortest codes
    const L = @TypeOf(leaves.items[0]);
    std.mem.sort(L, leaves.items, {}, struct {
        fn less(_: void, x: L, y: L) bool {
            if (x.f != y.f) return x.f > y.f;
            return x.sym < y.sym;
        }
    }.less);
    var li: usize = 0;
    d = 1;
    while (d <= max_len) : (d += 1) {
        var k: u32 = 0;
        while (k < depth_count[d]) : (k += 1) {
            lens[leaves.items[li].sym] = @intCast(d);
            li += 1;
        }
    }
}

/// Canonical codes (deflate bit order = reversed).
fn canonCodes(lens: []const u8, codes: []u16, reversed: bool) void {
    var bl_count = @as([17]u16, @splat(0));
    for (lens) |l| bl_count[l] += 1;
    bl_count[0] = 0;
    var next = @as([17]u16, @splat(0));
    var code: u16 = 0;
    var b: usize = 1;
    while (b <= 16) : (b += 1) {
        code = (code + bl_count[b - 1]) << 1;
        next[b] = code;
    }
    for (lens, 0..) |l, i| {
        if (l == 0) continue;
        var c = next[l];
        next[l] += 1;
        if (reversed) {
            var rv: u16 = 0;
            var k: u8 = 0;
            while (k < l) : (k += 1) {
                rv = (rv << 1) | (c & 1);
                c >>= 1;
            }
            c = rv;
        }
        codes[i] = c;
    }
}

fn lenSym(len: usize) usize {
    var i: usize = 28;
    while (len_base[i] > len) i -= 1;
    return i;
}
fn distSym(dist: usize) usize {
    var i: usize = 29;
    while (dist_base[i] > dist) i -= 1;
    return i;
}

/// zlib-compress `src` (single dynamic-Huffman block, hash-chain LZ77).
pub fn deflateZlib(src: []const u8) []u8 {
    const Tok = packed struct { len: u16, dist: u16 };
    var toks: std.ArrayList(Tok) = .empty;
    toks.ensureTotalCapacity(sys.A, src.len / 2 + 16) catch {};
    const hash_bits = 15;
    const head = sys.A.alloc(i32, 1 << hash_bits) catch return &.{};
    @memset(head, -1);
    const prev = sys.A.alloc(i32, src.len) catch return &.{};
    var i: usize = 0;
    const H = struct {
        fn h(p: []const u8) usize {
            const x = (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
            return (x *% 2654435761) >> (32 - hash_bits);
        }
    };
    while (i < src.len) {
        var best_len: usize = 0;
        var best_dist: usize = 0;
        if (i + 3 <= src.len) {
            const hv = H.h(src[i..]);
            var cand = head[hv];
            var chain: usize = 0;
            const max_len = @min(258, src.len - i);
            while (cand >= 0 and chain < 48) : (chain += 1) {
                const c: usize = @intCast(cand);
                if (i - c > 32768) break;
                if (src[c + best_len] == src[i + best_len] or best_len == 0) {
                    var l: usize = 0;
                    while (l < max_len and src[c + l] == src[i + l]) l += 1;
                    if (l > best_len) {
                        best_len = l;
                        best_dist = i - c;
                        if (l == max_len) break;
                    }
                }
                cand = prev[c];
            }
            prev[i] = head[hv];
            head[hv] = @intCast(i);
        }
        if (best_len >= 3) {
            toks.append(sys.A, .{ .len = @intCast(best_len), .dist = @intCast(best_dist) }) catch {};
            var k: usize = 1;
            while (k < best_len) : (k += 1) {
                const p = i + k;
                if (p + 3 <= src.len) {
                    const hv = H.h(src[p..]);
                    prev[p] = head[hv];
                    head[hv] = @intCast(p);
                }
            }
            i += best_len;
        } else {
            toks.append(sys.A, .{ .len = src[i], .dist = 0 }) catch {};
            i += 1;
        }
    }
    var lfreq = @as([286]u32, @splat(0));
    var dfreq = @as([30]u32, @splat(0));
    for (toks.items) |t| {
        if (t.dist == 0) lfreq[t.len] += 1 else {
            lfreq[257 + lenSym(t.len)] += 1;
            dfreq[distSym(t.dist)] += 1;
        }
    }
    lfreq[256] = 1;
    var llens: [286]u8 = undefined;
    var dlens: [30]u8 = undefined;
    huffLengths(&lfreq, &llens, 15);
    huffLengths(&dfreq, &dlens, 15);
    var any_dist = false;
    for (dlens) |l| if (l != 0) {
        any_dist = true;
    };
    if (!any_dist) dlens[0] = 1;
    var lcodes: [286]u16 = undefined;
    var dcodes: [30]u16 = undefined;
    canonCodes(&llens, &lcodes, true);
    canonCodes(&dlens, &dcodes, true);
    // code length alphabet (no run-length symbols: simple and valid)
    var clfreq = @as([19]u32, @splat(0));
    for (llens) |l| clfreq[l] += 1;
    for (dlens) |l| clfreq[l] += 1;
    var cllens: [19]u8 = undefined;
    huffLengths(&clfreq, &cllens, 7);
    var clcodes: [19]u16 = undefined;
    canonCodes(&cllens, &clcodes, true);

    var w: BitWriter = .{};
    w.out.ensureTotalCapacity(sys.A, src.len / 2 + 64) catch {};
    w.out.appendSlice(sys.A, &.{ 0x78, 0x9C }) catch {};
    w.put(1, 1);
    w.put(2, 2);
    w.put(286 - 257, 5);
    w.put(30 - 1, 5);
    w.put(19 - 4, 4);
    for (clen_order) |o| w.put(cllens[o], 3);
    for (llens) |l| w.put(clcodes[l], @intCast(cllens[l]));
    for (dlens) |l| w.put(clcodes[l], @intCast(cllens[l]));
    for (toks.items) |t| {
        if (t.dist == 0) {
            w.put(lcodes[t.len], @intCast(llens[t.len]));
        } else {
            const ls = lenSym(t.len);
            w.put(lcodes[257 + ls], @intCast(llens[257 + ls]));
            w.put(t.len - len_base[ls], len_extra[ls]);
            const ds = distSym(t.dist);
            w.put(dcodes[ds], @intCast(dlens[ds]));
            w.put(t.dist - dist_base[ds], dist_extra[ds]);
        }
    }
    w.put(lcodes[256], @intCast(llens[256]));
    w.flush();
    // adler32
    var a: u32 = 1;
    var b: u32 = 0;
    for (src) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    const ad = (b << 16) | a;
    w.out.appendSlice(sys.A, &.{ @truncate(ad >> 24), @truncate(ad >> 16), @truncate(ad >> 8), @truncate(ad) }) catch {};
    return w.out.items;
}

// ================================================================ PNG

fn be32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

fn paeth(a: i32, b: i32, c: i32) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return @intCast(a);
    if (pb <= pc) return @intCast(b);
    return @intCast(c);
}

fn unfilter(raw: []u8, w_bytes: usize, h: usize, bpp: usize) !void {
    const stride = w_bytes + 1;
    if (raw.len < stride * h) return error.ImageError;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const ft = raw[y * stride];
        const row = raw[y * stride + 1 .. (y + 1) * stride];
        const up: ?[]u8 = if (y > 0) raw[(y - 1) * stride + 1 .. y * stride] else null;
        switch (ft) {
            0 => {},
            1 => for (row[bpp..], 0..) |*p, i| {
                p.* +%= row[i];
            },
            2 => if (up) |u| for (row, 0..) |*p, i| {
                p.* +%= u[i];
            },
            3 => for (row, 0..) |*p, i| {
                const l: u32 = if (i >= bpp) row[i - bpp] else 0;
                const u: u32 = if (up) |uu| uu[i] else 0;
                p.* +%= @intCast((l + u) / 2);
            },
            4 => for (row, 0..) |*p, i| {
                const l: i32 = if (i >= bpp) row[i - bpp] else 0;
                const u: i32 = if (up) |uu| uu[i] else 0;
                const ul: i32 = if (i >= bpp and up != null) up.?[i - bpp] else 0;
                p.* +%= paeth(l, u, ul);
            },
            else => return error.ImageError,
        }
    }
}

pub fn decodePng(b: []const u8) anyerror!Image {
    var pos: usize = 8;
    var w: u32 = 0;
    var h: u32 = 0;
    var depth: u8 = 0;
    var ctype: u8 = 0;
    var interlace: u8 = 0;
    var pal: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    while (pos + 8 <= b.len) {
        const len = be32(b[pos..]);
        const typ = b[pos + 4 .. pos + 8];
        const body_start = pos + 8;
        if (body_start + len > b.len) break;
        const body = b[body_start .. body_start + len];
        if (v.eq(typ, "IHDR")) {
            if (len < 13) return fail("PNG: bad IHDR", .{});
            w = be32(body[0..]);
            h = be32(body[4..]);
            depth = body[8];
            ctype = body[9];
            interlace = body[12];
        } else if (v.eq(typ, "PLTE")) {
            pal = body;
        } else if (v.eq(typ, "tRNS")) {
            trns = body;
        } else if (v.eq(typ, "IDAT")) {
            try idat.appendSlice(sys.A, body);
        } else if (v.eq(typ, "IEND")) break;
        pos = body_start + len + 4;
    }
    if (w == 0 or h == 0 or w > 65535 or h > 65535) return fail("PNG: invalid dimensions", .{});
    const channels: usize = switch (ctype) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return fail("PNG: unsupported colour type {d}", .{ctype}),
    };
    const bits_pp = channels * depth;
    const bpp = @max(1, bits_pp / 8);
    const raw = inflateZlib(idat.items, (@as(usize, w) * bits_pp / 8 + 2) * h) catch return fail("PNG: corrupt image data", .{});
    var img = try Image.init(w, h);

    const Pass = struct { x0: u32, y0: u32, dx: u32, dy: u32 };
    const passes: []const Pass = if (interlace == 1) &.{
        .{ .x0 = 0, .y0 = 0, .dx = 8, .dy = 8 }, .{ .x0 = 4, .y0 = 0, .dx = 8, .dy = 8 }, .{ .x0 = 0, .y0 = 4, .dx = 4, .dy = 8 },
        .{ .x0 = 2, .y0 = 0, .dx = 4, .dy = 4 }, .{ .x0 = 0, .y0 = 2, .dx = 2, .dy = 4 }, .{ .x0 = 1, .y0 = 0, .dx = 2, .dy = 2 },
        .{ .x0 = 0, .y0 = 1, .dx = 1, .dy = 2 },
    } else &.{.{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1 }};
    var off: usize = 0;
    for (passes) |ps| {
        if (ps.x0 >= w or ps.y0 >= h) continue;
        const pw: usize = (w - ps.x0 + ps.dx - 1) / ps.dx;
        const ph: usize = (h - ps.y0 + ps.dy - 1) / ps.dy;
        const row_bytes = (pw * bits_pp + 7) / 8;
        const need = (row_bytes + 1) * ph;
        if (off + need > raw.len) return fail("PNG: truncated image data", .{});
        const data = raw[off .. off + need];
        off += need;
        unfilter(data, row_bytes, ph, bpp) catch return fail("PNG: bad filter", .{});
        if (depth == 8 and interlace == 0 and !(ctype == 0 and trns.len >= 2) and !(ctype == 2 and trns.len >= 6)) {
            // fast path: 8-bit, non-interlaced
            var lut: [256][4]u8 = undefined;
            if (ctype == 3) for (0..256) |pi| {
                lut[pi] = if (pi * 3 + 2 < pal.len) .{ pal[pi * 3], pal[pi * 3 + 1], pal[pi * 3 + 2], 255 } else .{ 0, 0, 0, 255 };
                if (pi < trns.len) lut[pi][3] = trns[pi];
            };
            for (0..ph) |y| {
                const row = data[y * (row_bytes + 1) + 1 ..][0..row_bytes];
                const dst = img.px[y * @as(usize, w) * 4 ..][0 .. @as(usize, w) * 4];
                switch (ctype) {
                    6 => @memcpy(dst, row),
                    2 => for (0..w) |x| {
                        dst[x * 4] = row[x * 3];
                        dst[x * 4 + 1] = row[x * 3 + 1];
                        dst[x * 4 + 2] = row[x * 3 + 2];
                        dst[x * 4 + 3] = 255;
                    },
                    3 => for (0..w) |x| {
                        dst[x * 4 ..][0..4].* = lut[row[x]];
                    },
                    0 => for (0..w) |x| {
                        dst[x * 4 ..][0..4].* = .{ row[x], row[x], row[x], 255 };
                    },
                    else => for (0..w) |x| {
                        dst[x * 4 ..][0..4].* = .{ row[x * 2], row[x * 2], row[x * 2], row[x * 2 + 1] };
                    },
                }
            }
            continue;
        }
        var y: usize = 0;
        while (y < ph) : (y += 1) {
            const row = data[y * (row_bytes + 1) + 1 ..][0..row_bytes];
            var x: usize = 0;
            while (x < pw) : (x += 1) {
                var s: [4]u16 = undefined;
                var c: usize = 0;
                while (c < channels) : (c += 1) {
                    const idx = x * channels + c;
                    s[c] = switch (depth) {
                        8 => row[idx],
                        16 => (@as(u16, row[idx * 2]) << 8) | row[idx * 2 + 1],
                        else => blk: {
                            const bit = idx * depth;
                            const shift: u3 = @intCast(8 - depth - (bit % 8));
                            break :blk (row[bit / 8] >> shift) & ((@as(u8, 1) << @intCast(depth)) - 1);
                        },
                    };
                }
                const o = ((ps.y0 + y * ps.dy) * @as(usize, w) + ps.x0 + x * ps.dx) * 4;
                const maxv: u32 = (@as(u32, 1) << @intCast(depth)) - 1;
                const sc = struct {
                    fn f(val: u16, m: u32) u8 {
                        return @intCast((@as(u32, val) * 255 + m / 2) / m);
                    }
                }.f;
                switch (ctype) {
                    0 => {
                        const g = sc(s[0], maxv);
                        img.px[o] = g;
                        img.px[o + 1] = g;
                        img.px[o + 2] = g;
                        img.px[o + 3] = 255;
                        if (trns.len >= 2 and ((@as(u16, trns[0]) << 8) | trns[1]) == s[0]) img.px[o + 3] = 0;
                    },
                    2 => {
                        img.px[o] = sc(s[0], maxv);
                        img.px[o + 1] = sc(s[1], maxv);
                        img.px[o + 2] = sc(s[2], maxv);
                        img.px[o + 3] = 255;
                        if (trns.len >= 6 and ((@as(u16, trns[0]) << 8) | trns[1]) == s[0] and ((@as(u16, trns[2]) << 8) | trns[3]) == s[1] and ((@as(u16, trns[4]) << 8) | trns[5]) == s[2]) img.px[o + 3] = 0;
                    },
                    3 => {
                        const pi: usize = s[0];
                        if (pi * 3 + 2 < pal.len) {
                            img.px[o] = pal[pi * 3];
                            img.px[o + 1] = pal[pi * 3 + 1];
                            img.px[o + 2] = pal[pi * 3 + 2];
                        }
                        img.px[o + 3] = if (pi < trns.len) trns[pi] else 255;
                    },
                    4 => {
                        const g = sc(s[0], maxv);
                        img.px[o] = g;
                        img.px[o + 1] = g;
                        img.px[o + 2] = g;
                        img.px[o + 3] = sc(s[1], maxv);
                    },
                    else => {
                        img.px[o] = sc(s[0], maxv);
                        img.px[o + 1] = sc(s[1], maxv);
                        img.px[o + 2] = sc(s[2], maxv);
                        img.px[o + 3] = sc(s[3], maxv);
                    },
                }
            }
        }
    }
    if (ctype == 3) {
        const np = @max(pal.len / 3, trns.len);
        const pl = try sys.A.alloc([4]u8, np);
        for (pl, 0..) |*e, i| {
            e.* = if (i * 3 + 2 < pal.len) .{ pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2], 255 } else .{ 0, 0, 0, 255 };
            if (i < trns.len) e[3] = trns[i];
        }
        img.palette = pl;
        img.kind = .paletted;
    } else if (ctype == 0 and depth <= 8 and trns.len == 0) {
        img.kind = .gray;
    } else if (ctype == 2 and depth == 8 and trns.len == 0) {
        img.kind = .rgba;
    }
    return img;
}

/// Go's draw.FloydSteinberg.Draw onto an *image.Paletted (image/draw drawPaletted).
pub fn ditherToPalette(img: *const Image, pal: []const [4]u8) []u8 {
    const w: usize = img.w;
    const h: usize = img.h;
    const out = sys.A.alloc(u8, w * h) catch return &.{};
    const P = sys.A.alloc([4]i32, pal.len) catch return &.{};
    for (pal, 0..) |e, i| {
        // color.NRGBA.RGBA()
        const a: u32 = e[3];
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            var c: u32 = e[k];
            c |= c << 8;
            c *= a;
            c /= 0xff;
            P[i][k] = @intCast(c);
        }
        P[i][3] = @intCast(a | (a << 8));
    }
    var cur = sys.A.alloc([4]i32, w + 2) catch return &.{};
    var nxt = sys.A.alloc([4]i32, w + 2) catch return &.{};
    @memset(cur, .{ 0, 0, 0, 0 });
    @memset(nxt, .{ 0, 0, 0, 0 });
    const clamp = struct {
        fn f(i: i32) i32 {
            return if (i < 0) 0 else if (i > 0xffff) 0xffff else i;
        }
    }.f;
    const sq = struct {
        fn f(x: i32, y: i32) u32 {
            const d: u32 = @bitCast(x -% y);
            return (d *% d) >> 2;
        }
    }.f;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const o = (y * w + x) * 4;
            const a: u32 = img.px[o + 3];
            var e: [4]i32 = undefined;
            var k: usize = 0;
            while (k < 3) : (k += 1) {
                var c: u32 = img.px[o + k];
                c |= c << 8;
                c *= a;
                c /= 0xff;
                e[k] = @intCast(c);
            }
            e[3] = @intCast(a | (a << 8));
            k = 0;
            while (k < 4) : (k += 1) e[k] = clamp(e[k] + @divTrunc(cur[x + 1][k], 16));
            var best: usize = 0;
            var best_sum: u32 = std.math.maxInt(u32);
            for (P, 0..) |p, idx| {
                const sum = sq(e[0], p[0]) +% sq(e[1], p[1]) +% sq(e[2], p[2]) +% sq(e[3], p[3]);
                if (sum < best_sum) {
                    best = idx;
                    best_sum = sum;
                    if (sum == 0) break;
                }
            }
            out[y * w + x] = @intCast(best);
            k = 0;
            while (k < 4) : (k += 1) {
                const er = e[k] - P[best][k];
                nxt[x][k] += er * 3;
                nxt[x + 1][k] += er * 5;
                nxt[x + 2][k] += er;
                cur[x + 2][k] += er * 7;
            }
        }
        const t = cur;
        cur = nxt;
        nxt = t;
        @memset(nxt, .{ 0, 0, 0, 0 });
    }
    return out;
}

/// Indexed PNG (like Go's png encoder for *image.Paletted).
pub fn encodePngPaletted(w: u32, h: u32, idx: []const u8, pal: []const [4]u8) []const u8 {
    const depth: u8 = if (pal.len <= 2) 1 else if (pal.len <= 4) 2 else if (pal.len <= 16) 4 else 8;
    const stride: usize = (@as(usize, w) * depth + 7) / 8;
    const raw = sys.A.alloc(u8, (stride + 1) * h) catch return "";
    @memset(raw, 0);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const val = idx[y * w + x];
            if (depth == 8) {
                row[x] = val;
            } else {
                const bit = x * depth;
                const shift: u3 = @intCast(8 - depth - (bit % 8));
                row[bit / 8] |= val << shift;
            }
        }
    }
    var out: v.Buf = .{};
    out.add("\x89PNG\r\n\x1a\n");
    const ihdr = [_]u8{ @truncate(w >> 24), @truncate(w >> 16), @truncate(w >> 8), @truncate(w), @truncate(h >> 24), @truncate(h >> 16), @truncate(h >> 8), @truncate(h), depth, 3, 0, 0, 0 };
    pngChunk(&out, "IHDR", &ihdr);
    var plte: v.Buf = .{};
    var last_t: usize = 0;
    for (pal, 0..) |e, i| {
        plte.add(e[0..3]);
        if (e[3] != 255) last_t = i + 1;
    }
    pngChunk(&out, "PLTE", plte.str());
    if (last_t > 0) {
        var t: v.Buf = .{};
        for (pal[0..last_t]) |e| t.ch(e[3]);
        pngChunk(&out, "tRNS", t.str());
    }
    pngChunk(&out, "IDAT", deflateZlib(raw));
    pngChunk(&out, "IEND", "");
    return out.str();
}

const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        e.* = c;
    }
    break :blk t;
};
fn crc32(parts: []const []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (parts) |p| for (p) |x| {
        c = crc_table[(c ^ x) & 0xFF] ^ (c >> 8);
    };
    return c ^ 0xFFFFFFFF;
}

fn pngChunk(out: *v.Buf, typ: []const u8, body: []const u8) void {
    const len: u32 = @intCast(body.len);
    out.add(&.{ @truncate(len >> 24), @truncate(len >> 16), @truncate(len >> 8), @truncate(len) });
    out.add(typ);
    out.add(body);
    const c = crc32(&.{ typ, body });
    out.add(&.{ @truncate(c >> 24), @truncate(c >> 16), @truncate(c >> 8), @truncate(c) });
}

/// PNG with Go's choice of colour type: 16-bit RGB(A) for 16-bit images,
/// grayscale for gray images, RGB when opaque, else RGBA.
fn encodePngWide(img: *const Image) []const u8 {
    const w: usize = img.w;
    const h: usize = img.h;
    var ch: usize = 1;
    var ctype: u8 = 0;
    var depth: u8 = 8;
    if (img.px16) |p| {
        depth = 16;
        var op = true;
        var i: usize = 3;
        while (i < p.len) : (i += 4) if (p[i] != 0xffff) {
            op = false;
            break;
        };
        ch = if (op) 3 else 4;
        ctype = if (op) 2 else 6;
    }
    const bpc: usize = depth / 8;
    const stride = w * ch * bpc;
    const raw = sys.A.alloc(u8, (stride + 1) * h) catch return "";
    const cur = sys.A.alloc(u8, stride) catch return "";
    const prv = sys.A.alloc(u8, stride) catch return "";
    @memset(prv, 0);
    const cand = sys.A.alloc(u8, stride * 5) catch return "";
    const bpp = ch * bpc;
    for (0..h) |y| {
        for (0..w) |x| {
            if (img.px16) |p| {
                for (0..ch) |c| std.mem.writeInt(u16, cur[(x * ch + c) * 2 ..][0..2], p[(y * w + x) * 4 + c], .big);
            } else cur[x] = img.px[(y * w + x) * 4];
        }
        var best: usize = 0;
        var best_sum: u64 = std.math.maxInt(u64);
        for (0..5) |f| {
            const dst = cand[f * stride ..][0..stride];
            var sum: u64 = 0;
            for (cur, 0..) |c, i| {
                const l: i32 = if (i >= bpp) cur[i - bpp] else 0;
                const u: i32 = prv[i];
                const ul: i32 = if (i >= bpp) prv[i - bpp] else 0;
                const val: u8 = switch (f) {
                    0 => c,
                    1 => c -% @as(u8, @intCast(l)),
                    2 => c -% @as(u8, @intCast(u)),
                    3 => c -% @as(u8, @intCast(@divTrunc(l + u, 2))),
                    else => c -% paeth(l, u, ul),
                };
                dst[i] = val;
                sum += if (val < 128) val else 256 - @as(u64, val);
            }
            if (sum < best_sum) {
                best_sum = sum;
                best = f;
            }
        }
        raw[y * (stride + 1)] = @intCast(best);
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], cand[best * stride ..][0..stride]);
        @memcpy(prv, cur);
    }
    var out: v.Buf = .{};
    out.add("\x89PNG\r\n\x1a\n");
    const W: u32 = img.w;
    const H: u32 = img.h;
    const ihdr = [_]u8{ @truncate(W >> 24), @truncate(W >> 16), @truncate(W >> 8), @truncate(W), @truncate(H >> 24), @truncate(H >> 16), @truncate(H >> 8), @truncate(H), depth, ctype, 0, 0, 0 };
    pngChunk(&out, "IHDR", &ihdr);
    pngChunk(&out, "IDAT", deflateZlib(raw));
    pngChunk(&out, "IEND", "");
    return out.str();
}

pub fn encodePng(img: *const Image) []const u8 {
    if (img.px16 != null or img.kind == .gray) return encodePngWide(img);
    const alpha = !img.opaque_();
    const ch: usize = if (alpha) 4 else 3;
    const w: usize = img.w;
    const h: usize = img.h;
    const stride = w * ch;
    const raw = sys.A.alloc(u8, (stride + 1) * h) catch return "";
    const cur = sys.A.alloc(u8, stride) catch return "";
    const prv = sys.A.alloc(u8, stride) catch return "";
    @memset(prv, 0);
    const cand = sys.A.alloc(u8, stride * 5) catch return "";
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const s = (y * w + x) * 4;
            @memcpy(cur[x * ch ..][0..ch], img.px[s..][0..ch]);
        }
        var best: usize = 0;
        var best_sum: u64 = std.math.maxInt(u64);
        var f: usize = 0;
        while (f < 5) : (f += 1) {
            const dst = cand[f * stride ..][0..stride];
            var sum: u64 = 0;
            for (cur, 0..) |c, i| {
                const l: i32 = if (i >= ch) cur[i - ch] else 0;
                const u: i32 = prv[i];
                const ul: i32 = if (i >= ch) prv[i - ch] else 0;
                const val: u8 = switch (f) {
                    0 => c,
                    1 => c -% @as(u8, @intCast(l)),
                    2 => c -% @as(u8, @intCast(u)),
                    3 => c -% @as(u8, @intCast(@divTrunc(l + u, 2))),
                    else => c -% paeth(l, u, ul),
                };
                dst[i] = val;
                sum += if (val < 128) val else 256 - @as(u64, val);
            }
            if (sum < best_sum) {
                best_sum = sum;
                best = f;
            }
        }
        raw[y * (stride + 1)] = @intCast(best);
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], cand[best * stride ..][0..stride]);
        @memcpy(prv, cur);
    }
    var out: v.Buf = .{};
    out.add("\x89PNG\r\n\x1a\n");
    const ihdr = [_]u8{ @truncate(w >> 24), @truncate(w >> 16), @truncate(w >> 8), @truncate(w), @truncate(h >> 24), @truncate(h >> 16), @truncate(h >> 8), @truncate(h), 8, if (alpha) 6 else 2, 0, 0, 0 };
    pngChunk(&out, "IHDR", &ihdr);
    pngChunk(&out, "IDAT", deflateZlib(raw));
    pngChunk(&out, "IEND", "");
    return out.str();
}

// ================================================================ JPEG decode

const zigzag = [64]u8{ 0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63 };

const JHuff = struct {
    maxcode: [18]i32 = undefined,
    valptr: [17]i32 = undefined,
    mincode: [17]i32 = undefined,
    vals: [256]u8 = undefined,
    ok: bool = false,

    fn build(h: *JHuff, counts: []const u8, vals: []const u8) void {
        @memcpy(h.vals[0..vals.len], vals);
        var code: i32 = 0;
        var k: i32 = 0;
        var l: usize = 1;
        while (l <= 16) : (l += 1) {
            h.valptr[l] = k;
            h.mincode[l] = code;
            code += counts[l - 1];
            k += counts[l - 1];
            h.maxcode[l] = if (counts[l - 1] == 0) -1 else code - 1;
            code <<= 1;
        }
        h.maxcode[17] = 0x7fffffff;
        h.ok = true;
    }
};

const JComp = struct {
    id: u8 = 0,
    hs: u8 = 1,
    vs: u8 = 1,
    tq: u8 = 0,
    td: u8 = 0,
    ta: u8 = 0,
    bw: usize = 0, // blocks per line
    bh: usize = 0,
    coef: []i16 = &.{},
    pred: i32 = 0,
    plane: []u8 = &.{},
};

const JDec = struct {
    s: []const u8,
    pos: usize = 0,
    bitbuf: u32 = 0,
    bitcnt: u6 = 0,
    marker: u8 = 0,
    eobrun: u32 = 0,

    fn fill(d: *JDec) void {
        while (d.bitcnt <= 24) {
            var b: u32 = 0;
            if (d.marker == 0 and d.pos < d.s.len) {
                b = d.s[d.pos];
                d.pos += 1;
                if (b == 0xFF) {
                    var m: u8 = if (d.pos < d.s.len) d.s[d.pos] else 0xD9;
                    while (m == 0xFF and d.pos + 1 < d.s.len) {
                        d.pos += 1;
                        m = d.s[d.pos];
                    }
                    d.pos += 1;
                    if (m != 0) {
                        d.marker = m;
                        b = 0;
                    }
                }
            }
            d.bitbuf |= b << @intCast(24 - d.bitcnt);
            d.bitcnt += 8;
        }
    }
    fn bit(d: *JDec) u32 {
        if (d.bitcnt == 0) d.fill();
        const r = d.bitbuf >> 31;
        d.bitbuf <<= 1;
        d.bitcnt -= 1;
        return r;
    }
    fn bits(d: *JDec, n: u5) u32 {
        if (n == 0) return 0;
        if (d.bitcnt < n) d.fill();
        const r = d.bitbuf >> @intCast(32 - @as(u6, n));
        d.bitbuf <<= n;
        d.bitcnt -= n;
        return r;
    }
    fn receiveExtend(d: *JDec, n: u5) i32 {
        if (n == 0) return 0;
        const r: i32 = @intCast(d.bits(n));
        if (r < (@as(i32, 1) << (n - 1))) return r - (@as(i32, 1) << n) + 1;
        return r;
    }
    fn huff(d: *JDec, h: *const JHuff) u8 {
        var code: i32 = 0;
        var l: usize = 1;
        while (l <= 16) : (l += 1) {
            code = (code << 1) | @as(i32, @intCast(d.bit()));
            if (h.maxcode[l] >= 0 and code <= h.maxcode[l]) {
                return h.vals[@intCast(h.valptr[l] + code - h.mincode[l])];
            }
        }
        return 0;
    }
    fn reset(d: *JDec) void {
        d.bitbuf = 0;
        d.bitcnt = 0;
        d.marker = 0;
        d.eobrun = 0;
    }
};


// ---- Go 1.26+ image/jpeg IDCT (dct.go), as used by the Hugo release builds
fn dfix(comptime x: u64, comptime bits: u6) i32 {
    return @intCast((x + (@as(u64, 1) << (59 - bits))) >> (60 - bits));
}
const d_cos1 = 1130768441178740757;
const d_sin1 = 224923827593068887;
const d_cos3 = 958619196450722178;
const d_sin3 = 640528868967736374;
const d_sqrt2inv = 815238614083298888;
const d_sqrt2inv_cos6 = 311978311033955632;
const d_sqrt2inv_sin6 = 753182269664427492;
inline fn shl(x: i32, comptime n: u5) i32 {
    return @bitCast(@as(u32, @bitCast(x)) << n);
}
inline fn dctBox(x0: i32, x1: i32, kcos: i32, ksin: i32) [2]i32 {
    const ksum = kcos *% (x0 +% x1);
    return .{ ksum +% (ksin -% kcos) *% x1, ksum -% (kcos +% ksin) *% x0 };
}

fn goIdct(b: *[64]i32) void {
    // rows
    for (0..8) |i| {
        const x = b[8 * i ..][0..8];
        var x0 = x[0];
        var x7 = x[1];
        var x2 = x[2];
        var x5 = x[3];
        var x1 = x[4];
        var x6 = x[5];
        var x3 = x[6];
        var x4 = x[7];
        x0 = shl(x0, 17);
        x1 = shl(x1, 17);
        var t0 = x0 +% x1;
        x1 = x0 -% x1;
        x0 = t0;
        var bx = dctBox(x2, x3, dfix(d_sqrt2inv_cos6, 18), -dfix(d_sqrt2inv_sin6, 18));
        x2 = bx[0];
        x3 = bx[1];
        t0 = x1 +% x2;
        x2 = x1 -% x2;
        x1 = t0;
        t0 = x0 +% x3;
        x3 = x0 -% x3;
        x0 = t0;
        x4 = shl(x4, 7);
        x7 = shl(x7, 7);
        t0 = x7 +% x4;
        x4 = x7 -% x4;
        x7 = t0;
        x6 = x6 *% dfix(d_sqrt2inv, 8);
        x5 = x5 *% dfix(d_sqrt2inv, 8);
        t0 = x7 +% x5;
        x5 = x7 -% x5;
        x7 = t0;
        t0 = x4 +% x6;
        x6 = x4 -% x6;
        x4 = t0;
        bx = dctBox(x4 >> 2, x7 >> 2, dfix(d_cos3, 12), -dfix(d_sin3, 12));
        x4 = bx[0];
        x7 = bx[1];
        bx = dctBox(x5 >> 2, x6 >> 2, dfix(d_cos1, 12), -dfix(d_sin1, 12));
        x5 = bx[0];
        x6 = bx[1];
        x[0] = x0 +% x7;
        x[7] = x0 -% x7;
        x[1] = x1 +% x6;
        x[6] = x1 -% x6;
        x[2] = x2 +% x5;
        x[5] = x2 -% x5;
        x[3] = x3 +% x4;
        x[4] = x3 -% x4;
    }
    // columns
    for (0..8) |i| {
        var x0 = b[0 * 8 + i];
        var x7 = b[1 * 8 + i];
        var x2 = b[2 * 8 + i];
        var x5 = b[3 * 8 + i];
        var x1 = b[4 * 8 + i];
        var x6 = b[5 * 8 + i];
        var x3 = b[6 * 8 + i];
        var x4 = b[7 * 8 + i];
        x0 +%= 1 << 19;
        var t0 = (x0 +% x1) >> 2;
        x1 = (x0 -% x1) >> 2;
        x0 = t0;
        var bx = dctBox(x2 >> 13, x3 >> 13, dfix(d_sqrt2inv_cos6, 12), -dfix(d_sqrt2inv_sin6, 12));
        x2 = bx[0];
        x3 = bx[1];
        t0 = x1 +% x2;
        x2 = x1 -% x2;
        x1 = t0;
        t0 = x0 +% x3;
        x3 = x0 -% x3;
        x0 = t0;
        t0 = x7 +% x4;
        x4 = x7 -% x4;
        x7 = t0;
        x5 = (x5 >> 13) *% dfix(d_sqrt2inv, 14);
        x6 = (x6 >> 13) *% dfix(d_sqrt2inv, 14);
        t0 = x7 +% x5;
        x5 = x7 -% x5;
        x7 = t0;
        t0 = x4 +% x6;
        x6 = x4 -% x6;
        x4 = t0;
        bx = dctBox(x4 >> 14, x7 >> 14, dfix(d_cos3, 12), -dfix(d_sin3, 12));
        x4 = bx[0];
        x7 = bx[1];
        bx = dctBox(x5 >> 14, x6 >> 14, dfix(d_cos1, 12), -dfix(d_sin1, 12));
        x5 = bx[0];
        x6 = bx[1];
        b[0 * 8 + i] = (x0 +% x7) >> 18;
        b[7 * 8 + i] = (x0 -% x7) >> 18;
        b[1 * 8 + i] = (x1 +% x6) >> 18;
        b[6 * 8 + i] = (x1 -% x6) >> 18;
        b[2 * 8 + i] = (x2 +% x5) >> 18;
        b[5 * 8 + i] = (x2 -% x5) >> 18;
        b[3 * 8 + i] = (x3 +% x4) >> 18;
        b[4 * 8 + i] = (x3 -% x4) >> 18;
    }
}

fn idctBlock(coef: []const i16, q: *const [64]u16, out: []u8, stride: usize) void {
    var b: [64]i32 = undefined;
    for (0..64) |i| b[zigzag[i]] = @as(i32, coef[i]) *% @as(i32, q[i]);
    goIdct(&b);
    for (0..8) |y| for (0..8) |x| {
        const c = b[y * 8 + x] +% 128;
        out[y * stride + x] = if (c < 0) 0 else if (c > 255) 255 else @intCast(c);
    };
}

/// color.YCbCrToRGB
pub fn yccToRgb(y: u8, cb: u8, cr: u8) [3]u8 {
    const yy1: i32 = @as(i32, y) * 0x10101;
    const cb1: i32 = @as(i32, cb) - 128;
    const cr1: i32 = @as(i32, cr) - 128;
    const f = struct {
        fn f(v_: i32) u8 {
            if (@as(u32, @bitCast(v_)) & 0xff000000 == 0) return @intCast((v_ >> 16) & 0xff);
            return @truncate(@as(u32, @bitCast(~(v_ >> 31))));
        }
    }.f;
    return .{ f(yy1 + 91881 * cr1), f(yy1 - 22554 * cb1 - 46802 * cr1), f(yy1 + 116130 * cb1) };
}

pub fn decodeJpeg(b: []const u8) anyerror!Image {
    var d: JDec = .{ .s = b, .pos = 2 };
    var qt: [4][64]u16 = undefined;
    var dc_h: [4]JHuff = .{ .{}, .{}, .{}, .{} };
    var ac_h: [4]JHuff = .{ .{}, .{}, .{}, .{} };
    var comps: [4]JComp = .{ .{}, .{}, .{}, .{} };
    var ncomp: usize = 0;
    var w: usize = 0;
    var h: usize = 0;
    var progressive = false;
    var restart: usize = 0;
    var hmax: usize = 1;
    var vmax: usize = 1;
    var mcux: usize = 0;
    var mcuy: usize = 0;
    var adobe_transform: i32 = -1;
    var orientation: u8 = 1;
    var got_frame = false;

    while (d.pos + 4 <= b.len) {
        if (b[d.pos] != 0xFF) {
            d.pos += 1;
            continue;
        }
        const m = b[d.pos + 1];
        d.pos += 2;
        if (m == 0xFF or m == 0x00 or (m >= 0xD0 and m <= 0xD7) or m == 0xD8 or m == 0x01) {
            if (m == 0xFF) d.pos -= 1;
            continue;
        }
        if (m == 0xD9) break;
        if (d.pos + 2 > b.len) break;
        const len = (@as(usize, b[d.pos]) << 8) | b[d.pos + 1];
        if (len < 2 or d.pos + len > b.len) return fail("JPEG: truncated segment", .{});
        const seg = b[d.pos + 2 .. d.pos + len];
        d.pos += len;
        switch (m) {
            0xDB => {
                var p: usize = 0;
                while (p < seg.len) {
                    const pq = seg[p] >> 4;
                    const tq = seg[p] & 3;
                    p += 1;
                    for (0..64) |i| {
                        if (pq == 0) {
                            if (p >= seg.len) return fail("JPEG: bad DQT", .{});
                            qt[tq][i] = seg[p];
                            p += 1;
                        } else {
                            if (p + 1 >= seg.len) return fail("JPEG: bad DQT", .{});
                            qt[tq][i] = (@as(u16, seg[p]) << 8) | seg[p + 1];
                            p += 2;
                        }
                    }
                }
            },
            0xC4 => {
                var p: usize = 0;
                while (p + 17 <= seg.len) {
                    const tc = seg[p] >> 4;
                    const th = seg[p] & 3;
                    const counts = seg[p + 1 .. p + 17];
                    var total: usize = 0;
                    for (counts) |c| total += c;
                    p += 17;
                    if (p + total > seg.len or total > 256) return fail("JPEG: bad DHT", .{});
                    if (tc == 0) dc_h[th].build(counts, seg[p .. p + total]) else ac_h[th].build(counts, seg[p .. p + total]);
                    p += total;
                }
            },
            0xC0, 0xC1, 0xC2 => {
                if (seg.len < 6) return fail("JPEG: bad SOF", .{});
                progressive = m == 0xC2;
                if (seg[0] != 8) return fail("JPEG: only 8-bit precision is supported", .{});
                h = (@as(usize, seg[1]) << 8) | seg[2];
                w = (@as(usize, seg[3]) << 8) | seg[4];
                ncomp = seg[5];
                if (ncomp != 1 and ncomp != 3 and ncomp != 4) return fail("JPEG: unsupported component count {d}", .{ncomp});
                if (seg.len < 6 + ncomp * 3 or w == 0 or h == 0) return fail("JPEG: bad SOF", .{});
                for (0..ncomp) |i| {
                    comps[i].id = seg[6 + i * 3];
                    comps[i].hs = seg[7 + i * 3] >> 4;
                    comps[i].vs = seg[7 + i * 3] & 15;
                    comps[i].tq = seg[8 + i * 3] & 3;
                    if (comps[i].hs == 0 or comps[i].vs == 0 or comps[i].hs > 4 or comps[i].vs > 4) return fail("JPEG: bad sampling factors", .{});
                    hmax = @max(hmax, comps[i].hs);
                    vmax = @max(vmax, comps[i].vs);
                }
                mcux = (w + 8 * hmax - 1) / (8 * hmax);
                mcuy = (h + 8 * vmax - 1) / (8 * vmax);
                for (0..ncomp) |i| {
                    comps[i].bw = mcux * comps[i].hs;
                    comps[i].bh = mcuy * comps[i].vs;
                    comps[i].coef = try sys.A.alloc(i16, comps[i].bw * comps[i].bh * 64);
                    @memset(comps[i].coef, 0);
                }
                got_frame = true;
            },
            0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return fail("JPEG: unsupported coding process (marker {x})", .{m}),
            0xDD => {
                if (seg.len >= 2) restart = (@as(usize, seg[0]) << 8) | seg[1];
            },
            0xEE => {
                if (seg.len >= 12 and v.startsWith(seg, "Adobe")) adobe_transform = seg[11];
            },
            0xE1 => orientation = exifOrientation(seg) orelse orientation,
            0xDA => {
                if (!got_frame) return fail("JPEG: scan before frame header", .{});
                const ns = seg[0];
                if (seg.len < 1 + @as(usize, ns) * 2 + 3) return fail("JPEG: bad SOS", .{});
                var scan: [4]usize = undefined;
                for (0..ns) |i| {
                    const cid = seg[1 + i * 2];
                    var found = false;
                    for (0..ncomp) |ci| if (comps[ci].id == cid) {
                        scan[i] = ci;
                        comps[ci].td = seg[2 + i * 2] >> 4;
                        comps[ci].ta = seg[2 + i * 2] & 15;
                        found = true;
                    };
                    if (!found) return fail("JPEG: unknown component in scan", .{});
                }
                const ss = seg[1 + @as(usize, ns) * 2];
                const se = seg[2 + @as(usize, ns) * 2];
                const ah = seg[3 + @as(usize, ns) * 2] >> 4;
                const al: u4 = @intCast(seg[3 + @as(usize, ns) * 2] & 15);
                d.reset();
                for (0..ncomp) |i| comps[i].pred = 0;
                // number of MCUs / blocks in this scan
                var total_units: usize = undefined;
                var single_bw: usize = 0;
                if (ns == 1) {
                    const c = &comps[scan[0]];
                    // non-interleaved: only the blocks that cover the image
                    single_bw = (w * c.hs + hmax * 8 - 1) / (hmax * 8);
                    const bh2 = (h * c.vs + vmax * 8 - 1) / (vmax * 8);
                    total_units = single_bw * bh2;
                } else total_units = mcux * mcuy;
                var unit: usize = 0;
                while (unit < total_units) : (unit += 1) {
                    if (restart != 0 and unit != 0 and unit % restart == 0) {
                        // expect RSTn
                        d.bitcnt = 0;
                        d.bitbuf = 0;
                        if (d.marker == 0) {
                            while (d.pos + 1 < b.len and !(b[d.pos] == 0xFF and b[d.pos + 1] >= 0xD0 and b[d.pos + 1] <= 0xD7)) d.pos += 1;
                            d.pos += 2;
                        }
                        d.marker = 0;
                        d.eobrun = 0;
                        for (0..ncomp) |i| comps[i].pred = 0;
                    }
                    for (0..ns) |si| {
                        const c = &comps[scan[si]];
                        const nh: usize = if (ns == 1) 1 else c.hs;
                        const nv: usize = if (ns == 1) 1 else c.vs;
                        for (0..nv) |by| for (0..nh) |bx| {
                            var col: usize = undefined;
                            var row: usize = undefined;
                            if (ns == 1) {
                                col = unit % single_bw;
                                row = unit / single_bw;
                            } else {
                                col = (unit % mcux) * c.hs + bx;
                                row = (unit / mcux) * c.vs + by;
                            }
                            const blk = c.coef[(row * c.bw + col) * 64 ..][0..64];
                            if (!progressive) {
                                const t = d.huff(&dc_h[c.td]);
                                c.pred += d.receiveExtend(@intCast(t & 15));
                                blk[0] = @truncate(c.pred);
                                var k: usize = 1;
                                while (k < 64) {
                                    const rs = d.huff(&ac_h[c.ta]);
                                    const sz: u5 = @intCast(rs & 15);
                                    const run = rs >> 4;
                                    if (sz == 0) {
                                        if (run < 15) break;
                                        k += 16;
                                        continue;
                                    }
                                    k += run;
                                    if (k > 63) break;
                                    blk[k] = @truncate(d.receiveExtend(sz));
                                    k += 1;
                                }
                            } else if (ss == 0) {
                                if (ah == 0) {
                                    const t = d.huff(&dc_h[c.td]);
                                    c.pred += d.receiveExtend(@intCast(t & 15));
                                    blk[0] = @truncate(c.pred * (@as(i32, 1) << al));
                                } else if (d.bit() != 0) {
                                    blk[0] |= @as(i16, 1) << al;
                                }
                            } else if (ah == 0) {
                                // AC first pass
                                if (d.eobrun > 0) {
                                    d.eobrun -= 1;
                                } else {
                                    var k: usize = ss;
                                    while (k <= se) {
                                        const rs = d.huff(&ac_h[c.ta]);
                                        const sz: u5 = @intCast(rs & 15);
                                        const run: u5 = @intCast(rs >> 4);
                                        if (sz == 0) {
                                            if (run < 15) {
                                                d.eobrun = (@as(u32, 1) << run) - 1;
                                                if (run > 0) d.eobrun += d.bits(run);
                                                break;
                                            }
                                            k += 16;
                                        } else {
                                            k += run;
                                            if (k > 63) break;
                                            blk[k] = @truncate(d.receiveExtend(sz) * (@as(i32, 1) << al));
                                            k += 1;
                                        }
                                    }
                                }
                            } else {
                                // AC refinement
                                const p1: i16 = @as(i16, 1) << al;
                                const m1: i16 = -p1;
                                var k: usize = ss;
                                if (d.eobrun == 0) {
                                    while (k <= se) {
                                        const rs = d.huff(&ac_h[c.ta]);
                                        const sz = rs & 15;
                                        var run: i32 = rs >> 4;
                                        var val: i16 = 0;
                                        if (sz == 0) {
                                            if (run < 15) {
                                                d.eobrun = (@as(u32, 1) << @intCast(run));
                                                if (run > 0) d.eobrun += d.bits(@intCast(run));
                                                break;
                                            }
                                        } else {
                                            val = if (d.bit() != 0) p1 else m1;
                                        }
                                        while (k <= se) {
                                            const cf = &blk[k];
                                            if (cf.* != 0) {
                                                if (d.bit() != 0 and (cf.* & p1) == 0) {
                                                    cf.* += if (cf.* >= 0) p1 else m1;
                                                }
                                            } else {
                                                run -= 1;
                                                if (run < 0) break;
                                            }
                                            k += 1;
                                        }
                                        if (val != 0 and k <= 63) blk[k] = val;
                                        k += 1;
                                    }
                                }
                                if (d.eobrun > 0) {
                                    while (k <= se) : (k += 1) {
                                        const cf = &blk[k];
                                        if (cf.* != 0) {
                                            if (d.bit() != 0 and (cf.* & p1) == 0) {
                                                cf.* += if (cf.* >= 0) p1 else m1;
                                            }
                                        }
                                    }
                                    d.eobrun -= 1;
                                }
                            }
                        };
                    }
                }
                // continue with the marker that ended the entropy data
                if (d.marker != 0) {
                    d.pos -= 2;
                } else {
                    // skip to the next marker
                    while (d.pos + 1 < b.len and !(b[d.pos] == 0xFF and b[d.pos + 1] != 0 and !(b[d.pos + 1] >= 0xD0 and b[d.pos + 1] <= 0xD7))) d.pos += 1;
                }
            },
            else => {},
        }
    }
    if (!got_frame) return fail("JPEG: no image data", .{});
    // dequantise + IDCT into component planes
    for (0..ncomp) |i| {
        const c = &comps[i];
        const pw = c.bw * 8;
        c.plane = try sys.A.alloc(u8, pw * c.bh * 8);
        for (0..c.bh) |by| for (0..c.bw) |bx| {
            idctBlock(c.coef[(by * c.bw + bx) * 64 ..][0..64], &qt[c.tq], c.plane[(by * 8) * pw + bx * 8 ..], pw);
        };
    }
    var img = try Image.init(@intCast(w), @intCast(h));
    img.orientation = orientation;
    const go_ycc = ncomp == 3 and adobe_transform != 0 and comps[1].hs == comps[2].hs and comps[1].vs == comps[2].vs and comps[0].hs % comps[1].hs == 0 and comps[0].vs % comps[1].vs == 0;
    if (ncomp == 1) img.kind = .gray;
    if (go_ycc) {
        // like Go's *image.YCbCr: chroma sampled by nearest neighbour
        const hd = comps[0].hs / comps[1].hs;
        const vd = comps[0].vs / comps[1].vs;
        const ys = comps[0].bw * 8;
        const cs = comps[1].bw * 8;
        img.ycc = .{ .y = comps[0].plane, .cb = comps[1].plane, .cr = comps[2].plane, .ystride = ys, .cstride = cs, .hdiv = hd, .vdiv = vd };
        for (0..h) |y| for (0..w) |x| {
            const ci = (y / vd) * cs + x / hd;
            const rgb = yccToRgb(comps[0].plane[y * ys + x], comps[1].plane[ci], comps[2].plane[ci]);
            const o = (y * w + x) * 4;
            img.px[o] = rgb[0];
            img.px[o + 1] = rgb[1];
            img.px[o + 2] = rgb[2];
            img.px[o + 3] = 255;
        };
        return img;
    }
    for (0..h) |y| for (0..w) |x| {
        var s: [4]i32 = .{ 0, 128, 128, 255 };
        for (0..ncomp) |i| {
            const c = &comps[i];
            if (c.hs == hmax and c.vs == vmax) {
                s[i] = c.plane[y * c.bw * 8 + x];
                continue;
            }
            // bilinear chroma upsampling
            const pw = c.bw * 8;
            const cw_max = (w * c.hs + hmax - 1) / hmax - 1;
            const ch_max = (h * c.vs + vmax - 1) / vmax - 1;
            const fx = @max((@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(c.hs)) / @as(f32, @floatFromInt(hmax)) - 0.5, 0);
            const fy = @max((@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(c.vs)) / @as(f32, @floatFromInt(vmax)) - 0.5, 0);
            const x0 = @min(@as(usize, @intFromFloat(fx)), cw_max);
            const y0 = @min(@as(usize, @intFromFloat(fy)), ch_max);
            const x1 = @min(x0 + 1, cw_max);
            const y1 = @min(y0 + 1, ch_max);
            const tx = fx - @as(f32, @floatFromInt(x0));
            const ty = fy - @as(f32, @floatFromInt(y0));
            const p00: f32 = @floatFromInt(c.plane[y0 * pw + x0]);
            const p10: f32 = @floatFromInt(c.plane[y0 * pw + x1]);
            const p01: f32 = @floatFromInt(c.plane[y1 * pw + x0]);
            const p11: f32 = @floatFromInt(c.plane[y1 * pw + x1]);
            s[i] = @intFromFloat((p00 * (1 - tx) + p10 * tx) * (1 - ty) + (p01 * (1 - tx) + p11 * tx) * ty + 0.5);
        }
        const o = (y * w + x) * 4;
        const clamp = struct {
            fn f(val: i32) u8 {
                return @intCast(std.math.clamp(val, 0, 255));
            }
        }.f;
        if (ncomp == 1) {
            img.px[o] = clamp(s[0]);
            img.px[o + 1] = clamp(s[0]);
            img.px[o + 2] = clamp(s[0]);
        } else {
            var r: i32 = s[0];
            var g: i32 = s[1];
            var bl: i32 = s[2];
            const ycc = if (ncomp == 3) adobe_transform != 0 else adobe_transform == 2;
            if (ycc) {
                const yy = s[0];
                const cb = s[1] - 128;
                const cr = s[2] - 128;
                r = yy + ((91881 * cr + 32768) >> 16);
                g = yy - ((22554 * cb + 46802 * cr + 32768) >> 16);
                bl = yy + ((116130 * cb + 32768) >> 16);
            }
            if (ncomp == 4) {
                // Adobe CMYK is stored inverted
                const k = s[3];
                r = @divTrunc(clamp(r) * k, 255);
                g = @divTrunc(clamp(g) * k, 255);
                bl = @divTrunc(clamp(bl) * k, 255);
            }
            img.px[o] = clamp(r);
            img.px[o + 1] = clamp(g);
            img.px[o + 2] = clamp(bl);
        }
        img.px[o + 3] = 255;
    };
    return img;
}

fn exifOrientation(seg: []const u8) ?u8 {
    if (seg.len < 14 or !v.startsWith(seg, "Exif\x00\x00")) return null;
    const t = seg[6..];
    const le = t[0] == 'I';
    const rd16 = struct {
        fn f(p: []const u8, l: bool) usize {
            return if (l) (@as(usize, p[1]) << 8) | p[0] else (@as(usize, p[0]) << 8) | p[1];
        }
    }.f;
    const rd32 = struct {
        fn f(p: []const u8, l: bool) usize {
            return if (l) (@as(usize, p[3]) << 24) | (@as(usize, p[2]) << 16) | (@as(usize, p[1]) << 8) | p[0] else (@as(usize, p[0]) << 24) | (@as(usize, p[1]) << 16) | (@as(usize, p[2]) << 8) | p[3];
        }
    }.f;
    if (t.len < 8) return null;
    const ifd = rd32(t[4..], le);
    if (ifd + 2 > t.len) return null;
    const n = rd16(t[ifd..], le);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = ifd + 2 + i * 12;
        if (e + 12 > t.len) return null;
        if (rd16(t[e..], le) == 0x0112) {
            const val = rd16(t[e + 8 ..], le);
            if (val >= 1 and val <= 8) return @intCast(val);
        }
    }
    return null;
}

// ================================================================ JPEG encode

// ---- JPEG encoder: port of Go 1.26+ image/jpeg writer.go (+ its fdct in dct.go)

const unscaled_quant = [2][64]u8{
    .{ 16, 11, 12, 14, 12, 10, 16, 14, 13, 14, 18, 17, 16, 19, 24, 40, 26, 24, 22, 22, 24, 49, 35, 37, 29, 40, 58, 51, 61, 60, 57, 51, 56, 55, 64, 72, 92, 78, 64, 68, 87, 69, 55, 56, 80, 109, 81, 87, 95, 98, 103, 104, 103, 62, 77, 113, 121, 112, 100, 120, 92, 101, 103, 99 },
    .{ 17, 18, 18, 24, 21, 24, 47, 26, 26, 47, 99, 66, 56, 66, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99 },
};

const HSpec = struct { count: [16]u8, value: []const u8 };
const huff_specs = [4]HSpec{
    .{ .count = .{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 }, .value = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 } },
    .{ .count = .{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125 }, .value = &.{ 0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa } },
    .{ .count = .{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 }, .value = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 } },
    .{ .count = .{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119 }, .value = &.{ 0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa } },
};

fn huffLut(comptime sp: HSpec) [256]u32 {
    var lut: [256]u32 = @splat(0);
    var code: u32 = 0;
    var k: usize = 0;
    for (0..16) |i| {
        const nbits: u32 = @as(u32, @intCast(i + 1)) << 24;
        for (0..sp.count[i]) |_| {
            lut[sp.value[k]] = nbits | code;
            code += 1;
            k += 1;
        }
        code <<= 1;
    }
    return lut;
}
const huff_luts = blk: {
    @setEvalBranchQuota(100000);
    break :blk [4][256]u32{ huffLut(huff_specs[0]), huffLut(huff_specs[1]), huffLut(huff_specs[2]), huffLut(huff_specs[3]) };
};

const d_sqrt2 = 1630477228166597777;
const d_sqrt2_cos6 = 623956622067911264;
const d_sqrt2_sin6 = 1506364539328854985;

fn goFdct(b: *[64]i32) void {
    // columns
    for (0..8) |i| {
        var x0 = b[0 * 8 + i];
        var x1 = b[1 * 8 + i];
        var x2 = b[2 * 8 + i];
        var x3 = b[3 * 8 + i];
        var x4 = b[4 * 8 + i];
        var x5 = b[5 * 8 + i];
        var x6 = b[6 * 8 + i];
        var x7 = b[7 * 8 + i];
        var t = x0 +% x7;
        x7 = x0 -% x7;
        x0 = t;
        t = x1 +% x6;
        x6 = x1 -% x6;
        x1 = t;
        t = x2 +% x5;
        x5 = x2 -% x5;
        x2 = t;
        t = x3 +% x4;
        x4 = x3 -% x4;
        x3 = t;
        var bx = dctBox(x4, x7, dfix(d_cos3, 18), dfix(d_sin3, 18));
        x4 = bx[0];
        x7 = bx[1];
        bx = dctBox(x5, x6, dfix(d_cos1, 18), dfix(d_sin1, 18));
        x5 = bx[0];
        x6 = bx[1];
        t = x0 +% x3;
        x3 = x0 -% x3;
        x0 = t;
        t = x1 +% x2;
        x2 = x1 -% x2;
        x1 = t;
        bx = dctBox(x2, x3, dfix(d_sqrt2_cos6, 18), dfix(d_sqrt2_sin6, 18));
        x2 = bx[0];
        x3 = bx[1];
        t = x0 +% x1;
        x1 = x0 -% x1;
        x0 = t;
        b[0 * 8 + i] = shl(x0 -% 128 * 8, 18);
        b[4 * 8 + i] = shl(x1, 18);
        b[2 * 8 + i] = x2;
        b[6 * 8 + i] = x3;
        t = x4 +% x6;
        x6 = x4 -% x6;
        x4 = t;
        t = x7 +% x5;
        x5 = x7 -% x5;
        x7 = t;
        x5 = (x5 >> 12) *% dfix(d_sqrt2, 12);
        x6 = (x6 >> 12) *% dfix(d_sqrt2, 12);
        t = x7 +% x4;
        x4 = x7 -% x4;
        x7 = t;
        b[1 * 8 + i] = x7;
        b[3 * 8 + i] = x5;
        b[5 * 8 + i] = x6;
        b[7 * 8 + i] = x4;
    }
    // rows
    for (0..8) |i| {
        const x = b[8 * i ..][0..8];
        var x0 = x[0];
        var x1 = x[1];
        var x2 = x[2];
        var x3 = x[3];
        var x4 = x[4];
        var x5 = x[5];
        var x6 = x[6];
        var x7 = x[7];
        var t = x0 +% x7;
        x7 = x0 -% x7;
        x0 = t;
        t = x1 +% x6;
        x6 = x1 -% x6;
        x1 = t;
        t = x2 +% x5;
        x5 = x2 -% x5;
        x2 = t;
        t = x3 +% x4;
        x4 = x3 -% x4;
        x3 = t;
        var bx = dctBox(x4 >> 14, x7 >> 14, dfix(d_cos3, 14), dfix(d_sin3, 14));
        x4 = bx[0];
        x7 = bx[1];
        bx = dctBox(x5 >> 14, x6 >> 14, dfix(d_cos1, 14), dfix(d_sin1, 14));
        x5 = bx[0];
        x6 = bx[1];
        t = x0 +% x3;
        x3 = x0 -% x3;
        x0 = t;
        t = x1 +% x2;
        x2 = x1 -% x2;
        x1 = t;
        bx = dctBox(x2 >> 14, x3 >> 14, dfix(d_sqrt2_cos6, 14), dfix(d_sqrt2_sin6, 14));
        x2 = bx[0];
        x3 = bx[1];
        t = x0 +% x1;
        x1 = x0 -% x1;
        x0 = t;
        t = x4 +% x6;
        x6 = x4 -% x6;
        x4 = t;
        t = x7 +% x5;
        x5 = x7 -% x5;
        x7 = t;
        x5 = (x5 >> 14) *% dfix(d_sqrt2, 14);
        x6 = (x6 >> 14) *% dfix(d_sqrt2, 14);
        t = x7 +% x4;
        x4 = x7 -% x4;
        x7 = t;
        const r = struct {
            fn f(val: i32) i32 {
                return (val +% (1 << 17)) >> 18;
            }
        }.f;
        x[0] = r(x0);
        x[1] = r(x7);
        x[2] = r(x2);
        x[3] = r(x5);
        x[4] = r(x1);
        x[5] = r(x6);
        x[6] = r(x3);
        x[7] = r(x4);
    }
}

const JEnc = struct {
    out: v.Buf = .{},
    bits: u32 = 0,
    nbits: u32 = 0,
    quant: [2][64]u8 = undefined,

    fn emit(e: *JEnc, bits_in: u32, nbits_in: u32) void {
        const nbits = nbits_in + e.nbits;
        var bits = if (nbits_in == 0) 0 else bits_in << @intCast(32 - nbits);
        bits |= e.bits;
        var n = nbits;
        while (n >= 8) {
            const b: u8 = @intCast(bits >> 24);
            e.out.ch(b);
            if (b == 0xff) e.out.ch(0);
            bits <<= 8;
            n -= 8;
        }
        e.bits = bits;
        e.nbits = n;
    }
    fn emitHuff(e: *JEnc, h: usize, value: i32) void {
        const x = huff_luts[h][@intCast(value)];
        e.emit(x & ((1 << 24) - 1), x >> 24);
    }
    fn emitHuffRLE(e: *JEnc, h: usize, run: i32, value: i32) void {
        var a = value;
        var b = value;
        if (a < 0) {
            a = -value;
            b = value - 1;
        }
        const nbits: u32 = if (a < 0x100) bitCountOf(@intCast(a)) else 8 + bitCountOf(@intCast(a >> 8));
        e.emitHuff(h, (run << 4) | @as(i32, @intCast(nbits)));
        if (nbits > 0) e.emit(@as(u32, @bitCast(b)) & ((@as(u32, 1) << @intCast(nbits)) - 1), nbits);
    }
    fn writeBlock(e: *JEnc, b: *[64]i32, q: usize, prev_dc: i32) i32 {
        goFdct(b);
        const dc = jdiv(b[0], 8 * @as(i32, e.quant[q][0]));
        e.emitHuffRLE(2 * q, 0, dc - prev_dc);
        const h = 2 * q + 1;
        var run: i32 = 0;
        for (1..64) |zig| {
            const ac = jdiv(b[zigzag[zig]], 8 * @as(i32, e.quant[q][zig]));
            if (ac == 0) {
                run += 1;
            } else {
                while (run > 15) {
                    e.emitHuff(h, 0xf0);
                    run -= 16;
                }
                e.emitHuffRLE(h, run, ac);
                run = 0;
            }
        }
        if (run > 0) e.emitHuff(h, 0x00);
        return dc;
    }
};

fn bitCountOf(a: u32) u32 {
    var n: u32 = 0;
    var x = a;
    while (x > 0) : (x >>= 1) n += 1;
    return n;
}
fn jdiv(a: i32, b: i32) i32 {
    if (a >= 0) return @divTrunc(a + (b >> 1), b);
    return -@divTrunc(-a + (b >> 1), b);
}

/// color.RGBToYCbCr
pub fn rgbToYcc(r: u8, g: u8, b: u8) [3]u8 {
    const r1: i32 = r;
    const g1: i32 = g;
    const b1: i32 = b;
    const yy = (19595 * r1 + 38470 * g1 + 7471 * b1 + (1 << 15)) >> 16;
    var cb = -11056 * r1 - 21712 * g1 + 32768 * b1 + (257 << 15);
    if (@as(u32, @bitCast(cb)) & 0xff000000 == 0) cb >>= 16 else cb = ~(cb >> 31);
    var cr = 32768 * r1 - 27440 * g1 - 5328 * b1 + (257 << 15);
    if (@as(u32, @bitCast(cr)) & 0xff000000 == 0) cr >>= 16 else cr = ~(cr >> 31);
    return .{ @intCast(yy), @truncate(@as(u32, @bitCast(cb))), @truncate(@as(u32, @bitCast(cr))) };
}

fn jscale(dst: *[64]i32, src: *const [4][64]i32) void {
    for (0..4) |i| {
        const off = ((i & 2) << 4) | ((i & 1) << 2);
        for (0..4) |y| for (0..4) |x| {
            const j = 16 * y + 2 * x;
            const sum = src[i][j] + src[i][j + 1] + src[i][j + 8] + src[i][j + 9];
            dst[8 * y + x + off] = (sum + 2) >> 2;
        };
    }
}

/// Baseline JPEG like Go's jpeg.Encode (4:2:0, standard tables). Images with
/// transparency are flattened onto bg first (as Hugo does).
pub fn encodeJpeg(img_in: *const Image, quality_in: i64, bg: [3]u8) []const u8 {
    var img = img_in.*;
    if (!img.opaque_()) {
        img.px = sys.A.dupe(u8, img.px) catch return "";
        flatten(&img, bg);
    }
    const quality = std.math.clamp(quality_in, 1, 100);
    const sc: i64 = if (quality < 50) @divTrunc(5000, quality) else 200 - quality * 2;
    var e: JEnc = .{};
    for (0..2) |i| for (0..64) |j| {
        e.quant[i][j] = @intCast(std.math.clamp(@divTrunc(@as(i64, unscaled_quant[i][j]) * sc + 50, 100), 1, 255));
    };
    const gray = img.kind == .gray;
    const ncomp: usize = if (gray) 1 else 3;
    const w: usize = img.w;
    const h: usize = img.h;
    e.out.add(&.{ 0xff, 0xd8 });
    // DQT
    e.out.add(&.{ 0xff, 0xdb, 0, 2 + 2 * 65 });
    for (0..2) |i| {
        e.out.ch(@intCast(i));
        e.out.add(&e.quant[i]);
    }
    // SOF0
    const sof_len: usize = 8 + 3 * ncomp;
    e.out.add(&.{ 0xff, 0xc0, @intCast(sof_len >> 8), @intCast(sof_len & 0xff), 8, @intCast(h >> 8), @intCast(h & 0xff), @intCast(w >> 8), @intCast(w & 0xff), @intCast(ncomp) });
    if (gray) e.out.add(&.{ 1, 0x11, 0 }) else e.out.add(&.{ 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1 });
    // DHT
    const nspec: usize = if (gray) 2 else 4;
    var dht_len: usize = 2;
    for (huff_specs[0..nspec]) |sp| dht_len += 1 + 16 + sp.value.len;
    e.out.add(&.{ 0xff, 0xc4, @intCast(dht_len >> 8), @intCast(dht_len & 0xff) });
    for (huff_specs[0..nspec], 0..) |sp, i| {
        e.out.ch("\x00\x10\x01\x11"[i]);
        e.out.add(&sp.count);
        e.out.add(sp.value);
    }
    // SOS
    if (gray) e.out.add(&.{ 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00 }) else e.out.add(&.{ 0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00 });
    const xmax = w - 1;
    const ymax = h - 1;
    var b: [64]i32 = undefined;
    if (gray) {
        var prev: i32 = 0;
        var y: usize = 0;
        while (y < h) : (y += 8) {
            var x: usize = 0;
            while (x < w) : (x += 8) {
                for (0..8) |j| for (0..8) |i| {
                    b[8 * j + i] = img.px[(@min(y + j, ymax) * w + @min(x + i, xmax)) * 4];
                };
                prev = e.writeBlock(&b, 0, prev);
            }
        }
    } else {
        var cb: [4][64]i32 = undefined;
        var cr: [4][64]i32 = undefined;
        var py: i32 = 0;
        var pcb: i32 = 0;
        var pcr: i32 = 0;
        var y: usize = 0;
        while (y < h) : (y += 16) {
            var x: usize = 0;
            while (x < w) : (x += 16) {
                for (0..4) |k| {
                    const xo = (k & 1) * 8;
                    const yo = (k & 2) * 4;
                    for (0..8) |j| for (0..8) |i| {
                        const sx = @min(x + xo + i, xmax);
                        const sy = @min(y + yo + j, ymax);
                        var c: [3]u8 = undefined;
                        if (img.ycc) |yc| {
                            const ci = (sy / yc.vdiv) * yc.cstride + sx / yc.hdiv;
                            c = .{ yc.y[sy * yc.ystride + sx], yc.cb[ci], yc.cr[ci] };
                        } else {
                            const o = (sy * w + sx) * 4;
                            c = rgbToYcc(img.px[o], img.px[o + 1], img.px[o + 2]);
                        }
                        b[8 * j + i] = c[0];
                        cb[k][8 * j + i] = c[1];
                        cr[k][8 * j + i] = c[2];
                    };
                    py = e.writeBlock(&b, 0, py);
                }
                jscale(&b, &cb);
                pcb = e.writeBlock(&b, 1, pcb);
                jscale(&b, &cr);
                pcr = e.writeBlock(&b, 1, pcr);
            }
        }
    }
    e.emit(0x7f, 7);
    e.out.add(&.{ 0xff, 0xd9 });
    return e.out.str();
}

// ================================================================ GIF (first frame)

pub fn decodeGif(b: []const u8) anyerror!Image {
    if (b.len < 13) return fail("GIF: truncated", .{});
    const sw = @as(u32, b[6]) | (@as(u32, b[7]) << 8);
    const sh = @as(u32, b[8]) | (@as(u32, b[9]) << 8);
    var pos: usize = 13;
    var gpal: []const u8 = &.{};
    if (b[10] & 0x80 != 0) {
        const n = @as(usize, 3) << @intCast((b[10] & 7) + 1);
        if (pos + n > b.len) return fail("GIF: truncated", .{});
        gpal = b[pos .. pos + n];
        pos += n;
    }
    var transparent: ?u8 = null;
    var img = try Image.init(sw, sh);
    while (pos < b.len) {
        const blk = b[pos];
        pos += 1;
        if (blk == 0x21) {
            if (pos >= b.len) break;
            const label = b[pos];
            pos += 1;
            if (label == 0xF9 and pos + 5 < b.len) {
                if (b[pos + 1] & 1 != 0) transparent = b[pos + 4];
            }
            while (pos < b.len and b[pos] != 0) pos += @as(usize, b[pos]) + 1;
            pos += 1;
        } else if (blk == 0x2C) {
            if (pos + 9 > b.len) break;
            const fx = @as(usize, b[pos]) | (@as(usize, b[pos + 1]) << 8);
            const fy = @as(usize, b[pos + 2]) | (@as(usize, b[pos + 3]) << 8);
            const fw = @as(usize, b[pos + 4]) | (@as(usize, b[pos + 5]) << 8);
            const fh = @as(usize, b[pos + 6]) | (@as(usize, b[pos + 7]) << 8);
            const flags = b[pos + 8];
            pos += 9;
            var pal = gpal;
            if (flags & 0x80 != 0) {
                const n = @as(usize, 3) << @intCast((flags & 7) + 1);
                if (pos + n > b.len) break;
                pal = b[pos .. pos + n];
                pos += n;
            }
            const min_code: u5 = @intCast(@min(b[pos], 11));
            pos += 1;
            var data: std.ArrayList(u8) = .empty;
            while (pos < b.len and b[pos] != 0) {
                const n: usize = b[pos];
                if (pos + 1 + n > b.len) break;
                try data.appendSlice(sys.A, b[pos + 1 .. pos + 1 + n]);
                pos += n + 1;
            }
            // LZW
            const idx = try sys.A.alloc(u8, fw * fh);
            @memset(idx, 0);
            var prefix: [4096]u16 = undefined;
            var suffix: [4096]u8 = undefined;
            var stack: [4097]u8 = undefined;
            const clear: u32 = @as(u32, 1) << min_code;
            const eoi = clear + 1;
            var avail = clear + 2;
            var size: u5 = min_code + 1;
            var mask: u32 = (@as(u32, 1) << size) - 1;
            var old: ?u32 = null;
            var first: u8 = 0;
            var acc: u32 = 0;
            var nb: u5 = 0;
            var di: usize = 0;
            var oi: usize = 0;
            var c0: u32 = 0;
            while (c0 < clear) : (c0 += 1) {
                prefix[c0] = 0;
                suffix[c0] = @intCast(c0);
            }
            outer: while (oi < idx.len) {
                while (nb < size) {
                    if (di >= data.items.len) break :outer;
                    acc |= @as(u32, data.items[di]) << nb;
                    di += 1;
                    nb += 8;
                }
                var code = acc & mask;
                acc >>= size;
                nb -= size;
                if (code == clear) {
                    size = min_code + 1;
                    mask = (@as(u32, 1) << size) - 1;
                    avail = clear + 2;
                    old = null;
                    continue;
                }
                if (code == eoi) break;
                if (old == null) {
                    idx[oi] = suffix[code];
                    oi += 1;
                    old = code;
                    first = @intCast(code);
                    continue;
                }
                const in_code = code;
                var sp: usize = 0;
                if (code >= avail) {
                    stack[sp] = first;
                    sp += 1;
                    code = old.?;
                }
                while (code >= clear and sp < 4096) {
                    stack[sp] = suffix[code];
                    sp += 1;
                    code = prefix[code];
                }
                first = suffix[code];
                stack[sp] = first;
                sp += 1;
                if (avail < 4096) {
                    prefix[avail] = @intCast(old.?);
                    suffix[avail] = first;
                    avail += 1;
                    if ((avail & mask) == 0 and avail < 4096) {
                        size += 1;
                        mask = (@as(u32, 1) << size) - 1;
                    }
                }
                old = in_code;
                while (sp > 0 and oi < idx.len) {
                    sp -= 1;
                    idx[oi] = stack[sp];
                    oi += 1;
                }
            }
            const interlaced = flags & 0x40 != 0;
            var rows: std.ArrayList(usize) = .empty;
            if (interlaced) {
                for ([_][2]usize{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } }) |ps| {
                    var y = ps[0];
                    while (y < fh) : (y += ps[1]) try rows.append(sys.A, y);
                }
            }
            for (0..fh) |ry| {
                const y = if (interlaced) rows.items[ry] else ry;
                for (0..fw) |x| {
                    const pi: usize = idx[ry * fw + x];
                    if (fx + x >= sw or fy + y >= sh) continue;
                    const o = ((fy + y) * sw + fx + x) * 4;
                    if (transparent != null and transparent.? == pi) continue;
                    if (pi * 3 + 2 < pal.len) {
                        img.px[o] = pal[pi * 3];
                        img.px[o + 1] = pal[pi * 3 + 1];
                        img.px[o + 2] = pal[pi * 3 + 2];
                        img.px[o + 3] = 255;
                    }
                }
            }
            return img;
        } else if (blk == 0x3B) break;
    }
    return fail("GIF: no image frame found", .{});
}

// ================================================================ pixel operations

pub const Filter = enum { box, linear, hermite, mitchell, catmullrom, bspline, gaussian, lanczos, hann, hamming, blackman, bartlett, welch, cosine, nearest };

pub fn filterByName(name: []const u8) ?Filter {
    const table = [_]struct { n: []const u8, f: Filter }{
        .{ .n = "box", .f = .box },               .{ .n = "linear", .f = .linear },         .{ .n = "hermite", .f = .hermite },
        .{ .n = "mitchellnetravali", .f = .mitchell }, .{ .n = "catmullrom", .f = .catmullrom }, .{ .n = "bspline", .f = .bspline },
        .{ .n = "gaussian", .f = .gaussian },     .{ .n = "lanczos", .f = .lanczos },       .{ .n = "hann", .f = .hann },
        .{ .n = "hamming", .f = .hamming },       .{ .n = "blackman", .f = .blackman },     .{ .n = "bartlett", .f = .bartlett },
        .{ .n = "welch", .f = .welch },           .{ .n = "cosine", .f = .cosine },         .{ .n = "nearestneighbor", .f = .nearest },
    };
    for (table) |t| if (v.eqi(t.n, name)) return t.f;
    return null;
}

fn sinc(x: f32) f32 {
    if (x == 0) return 1;
    const a = x * std.math.pi;
    return @sin(a) / a;
}
fn bcspline(x_in: f32, b: f32, c: f32) f32 {
    const x = @abs(x_in);
    if (x < 1) return ((12 - 9 * b - 6 * c) * x * x * x + (-18 + 12 * b + 6 * c) * x * x + (6 - 2 * b)) / 6;
    if (x < 2) return ((-b - 6 * c) * x * x * x + (6 * b + 30 * c) * x * x + (-12 * b - 48 * c) * x + (8 * b + 24 * c)) / 6;
    return 0;
}
fn support(f: Filter) f32 {
    return switch (f) {
        .box => 0.5,
        .linear, .hermite => 1,
        .mitchell, .catmullrom, .bspline, .gaussian => 2,
        .nearest => 0,
        else => 3,
    };
}
fn kernel(f: Filter, x_in: f32) f32 {
    const x = @abs(x_in);
    const pi = std.math.pi;
    return switch (f) {
        .box => if (x < 0.5 or x_in == -0.5) 1 else 0,
        .linear => if (x < 1) 1 - x else 0,
        .hermite => if (x < 1) bcspline(x, 0, 0) else 0,
        .mitchell => if (x < 2) bcspline(x, 1.0 / 3.0, 1.0 / 3.0) else 0,
        .catmullrom => if (x < 2) bcspline(x, 0, 0.5) else 0,
        .bspline => if (x < 2) bcspline(x, 1, 0) else 0,
        .gaussian => if (x < 2) @exp(-2 * x * x) else 0,
        .lanczos => if (x < 3) sinc(x) * sinc(x / 3) else 0,
        .hann => if (x < 3) sinc(x) * (0.5 + 0.5 * @cos(pi * x / 3)) else 0,
        .hamming => if (x < 3) sinc(x) * (0.54 + 0.46 * @cos(pi * x / 3)) else 0,
        .blackman => if (x < 3) sinc(x) * (0.42 - 0.5 * @cos(pi * x / 3 + pi) + 0.08 * @cos(2 * pi * x / 3)) else 0,
        .bartlett => if (x < 3) sinc(x) * (3 - x) / 3 else 0,
        .welch => if (x < 3) sinc(x) * (1 - (x * x / 9)) else 0,
        .cosine => if (x < 3) sinc(x) * @cos((pi / 2.0) * (x / 3.0)) else 0,
        .nearest => 0,
    };
}

const Weights = struct { start: []u32, n: []u32, w: []f32, per: usize };

fn precompute(src: u32, dst: u32, f: Filter) !Weights {
    const du = @as(f32, @floatFromInt(src)) / @as(f32, @floatFromInt(dst));
    const scale = @max(du, 1.0);
    const ru = @ceil(scale * support(f));
    const per: usize = @as(usize, @intFromFloat(ru)) * 2 + 2;
    const start = try sys.A.alloc(u32, dst);
    const cnt = try sys.A.alloc(u32, dst);
    const ws = try sys.A.alloc(f32, dst * per);
    for (0..dst) |i| {
        const fu = (@as(f32, @floatFromInt(i)) + 0.5) * du - 0.5;
        var begin: i64 = @intFromFloat(@ceil(fu - ru));
        if (begin < 0) begin = 0;
        var end: i64 = @intFromFloat(@floor(fu + ru));
        if (end > @as(i64, src) - 1) end = @as(i64, src) - 1;
        var sum: f32 = 0;
        var k: usize = 0;
        var u = begin;
        while (u <= end and k < per) : (u += 1) {
            const wv = kernel(f, (@as(f32, @floatFromInt(u)) - fu) / scale);
            ws[i * per + k] = wv;
            sum += wv;
            k += 1;
        }
        if (sum != 0) {
            for (ws[i * per ..][0..k]) |*x| x.* /= sum;
        } else if (k > 0) {
            ws[i * per] = 1;
            k = 1;
        }
        start[i] = @intCast(begin);
        cnt[i] = @intCast(k);
    }
    return .{ .start = start, .n = cnt, .w = ws, .per = per };
}

pub fn resize(img: *const Image, dw: u32, dh: u32, f: Filter) anyerror!Image {
    if (dw == 0 or dh == 0) return fail("resize: zero-sized target", .{});
    return @import("giftx.zig").run(img, &.{.{ .resize = .{ .w = dw, .h = dh, .f = f } }});
}

pub fn crop(img: *const Image, x0: u32, y0: u32, w: u32, h: u32) anyerror!Image {
    var out = try Image.init(w, h);
    for (0..h) |y| {
        @memcpy(out.px[y * w * 4 ..][0 .. w * 4], img.px[((y0 + y) * @as(usize, img.w) + x0) * 4 ..][0 .. w * 4]);
    }
    return out;
}

/// Rotate counter-clockwise by a multiple of 90 degrees.
pub fn rotate90(img: *const Image, quarter_turns: u32) anyerror!Image {
    const t = quarter_turns % 4;
    if (t == 0) return crop(img, 0, 0, img.w, img.h);
    const nw = if (t == 2) img.w else img.h;
    const nh = if (t == 2) img.h else img.w;
    var out = try Image.init(nw, nh);
    for (0..img.h) |y| for (0..img.w) |x| {
        const dx: usize = switch (t) {
            1 => y,
            2 => img.w - 1 - x,
            else => img.h - 1 - y,
        };
        const dy: usize = switch (t) {
            1 => img.w - 1 - x,
            2 => img.h - 1 - y,
            else => x,
        };
        @memcpy(out.px[(dy * nw + dx) * 4 ..][0..4], img.px[(y * img.w + x) * 4 ..][0..4]);
    };
    return out;
}

pub fn flipH(img: *Image) void {
    for (0..img.h) |y| {
        var a: usize = 0;
        var b: usize = img.w - 1;
        while (a < b) : ({
            a += 1;
            b -= 1;
        }) {
            var t: [4]u8 = undefined;
            const pa = img.px[(y * img.w + a) * 4 ..][0..4];
            const pb = img.px[(y * img.w + b) * 4 ..][0..4];
            @memcpy(&t, pa);
            @memcpy(pa, pb);
            @memcpy(pb, &t);
        }
    }
}

/// Apply the EXIF orientation so that the pixels are upright.
pub fn autoOrient(img: *const Image) anyerror!Image {
    var out: Image = undefined;
    switch (img.orientation) {
        2 => {
            out = try crop(img, 0, 0, img.w, img.h);
            flipH(&out);
        },
        3 => out = try rotate90(img, 2),
        4 => {
            out = try rotate90(img, 2);
            flipH(&out);
        },
        5 => {
            out = try rotate90(img, 3);
            flipH(&out);
        },
        6 => out = try rotate90(img, 3),
        7 => {
            out = try rotate90(img, 1);
            flipH(&out);
        },
        8 => out = try rotate90(img, 1),
        else => out = try crop(img, 0, 0, img.w, img.h),
    }
    out.orientation = 1;
    return out;
}

fn c8f(val: f32) u8 {
    return if (val <= 0) 0 else if (val >= 255) 255 else @intFromFloat(val + 0.5);
}

pub const ColorOp = enum { grayscale, invert, brightness, contrast, saturation, gamma, sepia, opacity, hue, colorize, sigmoid, colorbalance };

pub fn colorOp(img: *Image, op: ColorOp, a: f32, b: f32, c: f32) void {
    var lut: [256]u8 = undefined;
    switch (op) {
        .brightness => for (&lut, 0..) |*l, i| {
            l.* = c8f(@as(f32, @floatFromInt(i)) + 255.0 * std.math.clamp(a, -100, 100) / 100.0);
        },
        .contrast => {
            const p = std.math.clamp(a, -100, 100);
            const alpha = if (p == 100) 1e9 else if (p < 0) 1 + p / 100.0 else 1 / (1 - p / 100.0);
            for (&lut, 0..) |*l, i| l.* = c8f((@as(f32, @floatFromInt(i)) / 255.0 - 0.5) * alpha * 255.0 + 127.5);
        },
        .gamma => for (&lut, 0..) |*l, i| {
            l.* = c8f(std.math.pow(f32, @as(f32, @floatFromInt(i)) / 255.0, 1.0 / @max(a, 0.0001)) * 255.0);
        },
        .sigmoid => {
            const mid = std.math.clamp(a, 0, 1);
            const factor = b;
            const sig = struct {
                fn f(aa: f32, bb: f32, x: f32) f32 {
                    return 1 / (1 + @exp(bb * (aa - x)));
                }
            }.f;
            const e = 1.0e-6;
            for (&lut, 0..) |*l, i| {
                const x = @as(f32, @floatFromInt(i)) / 255.0;
                if (factor == 0) {
                    l.* = @intCast(i);
                } else if (factor > 0) {
                    const sig0 = sig(mid, factor, 0);
                    const sig1 = sig(mid, factor, 1);
                    l.* = c8f(((sig(mid, factor, x) - sig0) / (sig1 - sig0)) * 255.0);
                } else {
                    const sig0 = sig(mid, -factor, 0);
                    const sig1 = sig(mid, -factor, 1);
                    const arg = std.math.clamp((sig1 - sig0) * x + sig0, e, 1 - e);
                    l.* = c8f((mid - @log(1 / arg - 1) / -factor) * 255.0);
                }
            }
        },
        else => {},
    }
    var i: usize = 0;
    while (i < img.px.len) : (i += 4) {
        const p = img.px[i..][0..4];
        const r: f32 = @floatFromInt(p[0]);
        const g: f32 = @floatFromInt(p[1]);
        const bl: f32 = @floatFromInt(p[2]);
        switch (op) {
            .grayscale => {
                const y = c8f(0.299 * r + 0.587 * g + 0.114 * bl);
                p[0] = y;
                p[1] = y;
                p[2] = y;
            },
            .invert => {
                p[0] = 255 - p[0];
                p[1] = 255 - p[1];
                p[2] = 255 - p[2];
            },
            .brightness, .contrast, .gamma, .sigmoid => {
                p[0] = lut[p[0]];
                p[1] = lut[p[1]];
                p[2] = lut[p[2]];
            },
            .saturation, .hue, .colorize => {
                var hsl = rgbToHsl(r / 255.0, g / 255.0, bl / 255.0);
                if (op == .saturation) {
                    hsl[1] = std.math.clamp(hsl[1] * (1 + std.math.clamp(a, -100, 500) / 100.0), 0, 1);
                } else if (op == .hue) {
                    hsl[0] = @mod(hsl[0] + a / 360.0, 1.0);
                } else {
                    hsl[0] = @mod(a / 360.0, 1.0);
                    hsl[1] = std.math.clamp(b / 100.0, 0, 1);
                    const rgb2 = hslToRgb(hsl[0], hsl[1], hsl[2]);
                    const pc = std.math.clamp(c / 100.0, 0, 1);
                    p[0] = c8f(r + (rgb2[0] * 255.0 - r) * pc);
                    p[1] = c8f(g + (rgb2[1] * 255.0 - g) * pc);
                    p[2] = c8f(bl + (rgb2[2] * 255.0 - bl) * pc);
                    continue;
                }
                const rgb = hslToRgb(hsl[0], hsl[1], hsl[2]);
                p[0] = c8f(rgb[0] * 255.0);
                p[1] = c8f(rgb[1] * 255.0);
                p[2] = c8f(rgb[2] * 255.0);
            },
            .sepia => {
                const pc = std.math.clamp(a, 0, 100) / 100.0;
                const nr = r * 0.393 + g * 0.769 + bl * 0.189;
                const ng = r * 0.349 + g * 0.686 + bl * 0.168;
                const nb = r * 0.272 + g * 0.534 + bl * 0.131;
                p[0] = c8f(r + (nr - r) * pc);
                p[1] = c8f(g + (ng - g) * pc);
                p[2] = c8f(bl + (nb - bl) * pc);
            },
            .opacity => p[3] = c8f(@as(f32, @floatFromInt(p[3])) * std.math.clamp(a, 0, 1)),
            .colorbalance => {
                p[0] = c8f(r * (1 + std.math.clamp(a, -100, 500) / 100.0));
                p[1] = c8f(g * (1 + std.math.clamp(b, -100, 500) / 100.0));
                p[2] = c8f(bl * (1 + std.math.clamp(c, -100, 500) / 100.0));
            },
        }
    }
}

fn rgbToHsl(r: f32, g: f32, b: f32) [3]f32 {
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const l = (mx + mn) / 2;
    if (mx == mn) return .{ 0, 0, l };
    const d = mx - mn;
    const s = if (l > 0.5) d / (2 - mx - mn) else d / (mx + mn);
    var h: f32 = 0;
    if (mx == r) {
        h = (g - b) / d + (if (g < b) @as(f32, 6) else 0);
    } else if (mx == g) {
        h = (b - r) / d + 2;
    } else h = (r - g) / d + 4;
    return .{ h / 6, s, l };
}
fn hue2rgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}
fn hslToRgb(h: f32, s: f32, l: f32) [3]f32 {
    if (s == 0) return .{ l, l, l };
    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
    const p = 2 * l - q;
    return .{ hue2rgb(p, q, h + 1.0 / 3.0), hue2rgb(p, q, h), hue2rgb(p, q, h - 1.0 / 3.0) };
}

pub fn gaussianBlur(img: *const Image, sigma: f32) anyerror!Image {
    if (sigma <= 0) return crop(img, 0, 0, img.w, img.h);
    const radius: usize = @intFromFloat(@ceil(sigma * 3));
    const k = try sys.A.alloc(f32, radius * 2 + 1);
    var sum: f32 = 0;
    for (k, 0..) |*x, i| {
        const d = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
        x.* = @exp(-(d * d) / (2 * sigma * sigma));
        sum += x.*;
    }
    for (k) |*x| x.* /= sum;
    const w: usize = img.w;
    const h: usize = img.h;
    const tmp = try sys.A.alloc(f32, w * h * 4);
    var out = try Image.init(img.w, img.h);
    for (0..h) |y| for (0..w) |x| {
        var acc = [4]f32{ 0, 0, 0, 0 };
        for (k, 0..) |wv, i| {
            const sx = std.math.clamp(@as(i64, @intCast(x + i)) - @as(i64, @intCast(radius)), 0, @as(i64, @intCast(w)) - 1);
            const s = img.px[(y * w + @as(usize, @intCast(sx))) * 4 ..][0..4];
            const a = @as(f32, @floatFromInt(s[3])) / 255.0;
            acc[0] += @as(f32, @floatFromInt(s[0])) * a * wv;
            acc[1] += @as(f32, @floatFromInt(s[1])) * a * wv;
            acc[2] += @as(f32, @floatFromInt(s[2])) * a * wv;
            acc[3] += @as(f32, @floatFromInt(s[3])) * wv;
        }
        @memcpy(tmp[(y * w + x) * 4 ..][0..4], &acc);
    };
    for (0..h) |y| for (0..w) |x| {
        var acc = [4]f32{ 0, 0, 0, 0 };
        for (k, 0..) |wv, i| {
            const sy = std.math.clamp(@as(i64, @intCast(y + i)) - @as(i64, @intCast(radius)), 0, @as(i64, @intCast(h)) - 1);
            const s = tmp[(@as(usize, @intCast(sy)) * w + x) * 4 ..][0..4];
            for (0..4) |ci| acc[ci] += s[ci] * wv;
        }
        const o = out.px[(y * w + x) * 4 ..][0..4];
        if (acc[3] > 0.0001) {
            const inv = 255.0 / acc[3];
            o[0] = c8f(acc[0] * inv);
            o[1] = c8f(acc[1] * inv);
            o[2] = c8f(acc[2] * inv);
        }
        o[3] = c8f(acc[3]);
    };
    return out;
}

pub fn unsharp(img: *const Image, sigma: f32, amount: f32, threshold: f32) anyerror!Image {
    const blurred = try gaussianBlur(img, sigma);
    var out = try crop(img, 0, 0, img.w, img.h);
    const amt = std.math.clamp(amount, 0, 500) / 100.0;
    const thr = std.math.clamp(threshold, 0, 100) * 255.0 / 100.0;
    var i: usize = 0;
    while (i < out.px.len) : (i += 1) {
        if (i % 4 == 3) continue;
        const o: f32 = @floatFromInt(img.px[i]);
        const bl: f32 = @floatFromInt(blurred.px[i]);
        const diff = o - bl;
        if (@abs(diff) > thr) out.px[i] = c8f(o + diff * amt);
    }
    return out;
}

pub fn pixelate(img: *Image, size_in: i64) void {
    const size: usize = @intCast(@max(size_in, 1));
    if (size <= 1) return;
    var by: usize = 0;
    while (by < img.h) : (by += size) {
        var bx: usize = 0;
        while (bx < img.w) : (bx += size) {
            var acc = [4]u64{ 0, 0, 0, 0 };
            var n: u64 = 0;
            const ey = @min(by + size, img.h);
            const ex = @min(bx + size, img.w);
            for (by..ey) |y| for (bx..ex) |x| {
                const s = img.px[(y * img.w + x) * 4 ..][0..4];
                for (0..4) |c| acc[c] += s[c];
                n += 1;
            };
            for (by..ey) |y| for (bx..ex) |x| {
                const s = img.px[(y * img.w + x) * 4 ..][0..4];
                for (0..4) |c| s[c] = @intCast(acc[c] / n);
            };
        }
    }
}

/// Alpha-composite `top` over `img` at (x, y).
pub fn overlay(img: *Image, top: *const Image, x0: i64, y0: i64) void {
    for (0..top.h) |ty| for (0..top.w) |tx| {
        const x = x0 + @as(i64, @intCast(tx));
        const y = y0 + @as(i64, @intCast(ty));
        if (x < 0 or y < 0 or x >= img.w or y >= img.h) continue;
        const s = top.px[(ty * top.w + tx) * 4 ..][0..4];
        const d = img.px[(@as(usize, @intCast(y)) * img.w + @as(usize, @intCast(x))) * 4 ..][0..4];
        const sa = @as(f32, @floatFromInt(s[3])) / 255.0;
        const da = @as(f32, @floatFromInt(d[3])) / 255.0;
        const oa = sa + da * (1 - sa);
        if (oa <= 0) continue;
        for (0..3) |c| d[c] = c8f((@as(f32, @floatFromInt(s[c])) * sa + @as(f32, @floatFromInt(d[c])) * da * (1 - sa)) / oa);
        d[3] = c8f(oa * 255.0);
    };
}

pub fn pad(img: *const Image, top: u32, right: u32, bottom: u32, left: u32, color: [4]u8) anyerror!Image {
    var out = try Image.init(img.w + left + right, img.h + top + bottom);
    var i: usize = 0;
    while (i < out.px.len) : (i += 4) @memcpy(out.px[i..][0..4], &color);
    for (0..img.h) |y| {
        @memcpy(out.px[((y + top) * @as(usize, out.w) + left) * 4 ..][0 .. img.w * 4], img.px[y * @as(usize, img.w) * 4 ..][0 .. img.w * 4]);
    }
    return out;
}

/// Flatten transparency onto a background colour.
pub fn flatten(img: *Image, bg: [3]u8) void {
    var i: usize = 0;
    while (i < img.px.len) : (i += 4) {
        const a: u32 = img.px[i + 3];
        if (a == 255) continue;
        // image/draw drawNRGBAOver onto a uniform opaque background
        const m: u32 = 0xffff;
        const sa: u32 = a * 0x101;
        const fa: u32 = (m - sa) * 0x101;
        for (0..3) |c| {
            const sc_: u32 = @as(u32, img.px[i + c]) * sa / 0xff;
            img.px[i + c] = @truncate((@as(u32, bg[c]) * fa / m + sc_) >> 8);
        }
        img.px[i + 3] = @truncate((255 * fa / m + sa) >> 8);
    }
}

/// Most frequent colours (coarse 4-bit-per-channel histogram), as #rrggbb strings.
pub fn dominantColors(img: *const Image, max: usize) [][]const u8 {
    const hist = sys.A.alloc(u32, 4096) catch return &.{};
    const sums = sys.A.alloc([3]u64, 4096) catch return &.{};
    @memset(hist, 0);
    for (sums) |*s| s.* = .{ 0, 0, 0 };
    const step: usize = @max(1, (@as(usize, img.w) * img.h) / 40000);
    var i: usize = 0;
    while (i < img.px.len) : (i += 4 * step) {
        if (img.px[i + 3] < 128) continue;
        const key = (@as(usize, img.px[i] >> 4) << 8) | (@as(usize, img.px[i + 1] >> 4) << 4) | (img.px[i + 2] >> 4);
        hist[key] += 1;
        sums[key][0] += img.px[i];
        sums[key][1] += img.px[i + 1];
        sums[key][2] += img.px[i + 2];
    }
    var out: std.ArrayList([]const u8) = .empty;
    while (out.items.len < max) {
        var best: usize = 0;
        for (hist, 0..) |hv, k| if (hv > hist[best]) {
            best = k;
        };
        if (hist[best] == 0) break;
        const n = hist[best];
        out.append(sys.A, v.fmt("#{x:0>2}{x:0>2}{x:0>2}", .{ sums[best][0] / n, sums[best][1] / n, sums[best][2] / n })) catch break;
        hist[best] = 0;
    }
    return out.items;
}
