// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Go golang.org/x/image/webp (BSD-3-Clause, Copyright The Go Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! WebP decoder written from scratch: lossy VP8 key frames (with the loop
//! filter), lossless VP8L (all four transforms, colour cache, meta Huffman
//! codes) and the VP8X container with an ALPH plane. Output follows Go's
//! x/image/webp (which Hugo uses): 4:2:0 chroma is sampled nearest-neighbour
//! and converted with Go's YCbCr->RGB constants.
const std = @import("std");
const sys = @import("sys.zig");
const image = @import("image.zig");
const tb = @import("vp8_tables.zig");
const Image = image.Image;

fn fail(msg: []const u8) error{ImageError} {
    image.err_msg = msg;
    return error.ImageError;
}

fn le32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

pub fn decode(b: []const u8) anyerror!Image {
    if (b.len < 20) return fail("webp: truncated file");
    var pos: usize = 12;
    var alpha: ?[]u8 = null;
    var canvas_w: u32 = 0;
    var canvas_h: u32 = 0;
    while (pos + 8 <= b.len) {
        const fourcc = b[pos .. pos + 4];
        const size = le32(b[pos + 4 ..]);
        const start = pos + 8;
        const end = @min(b.len, start + size);
        const body = b[start..end];
        pos = start + size + (size & 1);
        if (std.mem.eql(u8, fourcc, "VP8X")) {
            if (body.len < 10) return fail("webp: bad VP8X chunk");
            if (body[0] & 0x02 != 0) return fail("webp: animated WebP images are not supported");
            canvas_w = 1 + (@as(u32, body[4]) | @as(u32, body[5]) << 8 | @as(u32, body[6]) << 16);
            canvas_h = 1 + (@as(u32, body[7]) | @as(u32, body[8]) << 8 | @as(u32, body[9]) << 16);
        } else if (std.mem.eql(u8, fourcc, "ALPH")) {
            if (canvas_w == 0) return fail("webp: ALPH chunk without VP8X");
            alpha = try decodeAlpha(body, canvas_w, canvas_h);
        } else if (std.mem.eql(u8, fourcc, "VP8 ")) {
            var img = try decodeVp8(body);
            if (alpha) |a| {
                if (a.len == @as(usize, img.w) * img.h) {
                    for (a, 0..) |av, i| img.px[i * 4 + 3] = av;
                }
            }
            return img;
        } else if (std.mem.eql(u8, fourcc, "VP8L")) {
            return decodeVp8l(body);
        }
    }
    return fail("webp: no image data");
}

// ================================================================ VP8 (lossy)

const BoolDec = struct {
    buf: []const u8,
    r: usize = 0,
    range_m1: u32 = 254,
    bits: u32 = 0,
    nbits: u8 = 0,
    eof: bool = false,

    fn init(buf: []const u8) BoolDec {
        return .{ .buf = buf };
    }
    fn bit(p: *BoolDec, prob: u8) bool {
        if (p.nbits < 8) {
            if (p.r >= p.buf.len) {
                p.eof = true;
                return false;
            }
            p.bits |= @as(u32, p.buf[p.r]) << @intCast(8 - p.nbits);
            p.r += 1;
            p.nbits += 8;
        }
        const split = ((p.range_m1 * prob) >> 8) + 1;
        const b = p.bits >= split << 8;
        if (b) {
            p.range_m1 -= split;
            p.bits -= split << 8;
        } else p.range_m1 = split - 1;
        if (p.range_m1 < 127) {
            const shift: u5 = @intCast(@clz(@as(u8, @intCast(p.range_m1 + 1))));
            // normalise so that range_m1 >= 127
            p.range_m1 = ((p.range_m1 + 1) << shift) - 1;
            p.bits <<= shift;
            p.nbits -= shift;
        }
        return b;
    }
    fn uint(p: *BoolDec, prob: u8, n: u5) u32 {
        var u: u32 = 0;
        var k = n;
        while (k > 0) {
            k -= 1;
            if (p.bit(prob)) u |= @as(u32, 1) << k;
        }
        return u;
    }
    fn sint(p: *BoolDec, prob: u8, n: u5) i32 {
        const u: i32 = @intCast(p.uint(prob, n));
        return if (p.bit(prob)) -u else u;
    }
    fn optInt(p: *BoolDec, prob: u8, n: u5) i32 {
        if (!p.bit(prob)) return 0;
        return p.sint(prob, n);
    }
};

const P_DC = 0;
const P_TM = 1;
const P_VE = 2;
const P_HE = 3;
const P_RD = 4;
const P_VR = 5;
const P_LD = 6;
const P_VL = 7;
const P_HD = 8;
const P_HU = 9;
const P_DCTOP = 10;
const P_DCLEFT = 11;
const P_DCTL = 12;

const FilterParam = struct { level: u8 = 0, ilevel: u8 = 0, hlevel: u8 = 0, inner: bool = false };
const MB = struct { pred: [4]u8 = .{ 0, 0, 0, 0 }, nz_mask: u8 = 0, nz_y16: u8 = 0 };
const Quant = struct { y1: [2]i32, y2: [2]i32, uv: [2]i32 };

const bands = [17]u8{ 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 };
const zigzag = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
const cat3456 = [4][]const u8{ &.{ 173, 148, 140 }, &.{ 176, 155, 140, 135 }, &.{ 180, 157, 141, 134, 130 }, &.{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 } };

const PLANE_Y1_WITH_Y2 = 0;
const PLANE_Y2 = 1;
const PLANE_UV = 2;
const PLANE_Y1_SANS_Y2 = 3;

// ybr working area layout (same as Go's decoder)
const YX = 8;
const YY = 1;
const BX = 8;
const BY = 18;
const RX = 24;
const RY = 18;

