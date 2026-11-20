// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
//! WebP encoder written from scratch: lossy VP8 key frames (16x16 intra
//! prediction, default token probabilities), lossless VP8L (subtract-green,
//! Huffman + LZ77), and the RIFF container with a VP8L-compressed alpha plane.
//! Decoding lives in webp_dec.zig.
const std = @import("std");
const sys = @import("sys.zig");
const v = @import("value.zig");
const image = @import("image.zig");
const tb = @import("vp8_tables.zig");
const Image = image.Image;

pub fn decode(b: []const u8) anyerror!Image {
    return @import("webp_dec.zig").decode(b);
}

// ================================================================ boolean entropy coder

const BoolEnc = struct {
    out: std.ArrayList(u8) = .empty,
    range: u32 = 255,
    bottom: u32 = 0,
    bit_count: i32 = 24,

    fn addOne(e: *BoolEnc) void {
        var i = e.out.items.len;
        while (i > 0) {
            i -= 1;
            if (e.out.items[i] == 255) {
                e.out.items[i] = 0;
            } else {
                e.out.items[i] += 1;
                break;
            }
        }
    }
    fn put(e: *BoolEnc, prob: u8, bit: bool) void {
        const split = 1 + (((e.range - 1) * prob) >> 8);
        if (bit) {
            e.bottom +%= split;
            // carry out of the 32-bit window
            if (e.bottom < split) e.addOne();
            e.range -= split;
        } else e.range = split;
        while (e.range < 128) {
            e.range <<= 1;
            if (e.bottom & 0x80000000 != 0) e.addOne();
            e.bottom <<= 1;
            e.bit_count -= 1;
            if (e.bit_count == 0) {
                e.out.append(sys.A, @truncate(e.bottom >> 24)) catch {};
                e.bottom &= 0xFFFFFF;
                e.bit_count = 8;
            }
        }
    }
    fn bits(e: *BoolEnc, val: u32, n: u5) void {
        var k: u5 = n;
        while (k > 0) {
            k -= 1;
            e.put(128, (val >> k) & 1 != 0);
        }
    }
    fn flush(e: *BoolEnc) void {
        var c = e.bit_count;
        var val = e.bottom;
        if (val & (@as(u32, 1) << @intCast(32 - c)) != 0) e.addOne();
        val <<= @intCast(c & 7);
        c >>= 3;
        while (c > 0) : (c -= 1) val <<= 8;
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            e.out.append(sys.A, @truncate(val >> 24)) catch {};
            val <<= 8;
        }
    }
};

// ================================================================ VP8 transforms (must mirror the decoder)

fn idct4(coef: *const [16]i16, dst: []u8, stride: usize) void {
    const c1: i32 = 85627;
    const c2: i32 = 35468;
    var m: [4][4]i32 = undefined;
    for (0..4) |i| {
        const a = @as(i32, coef[i]) + coef[8 + i];
        const b = @as(i32, coef[i]) - coef[8 + i];
        const c = ((@as(i32, coef[4 + i]) * c2) >> 16) - ((@as(i32, coef[12 + i]) * c1) >> 16);
        const d = ((@as(i32, coef[4 + i]) * c1) >> 16) + ((@as(i32, coef[12 + i]) * c2) >> 16);
        m[i][0] = a + d;
        m[i][1] = b + c;
        m[i][2] = b - c;
        m[i][3] = a - d;
    }
    for (0..4) |j| {
        const dc = m[0][j] + 4;
        const a = dc + m[2][j];
        const b = dc - m[2][j];
        const c = ((m[1][j] * c2) >> 16) - ((m[3][j] * c1) >> 16);
        const d = ((m[1][j] * c1) >> 16) + ((m[3][j] * c2) >> 16);
        const row = dst[j * stride ..];
        row[0] = clip8(@as(i32, row[0]) + ((a + d) >> 3));
        row[1] = clip8(@as(i32, row[1]) + ((b + c) >> 3));
        row[2] = clip8(@as(i32, row[2]) + ((b - c) >> 3));
        row[3] = clip8(@as(i32, row[3]) + ((a - d) >> 3));
    }
}

fn clip8(x: i32) u8 {
    return @intCast(std.math.clamp(x, 0, 255));
}

/// Inverse Walsh-Hadamard: 16 Y2 coefficients -> the DC of each of the 16 luma blocks.
fn iwht(in: *const [16]i16, out: *[16]i16) void {
    var m: [16]i32 = undefined;
    for (0..4) |i| {
        const a0 = @as(i32, in[i]) + in[12 + i];
        const a1 = @as(i32, in[4 + i]) + in[8 + i];
        const a2 = @as(i32, in[4 + i]) - in[8 + i];
        const a3 = @as(i32, in[i]) - in[12 + i];
        m[i] = a0 + a1;
        m[8 + i] = a0 - a1;
        m[4 + i] = a3 + a2;
        m[12 + i] = a3 - a2;
    }
    for (0..4) |i| {
        const dc = m[i * 4] + 3;
        const a0 = dc + m[3 + i * 4];
        const a1 = m[1 + i * 4] + m[2 + i * 4];
        const a2 = m[1 + i * 4] - m[2 + i * 4];
        const a3 = dc - m[3 + i * 4];
        out[i * 4 + 0] = @truncate((a0 + a1) >> 3);
        out[i * 4 + 1] = @truncate((a3 + a2) >> 3);
        out[i * 4 + 2] = @truncate((a0 - a1) >> 3);
        out[i * 4 + 3] = @truncate((a3 - a2) >> 3);
    }
}

/// Forward 4x4 DCT of (src - pred).
fn fdct4(src: []const u8, sstride: usize, pred: []const u8, pstride: usize, out: *[16]i16) void {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const d0 = @as(i32, src[i * sstride + 0]) - pred[i * pstride + 0];
        const d1 = @as(i32, src[i * sstride + 1]) - pred[i * pstride + 1];
        const d2 = @as(i32, src[i * sstride + 2]) - pred[i * pstride + 2];
        const d3 = @as(i32, src[i * sstride + 3]) - pred[i * pstride + 3];
        const a0 = d0 + d3;
        const a1 = d1 + d2;
        const a2 = d1 - d2;
        const a3 = d0 - d3;
        tmp[0 + i * 4] = (a0 + a1) * 8;
        tmp[1 + i * 4] = (a2 * 2217 + a3 * 5352 + 1812) >> 9;
        tmp[2 + i * 4] = (a0 - a1) * 8;
        tmp[3 + i * 4] = (a3 * 2217 - a2 * 5352 + 937) >> 9;
    }
    for (0..4) |i| {
        const a0 = tmp[0 + i] + tmp[12 + i];
        const a1 = tmp[4 + i] + tmp[8 + i];
        const a2 = tmp[4 + i] - tmp[8 + i];
        const a3 = tmp[0 + i] - tmp[12 + i];
        out[0 + i] = @truncate((a0 + a1 + 7) >> 4);
        out[4 + i] = @truncate(((a2 * 2217 + a3 * 5352 + 12000) >> 16) + @as(i32, @intFromBool(a3 != 0)));
        out[8 + i] = @truncate((a0 - a1 + 7) >> 4);
        out[12 + i] = @truncate((a3 * 2217 - a2 * 5352 + 51000) >> 16);
    }
}