const Vp8 = struct {
    w: usize,
    h: usize,
    mbw: usize,
    mbh: usize,
    ys: []u8,
    cb: []u8,
    cr: []u8,
    ystride: usize,
    cstride: usize,
    fp: BoolDec,
    op: [8]BoolDec = undefined,
    nop: usize = 1,
    use_segment: bool = false,
    update_map: bool = false,
    relative_delta: bool = false,
    seg_quant: [4]i8 = .{ 0, 0, 0, 0 },
    seg_filter: [4]i8 = .{ 0, 0, 0, 0 },
    seg_prob: [3]u8 = .{ 255, 255, 255 },
    f_simple: bool = false,
    f_level: i8 = 0,
    f_sharp: u8 = 0,
    use_lf_delta: bool = false,
    ref_lf_delta: [4]i8 = .{ 0, 0, 0, 0 },
    mode_lf_delta: [4]i8 = .{ 0, 0, 0, 0 },
    quant: [4]Quant = undefined,
    tok: [1056]u8 = undefined,
    use_skip: bool = false,
    skip_prob: u8 = 0,
    fparams: [4][2]FilterParam = @splat(.{ .{}, .{} }),
    mbf: []FilterParam,
    segment: usize = 0,
    left: MB = .{},
    up: []MB,
    nz_dc: u32 = 0,
    nz_ac: u32 = 0,
    y16: bool = false,
    pred_y16: u8 = 0,
    pred_c8: u8 = 0,
    pred_y4: [4][4]u8 = undefined,
    coeff: [16 * 16 + 2 * 8 * 8 + 16]i16 = undefined,
    ybr: [26][32]u8 = undefined,

    fn parseSegment(d: *Vp8) void {
        d.use_segment = d.fp.bit(128);
        if (!d.use_segment) {
            d.update_map = false;
            return;
        }
        d.update_map = d.fp.bit(128);
        if (d.fp.bit(128)) {
            d.relative_delta = !d.fp.bit(128);
            for (&d.seg_quant) |*q| q.* = @intCast(d.fp.optInt(128, 7));
            for (&d.seg_filter) |*q| q.* = @intCast(d.fp.optInt(128, 6));
        }
        if (!d.update_map) return;
        for (&d.seg_prob) |*p| p.* = if (d.fp.bit(128)) @intCast(d.fp.uint(128, 8)) else 255;
    }

    fn parseFilter(d: *Vp8) void {
        d.f_simple = d.fp.bit(128);
        d.f_level = @intCast(d.fp.uint(128, 6));
        d.f_sharp = @intCast(d.fp.uint(128, 3));
        d.use_lf_delta = d.fp.bit(128);
        if (d.use_lf_delta and d.fp.bit(128)) {
            for (&d.ref_lf_delta) |*x| x.* = @intCast(d.fp.optInt(128, 6));
            for (&d.mode_lf_delta) |*x| x.* = @intCast(d.fp.optInt(128, 6));
        }
        if (d.f_level == 0) return;
        for (0..4) |i| {
            var base: i32 = d.f_level;
            if (d.use_segment) {
                base = d.seg_filter[i];
                if (d.relative_delta) base += d.f_level;
            }
            for (0..2) |j| {
                const p = &d.fparams[i][j];
                p.inner = j != 0;
                var level = base;
                if (d.use_lf_delta) {
                    level += d.ref_lf_delta[0];
                    if (j != 0) level += d.mode_lf_delta[0];
                }
                if (level <= 0) {
                    p.level = 0;
                    continue;
                }
                if (level > 63) level = 63;
                var il = level;
                if (d.f_sharp > 0) {
                    il = if (d.f_sharp > 4) il >> 2 else il >> 1;
                    const x: i32 = 9 - @as(i32, d.f_sharp);
                    if (il > x) il = x;
                }
                if (il < 1) il = 1;
                p.ilevel = @intCast(il);
                p.level = @intCast(2 * level + il);
                p.hlevel = if (level < 15) 0 else if (level < 40) 1 else 2;
            }
        }
    }

    fn parseQuant(d: *Vp8) void {
        const base: i32 = @intCast(d.fp.uint(128, 7));
        const y1dc = d.fp.optInt(128, 4);
        const y2dc = d.fp.optInt(128, 4);
        const y2ac = d.fp.optInt(128, 4);
        const uvdc = d.fp.optInt(128, 4);
        const uvac = d.fp.optInt(128, 4);
        for (0..4) |i| {
            var q = base;
            if (d.use_segment) {
                q = if (d.relative_delta) q + d.seg_quant[i] else d.seg_quant[i];
            }
            const Q = &d.quant[i];
            Q.y1[0] = tb.dc_q[cl(q + y1dc, 127)];
            Q.y1[1] = tb.ac_q[cl(q, 127)];
            Q.y2[0] = @as(i32, tb.dc_q[cl(q + y2dc, 127)]) * 2;
            Q.y2[1] = @divTrunc(@as(i32, tb.ac_q[cl(q + y2ac, 127)]) * 155, 100);
            if (Q.y2[1] < 8) Q.y2[1] = 8;
            Q.uv[0] = tb.dc_q[cl(q + uvdc, 117)];
            Q.uv[1] = tb.ac_q[cl(q + uvac, 127)];
        }
    }

    fn residuals4(d: *Vp8, r: *BoolDec, plane: usize, ctx: u8, q: [2]i32, skip_first: bool, base: usize) u8 {
        var n: usize = if (skip_first) 1 else 0;
        var p: usize = tokOff(plane, bands[n], ctx);
        if (!r.bit(d.tok[p])) return 0;
        while (n != 16) {
            n += 1;
            if (!r.bit(d.tok[p + 1])) {
                p = tokOff(plane, bands[n], 0);
                continue;
            }
            var val: u32 = 0;
            if (!r.bit(d.tok[p + 2])) {
                val = 1;
                p = tokOff(plane, bands[n], 1);
            } else {
                if (!r.bit(d.tok[p + 3])) {
                    if (!r.bit(d.tok[p + 4])) val = 2 else val = 3 + r.uint(d.tok[p + 5], 1);
                } else if (!r.bit(d.tok[p + 6])) {
                    if (!r.bit(d.tok[p + 7])) {
                        val = 5 + r.uint(159, 1);
                    } else {
                        val = 7 + 2 * r.uint(165, 1) + r.uint(145, 1);
                    }
                } else {
                    const b1 = r.uint(d.tok[p + 8], 1);
                    const b0 = r.uint(d.tok[p + 9 + b1], 1);
                    const cat = 2 * b1 + b0;
                    val = 0;
                    for (cat3456[cat]) |pr| val = val * 2 + r.uint(pr, 1);
                    val += 3 + (@as(u32, 8) << @intCast(cat));
                }
                p = tokOff(plane, bands[n], 2);
            }
            const z = zigzag[n - 1];
            var c: i32 = @as(i32, @intCast(val)) * q[if (z > 0) 1 else 0];
            if (r.bit(128)) c = -c;
            d.coeff[base + z] = @truncate(c);
            if (n == 16 or !r.bit(d.tok[p])) return 1;
        }
        return 1;
    }

    fn residuals(d: *Vp8, mbx: usize, mby: usize) bool {
        const part = &d.op[mby & (d.nop - 1)];
        var plane: usize = PLANE_Y1_SANS_Y2;
        const q = d.quant[d.segment];
        if (d.y16) {
            const nz = d.residuals4(part, PLANE_Y2, d.left.nz_y16 + d.up[mbx].nz_y16, q.y2, false, 384);
            d.left.nz_y16 = nz;
            d.up[mbx].nz_y16 = nz;
            d.inverseWht();
            plane = PLANE_Y1_WITH_Y2;
        }
        var nz_dc: [4]u8 = undefined;
        var nz_ac: [4]u8 = undefined;
        var dcm: u32 = 0;
        var acm: u32 = 0;
        var base: usize = 0;
        var lnz = unpack(d.left.nz_mask & 0x0f);
        var unz = unpack(d.up[mbx].nz_mask & 0x0f);
        for (0..4) |y| {
            var nz = lnz[y];
            for (0..4) |x| {
                nz = d.residuals4(part, plane, nz + unz[x], q.y1, d.y16, base);
                unz[x] = nz;
                nz_ac[x] = nz;
                nz_dc[x] = @intFromBool(d.coeff[base] != 0);
                base += 16;
            }
            lnz[y] = nz;
            dcm |= pack(nz_dc, y * 4);
            acm |= pack(nz_ac, y * 4);
        }
        var lmask = pack(lnz, 0);
        var umask = pack(unz, 0);
        lnz = unpack(d.left.nz_mask >> 4);
        unz = unpack(d.up[mbx].nz_mask >> 4);
        var c: usize = 0;
        while (c < 4) : (c += 2) {
            for (0..2) |y| {
                var nz = lnz[y + c];
                for (0..2) |x| {
                    nz = d.residuals4(part, PLANE_UV, nz + unz[x + c], q.uv, false, base);
                    unz[x + c] = nz;
                    nz_ac[y * 2 + x] = nz;
                    nz_dc[y * 2 + x] = @intFromBool(d.coeff[base] != 0);
                    base += 16;
                }
                lnz[y + c] = nz;
            }
            dcm |= pack(nz_dc, 16 + c * 2);
            acm |= pack(nz_ac, 16 + c * 2);
        }
        lmask |= pack(lnz, 4);
        umask |= pack(unz, 4);
        d.left.nz_mask = @truncate(lmask);
        d.up[mbx].nz_mask = @truncate(umask);
        d.nz_dc = dcm;
        d.nz_ac = acm;
        return dcm == 0 and acm == 0;
    }

    fn inverseWht(d: *Vp8) void {
        var m: [16]i32 = undefined;
        for (0..4) |i| {
            const a0 = @as(i32, d.coeff[384 + i]) + d.coeff[384 + 12 + i];
            const a1 = @as(i32, d.coeff[384 + 4 + i]) + d.coeff[384 + 8 + i];
            const a2 = @as(i32, d.coeff[384 + 4 + i]) - d.coeff[384 + 8 + i];
            const a3 = @as(i32, d.coeff[384 + i]) - d.coeff[384 + 12 + i];
            m[i] = a0 + a1;
            m[8 + i] = a0 - a1;
            m[4 + i] = a3 + a2;
            m[12 + i] = a3 - a2;
        }
        var out: usize = 0;
        for (0..4) |i| {
            const dc = m[i * 4] + 3;
            const a0 = dc + m[3 + i * 4];
            const a1 = m[1 + i * 4] + m[2 + i * 4];
            const a2 = m[1 + i * 4] - m[2 + i * 4];
            const a3 = dc - m[3 + i * 4];
            d.coeff[out + 0] = @truncate((a0 + a1) >> 3);
            d.coeff[out + 16] = @truncate((a3 + a2) >> 3);
            d.coeff[out + 32] = @truncate((a0 - a1) >> 3);
            d.coeff[out + 48] = @truncate((a3 - a2) >> 3);
            out += 64;
        }
    }

    fn idct4(d: *Vp8, y: usize, x: usize, base: usize) void {
        const c1: i32 = 85627;
        const c2: i32 = 35468;
        var m: [4][4]i32 = undefined;
        const co = d.coeff[base..];
        for (0..4) |i| {
            const a = @as(i32, co[i]) + co[8 + i];
            const b = @as(i32, co[i]) - co[8 + i];
            const c = ((@as(i32, co[4 + i]) * c2) >> 16) - ((@as(i32, co[12 + i]) * c1) >> 16);
            const dd = ((@as(i32, co[4 + i]) * c1) >> 16) + ((@as(i32, co[12 + i]) * c2) >> 16);
            m[i] = .{ a + dd, b + c, b - c, a - dd };
        }
        for (0..4) |j| {
            const dc = m[0][j] + 4;
            const a = dc + m[2][j];
            const b = dc - m[2][j];
            const c = ((m[1][j] * c2) >> 16) - ((m[3][j] * c1) >> 16);
            const dd = ((m[1][j] * c1) >> 16) + ((m[3][j] * c2) >> 16);
            const row = &d.ybr[y + j];
            row[x + 0] = clip8(@as(i32, row[x + 0]) + ((a + dd) >> 3));
            row[x + 1] = clip8(@as(i32, row[x + 1]) + ((b + c) >> 3));
            row[x + 2] = clip8(@as(i32, row[x + 2]) + ((b - c) >> 3));
            row[x + 3] = clip8(@as(i32, row[x + 3]) + ((a - dd) >> 3));
        }
    }
    fn idctDc(d: *Vp8, y: usize, x: usize, base: usize) void {
        const dc = (@as(i32, d.coeff[base]) + 4) >> 3;
        for (0..4) |j| for (0..4) |i| {
            d.ybr[y + j][x + i] = clip8(@as(i32, d.ybr[y + j][x + i]) + dc);
        };
    }
    fn idctBlock(d: *Vp8, y: usize, x: usize, base: usize, n: u5) void {
        const mask = @as(u32, 1) << n;
        if (d.nz_ac & mask != 0) d.idct4(y, x, base) else if (d.nz_dc & mask != 0) d.idctDc(y, x, base);
    }

    fn prepareYbr(d: *Vp8, mbx: usize, mby: usize) void {
        if (mbx == 0) {
            for (0..17) |y| d.ybr[y][7] = 0x81;
            for (17..26) |y| {
                d.ybr[y][7] = 0x81;
                d.ybr[y][23] = 0x81;
            }
        } else {
            for (0..17) |y| d.ybr[y][7] = d.ybr[y][7 + 16];
            for (17..26) |y| {
                d.ybr[y][7] = d.ybr[y][15];
                d.ybr[y][23] = d.ybr[y][31];
            }
        }
        if (mby == 0) {
            for (7..28) |x| d.ybr[0][x] = 0x7f;
            for (7..16) |x| d.ybr[17][x] = 0x7f;
            for (23..32) |x| d.ybr[17][x] = 0x7f;
        } else {
            const yrow = (16 * mby - 1) * d.ystride + 16 * mbx;
            const crow = (8 * mby - 1) * d.cstride + 8 * mbx;
            for (0..16) |i| d.ybr[0][8 + i] = d.ys[yrow + i];
            for (0..8) |i| d.ybr[17][8 + i] = d.cb[crow + i];
            for (0..8) |i| d.ybr[17][24 + i] = d.cr[crow + i];
            for (16..20) |i| d.ybr[0][8 + i] = if (mbx == d.mbw - 1) d.ys[yrow + 15] else d.ys[yrow + i];
        }
        var y: usize = 4;
        while (y < 16) : (y += 4) {
            for (24..28) |x| d.ybr[y][x] = d.ybr[0][x];
        }
    }

    fn predN(d: *Vp8, y: usize, x: usize, n: usize, mode: u8) void {
        switch (mode) {
            P_DC, P_DCTOP, P_DCLEFT, P_DCTL => {
                var sum: u32 = 0;
                var cnt: u32 = 0;
                if (mode == P_DC or mode == P_DCLEFT) {
                    for (0..n) |i| sum += d.ybr[y - 1][x + i];
                    cnt += @intCast(n);
                }
                if (mode == P_DC or mode == P_DCTOP) {
                    for (0..n) |j| sum += d.ybr[y + j][x - 1];
                    cnt += @intCast(n);
                }
                const avg: u8 = if (cnt == 0) 0x80 else @intCast((sum + cnt / 2) / cnt);
                for (0..n) |j| @memset(d.ybr[y + j][x .. x + n], avg);
            },
            P_TM => {
                const d0 = -@as(i32, d.ybr[y - 1][x - 1]);
                for (0..n) |j| {
                    const d1 = d0 + d.ybr[y + j][x - 1];
                    for (0..n) |i| d.ybr[y + j][x + i] = clip8(d1 + d.ybr[y - 1][x + i]);
                }
            },
            P_VE => for (0..n) |j| for (0..n) |i| {
                d.ybr[y + j][x + i] = d.ybr[y - 1][x + i];
            },
            P_HE => for (0..n) |j| @memset(d.ybr[y + j][x .. x + n], d.ybr[y + j][x - 1]),
            else => {},
        }
    }

    fn pred4(d: *Vp8, y: usize, x: usize, mode: u8) void {
        const z = &d.ybr;
        // edge: L[3..0] = left column bottom-up, A = top-left, T[0..7] = top row
        const s: i32 = z[y + 3][x - 1];
        const r: i32 = z[y + 2][x - 1];
        const q: i32 = z[y + 1][x - 1];
        const p: i32 = z[y + 0][x - 1];
        const a: i32 = z[y - 1][x - 1];
        var t: [8]i32 = undefined;
        for (0..8) |i| t[i] = z[y - 1][x + i];
        const av3 = struct {
            fn f(u: i32, w: i32, e: i32) u8 {
                return @intCast(@divTrunc(u + 2 * w + e + 2, 4));
            }
        }.f;
        const av2 = struct {
            fn f(u: i32, w: i32) u8 {
                return @intCast(@divTrunc(u + w + 1, 2));
            }
        }.f;
        var o: [4][4]u8 = undefined;
        switch (mode) {
            P_DC => {
                var sum: u32 = 4;
                for (0..4) |i| sum += @intCast(t[i]);
                sum += @intCast(s + r + q + p);
                const avg: u8 = @intCast(sum / 8);
                o = .{ .{ avg, avg, avg, avg }, .{ avg, avg, avg, avg }, .{ avg, avg, avg, avg }, .{ avg, avg, avg, avg } };
            },
            P_TM => {
                for (0..4) |j| {
                    const lv: i32 = z[y + j][x - 1];
                    for (0..4) |i| o[j][i] = clip8(lv + t[i] - a);
                }
            },
            P_VE => {
                const row = [4]u8{ av3(a, t[0], t[1]), av3(t[0], t[1], t[2]), av3(t[1], t[2], t[3]), av3(t[2], t[3], t[4]) };
                o = .{ row, row, row, row };
            },
            P_HE => {
                const v0 = av3(a, p, q);
                const v1 = av3(p, q, r);
                const v2 = av3(q, r, s);
                const v3 = av3(r, s, s);
                o = .{ .{ v0, v0, v0, v0 }, .{ v1, v1, v1, v1 }, .{ v2, v2, v2, v2 }, .{ v3, v3, v3, v3 } };
            },
            P_RD => {
                const srq = av3(s, r, q);
                const rqp = av3(r, q, p);
                const qpa = av3(q, p, a);
                const pab = av3(p, a, t[0]);
                const abc = av3(a, t[0], t[1]);
                const bcd = av3(t[0], t[1], t[2]);
                const cde = av3(t[1], t[2], t[3]);
                o = .{ .{ pab, abc, bcd, cde }, .{ qpa, pab, abc, bcd }, .{ rqp, qpa, pab, abc }, .{ srq, rqp, qpa, pab } };
            },
            P_VR => {
                const ab = av2(a, t[0]);
                const bc = av2(t[0], t[1]);
                const cd = av2(t[1], t[2]);
                const de = av2(t[2], t[3]);
                const rqp = av3(r, q, p);
                const qpa = av3(q, p, a);
                const pab = av3(p, a, t[0]);
                const abc = av3(a, t[0], t[1]);
                const bcd = av3(t[0], t[1], t[2]);
                const cde = av3(t[1], t[2], t[3]);
                o = .{ .{ ab, bc, cd, de }, .{ pab, abc, bcd, cde }, .{ qpa, ab, bc, cd }, .{ rqp, pab, abc, bcd } };
            },
            P_LD => {
                const abc = av3(t[0], t[1], t[2]);
                const bcd = av3(t[1], t[2], t[3]);
                const cde = av3(t[2], t[3], t[4]);
                const def = av3(t[3], t[4], t[5]);
                const efg = av3(t[4], t[5], t[6]);
                const fgh = av3(t[5], t[6], t[7]);
                const ghh = av3(t[6], t[7], t[7]);
                o = .{ .{ abc, bcd, cde, def }, .{ bcd, cde, def, efg }, .{ cde, def, efg, fgh }, .{ def, efg, fgh, ghh } };
            },
            P_VL => {
                const ab = av2(t[0], t[1]);
                const bc = av2(t[1], t[2]);
                const cd = av2(t[2], t[3]);
                const de = av2(t[3], t[4]);
                const abc = av3(t[0], t[1], t[2]);
                const bcd = av3(t[1], t[2], t[3]);
                const cde = av3(t[2], t[3], t[4]);
                const def = av3(t[3], t[4], t[5]);
                const efg = av3(t[4], t[5], t[6]);
                const fgh = av3(t[5], t[6], t[7]);
                o = .{ .{ ab, bc, cd, de }, .{ abc, bcd, cde, def }, .{ bc, cd, de, efg }, .{ bcd, cde, def, fgh } };
            },
            P_HD => {
                const sr = av2(s, r);
                const rq = av2(r, q);
                const qp = av2(q, p);
                const pa = av2(p, a);
                const srq = av3(s, r, q);
                const rqp = av3(r, q, p);
                const qpa = av3(q, p, a);
                const pab = av3(p, a, t[0]);
                const abc = av3(a, t[0], t[1]);
                const bcd = av3(t[0], t[1], t[2]);
                o = .{ .{ pa, pab, abc, bcd }, .{ qp, qpa, pa, pab }, .{ rq, rqp, qp, qpa }, .{ sr, srq, rq, rqp } };
            },
            else => { // P_HU
                const pq = av2(p, q);
                const qr = av2(q, r);
                const rs = av2(r, s);
                const pqr = av3(p, q, r);
                const qrs = av3(q, r, s);
                const rss = av3(r, s, s);
                const sss: u8 = @intCast(s);
                o = .{ .{ pq, pqr, qr, qrs }, .{ qr, qrs, rs, rss }, .{ rs, rss, sss, sss }, .{ sss, sss, sss, sss } };
            },
        }
        for (0..4) |j| @memcpy(z[y + j][x .. x + 4], &o[j]);
    }

    fn reconstruct(d: *Vp8, mbx: usize, mby: usize) bool {
        if (d.update_map) {
            if (!d.fp.bit(d.seg_prob[0])) {
                d.segment = d.fp.uint(d.seg_prob[1], 1);
            } else d.segment = d.fp.uint(d.seg_prob[2], 1) + 2;
        }
        var skip = false;
        if (d.use_skip) skip = d.fp.bit(d.skip_prob);
        @memset(&d.coeff, 0);
        d.prepareYbr(mbx, mby);
        d.y16 = d.fp.bit(145);
        if (d.y16) {
            var p: u8 = undefined;
            if (!d.fp.bit(156)) {
                p = if (!d.fp.bit(163)) P_DC else P_VE;
            } else if (!d.fp.bit(128)) p = P_HE else p = P_TM;
            d.up[mbx].pred = .{ p, p, p, p };
            d.left.pred = .{ p, p, p, p };
            d.pred_y16 = p;
        } else {
            for (0..4) |j| {
                var p = d.left.pred[j];
                for (0..4) |i| {
                    const pr = tb.pred_prob[(@as(usize, d.up[mbx].pred[i]) * 10 + p) * 9 ..][0..9];
                    if (!d.fp.bit(pr[0])) {
                        p = P_DC;
                    } else if (!d.fp.bit(pr[1])) {
                        p = P_TM;
                    } else if (!d.fp.bit(pr[2])) {
                        p = P_VE;
                    } else if (!d.fp.bit(pr[3])) {
                        if (!d.fp.bit(pr[4])) p = P_HE else if (!d.fp.bit(pr[5])) p = P_RD else p = P_VR;
                    } else if (!d.fp.bit(pr[6])) {
                        p = P_LD;
                    } else if (!d.fp.bit(pr[7])) {
                        p = P_VL;
                    } else if (!d.fp.bit(pr[8])) p = P_HD else p = P_HU;
                    d.pred_y4[j][i] = p;
                    d.up[mbx].pred[i] = p;
                }
                d.left.pred[j] = p;
            }
        }
        if (!d.fp.bit(142)) {
            d.pred_c8 = P_DC;
        } else if (!d.fp.bit(114)) {
            d.pred_c8 = P_VE;
        } else if (!d.fp.bit(183)) d.pred_c8 = P_HE else d.pred_c8 = P_TM;

        if (!skip) {
            skip = d.residuals(mbx, mby);
        } else {
            if (d.y16) {
                d.left.nz_y16 = 0;
                d.up[mbx].nz_y16 = 0;
            }
            d.left.nz_mask = 0;
            d.up[mbx].nz_mask = 0;
            d.nz_dc = 0;
            d.nz_ac = 0;
        }
        // reconstruct
        if (d.y16) {
            d.predN(YY, YX, 16, topLeft(mbx, mby, d.pred_y16));
            for (0..4) |j| for (0..4) |i| {
                const n = 4 * j + i;
                d.idctBlock(4 * j + 1, 4 * i + 8, 16 * n, @intCast(n));
            };
        } else {
            for (0..4) |j| for (0..4) |i| {
                const n = 4 * j + i;
                d.pred4(4 * j + 1, 4 * i + 8, d.pred_y4[j][i]);
                d.idctBlock(4 * j + 1, 4 * i + 8, 16 * n, @intCast(n));
            };
        }
        const pc = topLeft(mbx, mby, d.pred_c8);
        d.predN(BY, BX, 8, pc);
        for (0..4) |k| d.idctBlock(BY + (k / 2) * 4, BX + (k % 2) * 4, 256 + 16 * k, @intCast(16 + k));
        d.predN(RY, RX, 8, pc);
        for (0..4) |k| d.idctBlock(RY + (k / 2) * 4, RX + (k % 2) * 4, 320 + 16 * k, @intCast(20 + k));

        for (0..16) |y| {
            const i = (mby * 16 + y) * d.ystride + mbx * 16;
            @memcpy(d.ys[i .. i + 16], d.ybr[YY + y][YX .. YX + 16]);
        }
        for (0..8) |y| {
            const i = (mby * 8 + y) * d.cstride + mbx * 8;
            @memcpy(d.cb[i .. i + 8], d.ybr[BY + y][BX .. BX + 8]);
            @memcpy(d.cr[i .. i + 8], d.ybr[RY + y][RX .. RX + 8]);
        }
        return skip;
    }

    fn loopFilter(d: *Vp8) void {
        for (0..d.mbh) |mby| for (0..d.mbw) |mbx| {
            const f = d.mbf[d.mbw * mby + mbx];
            if (f.level == 0) continue;
            const l: i32 = f.level;
            const il: i32 = f.ilevel;
            const hl: i32 = f.hlevel;
            const yi = (mby * d.ystride + mbx) * 16;
            const ci = (mby * d.cstride + mbx) * 8;
            const ys = d.ystride;
            const cs = d.cstride;
            if (d.f_simple) {
                if (mbx > 0) filter2(d.ys, l + 4, yi, ys, 1);
                if (f.inner) for ([_]usize{ 4, 8, 12 }) |o| filter2(d.ys, l, yi + o, ys, 1);
                if (mby > 0) filter2(d.ys, l + 4, yi, 1, ys);
                if (f.inner) for ([_]usize{ 4, 8, 12 }) |o| filter2(d.ys, l, yi + ys * o, 1, ys);
                continue;
            }
            if (mbx > 0) {
                filter246(d.ys, 16, l + 4, il, hl, yi, ys, 1, false);
                filter246(d.cb, 8, l + 4, il, hl, ci, cs, 1, false);
                filter246(d.cr, 8, l + 4, il, hl, ci, cs, 1, false);
            }
            if (f.inner) {
                for ([_]usize{ 4, 8, 12 }) |o| filter246(d.ys, 16, l, il, hl, yi + o, ys, 1, true);
                filter246(d.cb, 8, l, il, hl, ci + 4, cs, 1, true);
                filter246(d.cr, 8, l, il, hl, ci + 4, cs, 1, true);
            }
            if (mby > 0) {
                filter246(d.ys, 16, l + 4, il, hl, yi, 1, ys, false);
                filter246(d.cb, 8, l + 4, il, hl, ci, 1, cs, false);
                filter246(d.cr, 8, l + 4, il, hl, ci, 1, cs, false);
            }
            if (f.inner) {
                for ([_]usize{ 4, 8, 12 }) |o| filter246(d.ys, 16, l, il, hl, yi + ys * o, 1, ys, true);
                filter246(d.cb, 8, l, il, hl, ci + cs * 4, 1, cs, true);
                filter246(d.cr, 8, l, il, hl, ci + cs * 4, 1, cs, true);
            }
        };
    }
};

fn cl(x: i32, max: i32) usize {
    return @intCast(std.math.clamp(x, 0, max));
}
fn clip8(x: i32) u8 {
    return @intCast(std.math.clamp(x, 0, 255));
}
fn tokOff(plane: usize, band: usize, ctx: usize) usize {
    return ((plane * 8 + band) * 3 + ctx) * 11;
}
fn unpack(m: u8) [4]u8 {
    return .{ m & 1, (m >> 1) & 1, (m >> 2) & 1, (m >> 3) & 1 };
}
fn pack(x: [4]u8, shift: usize) u32 {
    const u = @as(u32, x[0]) | @as(u32, x[1]) << 1 | @as(u32, x[2]) << 2 | @as(u32, x[3]) << 3;
    return u << @intCast(shift);
}
fn topLeft(mbx: usize, mby: usize, p: u8) u8 {
    if (p != P_DC) return p;
    if (mbx == 0) return if (mby == 0) P_DCTL else P_DCLEFT;
    if (mby == 0) return P_DCTOP;
    return P_DC;
}

fn iabs(x: i32) i32 {
    return if (x < 0) -x else x;
}
fn c15(x: i32) i32 {
    return std.math.clamp(x, -16, 15);
}
fn c127(x: i32) i32 {
    return std.math.clamp(x, -128, 127);
}