fn fwht(in: *const [16]i16, out: *[16]i16) void {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const a0 = @as(i32, in[i * 4 + 0]) + in[i * 4 + 2];
        const a1 = @as(i32, in[i * 4 + 1]) + in[i * 4 + 3];
        const a2 = @as(i32, in[i * 4 + 1]) - in[i * 4 + 3];
        const a3 = @as(i32, in[i * 4 + 0]) - in[i * 4 + 2];
        tmp[0 + i * 4] = a0 + a1;
        tmp[1 + i * 4] = a3 + a2;
        tmp[2 + i * 4] = a3 - a2;
        tmp[3 + i * 4] = a0 - a1;
    }
    for (0..4) |i| {
        const a0 = tmp[0 + i] + tmp[8 + i];
        const a1 = tmp[4 + i] + tmp[12 + i];
        const a2 = tmp[4 + i] - tmp[12 + i];
        const a3 = tmp[0 + i] - tmp[8 + i];
        out[0 + i] = @truncate((a0 + a1) >> 1);
        out[4 + i] = @truncate((a3 + a2) >> 1);
        out[8 + i] = @truncate((a3 - a2) >> 1);
        out[12 + i] = @truncate((a0 - a1) >> 1);
    }
}

const zigzag4 = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
const bands = [17]u8{ 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 };
const cat3456 = [4][]const u8{ &.{ 173, 148, 140 }, &.{ 176, 155, 140, 135 }, &.{ 180, 157, 141, 134, 130 }, &.{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 } };

/// Quantise `coef` (raster order) in place to levels; returns true if any level in
/// scan positions >= first is non-zero. `coef` is then replaced by the dequantised values.
fn quantize(coef: *[16]i16, levels: *[16]i16, first: usize, qdc: i32, qac: i32) bool {
    var any = false;
    for (0..16) |n| {
        const z = zigzag4[n];
        if (n < first) {
            levels[n] = 0;
            continue;
        }
        const q: i32 = if (z == 0) qdc else qac;
        const c: i32 = coef[z];
        const a: i32 = @intCast(@abs(c));
        // slight dead zone for AC coefficients
        const bias: i32 = if (z == 0) @divTrunc(q, 2) else @divTrunc(q * 3, 8);
        var l = @divTrunc(a + bias, q);
        if (l > 2047) l = 2047;
        const sl: i32 = if (c < 0) -l else l;
        levels[n] = @intCast(sl);
        coef[z] = @intCast(sl * q);
        if (l != 0) any = true;
    }
    return any;
}

/// A recorded binary decision: either against an adaptive token probability
/// (idx < 1056) or against a fixed probability.
const Ev = struct { idx: u16, fixed: u8, bit: bool };
const fixed_ev: u16 = 0xFFFF;
const Events = std.ArrayList(Ev);

fn tokIdx(plane: usize, band: usize, ctx: usize, k: usize) u16 {
    return @intCast(((plane * 8 + band) * 3 + ctx) * 11 + k);
}

fn recTokens(ev: *Events, plane: usize, ctx_in: usize, first: usize, levels: *const [16]i16) u8 {
    const R = struct {
        fn a(e: *Events, pl: usize, band: usize, ctx: usize, k: usize, bit: bool) void {
            e.append(sys.A, .{ .idx = tokIdx(pl, band, ctx, k), .fixed = 0, .bit = bit }) catch {};
        }
        fn f(e: *Events, pr: u8, bit: bool) void {
            e.append(sys.A, .{ .idx = fixed_ev, .fixed = pr, .bit = bit }) catch {};
        }
    };
    var n: usize = first;
    var band: usize = bands[n];
    var ctx: usize = ctx_in;
    var last: i32 = -1;
    for (first..16) |k| if (levels[k] != 0) {
        last = @intCast(k);
    };
    if (last < 0) {
        R.a(ev, plane, band, ctx, 0, false);
        return 0;
    }
    R.a(ev, plane, band, ctx, 0, true);
    while (n < 16) {
        const c: i32 = levels[n];
        n += 1;
        if (c == 0) {
            R.a(ev, plane, band, ctx, 1, false);
            band = bands[n];
            ctx = 0;
            continue;
        }
        R.a(ev, plane, band, ctx, 1, true);
        const a: u32 = @abs(c);
        if (a == 1) {
            R.a(ev, plane, band, ctx, 2, false);
        } else {
            R.a(ev, plane, band, ctx, 2, true);
            if (a <= 4) {
                R.a(ev, plane, band, ctx, 3, false);
                if (a == 2) {
                    R.a(ev, plane, band, ctx, 4, false);
                } else {
                    R.a(ev, plane, band, ctx, 4, true);
                    R.a(ev, plane, band, ctx, 5, a == 4);
                }
            } else if (a <= 10) {
                R.a(ev, plane, band, ctx, 3, true);
                R.a(ev, plane, band, ctx, 6, false);
                if (a <= 6) {
                    R.a(ev, plane, band, ctx, 7, false);
                    R.f(ev, 159, a == 6);
                } else {
                    R.a(ev, plane, band, ctx, 7, true);
                    R.f(ev, 165, (a - 7) >> 1 != 0);
                    R.f(ev, 145, (a - 7) & 1 != 0);
                }
            } else {
                R.a(ev, plane, band, ctx, 3, true);
                R.a(ev, plane, band, ctx, 6, true);
                const cat: u32 = if (a < 19) 0 else if (a < 35) 1 else if (a < 67) 2 else 3;
                R.a(ev, plane, band, ctx, 8, cat >> 1 != 0);
                R.a(ev, plane, band, ctx, 9 + (cat >> 1), cat & 1 != 0);
                const extra = a - (3 + (@as(u32, 8) << @intCast(cat)));
                const tab = cat3456[cat];
                var k: usize = tab.len;
                for (tab) |tp| {
                    k -= 1;
                    R.f(ev, tp, (extra >> @intCast(k)) & 1 != 0);
                }
            }
        }
        const next_ctx: usize = if (a == 1) 1 else 2;
        R.f(ev, 128, c < 0);
        if (n == 16) return 1;
        band = bands[n];
        ctx = next_ctx;
        if (@as(i32, @intCast(n)) - 1 == last) {
            R.a(ev, plane, band, ctx, 0, false);
            return 1;
        }
        R.a(ev, plane, band, ctx, 0, true);
    }
    return 1;
}

const PredMode = enum(u2) { dc, tm, ve, he };

/// Fill `out` (size x size) with the intra prediction built from the reconstructed frame.
fn predict(rec: []const u8, stride: usize, x0: usize, y0: usize, size: usize, mode: PredMode, out: []u8) void {
    const has_top = y0 > 0;
    const has_left = x0 > 0;
    var top: [16]u8 = undefined;
    var left: [16]u8 = undefined;
    for (0..size) |i| {
        top[i] = if (has_top) rec[(y0 - 1) * stride + x0 + i] else 0x7f;
        left[i] = if (has_left) rec[(y0 + i) * stride + x0 - 1] else 0x81;
    }
    const tl: i32 = if (has_top and has_left) rec[(y0 - 1) * stride + x0 - 1] else if (has_top) 0x81 else 0x7f;
    const shift: u5 = if (size == 16) 5 else 4;
    switch (mode) {
        .dc => {
            var val: u32 = 0x80;
            if (has_top and has_left) {
                var sum: u32 = @intCast(size);
                for (0..size) |i| sum += @as(u32, top[i]) + left[i];
                val = sum >> shift;
            } else if (has_top or has_left) {
                var sum: u32 = @intCast(size / 2);
                for (0..size) |i| sum += if (has_top) top[i] else left[i];
                val = sum >> (shift - 1);
            }
            @memset(out[0 .. size * size], @intCast(val));
        },
        .tm => for (0..size) |j| for (0..size) |i| {
            out[j * size + i] = clip8(@as(i32, left[j]) + top[i] - tl);
        },
        .ve => for (0..size) |j| for (0..size) |i| {
            out[j * size + i] = top[i];
        },
        .he => for (0..size) |j| for (0..size) |i| {
            out[j * size + i] = left[j];
        },
    }
}

// 4x4 sub-block modes (numbering as in the bitstream); only those that do not
// need above-right pixels are used by this encoder.
const B_DC = 0;
const B_TM = 1;
const B_HE = 3;
const B_RD = 4;
const B_VR = 5;
const B_HD = 8;
const B_HU = 9;
const i4_modes = [_]u8{ B_DC, B_TM, B_HE, B_RD, B_VR, B_HD, B_HU };

fn pred4(rec: []const u8, stride: usize, x0: usize, y0: usize, mode: u8, out: *[16]u8) void {
    const has_top = y0 > 0;
    const has_left = x0 > 0;
    var t: [4]i32 = undefined;
    var l: [4]i32 = undefined;
    for (0..4) |i| {
        t[i] = if (has_top) rec[(y0 - 1) * stride + x0 + i] else 0x7f;
        l[i] = if (has_left) rec[(y0 + i) * stride + x0 - 1] else 0x81;
    }
    const a: i32 = if (has_top and has_left) rec[(y0 - 1) * stride + x0 - 1] else if (has_top) 0x81 else 0x7f;
    const b = t[0];
    const c = t[1];
    const d = t[2];
    const e = t[3];
    const p = l[0];
    const q = l[1];
    const r = l[2];
    const s = l[3];
    const A3 = struct {
        fn f(x: i32, y: i32, z: i32) u8 {
            return @intCast(@divTrunc(x + 2 * y + z + 2, 4));
        }
    }.f;
    const A2 = struct {
        fn f(x: i32, y: i32) u8 {
            return @intCast(@divTrunc(x + y + 1, 2));
        }
    }.f;
    switch (mode) {
        B_DC => {
            const sum: i32 = 4 + b + c + d + e + p + q + r + s;
            @memset(out, @intCast(@divTrunc(sum, 8)));
        },
        B_TM => for (0..4) |j| for (0..4) |i| {
            out[j * 4 + i] = clip8(l[j] + t[i] - a);
        },
        B_HE => {
            const rows = [4]u8{ A3(a, p, q), A3(r, q, p), A3(s, r, q), A3(s, s, r) };
            for (0..4) |j| @memset(out[j * 4 ..][0..4], rows[j]);
        },
        B_RD => {
            const srq = A3(s, r, q);
            const rqp = A3(r, q, p);
            const qpa = A3(q, p, a);
            const pab = A3(p, a, b);
            const abc = A3(a, b, c);
            const bcd = A3(b, c, d);
            const cde = A3(c, d, e);
            out.* = .{ pab, abc, bcd, cde, qpa, pab, abc, bcd, rqp, qpa, pab, abc, srq, rqp, qpa, pab };
        },
        B_VR => {
            const ab = A2(a, b);
            const bc = A2(b, c);
            const cd = A2(c, d);
            const de = A2(d, e);
            const rqp = A3(r, q, p);
            const qpa = A3(q, p, a);
            const pab = A3(p, a, b);
            const abc = A3(a, b, c);
            const bcd = A3(b, c, d);
            const cde = A3(c, d, e);
            out.* = .{ ab, bc, cd, de, pab, abc, bcd, cde, qpa, ab, bc, cd, rqp, pab, abc, bcd };
        },
        B_HD => {
            const sr = A2(s, r);
            const rq = A2(r, q);
            const qp = A2(q, p);
            const pa = A2(p, a);
            const srq = A3(s, r, q);
            const rqp = A3(r, q, p);
            const qpa = A3(q, p, a);
            const pab = A3(p, a, b);
            const abc = A3(a, b, c);
            const bcd = A3(b, c, d);
            out.* = .{ pa, pab, abc, bcd, qp, qpa, pa, pab, rq, rqp, qp, qpa, sr, srq, rq, rqp };
        },
        else => { // B_HU
            const pq = A2(p, q);
            const qr = A2(q, r);
            const rs = A2(r, s);
            const pqr = A3(p, q, r);
            const qrs = A3(q, r, s);
            const rss = A3(r, s, s);
            const sss: u8 = @intCast(s);
            out.* = .{ pq, pqr, qr, qrs, qr, qrs, rs, rss, rs, rss, sss, sss, sss, sss, sss, sss };
        },
    }
}

fn sad(src: []const u8, sstride: usize, x0: usize, y0: usize, size: usize, pred: []const u8) u32 {
    var s: u32 = 0;
    for (0..size) |j| for (0..size) |i| {
        s += @abs(@as(i32, src[(y0 + j) * sstride + x0 + i]) - pred[j * size + i]);
    };
    return s;
}

fn sse(src: []const u8, sstride: usize, x0: usize, y0: usize, size: usize, rec: []const u8, rstride: usize, rx: usize, ry: usize) u64 {
    var s: u64 = 0;
    for (0..size) |j| for (0..size) |i| {
        const d = @as(i64, src[(y0 + j) * sstride + x0 + i]) - rec[(ry + j) * rstride + rx + i];
        s += @intCast(d * d);
    };
    return s;
}

/// Rough bit cost of a block of levels (used only for the i16 / i4 decision).
fn levelBits(levels: *const [16]i16, first: usize) u32 {
    var bits_n: u32 = 1;
    var last: usize = 0;
    var any = false;
    for (first..16) |k| if (levels[k] != 0) {
        last = k;
        any = true;
    };
    if (!any) return 1;
    for (first..last + 1) |k| {
        const a: u32 = @abs(levels[k]);
        if (a == 0) {
            bits_n += 1;
        } else {
            bits_n += 4 + 2 * (32 - @clz(a));
        }
    }
    return bits_n;
}

fn qualityToIndex(q_in: i64) i32 {
    const q: f64 = @as(f64, @floatFromInt(std.math.clamp(q_in, 0, 100))) / 100.0;
    const linear = if (q < 0.75) q * (2.0 / 3.0) else 2.0 * q - 1.0;
    const val = std.math.pow(f64, linear, 1.0 / 3.0);
    return std.math.clamp(@as(i32, @intFromFloat(127.0 * (1.0 - val))), 0, 127);
}

fn bitCost(pr: u32, bit: bool) f64 {
    const pz: f64 = @as(f64, @floatFromInt(std.math.clamp(pr, 1, 255))) / 256.0;
    return -@log2(if (bit) 1.0 - pz else pz);
}