fn filter2(pix: []u8, level: i32, index0: usize, istep: usize, jstep: usize) void {
    var index = index0;
    var n: usize = 16;
    while (n > 0) : ({
        n -= 1;
        index += istep;
    }) {
        const p1: i32 = pix[index - 2 * jstep];
        const p0: i32 = pix[index - jstep];
        const q0: i32 = pix[index];
        const q1: i32 = pix[index + jstep];
        if ((iabs(p0 - q0) << 1) + (iabs(p1 - q1) >> 1) > level) continue;
        const a = 3 * (q0 - p0) + c127(p1 - q1);
        const a1 = c15((a + 4) >> 3);
        const a2 = c15((a + 3) >> 3);
        pix[index - jstep] = clip8(p0 + a2);
        pix[index] = clip8(q0 - a1);
    }
}

fn filter246(pix: []u8, n0: usize, level: i32, ilevel: i32, hlevel: i32, index0: usize, istep: usize, jstep: usize, four: bool) void {
    var index = index0;
    var n = n0;
    while (n > 0) : ({
        n -= 1;
        index += istep;
    }) {
        const p3: i32 = pix[index - 4 * jstep];
        const p2: i32 = pix[index - 3 * jstep];
        const p1: i32 = pix[index - 2 * jstep];
        const p0: i32 = pix[index - jstep];
        const q0: i32 = pix[index];
        const q1: i32 = pix[index + jstep];
        const q2: i32 = pix[index + 2 * jstep];
        const q3: i32 = pix[index + 3 * jstep];
        if ((iabs(p0 - q0) << 1) + (iabs(p1 - q1) >> 1) > level) continue;
        if (iabs(p3 - p2) > ilevel or iabs(p2 - p1) > ilevel or iabs(p1 - p0) > ilevel or
            iabs(q1 - q0) > ilevel or iabs(q2 - q1) > ilevel or iabs(q3 - q2) > ilevel) continue;
        if (iabs(p1 - p0) > hlevel or iabs(q1 - q0) > hlevel) {
            const a = 3 * (q0 - p0) + c127(p1 - q1);
            const a1 = c15((a + 4) >> 3);
            const a2 = c15((a + 3) >> 3);
            pix[index - jstep] = clip8(p0 + a2);
            pix[index] = clip8(q0 - a1);
        } else if (four) {
            const a = 3 * (q0 - p0);
            const a1 = c15((a + 4) >> 3);
            const a2 = c15((a + 3) >> 3);
            const a3 = (a1 + 1) >> 1;
            pix[index - 2 * jstep] = clip8(p1 + a3);
            pix[index - jstep] = clip8(p0 + a2);
            pix[index] = clip8(q0 - a1);
            pix[index + jstep] = clip8(q1 - a3);
        } else {
            const a = c127(3 * (q0 - p0) + c127(p1 - q1));
            const a1 = (27 * a + 63) >> 7;
            const a2 = (18 * a + 63) >> 7;
            const a3 = (9 * a + 63) >> 7;
            pix[index - 3 * jstep] = clip8(p2 + a3);
            pix[index - 2 * jstep] = clip8(p1 + a2);
            pix[index - jstep] = clip8(p0 + a1);
            pix[index] = clip8(q0 - a1);
            pix[index + jstep] = clip8(q1 - a2);
            pix[index + 2 * jstep] = clip8(q2 - a3);
        }
    }
}

fn decodeVp8(b: []const u8) !Image {
    if (b.len < 10) return fail("vp8: truncated frame");
    if (b[0] & 1 != 0) return fail("vp8: not a key frame");
    const first_len = (@as(usize, b[0]) >> 5) | @as(usize, b[1]) << 3 | @as(usize, b[2]) << 11;
    if (b[3] != 0x9d or b[4] != 0x01 or b[5] != 0x2a) return fail("vp8: invalid format");
    const w = (@as(usize, b[7] & 0x3f) << 8) | b[6];
    const h = (@as(usize, b[9] & 0x3f) << 8) | b[8];
    if (w == 0 or h == 0) return fail("vp8: invalid dimensions");
    const rest = b[10..];
    if (first_len > rest.len) return fail("vp8: truncated first partition");
    const mbw = (w + 15) >> 4;
    const mbh = (h + 15) >> 4;
    var d = try sys.A.create(Vp8);
    d.* = .{
        .w = w,
        .h = h,
        .mbw = mbw,
        .mbh = mbh,
        .ys = try sys.A.alloc(u8, 256 * mbw * mbh),
        .cb = try sys.A.alloc(u8, 64 * mbw * mbh),
        .cr = try sys.A.alloc(u8, 64 * mbw * mbh),
        .ystride = 16 * mbw,
        .cstride = 8 * mbw,
        .fp = BoolDec.init(rest[0..first_len]),
        .mbf = try sys.A.alloc(FilterParam, mbw * mbh),
        .up = try sys.A.alloc(MB, mbw),
    };
    @memcpy(&d.tok, &tb.default_token_prob);
    _ = d.fp.bit(128); // colour space
    _ = d.fp.bit(128); // clamping type
    d.parseSegment();
    d.parseFilter();
    // partitions
    var data = rest[first_len..];
    d.nop = @as(usize, 1) << @intCast(d.fp.uint(128, 2));
    const n3 = 3 * (d.nop - 1);
    if (data.len < n3) return fail("vp8: truncated partitions");
    var lens: [8]usize = undefined;
    var remaining = data.len - n3;
    for (0..d.nop - 1) |i| {
        const pl = @as(usize, data[3 * i]) | @as(usize, data[3 * i + 1]) << 8 | @as(usize, data[3 * i + 2]) << 16;
        if (pl > remaining) return fail("vp8: truncated partitions");
        lens[i] = pl;
        remaining -= pl;
    }
    lens[d.nop - 1] = remaining;
    data = data[n3..];
    for (0..d.nop) |i| {
        d.op[i] = BoolDec.init(data[0..lens[i]]);
        data = data[lens[i]..];
    }
    d.parseQuant();
    _ = d.fp.bit(128); // refresh entropy probs
    for (0..1056) |i| {
        if (d.fp.bit(tb.token_update_prob[i])) d.tok[i] = @intCast(d.fp.uint(128, 8));
    }
    d.use_skip = d.fp.bit(128);
    if (d.use_skip) d.skip_prob = @intCast(d.fp.uint(128, 8));
    if (d.fp.eof) return fail("vp8: unexpected end of data");

    for (d.up) |*u| u.* = .{};
    for (0..mbh) |mby| {
        d.left = .{};
        for (0..mbw) |mbx| {
            const skip = d.reconstruct(mbx, mby);
            var fs = d.fparams[d.segment][@intFromBool(!d.y16)];
            fs.inner = fs.inner or !skip;
            d.mbf[mbw * mby + mbx] = fs;
        }
    }
    if (d.f_level != 0) d.loopFilter();

    var img = try Image.init(@intCast(w), @intCast(h));
    for (0..h) |y| for (0..w) |x| {
        const yy: i32 = @as(i32, d.ys[y * d.ystride + x]) * 0x10101;
        const ci = (y / 2) * d.cstride + x / 2;
        const cb1: i32 = @as(i32, d.cb[ci]) - 128;
        const cr1: i32 = @as(i32, d.cr[ci]) - 128;
        const o = (y * w + x) * 4;
        img.px[o] = sat(yy + 91881 * cr1);
        img.px[o + 1] = sat(yy - 22554 * cb1 - 46802 * cr1);
        img.px[o + 2] = sat(yy + 116130 * cb1);
        img.px[o + 3] = 255;
    };
    return img;
}