/// Encode the colour planes as a VP8 key frame (the payload of a "VP8 " chunk).
fn encodeVp8(img: *const Image, quality: i64) []const u8 {
    const w: usize = img.w;
    const h: usize = img.h;
    const mbw = (w + 15) / 16;
    const mbh = (h + 15) / 16;
    const ys = mbw * 16;
    const cs = mbw * 8;
    const Y = sys.A.alloc(u8, ys * mbh * 16) catch return "";
    const U = sys.A.alloc(u8, cs * mbh * 8) catch return "";
    const V = sys.A.alloc(u8, cs * mbh * 8) catch return "";
    // RGB -> YUV (BT.601, as specified for WebP), edges replicated
    for (0..mbh * 16) |y| for (0..ys) |x| {
        const o = (@min(y, h - 1) * w + @min(x, w - 1)) * 4;
        const r: i32 = img.px[o];
        const g: i32 = img.px[o + 1];
        const b: i32 = img.px[o + 2];
        Y[y * ys + x] = clip8(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
    };
    for (0..mbh * 8) |y| for (0..cs) |x| {
        var r: i32 = 0;
        var g: i32 = 0;
        var b: i32 = 0;
        for (0..2) |dy| for (0..2) |dx| {
            const o = (@min(y * 2 + dy, h - 1) * w + @min(x * 2 + dx, w - 1)) * 4;
            r += img.px[o];
            g += img.px[o + 1];
            b += img.px[o + 2];
        };
        r = (r + 2) >> 2;
        g = (g + 2) >> 2;
        b = (b + 2) >> 2;
        U[y * cs + x] = clip8(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
        V[y * cs + x] = clip8(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    };
    const rY = sys.A.alloc(u8, Y.len) catch return "";
    const rU = sys.A.alloc(u8, U.len) catch return "";
    const rV = sys.A.alloc(u8, V.len) catch return "";

    const qi = qualityToIndex(quality);
    const y1dc: i32 = tb.dc_q[@intCast(qi)];
    const y1ac: i32 = tb.ac_q[@intCast(qi)];
    const y2dc: i32 = @as(i32, tb.dc_q[@intCast(qi)]) * 2;
    const y2ac: i32 = @max(8, @divTrunc(@as(i32, tb.ac_q[@intCast(qi)]) * 155, 100));
    const uvdc: i32 = tb.dc_q[@intCast(@min(qi, 117))];
    const uvac: i32 = tb.ac_q[@intCast(qi)];
    const lambda: f64 = 0.12 * @as(f64, @floatFromInt(y1ac * y1ac));

    var tok: Events = .empty; // token partition decisions
    var fpe: Events = .empty; // per-macroblock header decisions (idx 0 = skip flag placeholder)
    var n_skip: u32 = 0;

    const up_y = sys.A.alloc(u8, mbw * 4) catch return "";
    const up_u = sys.A.alloc(u8, mbw * 2) catch return "";
    const up_v = sys.A.alloc(u8, mbw * 2) catch return "";
    const up_y2 = sys.A.alloc(u8, mbw) catch return "";
    const up_mode = sys.A.alloc(u8, mbw * 4) catch return "";
    @memset(up_y, 0);
    @memset(up_u, 0);
    @memset(up_v, 0);
    @memset(up_y2, 0);
    @memset(up_mode, 0);

    var pred_buf: [4][256]u8 = undefined;
    const modes = [_]PredMode{ .dc, .tm, .ve, .he };
    for (0..mbh) |my| {
        var left_y = @as([4]u8, @splat(0));
        var left_u = @as([2]u8, @splat(0));
        var left_v = @as([2]u8, @splat(0));
        var left_y2: u8 = 0;
        var left_mode = @as([4]u8, @splat(0));
        for (0..mbw) |mx| {
            const x0 = mx * 16;
            const y0 = my * 16;
            // ---- 16x16 candidate
            var best: usize = 0;
            var best_sad: u32 = std.math.maxInt(u32);
            for (modes, 0..) |m, k| {
                predict(rY, ys, x0, y0, 16, m, &pred_buf[k]);
                const sd = sad(Y, ys, x0, y0, 16, &pred_buf[k]);
                if (sd < best_sad) {
                    best_sad = sd;
                    best = k;
                }
            }
            const ymode = modes[best];
            const ypred = pred_buf[best];
            var coefs: [16][16]i16 = undefined;
            var dcs: [16]i16 = undefined;
            for (0..16) |n| {
                const bx = (n % 4) * 4;
                const by = (n / 4) * 4;
                fdct4(Y[(y0 + by) * ys + x0 + bx ..], ys, ypred[by * 16 + bx ..], 16, &coefs[n]);
                dcs[n] = coefs[n][0];
            }
            var y2: [16]i16 = undefined;
            fwht(&dcs, &y2);
            var y2_levels: [16]i16 = undefined;
            var any16 = quantize(&y2, &y2_levels, 0, y2dc, y2ac);
            var rdcs: [16]i16 = undefined;
            iwht(&y2, &rdcs);
            var lev16: [16][16]i16 = undefined;
            var rec16: [256]u8 = undefined;
            var bits16: u32 = 2 + levelBits(&y2_levels, 0);
            for (0..16) |n| {
                const bx = n % 4;
                const by = n / 4;
                if (quantize(&coefs[n], &lev16[n], 1, y1dc, y1ac)) any16 = true;
                bits16 += levelBits(&lev16[n], 1);
                coefs[n][0] = rdcs[n];
                const dst = rec16[(by * 4) * 16 + bx * 4 ..];
                for (0..4) |j| @memcpy(dst[j * 16 ..][0..4], ypred[(by * 4 + j) * 16 + bx * 4 ..][0..4]);
                idct4(&coefs[n], dst, 16);
            }
            const sse16 = sse(Y, ys, x0, y0, 16, &rec16, 16, 0, 0);
            // ---- 4x4 candidate, reconstructed in place
            var lev4: [16][16]i16 = undefined;
            var mode4: [16]u8 = undefined;
            var bits4: u32 = 0;
            var any4 = false;
            for (0..16) |n| {
                const bx = x0 + (n % 4) * 4;
                const by = y0 + (n / 4) * 4;
                var bbest: u8 = B_DC;
                var bsad: u32 = std.math.maxInt(u32);
                var bpred: [16]u8 = undefined;
                var cand: [16]u8 = undefined;
                for (i4_modes) |m| {
                    pred4(rY, ys, bx, by, m, &cand);
                    var sd: u32 = 0;
                    for (0..4) |j| for (0..4) |i| {
                        sd += @abs(@as(i32, Y[(by + j) * ys + bx + i]) - cand[j * 4 + i]);
                    };
                    if (m != B_DC) sd += @intCast(@divTrunc(y1ac, 4));
                    if (sd < bsad) {
                        bsad = sd;
                        bbest = m;
                        bpred = cand;
                    }
                }
                mode4[n] = bbest;
                var cf: [16]i16 = undefined;
                fdct4(Y[by * ys + bx ..], ys, &bpred, 4, &cf);
                if (quantize(&cf, &lev4[n], 0, y1dc, y1ac)) any4 = true;
                bits4 += levelBits(&lev4[n], 0) + (if (bbest == B_DC) @as(u32, 2) else 4);
                const dst = rY[by * ys + bx ..];
                for (0..4) |j| @memcpy(dst[j * ys ..][0..4], bpred[j * 4 ..][0..4]);
                idct4(&cf, dst, ys);
            }
            const sse4 = sse(Y, ys, x0, y0, 16, rY, ys, x0, y0);
            const cost16 = @as(f64, @floatFromInt(sse16)) + lambda * @as(f64, @floatFromInt(bits16));
            const cost4 = @as(f64, @floatFromInt(sse4)) + lambda * @as(f64, @floatFromInt(bits4));
            const use4 = cost4 < cost16;
            if (!use4) {
                for (0..16) |j| @memcpy(rY[(y0 + j) * ys + x0 ..][0..16], rec16[j * 16 ..][0..16]);
            }
            // ---- chroma (U and V share the mode)
            var cbest: usize = 0;
            var cbest_sad: u32 = std.math.maxInt(u32);
            var upred: [4][64]u8 = undefined;
            var vpred: [4][64]u8 = undefined;
            for (modes, 0..) |m, k| {
                predict(rU, cs, mx * 8, my * 8, 8, m, &upred[k]);
                predict(rV, cs, mx * 8, my * 8, 8, m, &vpred[k]);
                const sd = sad(U, cs, mx * 8, my * 8, 8, &upred[k]) + sad(V, cs, mx * 8, my * 8, 8, &vpred[k]);
                if (sd < cbest_sad) {
                    cbest_sad = sd;
                    cbest = k;
                }
            }
            const cmode = modes[cbest];
            var clev: [8][16]i16 = undefined;
            var anyc = false;
            inline for (.{ 0, 1 }) |ci| {
                const plane_src = if (ci == 0) U else V;
                const plane_rec = if (ci == 0) rU else rV;
                const cpred = if (ci == 0) upred[cbest] else vpred[cbest];
                for (0..4) |n| {
                    const bx = n % 2;
                    const by = n / 2;
                    var cf: [16]i16 = undefined;
                    fdct4(plane_src[(my * 8 + by * 4) * cs + mx * 8 + bx * 4 ..], cs, cpred[by * 4 * 8 + bx * 4 ..], 8, &cf);
                    if (quantize(&cf, &clev[ci * 4 + n], 0, uvdc, uvac)) anyc = true;
                    const dst = plane_rec[(my * 8 + by * 4) * cs + mx * 8 + bx * 4 ..];
                    for (0..4) |j| @memcpy(dst[j * cs ..][0..4], cpred[(by * 4 + j) * 8 + bx * 4 ..][0..4]);
                    idct4(&cf, dst, cs);
                }
            }
            // ---- macroblock header
            const skip = !anyc and !(if (use4) any4 else any16);
            if (skip) n_skip += 1;
            const F = struct {
                fn f(e: *Events, pr: u8, bit: bool) void {
                    e.append(sys.A, .{ .idx = fixed_ev, .fixed = pr, .bit = bit }) catch {};
                }
            };
            fpe.append(sys.A, .{ .idx = 0, .fixed = 0, .bit = skip }) catch {};
            F.f(&fpe, 145, !use4);
            if (!use4) {
                switch (ymode) {
                    .dc => {
                        F.f(&fpe, 156, false);
                        F.f(&fpe, 163, false);
                    },
                    .ve => {
                        F.f(&fpe, 156, false);
                        F.f(&fpe, 163, true);
                    },
                    .he => {
                        F.f(&fpe, 156, true);
                        F.f(&fpe, 128, false);
                    },
                    .tm => {
                        F.f(&fpe, 156, true);
                        F.f(&fpe, 128, true);
                    },
                }
                const mv: u8 = @intFromEnum(ymode);
                for (0..4) |k| {
                    up_mode[mx * 4 + k] = mv;
                    left_mode[k] = mv;
                }
            } else {
                for (0..16) |n| {
                    const bx = n % 4;
                    const by = n / 4;
                    const pp = tb.pred_prob[(@as(usize, up_mode[mx * 4 + bx]) * 10 + left_mode[by]) * 9 ..][0..9];
                    const m = mode4[n];
                    if (m == B_DC) {
                        F.f(&fpe, pp[0], false);
                    } else {
                        F.f(&fpe, pp[0], true);
                        if (m == B_TM) {
                            F.f(&fpe, pp[1], false);
                        } else {
                            F.f(&fpe, pp[1], true);
                            F.f(&fpe, pp[2], true); // not VE
                            if (m == B_HE or m == B_RD or m == B_VR) {
                                F.f(&fpe, pp[3], false);
                                if (m == B_HE) {
                                    F.f(&fpe, pp[4], false);
                                } else {
                                    F.f(&fpe, pp[4], true);
                                    F.f(&fpe, pp[5], m == B_VR);
                                }
                            } else {
                                F.f(&fpe, pp[3], true);
                                F.f(&fpe, pp[6], true); // not LD
                                F.f(&fpe, pp[7], true); // not VL
                                F.f(&fpe, pp[8], m == B_HU);
                            }
                        }
                    }
                    up_mode[mx * 4 + bx] = m;
                    left_mode[by] = m;
                }
            }
            switch (cmode) {
                .dc => F.f(&fpe, 142, false),
                .ve => {
                    F.f(&fpe, 142, true);
                    F.f(&fpe, 114, false);
                },
                .he => {
                    F.f(&fpe, 142, true);
                    F.f(&fpe, 114, true);
                    F.f(&fpe, 183, false);
                },
                .tm => {
                    F.f(&fpe, 142, true);
                    F.f(&fpe, 114, true);
                    F.f(&fpe, 183, true);
                },
            }
            // ---- residual tokens
            if (skip) {
                if (!use4) {
                    left_y2 = 0;
                    up_y2[mx] = 0;
                }
                @memset(&left_y, 0);
                @memset(up_y[mx * 4 ..][0..4], 0);
                @memset(&left_u, 0);
                @memset(&left_v, 0);
                @memset(up_u[mx * 2 ..][0..2], 0);
                @memset(up_v[mx * 2 ..][0..2], 0);
                continue;
            }
            if (!use4) {
                const nz2 = recTokens(&tok, 1, left_y2 + up_y2[mx], 0, &y2_levels);
                left_y2 = nz2;
                up_y2[mx] = nz2;
            }
            for (0..16) |n| {
                const bx = n % 4;
                const by = n / 4;
                const nz = if (use4) recTokens(&tok, 3, left_y[by] + up_y[mx * 4 + bx], 0, &lev4[n]) else recTokens(&tok, 0, left_y[by] + up_y[mx * 4 + bx], 1, &lev16[n]);
                left_y[by] = nz;
                up_y[mx * 4 + bx] = nz;
            }
            inline for (.{ 0, 1 }) |ci| {
                const upc = if (ci == 0) up_u else up_v;
                const leftc = if (ci == 0) &left_u else &left_v;
                for (0..4) |n| {
                    const bx = n % 2;
                    const by = n / 2;
                    const nz = recTokens(&tok, 2, leftc[by] + upc[mx * 2 + bx], 0, &clev[ci * 4 + n]);
                    leftc[by] = nz;
                    upc[mx * 2 + bx] = nz;
                }
            }
        }
    }

    // ---- adapt the token probabilities to this image
    var probs: [1056]u8 = tb.default_token_prob;
    var update: [1056]bool = @as([1056]bool, @splat(false));
    {
        const cnt = sys.A.alloc([2]u32, 1056) catch return "";
        for (cnt) |*c| c.* = .{ 0, 0 };
        for (tok.items) |e| if (e.idx != fixed_ev) {
            cnt[e.idx][@intFromBool(e.bit)] += 1;
        };
        for (0..1056) |k| {
            const c0: f64 = @floatFromInt(cnt[k][0]);
            const c1: f64 = @floatFromInt(cnt[k][1]);
            if (c0 + c1 == 0) continue;
            const np: u32 = std.math.clamp(@as(u32, @intFromFloat(@round(255.0 * c0 / (c0 + c1)))), 1, 255);
            const old: u32 = probs[k];
            const cost_old = c0 * bitCost(old, false) + c1 * bitCost(old, true);
            const cost_new = c0 * bitCost(np, false) + c1 * bitCost(np, true);
            const up: u32 = tb.token_update_prob[k];
            const signal = 8.0 + bitCost(up, true) - bitCost(up, false);
            if (cost_new + signal < cost_old) {
                probs[k] = @intCast(np);
                update[k] = true;
            }
        }
    }
    const total_mb: u32 = @intCast(mbw * mbh);
    const use_skip = n_skip > 0;
    const skip_prob: u8 = @intCast(std.math.clamp(@divTrunc((total_mb - n_skip) * 255, total_mb), 1, 255));

    var fp: BoolEnc = .{};
    fp.put(128, false); // colour space
    fp.put(128, false); // clamping type
    fp.put(128, false); // no segmentation
    fp.put(128, false); // normal loop filter
    fp.bits(@intCast(std.math.clamp(@divTrunc(qi * 5, 8), 0, 63)), 6); // filter level
    fp.bits(0, 3); // sharpness
    fp.put(128, false); // no loop filter deltas
    fp.bits(0, 2); // one token partition
    fp.bits(@intCast(qi), 7);
    for (0..5) |_| fp.put(128, false); // no quantiser deltas
    fp.put(128, false); // refresh entropy probs
    for (0..1056) |k| {
        fp.put(tb.token_update_prob[k], update[k]);
        if (update[k]) fp.bits(probs[k], 8);
    }
    fp.put(128, use_skip);
    if (use_skip) fp.bits(skip_prob, 8);
    for (fpe.items) |e| {
        if (e.idx == 0) {
            if (use_skip) fp.put(skip_prob, e.bit);
        } else fp.put(e.fixed, e.bit);
    }
    fp.flush();
    var tp: BoolEnc = .{};
    for (tok.items) |e| tp.put(if (e.idx == fixed_ev) e.fixed else probs[e.idx], e.bit);
    tp.flush();

    var out: v.Buf = .{};
    const fsize: u32 = @intCast(fp.out.items.len);
    const tag: u32 = (fsize << 5) | (1 << 4); // key frame, version 0, show_frame
    out.add(&.{ @truncate(tag), @truncate(tag >> 8), @truncate(tag >> 16), 0x9d, 0x01, 0x2a, @truncate(w), @truncate(w >> 8), @truncate(h), @truncate(h >> 8) });
    out.add(fp.out.items);
    out.add(tp.out.items);
    return out.str();
}

// ================================================================ VP8L (lossless)

const LBits = struct {
    out: std.ArrayList(u8) = .empty,
    acc: u64 = 0,
    n: u6 = 0,
    fn put(w: *LBits, val: u32, nbits: u6) void {
        if (nbits == 0) return;
        w.acc |= @as(u64, val) << w.n;
        w.n += nbits;
        while (w.n >= 8) {
            w.out.append(sys.A, @truncate(w.acc)) catch {};
            w.acc >>= 8;
            w.n -= 8;
        }
    }
    fn finish(w: *LBits) []const u8 {
        if (w.n > 0) w.out.append(sys.A, @truncate(w.acc)) catch {};
        return w.out.items;
    }
};

const code_length_order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

const LCode = struct { lens: []u8, codes: []u16 };

fn reverseBits(c_in: u16, n: u8) u16 {
    var c = c_in;
    var r: u16 = 0;
    var k: u8 = 0;
    while (k < n) : (k += 1) {
        r = (r << 1) | (c & 1);
        c >>= 1;
    }
    return r;
}

/// Build and write one prefix code for the given symbol frequencies.
fn writeCode(w: *LBits, freq: []u32) LCode {
    const n = freq.len;
    const lens = sys.A.alloc(u8, n) catch unreachable;
    const codes = sys.A.alloc(u16, n) catch unreachable;
    @memset(codes, 0);
    var used: usize = 0;
    var syms: [2]usize = .{ 0, 0 };
    for (freq, 0..) |f, i| if (f > 0) {
        if (used < 2) syms[used] = i;
        used += 1;
    };
    if (used <= 2 and syms[0] < 256 and syms[1] < 256) {
        // "simple" code: one or two symbols
        @memset(lens, 0);
        w.put(1, 1);
        w.put(if (used == 2) 1 else 0, 1);
        if (syms[0] < 2) {
            w.put(0, 1);
            w.put(@intCast(syms[0]), 1);
        } else {
            w.put(1, 1);
            w.put(@intCast(syms[0]), 8);
        }
        if (used == 2) {
            w.put(@intCast(syms[1]), 8);
            lens[syms[0]] = 1;
            lens[syms[1]] = 1;
            codes[syms[0]] = 0;
            codes[syms[1]] = 1;
        }
        return .{ .lens = lens, .codes = codes };
    }
    if (used < 2) {
        // a normal code needs at least two symbols
        freq[if (syms[0] == 0) 1 else 0] = 1;
    }
    image.huffLengths(freq, lens, 15);
    // canonical codes, bit-reversed for the LSB-first stream
    var bl_count = @as([16]u16, @splat(0));
    for (lens) |l| bl_count[l] += 1;
    bl_count[0] = 0;
    var next = @as([16]u16, @splat(0));
    var code: u16 = 0;
    for (1..16) |b| {
        code = (code + bl_count[b - 1]) << 1;
        next[b] = code;
    }
    for (lens, 0..) |l, i| if (l != 0) {
        codes[i] = reverseBits(next[l], l);
        next[l] += 1;
    };
    // run-length encode the code lengths (17/18 = runs of zeros)
    const Sym = struct { s: u8, extra: u8, nbits: u6 };
    var seq: std.ArrayList(Sym) = .empty;
    var i: usize = 0;
    while (i < n) {
        if (lens[i] == 0) {
            var run: usize = 1;
            while (i + run < n and lens[i + run] == 0) run += 1;
            var left = run;
            while (left > 0) {
                if (left >= 11) {
                    const r = @min(left, 138);
                    seq.append(sys.A, .{ .s = 18, .extra = @intCast(r - 11), .nbits = 7 }) catch {};
                    left -= r;
                } else if (left >= 3) {
                    seq.append(sys.A, .{ .s = 17, .extra = @intCast(left - 3), .nbits = 3 }) catch {};
                    left = 0;
                } else {
                    seq.append(sys.A, .{ .s = 0, .extra = 0, .nbits = 0 }) catch {};
                    left -= 1;
                }
            }
            i += run;
        } else {
            seq.append(sys.A, .{ .s = lens[i], .extra = 0, .nbits = 0 }) catch {};
            i += 1;
        }
    }
    var clfreq = @as([19]u32, @splat(0));
    for (seq.items) |s| clfreq[s.s] += 1;
    var cl_used: usize = 0;
    for (clfreq) |f| if (f > 0) {
        cl_used += 1;
    };
    if (cl_used < 2) clfreq[if (clfreq[0] > 0) 1 else 0] += 1;
    var cllens: [19]u8 = undefined;
    image.huffLengths(&clfreq, &cllens, 7);
    var clcodes = @as([19]u16, @splat(0));
    {
        var blc = @as([8]u16, @splat(0));
        for (cllens) |l| blc[l] += 1;
        blc[0] = 0;
        var nx = @as([8]u16, @splat(0));
        var c: u16 = 0;
        for (1..8) |b| {
            c = (c + blc[b - 1]) << 1;
            nx[b] = c;
        }
        for (cllens, 0..) |l, k| if (l != 0) {
            clcodes[k] = reverseBits(nx[l], l);
            nx[l] += 1;
        };
    }
    w.put(0, 1); // normal code
    w.put(19 - 4, 4);
    for (code_length_order) |o| w.put(cllens[o], 3);
    w.put(0, 1); // max_symbol = alphabet size
    for (seq.items) |s| {
        w.put(clcodes[s.s], @intCast(cllens[s.s]));
        w.put(s.extra, s.nbits);
    }
    return .{ .lens = lens, .codes = codes };
}

const Prefix = struct { sym: u32, extra: u32, nbits: u6 };
fn prefixEncode(val: u32) Prefix {
    if (val <= 4) return .{ .sym = val - 1, .extra = 0, .nbits = 0 };
    const d = val - 1;
    const hb: u5 = @intCast(31 - @clz(d));
    const second = (d >> (hb - 1)) & 1;
    return .{ .sym = 2 * @as(u32, hb) + second, .extra = d & ((@as(u32, 1) << (hb - 1)) - 1), .nbits = hb - 1 };
}

fn avg2(a: u32, b: u32) u32 {
    return (((a ^ b) & 0xfefefefe) >> 1) + (a & b);
}
fn chan(x: u32, shift: u5) i32 {
    return @intCast((x >> shift) & 0xff);
}
fn clampAddSub(a: u32, b: u32, c: u32, half: bool) u32 {
    var out: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |sh| {
        const va = chan(a, sh);
        const vb = chan(b, sh);
        const vc = chan(c, sh);
        const r = if (half) va + @divTrunc(va - vc, 2) else va + vb - vc;
        out |= @as(u32, @intCast(std.math.clamp(r, 0, 255))) << sh;
    }
    return out;
}
fn selectPred(l: u32, t: u32, tl: u32) u32 {
    var pl: i32 = 0;
    var pt: i32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |sh| {
        // distance of the gradient estimate (L + T - TL) to L and to T
        pl += @intCast(@abs(chan(t, sh) - chan(tl, sh)));
        pt += @intCast(@abs(chan(l, sh) - chan(tl, sh)));
    }
    return if (pl < pt) l else t;
}

fn predictPixel(px: []const u32, w: usize, i: usize, mode: u32) u32 {
    const x = i % w;
    if (i == 0) return 0xff000000;
    if (i < w) return px[i - 1];
    if (x == 0) return px[i - w];
    const l = px[i - 1];
    const t = px[i - w];
    const tl = px[i - w - 1];
    const tr = px[i - w + 1];
    return switch (mode) {
        0 => 0xff000000,
        1 => l,
        2 => t,
        3 => tr,
        4 => tl,
        5 => avg2(avg2(l, tr), t),
        6 => avg2(l, tl),
        7 => avg2(l, t),
        8 => avg2(tl, t),
        9 => avg2(t, tr),
        10 => avg2(avg2(l, tl), avg2(t, tr)),
        11 => selectPred(l, t, tl),
        12 => clampAddSub(l, t, tl, false),
        else => clampAddSub(avg2(l, t), tl, tl, true),
    };
}

fn subPixels(a: u32, b: u32) u32 {
    const ag = ((a | 0x00ff00ff) -% (b & 0xff00ff00)) & 0xff00ff00;
    const rb = ((a | 0xff00ff00) -% (b & 0x00ff00ff)) & 0x00ff00ff;
    return ag | rb;
}

fn residualCost(d: u32) u32 {
    var c: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |sh| {
        const val: u32 = (d >> sh) & 0xff;
        c += if (val < 128) val else 256 - val;
    }
    return c;
}

/// Encode ARGB pixels as a VP8L image stream (without the 5-byte signature header).
fn encodeVp8lStream(argb_in: []u32, w: usize, colour_transforms: bool) []const u8 {
    var bw: LBits = .{};
    var argb = argb_in;
    if (colour_transforms) {
        // subtract green
        bw.put(1, 1);
        bw.put(2, 2);
        for (argb) |*p| {
            const g = (p.* >> 8) & 0xff;
            const r = ((p.* >> 16) -% g) & 0xff;
            const b = (p.* -% g) & 0xff;
            p.* = (p.* & 0xff00ff00) | (r << 16) | b;
        }
    }
    {
        // spatial predictor, best mode per 16x16 block
        const bits: u5 = 4;
        const bsz: usize = @as(usize, 1) << bits;
        const h = argb.len / w;
        const bwid = (w + bsz - 1) / bsz;
        const bhei = (h + bsz - 1) / bsz;
        const mode_img = sys.A.alloc(u32, bwid * bhei) catch return "";
        const res = sys.A.alloc(u32, argb.len) catch return "";
        const candidates = [_]u32{ 1, 2, 5, 7, 11, 12, 13, 4, 10 };
        for (0..bhei) |by| for (0..bwid) |bx| {
            var best_mode: u32 = 1;
            var best_cost: u64 = std.math.maxInt(u64);
            for (candidates) |m| {
                var cost: u64 = 0;
                var yy = by * bsz;
                while (yy < @min(h, (by + 1) * bsz)) : (yy += 1) {
                    var xx = bx * bsz;
                    while (xx < @min(w, (bx + 1) * bsz)) : (xx += 1) {
                        const i = yy * w + xx;
                        cost += residualCost(subPixels(argb[i], predictPixel(argb, w, i, m)));
                    }
                }
                if (cost < best_cost) {
                    best_cost = cost;
                    best_mode = m;
                }
            }
            mode_img[by * bwid + bx] = 0xff000000 | (best_mode << 8);
            var yy = by * bsz;
            while (yy < @min(h, (by + 1) * bsz)) : (yy += 1) {
                var xx = bx * bsz;
                while (xx < @min(w, (bx + 1) * bsz)) : (xx += 1) {
                    const i = yy * w + xx;
                    res[i] = subPixels(argb[i], predictPixel(argb, w, i, best_mode));
                }
            }
        };
        bw.put(1, 1);
        bw.put(0, 2); // predictor transform
        bw.put(bits - 2, 3);
        writeImageData(&bw, mode_img, bwid, false);
        argb = res;
    }
    bw.put(0, 1); // no more transforms
    writeImageData(&bw, argb, w, true);
    return bw.finish();
}

fn writeImageData(bw: *LBits, argb: []const u32, w: usize, top_level: bool) void {
    bw.put(0, 1); // no colour cache
    if (top_level) bw.put(0, 1); // no meta prefix codes
    // LZ77 over pixels
    const Tok = struct { len: u32, dist: u32, px: u32 };
    var toks: std.ArrayList(Tok) = .empty;
    const hash_bits = 15;
    const head = sys.A.alloc(i32, 1 << hash_bits) catch return;
    @memset(head, -1);
    const prev = sys.A.alloc(i32, argb.len) catch return;
    var i: usize = 0;
    while (i < argb.len) {
        var best_len: usize = 0;
        var best_dist: usize = 0;
        if (i + 2 <= argb.len) {
            const hv: usize = @intCast(((argb[i] *% 0x9E3779B1) ^ (argb[i + 1] *% 0x85EBCA6B)) >> (32 - hash_bits));
            var cand = head[hv];
            var chain: usize = 0;
            const max_len = @min(4096, argb.len - i);
            while (cand >= 0 and chain < 32) : (chain += 1) {
                const c: usize = @intCast(cand);
                if (i - c > (1 << 20) - 121) break;
                var l: usize = 0;
                while (l < max_len and argb[c + l] == argb[i + l]) l += 1;
                if (l > best_len) {
                    best_len = l;
                    best_dist = i - c;
                    if (l == max_len) break;
                }
                cand = prev[c];
            }
            prev[i] = head[hv];
            head[hv] = @intCast(i);
        }
        if (best_len >= 3) {
            toks.append(sys.A, .{ .len = @intCast(best_len), .dist = @intCast(best_dist), .px = 0 }) catch {};
            var k: usize = 1;
            while (k < best_len) : (k += 1) {
                const p = i + k;
                if (p + 2 <= argb.len) {
                    const hv: usize = @intCast(((argb[p] *% 0x9E3779B1) ^ (argb[p + 1] *% 0x85EBCA6B)) >> (32 - hash_bits));
                    prev[p] = head[hv];
                    head[hv] = @intCast(p);
                }
            }
            i += best_len;
        } else {
            toks.append(sys.A, .{ .len = 0, .dist = 0, .px = argb[i] }) catch {};
            i += 1;
        }
    }
    const distCode = struct {
        fn f(d: u32, width: usize) u32 {
            if (d == 1) return 2;
            if (d == width) return 1;
            return d + 120;
        }
    }.f;
    var fg = @as([280]u32, @splat(0));
    var fr = @as([256]u32, @splat(0));
    var fb = @as([256]u32, @splat(0));
    var fa = @as([256]u32, @splat(0));
    var fd = @as([40]u32, @splat(0));
    for (toks.items) |t| {
        if (t.len == 0) {
            fg[(t.px >> 8) & 0xff] += 1;
            fr[(t.px >> 16) & 0xff] += 1;
            fb[t.px & 0xff] += 1;
            fa[t.px >> 24] += 1;
        } else {
            fg[256 + prefixEncode(t.len).sym] += 1;
            fd[prefixEncode(distCode(t.dist, w)).sym] += 1;
        }
    }
    const cg = writeCode(bw, &fg);
    const cr = writeCode(bw, &fr);
    const cb = writeCode(bw, &fb);
    const ca = writeCode(bw, &fa);
    const cd = writeCode(bw, &fd);
    for (toks.items) |t| {
        if (t.len == 0) {
            const g = (t.px >> 8) & 0xff;
            const r = (t.px >> 16) & 0xff;
            const b = t.px & 0xff;
            const a = t.px >> 24;
            bw.put(cg.codes[g], @intCast(cg.lens[g]));
            bw.put(cr.codes[r], @intCast(cr.lens[r]));
            bw.put(cb.codes[b], @intCast(cb.lens[b]));
            bw.put(ca.codes[a], @intCast(ca.lens[a]));
        } else {
            const lp = prefixEncode(t.len);
            bw.put(cg.codes[256 + lp.sym], @intCast(cg.lens[256 + lp.sym]));
            bw.put(lp.extra, lp.nbits);
            const dp = prefixEncode(distCode(t.dist, w));
            bw.put(cd.codes[dp.sym], @intCast(cd.lens[dp.sym]));
            bw.put(dp.extra, dp.nbits);
        }
    }
}

fn chunk(out: *v.Buf, fourcc: []const u8, body: []const u8) void {
    out.add(fourcc);
    const n: u32 = @intCast(body.len);
    out.add(&.{ @truncate(n), @truncate(n >> 8), @truncate(n >> 16), @truncate(n >> 24) });
    out.add(body);
    if (body.len % 2 == 1) out.ch(0);
}

fn riff(body: []const u8) []const u8 {
    var out: v.Buf = .{};
    out.add("RIFF");
    const n: u32 = @intCast(body.len + 4);
    out.add(&.{ @truncate(n), @truncate(n >> 8), @truncate(n >> 16), @truncate(n >> 24) });
    out.add("WEBP");
    out.add(body);
    return out.str();
}

/// Encode as WebP. `lossless` selects VP8L; otherwise lossy VP8 (+ lossless alpha when needed).
pub fn encode(img: *const Image, quality: i64, lossless: bool) []const u8 {
    const w: usize = img.w;
    const h: usize = img.h;
    const has_alpha = !img.opaque_();
    var body: v.Buf = .{};
    if (lossless) {
        const argb = sys.A.alloc(u32, w * h) catch return "";
        for (argb, 0..) |*p, i| {
            const s = img.px[i * 4 ..][0..4];
            p.* = (@as(u32, s[3]) << 24) | (@as(u32, s[0]) << 16) | (@as(u32, s[1]) << 8) | s[2];
        }
        const stream = encodeVp8lStream(argb, w, true);
        var l: v.Buf = .{};
        const hdr: u32 = @as(u32, @intCast(w - 1)) | (@as(u32, @intCast(h - 1)) << 14) | (@as(u32, @intFromBool(has_alpha)) << 28);
        l.add(&.{ 0x2f, @truncate(hdr), @truncate(hdr >> 8), @truncate(hdr >> 16), @truncate(hdr >> 24) });
        l.add(stream);
        chunk(&body, "VP8L", l.str());
        return riff(body.str());
    }
    const vp8 = encodeVp8(img, quality);
    if (!has_alpha) {
        chunk(&body, "VP8 ", vp8);
        return riff(body.str());
    }
    // extended format: VP8X + ALPH (alpha in the green channel of a VP8L stream) + VP8
    var x: [10]u8 = undefined;
    x[0] = 0x10; // alpha flag
    x[1] = 0;
    x[2] = 0;
    x[3] = 0;
    const cw: u32 = @intCast(w - 1);
    const chh: u32 = @intCast(h - 1);
    x[4] = @truncate(cw);
    x[5] = @truncate(cw >> 8);
    x[6] = @truncate(cw >> 16);
    x[7] = @truncate(chh);
    x[8] = @truncate(chh >> 8);
    x[9] = @truncate(chh >> 16);
    chunk(&body, "VP8X", &x);
    const argb = sys.A.alloc(u32, w * h) catch return "";
    for (argb, 0..) |*p, i| p.* = 0xff000000 | (@as(u32, img.px[i * 4 + 3]) << 8);
    var al: v.Buf = .{};
    al.ch(1); // no pre-processing, no filter, lossless compression
    al.add(encodeVp8lStream(argb, w, false));
    chunk(&body, "ALPH", al.str());
    chunk(&body, "VP8 ", vp8);
    return riff(body.str());
}