fn sat(x: i32) u8 {
    if (@as(u32, @bitCast(x)) & 0xff000000 == 0) return @intCast(x >> 16);
    return if (x < 0) 0 else 255;
}

// ================================================================ alpha

fn decodeAlpha(body: []const u8, w: u32, h: u32) ![]u8 {
    if (body.len < 1) return fail("webp: empty ALPH chunk");
    const comp = body[0] & 3;
    const filter = (body[0] >> 2) & 3;
    const n = @as(usize, w) * h;
    const a = try sys.A.alloc(u8, n);
    switch (comp) {
        0 => {
            if (body.len - 1 < n) return fail("webp: truncated alpha");
            @memcpy(a, body[1 .. 1 + n]);
        },
        1 => {
            var br = LReader{ .buf = body[1..] };
            const pix = try vp8lBody(&br, w, h);
            for (0..n) |i| a[i] = @truncate(pix[i] >> 8);
        },
        else => return fail("webp: invalid alpha compression"),
    }
    const s: usize = w;
    switch (filter) {
        1 => {
            for (1..s) |i| a[i] +%= a[i - 1];
            var i: usize = s;
            while (i < n) : (i += s) {
                a[i] +%= a[i - s];
                for (1..s) |j| a[i + j] +%= a[i + j - 1];
            }
        },
        2 => {
            for (1..s) |i| a[i] +%= a[i - 1];
            for (s..n) |i| a[i] +%= a[i - s];
        },
        3 => {
            for (1..s) |i| a[i] +%= a[i - 1];
            var i: usize = s;
            while (i < n) : (i += s) {
                a[i] +%= a[i - s];
                for (1..s) |j| {
                    const c: i32 = a[i + j - s - 1];
                    const bb: i32 = a[i + j - s];
                    const aa: i32 = a[i + j - 1];
                    a[i + j] +%= clip8(aa + bb - c);
                }
            }
        },
        else => {},
    }
    return a;
}

// ================================================================ VP8L (lossless)

const LReader = struct {
    buf: []const u8,
    pos: usize = 0,
    bits: u64 = 0,
    nbits: u6 = 0,

    fn read(r: *LReader, n: u6) !u32 {
        while (r.nbits < n) {
            if (r.pos >= r.buf.len) return fail("vp8l: unexpected end of data");
            r.bits |= @as(u64, r.buf[r.pos]) << r.nbits;
            r.pos += 1;
            r.nbits += 8;
        }
        const u: u32 = @truncate(r.bits & ((@as(u64, 1) << n) - 1));
        r.bits >>= n;
        r.nbits -= n;
        return u;
    }
};

/// Canonical Huffman decoder (deflate-style codes, read one bit at a time
/// through a 8-bit fast table).
const HTree = struct {
    single: ?u32 = null,
    counts: [16]u16 = @as([16]u16, @splat(0)),
    symbols: []u16 = &.{},
    fast: []u16 = &.{}, // (len << 12) | sym for codes up to 8 bits; 0 = slow path

    fn build(lens: []const u32) !HTree {
        var t = HTree{};
        var nz: usize = 0;
        var last: u32 = 0;
        for (lens, 0..) |l, i| {
            if (l > 15) return fail("vp8l: invalid code length");
            if (l != 0) {
                nz += 1;
                last = @intCast(i);
            }
        }
        if (nz == 0) return fail("vp8l: invalid Huffman tree");
        if (nz == 1) {
            t.single = last;
            return t;
        }
        for (lens) |l| t.counts[l] += 1;
        t.counts[0] = 0;
        var offs: [16]u16 = undefined;
        offs[1] = 0;
        for (1..15) |i| offs[i + 1] = offs[i] + t.counts[i];
        t.symbols = try sys.A.alloc(u16, nz);
        for (lens, 0..) |l, i| if (l != 0) {
            t.symbols[offs[l]] = @intCast(i);
            offs[l] += 1;
        };
        // completeness check
        var left: i32 = 1;
        for (1..16) |i| {
            left <<= 1;
            left -= t.counts[i];
            if (left < 0) return fail("vp8l: invalid Huffman tree");
        }
        if (left != 0) return fail("vp8l: invalid Huffman tree");
        // fast table: index = next 8 input bits (LSB first)
        t.fast = try sys.A.alloc(u16, 256);
        @memset(t.fast, 0);
        var code: u32 = 0;
        var idx: usize = 0;
        for (1..9) |len| {
            for (0..t.counts[len]) |_| {
                const sym = t.symbols[idx];
                idx += 1;
                // reverse `len` bits of code
                var rev: u32 = 0;
                for (0..len) |k| rev |= ((code >> @intCast(k)) & 1) << @intCast(len - 1 - k);
                var fill: u32 = rev;
                while (fill < 256) : (fill += @as(u32, 1) << @intCast(len)) t.fast[fill] = @intCast((len << 12) | sym);
                code += 1;
            }
            code <<= 1;
        }
        return t;
    }

    fn next(t: *const HTree, r: *LReader) !u32 {
        if (t.single) |s| return s;
        // try the fast path
        while (r.nbits < 8 and r.pos < r.buf.len) {
            r.bits |= @as(u64, r.buf[r.pos]) << r.nbits;
            r.pos += 1;
            r.nbits += 8;
        }
        if (r.nbits >= 8) {
            const e = t.fast[@as(usize, @truncate(r.bits & 0xff))];
            if (e != 0) {
                const len: u6 = @intCast(e >> 12);
                r.bits >>= len;
                r.nbits -= len;
                return e & 0xfff;
            }
        }
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..16) |len| {
            code |= @intCast(try r.read(1));
            const count: i32 = t.counts[len];
            if (code - count < first) return t.symbols[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return fail("vp8l: invalid Huffman code");
    }
};

const code_length_order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

fn readTree(r: *LReader, alphabet: usize) !HTree {
    if (try r.read(1) != 0) {
        const nsym = try r.read(1) + 1;
        const first_bits: u6 = if (try r.read(1) != 0) 8 else 1;
        const lens = try sys.A.alloc(u32, @max(alphabet, 256));
        @memset(lens, 0);
        const s0 = try r.read(first_bits);
        if (s0 >= lens.len) return fail("vp8l: invalid simple code");
        lens[s0] = 1;
        if (nsym == 2) {
            const s1 = try r.read(8);
            lens[s1] = 1;
            if (s1 == s0) lens[s1] = 1;
        }
        var cnt: usize = 0;
        for (lens) |l| cnt += l;
        if (cnt == 1) return .{ .single = s0 };
        return HTree.build(lens);
    }
    const ncodes = try r.read(4) + 4;
    var cll = @as([19]u32, @splat(0));
    for (0..ncodes) |i| cll[code_length_order[i]] = try r.read(3);
    const lt = try HTree.build(&cll);
    const lens = try sys.A.alloc(u32, alphabet);
    @memset(lens, 0);
    var max_sym: usize = alphabet;
    if (try r.read(1) != 0) {
        const nb: u6 = @intCast(2 + 2 * try r.read(3));
        max_sym = try r.read(nb) + 2;
        if (max_sym > alphabet) return fail("vp8l: invalid code lengths");
    }
    var prev: u32 = 8;
    var sym: usize = 0;
    while (sym < alphabet) {
        if (max_sym == 0) break;
        max_sym -= 1;
        const c = try lt.next(r);
        if (c < 16) {
            lens[sym] = c;
            sym += 1;
            if (c != 0) prev = c;
            continue;
        }
        const extra: u6 = switch (c) {
            16 => 2,
            17 => 3,
            else => 7,
        };
        const off: usize = if (c == 18) 11 else 3;
        const rep = try r.read(extra) + off;
        if (sym + rep > alphabet) return fail("vp8l: invalid code lengths");
        const val: u32 = if (c == 16) prev else 0;
        for (0..rep) |_| {
            lens[sym] = val;
            sym += 1;
        }
    }
    return HTree.build(lens);
}

const HGroup = [5]HTree;

fn nTiles(size: usize, bits: u5) usize {
    return (size + (@as(usize, 1) << bits) - 1) >> bits;
}

const dist_map = [120]u8{
    0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a, 0x26, 0x2a, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a,
    0x25, 0x2b, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b, 0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03,
    0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d, 0x44, 0x4c, 0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e,
    0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b, 0x32, 0x3e, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f,
    0x64, 0x6c, 0x42, 0x4e, 0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b, 0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e, 0x00, 0x74, 0x7c, 0x41,
    0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f, 0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70,
};

fn lz77Param(r: *LReader, sym: u32) !u32 {
    if (sym < 4) return sym + 1;
    const extra: u6 = @intCast((sym - 2) >> 1);
    const off = (2 + (sym & 1)) << @intCast(extra);
    return off + try r.read(extra) + 1;
}

/// Decodes entropy-coded ARGB pixels (u32, 0xAARRGGBB).
fn decodePix(r: *LReader, w: usize, h: usize, top: bool) ![]u32 {
    var cc_bits: u5 = 0;
    var cache: []u32 = &.{};
    if (try r.read(1) != 0) {
        const cb = try r.read(4);
        if (cb < 1 or cb > 11) return fail("vp8l: invalid colour cache");
        cc_bits = @intCast(cb);
        cache = try sys.A.alloc(u32, @as(usize, 1) << cc_bits);
        @memset(cache, 0);
    }
    var hbits: u5 = 0;
    var hpix: []u32 = &.{};
    var ngroups: usize = 1;
    if (top and try r.read(1) != 0) {
        hbits = @intCast(try r.read(3) + 2);
        hpix = try decodePix(r, nTiles(w, hbits), nTiles(h, hbits), false);
        var maxg: usize = 0;
        for (hpix) |p| maxg = @max(maxg, (p >> 8) & 0xffff);
        ngroups = maxg + 1;
    }
    const groups = try sys.A.alloc(HGroup, ngroups);
    const sizes = [5]usize{ 256 + 24 + (if (cc_bits > 0) @as(usize, 1) << cc_bits else 0), 256, 256, 256, 40 };
    for (groups) |*g| {
        for (0..5) |j| g[j] = try readTree(r, sizes[j]);
    }
    const out = try sys.A.alloc(u32, w * h);
    const tiles_per_row = if (hbits > 0) nTiles(w, hbits) else 0;
    const hmask: usize = if (hbits > 0) (@as(usize, 1) << hbits) - 1 else 0;
    var p: usize = 0;
    var cached: usize = 0;
    var x: usize = 0;
    var y: usize = 0;
    var g: *const HGroup = &groups[0];
    var lookup = hbits > 0;
    const shift: u5 = if (cc_bits > 0) @intCast(32 - @as(u6, cc_bits)) else 0;
    while (p < out.len) {
        if (lookup) {
            const idx = (hpix[tiles_per_row * (y >> hbits) + (x >> hbits)] >> 8) & 0xffff;
            g = &groups[idx];
        }
        const green = try g[0].next(r);
        if (green < 256) {
            const red = try g[1].next(r);
            const blue = try g[2].next(r);
            const alpha = try g[3].next(r);
            out[p] = alpha << 24 | red << 16 | green << 8 | blue;
            p += 1;
            x += 1;
            if (x == w) {
                x = 0;
                y += 1;
            }
            lookup = hbits > 0 and x & hmask == 0;
        } else if (green < 256 + 24) {
            const length = try lz77Param(r, green - 256);
            const dsym = try g[4].next(r);
            const dcode = try lz77Param(r, dsym);
            var dist: usize = undefined;
            if (dcode > 120) {
                dist = dcode - 120;
            } else {
                const dc: i32 = dist_map[dcode - 1];
                const dd = (dc >> 4) * @as(i32, @intCast(w)) + (8 - (dc & 0xf));
                dist = if (dd >= 1) @intCast(dd) else 1;
            }
            if (dist > p or p + length > out.len) return fail("vp8l: invalid LZ77 parameters");
            for (0..length) |_| {
                out[p] = out[p - dist];
                p += 1;
            }
            x += length;
            while (x >= w) {
                x -= w;
                y += 1;
            }
            lookup = hbits > 0;
        } else {
            while (cached < p) : (cached += 1) cache[(out[cached] *% 0x1e35a7bd) >> shift] = out[cached];
            const ci = green - 256 - 24;
            if (ci >= cache.len) return fail("vp8l: invalid colour cache index");
            out[p] = cache[ci];
            p += 1;
            x += 1;
            if (x == w) {
                x = 0;
                y += 1;
            }
            lookup = hbits > 0 and x & hmask == 0;
        }
        if (cache.len > 0 and p - cached > 0) {
            while (cached < p) : (cached += 1) cache[(out[cached] *% 0x1e35a7bd) >> shift] = out[cached];
        }
    }
    return out;
}

const Transform = struct { kind: u2, old_w: usize, bits: u5 = 0, data: []u32 = &.{} };

fn vp8lBody(r: *LReader, w0: usize, h: usize) ![]u32 {
    var ts: [4]Transform = undefined;
    var nt: usize = 0;
    var seen = [4]bool{ false, false, false, false };
    var w = w0;
    while (try r.read(1) != 0) {
        const kind: u2 = @intCast(try r.read(2));
        if (seen[kind]) return fail("vp8l: repeated transform");
        seen[kind] = true;
        var t = Transform{ .kind = kind, .old_w = w };
        switch (kind) {
            0, 1 => {
                t.bits = @intCast(try r.read(3) + 2);
                t.data = try decodePix(r, nTiles(w, t.bits), nTiles(h, t.bits), false);
            },
            2 => {},
            3 => {
                const ncol = try r.read(8) + 1;
                t.bits = if (ncol <= 2) 3 else if (ncol <= 4) 2 else if (ncol <= 16) 1 else 0;
                const pal = try decodePix(r, ncol, 1, false);
                const full = try sys.A.alloc(u32, 256);
                @memset(full, 0);
                for (pal, 0..) |c, i| full[i] = if (i == 0) c else addPix(c, full[i - 1]);
                t.data = full;
                w = nTiles(w, t.bits);
            },
        }
        ts[nt] = t;
        nt += 1;
    }
    var pix = try decodePix(r, w, h, true);
    var i = nt;
    while (i > 0) {
        i -= 1;
        const t = &ts[i];
        switch (t.kind) {
            0 => invPredictor(t, pix, h),
            1 => invCrossColor(t, pix, h),
            2 => for (pix) |*p| {
                const g = (p.* >> 8) & 0xff;
                p.* = (p.* & 0xff00ff00) | (((p.* >> 16) +% g) & 0xff) << 16 | ((p.* +% g) & 0xff);
            },
            3 => pix = try invColorIndex(t, pix, h),
        }
    }
    return pix;
}

fn addPix(a: u32, b: u32) u32 {
    const ag = (a & 0xff00ff00) +% (b & 0xff00ff00);
    const rb = (a & 0x00ff00ff) +% (b & 0x00ff00ff);
    return (ag & 0xff00ff00) | (rb & 0x00ff00ff);
}
fn avg2(a: u32, b: u32) u32 {
    return (((a ^ b) & 0xfefefefe) >> 1) +% (a & b);
}
fn chan(x: u32, s: u5) i32 {
    return @intCast((x >> s) & 0xff);
}
fn select(l: u32, t: u32, tl: u32) u32 {
    var pl: i32 = 0;
    var pt: i32 = 0;
    for ([_]u5{ 0, 8, 16, 24 }) |s| {
        pl += iabs(chan(tl, s) - chan(t, s));
        pt += iabs(chan(tl, s) - chan(l, s));
    }
    return if (pl < pt) l else t;
}
fn clampFull(a: u32, b: u32, c: u32) u32 {
    var o: u32 = 0;
    for ([_]u5{ 0, 8, 16, 24 }) |s| {
        const x = std.math.clamp(chan(a, s) + chan(b, s) - chan(c, s), 0, 255);
        o |= @as(u32, @intCast(x)) << s;
    }
    return o;
}
fn clampHalf(a: u32, b: u32) u32 {
    var o: u32 = 0;
    for ([_]u5{ 0, 8, 16, 24 }) |s| {
        const x = std.math.clamp(chan(a, s) + @divTrunc(chan(a, s) - chan(b, s), 2), 0, 255);
        o |= @as(u32, @intCast(x)) << s;
    }
    return o;
}

fn invPredictor(t: *const Transform, pix: []u32, h: usize) void {
    const w = t.old_w;
    if (w == 0 or h == 0) return;
    pix[0] = addPix(pix[0], 0xff000000);
    for (1..w) |x| pix[x] = addPix(pix[x], pix[x - 1]);
    const tpr = nTiles(w, t.bits);
    const mask = (@as(usize, 1) << t.bits) - 1;
    for (1..h) |y| {
        const row = y * w;
        pix[row] = addPix(pix[row], pix[row - w]);
        var q = (y >> t.bits) * tpr;
        var mode = (t.data[q] >> 8) & 0xf;
        q += 1;
        for (1..w) |x| {
            if (x & mask == 0) {
                mode = (t.data[q] >> 8) & 0xf;
                q += 1;
            }
            const i = row + x;
            const L = pix[i - 1];
            const T = pix[i - w];
            const TL = pix[i - w - 1];
            const TR = pix[i - w + 1];
            const pred: u32 = switch (mode) {
                0 => 0xff000000,
                1 => L,
                2 => T,
                3 => TR,
                4 => TL,
                5 => avg2(avg2(L, TR), T),
                6 => avg2(L, TL),
                7 => avg2(L, T),
                8 => avg2(TL, T),
                9 => avg2(T, TR),
                10 => avg2(avg2(L, TL), avg2(T, TR)),
                11 => select(L, T, TL),
                12 => clampFull(L, T, TL),
                13 => clampHalf(avg2(L, T), TL),
                else => 0,
            };
            pix[i] = addPix(pix[i], pred);
        }
    }
}

fn ctd(t: i8, c: i8) u32 {
    return @bitCast((@as(i32, t) * @as(i32, c)) >> 5);
}

fn invCrossColor(t: *const Transform, pix: []u32, h: usize) void {
    const w = t.old_w;
    const tpr = nTiles(w, t.bits);
    for (0..h) |y| {
        const trow = (y >> t.bits) * tpr;
        for (0..w) |x| {
            const m = t.data[trow + (x >> t.bits)];
            const r2b: i8 = @bitCast(@as(u8, @truncate(m >> 16)));
            const g2b: i8 = @bitCast(@as(u8, @truncate(m >> 8)));
            const g2r: i8 = @bitCast(@as(u8, @truncate(m)));
            const p = pix[y * w + x];
            const g: i8 = @bitCast(@as(u8, @truncate(p >> 8)));
            var red: u32 = (p >> 16) & 0xff;
            var blue: u32 = p & 0xff;
            red = (red +% ctd(g2r, g)) & 0xff;
            blue = (blue +% ctd(g2b, g)) & 0xff;
            blue = (blue +% ctd(r2b, @bitCast(@as(u8, @truncate(red))))) & 0xff;
            pix[y * w + x] = (p & 0xff00ff00) | red << 16 | blue;
        }
    }
}

fn invColorIndex(t: *const Transform, pix: []u32, h: usize) ![]u32 {
    const w = t.old_w;
    if (t.bits == 0) {
        for (pix) |*p| p.* = t.data[(p.* >> 8) & 0xff];
        return pix;
    }
    const bpp: u5 = @intCast(@as(u32, 8) >> t.bits);
    const xmask = (@as(usize, 1) << t.bits) - 1;
    const vmask = (@as(u32, 1) << bpp) - 1;
    const pw = nTiles(w, t.bits);
    const out = try sys.A.alloc(u32, w * h);
    for (0..h) |y| {
        var val: u32 = 0;
        for (0..w) |x| {
            if (x & xmask == 0) val = (pix[y * pw + (x >> t.bits)] >> 8) & 0xff;
            out[y * w + x] = t.data[val & vmask];
            val >>= bpp;
        }
    }
    return out;
}

fn decodeVp8l(b: []const u8) !Image {
    if (b.len < 5 or b[0] != 0x2f) return fail("vp8l: invalid header");
    var r = LReader{ .buf = b[1..] };
    const w = try r.read(14) + 1;
    const h = try r.read(14) + 1;
    _ = try r.read(1);
    if (try r.read(3) != 0) return fail("vp8l: invalid version");
    const pix = try vp8lBody(&r, w, h);
    var img = try Image.init(w, h);
    for (pix, 0..) |p, i| {
        img.px[i * 4] = @truncate(p >> 16);
        img.px[i * 4 + 1] = @truncate(p >> 8);
        img.px[i * 4 + 2] = @truncate(p);
        img.px[i * 4 + 3] = @truncate(p >> 24);
    }
    return img;
}
