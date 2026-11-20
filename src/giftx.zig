// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: gift (MIT, Copyright Grigory Dryapak).
// The original notices and licences are kept in NOTICE and licenses/.
//! Exact port of the parts of github.com/gohugoio/gift that Hugo uses for
//! Resize / Fit / Fill / Crop: float32 pixel getters and setters per Go image
//! type, resampling weights, separable resize through an NRGBA64 temporary,
//! crops and filter chains (each intermediate result is an NRGBA64 image).
const std = @import("std");
const sys = @import("sys.zig");
const image = @import("image.zig");
const Image = image.Image;

pub const Px = [4]f32;

const qf8: f32 = 1.0 / 255.0;
const qf16: f32 = 1.0 / 65535.0;

pub const SKind = enum { nrgba8, rgba8, gray8, pal8, n64, ycc };

/// An image in one of the Go in-memory layouts gift distinguishes.
pub const Surf = struct {
    w: u32,
    h: u32,
    k: SKind,
    p8: []u8 = &.{}, // 4 bytes per pixel (gray8 keeps r=g=b)
    p16: []u16 = &.{}, // n64: 4 channels per pixel
    ycc: ?image.Ycc = null,

    pub fn alloc(w: u32, h: u32, k: SKind) !Surf {
        var s: Surf = .{ .w = w, .h = h, .k = k };
        const n = @as(usize, w) * h * 4;
        if (k == .n64) {
            s.p16 = try sys.A.alloc(u16, n);
            @memset(s.p16, 0);
        } else {
            s.p8 = try sys.A.alloc(u8, n);
            @memset(s.p8, 0);
        }
        return s;
    }

    pub fn fromImage(img: *const Image) Surf {
        const k: SKind = switch (img.kind) {
            .nrgba => .nrgba8,
            .rgba => .rgba8,
            .gray => .gray8,
            .paletted => .pal8,
        };
        if (img.ycc) |y| return .{ .w = img.w, .h = img.h, .k = .ycc, .p8 = img.px, .ycc = y };
        if (img.px16) |p| return .{ .w = img.w, .h = img.h, .k = .n64, .p16 = p };
        return .{ .w = img.w, .h = img.h, .k = k, .p8 = img.px };
    }

    /// The image a gift chain draws into for a source (Hugo's doFilter).
    pub fn dstKindFor(k: SKind) SKind {
        return switch (k) {
            .rgba8 => .rgba8,
            .gray8 => .gray8,
            .n64 => .n64,
            else => .nrgba8,
        };
    }

    pub fn toImage(s: *const Surf) Image {
        if (s.k == .n64) {
            // a >8-bit AVIF stays 16-bit (Hugo's NRGBA64 frame)
            const p8 = sys.A.alloc(u8, s.p16.len) catch @panic("oom");
            for (p8, s.p16) |*o, x| o.* = @intCast(x >> 8);
            return .{ .w = s.w, .h = s.h, .px = p8, .px16 = s.p16 };
        }
        var img: Image = .{ .w = s.w, .h = s.h, .px = s.p8 };
        img.kind = switch (s.k) {
            .rgba8 => .rgba,
            .gray8 => .gray,
            else => .nrgba,
        };
        if (s.k == .rgba8) {
            // stored premultiplied like image.RGBA; ZSSG images are straight alpha
            var i: usize = 0;
            while (i < img.px.len) : (i += 4) {
                const a: u32 = img.px[i + 3];
                if (a == 255 or a == 0) continue;
                inline for (0..3) |c| {
                    // color.NRGBAModel: (r16 * 0xffff / a16) >> 8
                    const r16: u32 = @as(u32, img.px[i + c]) * 0x101;
                    const a16: u32 = a * 0x101;
                    img.px[i + c] = @intCast(((r16 * 0xffff) / a16) >> 8);
                }
            }
        }
        return img;
    }

    pub fn get(s: *const Surf, x: usize, y: usize) Px {
        const i = (y * s.w + x) * 4;
        switch (s.k) {
            .nrgba8 => return .{ @as(f32, @floatFromInt(s.p8[i])) * qf8, @as(f32, @floatFromInt(s.p8[i + 1])) * qf8, @as(f32, @floatFromInt(s.p8[i + 2])) * qf8, @as(f32, @floatFromInt(s.p8[i + 3])) * qf8 },
            .n64 => return .{ @as(f32, @floatFromInt(s.p16[i])) * qf16, @as(f32, @floatFromInt(s.p16[i + 1])) * qf16, @as(f32, @floatFromInt(s.p16[i + 2])) * qf16, @as(f32, @floatFromInt(s.p16[i + 3])) * qf16 },
            .rgba8 => {
                const a8 = s.p8[i + 3];
                if (a8 == 0xff) return .{ @as(f32, @floatFromInt(s.p8[i])) * qf8, @as(f32, @floatFromInt(s.p8[i + 1])) * qf8, @as(f32, @floatFromInt(s.p8[i + 2])) * qf8, 1 };
                if (a8 == 0) return .{ 0, 0, 0, 0 };
                // ZSSG keeps straight alpha: premultiply like image.RGBA would hold it
                const q = @as(f32, 1) / @as(f32, @floatFromInt(a8));
                var out: Px = undefined;
                inline for (0..3) |c| {
                    const pm: u32 = (@as(u32, s.p8[i + c]) * 0x101 * a8 / 0xff) >> 8;
                    out[c] = @as(f32, @floatFromInt(pm)) * q;
                }
                out[3] = @as(f32, @floatFromInt(a8)) * qf8;
                return out;
            },
            .gray8 => {
                const val = @as(f32, @floatFromInt(s.p8[i])) * qf8;
                return .{ val, val, val, 1 };
            },
            .ycc => {
                const c = s.ycc.?;
                const iy = y * c.ystride + x;
                const ic = (y / c.vdiv) * c.cstride + x / c.hdiv;
                const mx: i32 = 255 * 100000;
                const inv: f32 = 1.0 / 25500000.0;
                const y1: i32 = @as(i32, c.y[iy]) * 100000;
                const cb1: i32 = @as(i32, c.cb[ic]) - 128;
                const cr1: i32 = @as(i32, c.cr[ic]) - 128;
                const cl = struct {
                    fn f(val: i32, m: i32) i32 {
                        if (val > m) return m;
                        if (val > 0) return val;
                        return 0;
                    }
                }.f;
                return .{
                    @as(f32, @floatFromInt(cl(y1 + 140200 * cr1, mx))) * inv,
                    @as(f32, @floatFromInt(cl(y1 - 34414 * cb1 - 71414 * cr1, mx))) * inv,
                    @as(f32, @floatFromInt(cl(y1 + 177200 * cb1, mx))) * inv,
                    1,
                };
            },
            .pal8 => {
                // pixelFromColor(color.NRGBA)
                const a8: u32 = s.p8[i + 3];
                const a16 = a8 | (a8 << 8);
                var c16: [3]u32 = undefined;
                inline for (0..3) |c| {
                    var r: u32 = s.p8[i + c];
                    r |= r << 8;
                    r *= a8;
                    r /= 0xff;
                    c16[c] = r;
                }
                if (a16 == 0) return .{ 0, 0, 0, 0 };
                if (a16 == 0xffff) return .{ @as(f32, @floatFromInt(c16[0])) * qf16, @as(f32, @floatFromInt(c16[1])) * qf16, @as(f32, @floatFromInt(c16[2])) * qf16, 1 };
                const q = @as(f32, 1) / @as(f32, @floatFromInt(a16));
                return .{ @as(f32, @floatFromInt(c16[0])) * q, @as(f32, @floatFromInt(c16[1])) * q, @as(f32, @floatFromInt(c16[2])) * q, @as(f32, @floatFromInt(a16)) * qf16 };
            },
        }
    }

    pub fn set(s: *Surf, x: usize, y: usize, px: Px) void {
        const i = (y * s.w + x) * 4;
        switch (s.k) {
            .nrgba8, .pal8, .ycc => inline for (0..4) |c| {
                s.p8[i + c] = f32u8(px[c] * 0xff);
            },
            .n64 => inline for (0..4) |c| {
                s.p16[i + c] = f32u16(px[c] * 0xffff);
            },
            .rgba8 => {
                const fa = px[3] * 0xff;
                inline for (0..3) |c| s.p8[i + c] = f32u8(px[c] * fa);
                s.p8[i + 3] = f32u8(fa);
            },
            .gray8 => {
                const g = f32u8((0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]) * px[3] * 0xff);
                s.p8[i] = g;
                s.p8[i + 1] = g;
                s.p8[i + 2] = g;
                s.p8[i + 3] = 255;
            },
        }
    }
};

fn f32u8(val: f32) u8 {
    const x: i64 = @intFromFloat(val + 0.5);
    if (x > 0xff) return 0xff;
    if (x > 0) return @intCast(x);
    return 0;
}
fn f32u16(val: f32) u16 {
    const x: i64 = @intFromFloat(val + 0.5);
    if (x > 0xffff) return 0xffff;
    if (x > 0) return @intCast(x);
    return 0;
}

// ---------------------------------------------------------------- kernels

fn sinc(x: f32) f32 {
    if (x == 0) return 1;
    const xd: f64 = @floatCast(x);
    return @floatCast(@sin(std.math.pi * xd) / (std.math.pi * xd));
}
fn bcspline(x_in: f32, b: f32, c: f32) f32 {
    var x = x_in;
    if (x < 0) x = -x;
    if (x < 1) return ((12 - 9 * b - 6 * c) * x * x * x + (-18 + 12 * b + 6 * c) * x * x + (6 - 2 * b)) / 6;
    if (x < 2) return ((-b - 6 * c) * x * x * x + (6 * b + 30 * c) * x * x + (-12 * b - 48 * c) * x + (8 * b + 24 * c)) / 6;
    return 0;
}

pub fn support(f: image.Filter) f32 {
    return switch (f) {
        .nearest => 0,
        .box => 0.5,
        .linear, .hermite => 1,
        .mitchell, .catmullrom, .bspline, .gaussian => 2,
        else => 3,
    };
}

pub fn kernel(f: image.Filter, x_in: f32) f32 {
    const x = @abs(x_in);
    const pi = std.math.pi;
    const xd: f64 = @floatCast(x);
    return switch (f) {
        .nearest => 0,
        .box => if (x <= 0.5) 1 else 0,
        .linear => if (x < 1) 1 - x else 0,
        .hermite => if (x < 1) bcspline(x, 0, 0) else 0,
        .mitchell => if (x < 2) bcspline(x, 1.0 / 3.0, 1.0 / 3.0) else 0,
        .catmullrom => if (x < 2) bcspline(x, 0, 0.5) else 0,
        .bspline => if (x < 2) bcspline(x, 1, 0) else 0,
        .gaussian => if (x < 2) @floatCast(@exp(@as(f64, @floatCast(-2 * x * x)))) else 0,
        .lanczos => if (x < 3) sinc(x) * sinc(x / 3) else 0,
        .hann => if (x < 3) sinc(x) * @as(f32, @floatCast(0.5 + 0.5 * @cos(pi * xd / 3.0))) else 0,
        .hamming => if (x < 3) sinc(x) * @as(f32, @floatCast(0.54 + 0.46 * @cos(pi * xd / 3.0))) else 0,
        .blackman => if (x < 3) sinc(x) * @as(f32, @floatCast(0.42 - 0.5 * @cos(pi * xd / 3.0 + pi) + 0.08 * @cos(2.0 * pi * xd / 3.0))) else 0,
        .bartlett => if (x < 3) sinc(x) * (3.0 - x) / 3.0 else 0,
        .welch => if (x < 3) sinc(x) * (1.0 - (x * x / 9.0)) else 0,
        .cosine => if (x < 3) sinc(x) * @as(f32, @floatCast(@cos((pi / 2.0) * (xd / 3.0)))) else 0,
    };
}

const W = struct { index: usize, weight: f32 };

fn prepareWeights(dst_size: usize, src_size: usize, f: image.Filter) ![][]W {
    const delta = @as(f32, @floatFromInt(src_size)) / @as(f32, @floatFromInt(dst_size));
    var scale = delta;
    if (scale < 1) scale = 1;
    const radius: f32 = @floatCast(@ceil(@as(f64, @floatCast(scale * support(f)))));
    const result = try sys.A.alloc([]W, dst_size);
    for (0..dst_size) |i| {
        const center = (@as(f32, @floatFromInt(i)) + 0.5) * delta - 0.5;
        const left: i64 = @max(@as(i64, @intFromFloat(@ceil(@as(f64, @floatCast(center - radius))))), 0);
        const right: i64 = @min(@as(i64, @intFromFloat(@floor(@as(f64, @floatCast(center + radius))))), @as(i64, @intCast(src_size)) - 1);
        var list: std.ArrayList(W) = .empty;
        var sum: f32 = 0;
        var j = left;
        while (j <= right) : (j += 1) {
            const wv = kernel(f, (@as(f32, @floatFromInt(j)) - center) / scale);
            if (wv == 0) continue;
            try list.append(sys.A, .{ .index = @intCast(j), .weight = wv });
            sum += wv;
        }
        for (list.items) |*e| e.weight /= sum;
        result[i] = list.items;
    }
    return result;
}

fn resizeLine(dst: []Px, src: []const Px, weights: []const []W) void {
    for (dst, 0..) |*d, i| {
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;
        var a: f32 = 0;
        for (weights[i]) |w| {
            const c = src[w.index];
            const wa = c[3] * w.weight;
            r += c[0] * wa;
            g += c[1] * wa;
            b += c[2] * wa;
            a += wa;
        }
        if (a != 0) {
            r /= a;
            g /= a;
            b /= a;
        }
        d.* = .{ r, g, b, a };
    }
}

fn getRow(s: *const Surf, y: usize, out: []Px) void {
    switch (s.k) {
        .nrgba8 => {
            const row = s.p8[y * s.w * 4 ..][0 .. s.w * 4];
            for (out, 0..) |*o, x| o.* = .{ @as(f32, @floatFromInt(row[x * 4])) * qf8, @as(f32, @floatFromInt(row[x * 4 + 1])) * qf8, @as(f32, @floatFromInt(row[x * 4 + 2])) * qf8, @as(f32, @floatFromInt(row[x * 4 + 3])) * qf8 };
        },
        .n64 => {
            const row = s.p16[y * s.w * 4 ..][0 .. s.w * 4];
            for (out, 0..) |*o, x| o.* = .{ @as(f32, @floatFromInt(row[x * 4])) * qf16, @as(f32, @floatFromInt(row[x * 4 + 1])) * qf16, @as(f32, @floatFromInt(row[x * 4 + 2])) * qf16, @as(f32, @floatFromInt(row[x * 4 + 3])) * qf16 };
        },
        else => for (out, 0..) |*o, x| {
            o.* = s.get(x, y);
        },
    }
}

fn setRow(s: *Surf, y: usize, row: []const Px) void {
    switch (s.k) {
        .n64 => {
            const d = s.p16[y * s.w * 4 ..][0 .. s.w * 4];
            for (row, 0..) |px, x| inline for (0..4) |c| {
                d[x * 4 + c] = f32u16(px[c] * 0xffff);
            };
        },
        .nrgba8 => {
            const d = s.p8[y * s.w * 4 ..][0 .. s.w * 4];
            for (row, 0..) |px, x| inline for (0..4) |c| {
                d[x * 4 + c] = f32u8(px[c] * 0xff);
            };
        },
        else => for (row, 0..) |px, x| s.set(x, y, px),
    }
}

fn resizeHorizontal(dst: *Surf, src: *const Surf, w: usize, f: image.Filter) !void {
    const weights = try prepareWeights(w, src.w, f);
    const sb = try sys.A.alloc(Px, src.w);
    const db = try sys.A.alloc(Px, w);
    for (0..src.h) |y| {
        getRow(src, y, sb);
        resizeLine(db, sb, weights);
        setRow(dst, y, db);
    }
}

/// Same arithmetic as gift's column-by-column pass (each output pixel sums
/// its weights in order), done row by row for cache locality.
fn resizeVertical(dst: *Surf, src: *const Surf, h: usize, f: image.Filter) !void {
    const weights = try prepareWeights(h, src.h, f);
    const w: usize = src.w;
    // source rows converted once
    const rows = try sys.A.alloc(Px, w * src.h);
    for (0..src.h) |y| getRow(src, y, rows[y * w ..][0..w]);
    const acc = try sys.A.alloc(Px, w);
    for (0..h) |y| {
        @memset(acc, .{ 0, 0, 0, 0 });
        for (weights[y]) |wt| {
            const sr = rows[wt.index * w ..][0..w];
            for (acc, sr) |*a, c| {
                const wa = c[3] * wt.weight;
                a[0] += c[0] * wa;
                a[1] += c[1] * wa;
                a[2] += c[2] * wa;
                a[3] += wa;
            }
        }
        for (acc) |*a| {
            if (a[3] != 0) {
                a[0] /= a[3];
                a[1] /= a[3];
                a[2] /= a[3];
            }
        }
        setRow(dst, y, acc);
    }
}

fn resizeNearest(dst: *Surf, src: *const Surf, w: usize, h: usize) void {
    const dx = @as(f64, @floatFromInt(src.w)) / @as(f64, @floatFromInt(w));
    const dy = @as(f64, @floatFromInt(src.h)) / @as(f64, @floatFromInt(h));
    for (0..h) |y| for (0..w) |x| {
        const fx: usize = @intFromFloat(@floor((@as(f64, @floatFromInt(x)) + 0.5) * dx));
        const fy: usize = @intFromFloat(@floor((@as(f64, @floatFromInt(y)) + 0.5) * dy));
        dst.set(x, y, src.get(fx, fy));
    };
}

pub fn copyImage(dst: *Surf, src: *const Surf, x0: usize, y0: usize, w: usize, h: usize) void {
    for (0..h) |y| for (0..w) |x| dst.set(x, y, src.get(x0 + x, y0 + y));
}

/// gift.Resize(w, h).Draw(dst, src); dst must be w x h.
pub fn resizeDraw(dst: *Surf, src: *const Surf, w: usize, h: usize, f: image.Filter) !void {
    if (w == 0 or h == 0) return;
    if (src.w == w and src.h == h) return copyImage(dst, src, 0, 0, w, h);
    if (support(f) <= 0) return resizeNearest(dst, src, w, h);
    if (src.w == w) return resizeVertical(dst, src, h, f);
    if (src.h == h) return resizeHorizontal(dst, src, w, f);
    var tmp = try Surf.alloc(@intCast(w), src.h, .n64);
    try resizeHorizontal(&tmp, src, w, f);
    try resizeVertical(dst, &tmp, h, f);
}

pub const Anchor = enum { smart, center, topleft, top, topright, left, right, bottomleft, bottom, bottomright };

pub const Rect = struct { x0: i64, y0: i64, x1: i64, y1: i64 };

fn intersect(a: Rect, b: Rect) Rect {
    var r: Rect = .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    if (r.x0 >= r.x1 or r.y0 >= r.y1) r = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    return r;
}

fn anchorPt(bw: i64, bh: i64, w: i64, h: i64, a: Anchor) [2]i64 {
    return switch (a) {
        .topleft => .{ 0, 0 },
        .top => .{ @divTrunc(bw - w, 2), 0 },
        .topright => .{ bw - w, 0 },
        .left => .{ 0, @divTrunc(bh - h, 2) },
        .right => .{ bw - w, @divTrunc(bh - h, 2) },
        .bottomleft => .{ 0, bh - h },
        .bottom => .{ @divTrunc(bw - w, 2), bh - h },
        .bottomright => .{ bw - w, bh - h },
        else => .{ @divTrunc(bw - w, 2), @divTrunc(bh - h, 2) },
    };
}

/// A gift filter as Hugo builds them in FiltersFromConfig.
pub const Op = union(enum) {
    resize: struct { w: u32, h: u32, f: image.Filter }, // one of w/h may be 0
    fit: struct { w: u32, h: u32, f: image.Filter },
    fill: struct { w: u32, h: u32, f: image.Filter, a: Anchor },
    crop: Rect,
    crop_to_size: struct { w: u32, h: u32, a: Anchor },
    rotate: u32, // quarter turns counter-clockwise

    pub fn bounds(op: Op, sw: u32, sh: u32) [2]u32 {
        switch (op) {
            .resize => |r| {
                if ((r.w == 0 and r.h == 0) or sw == 0 or sh == 0) return .{ 0, 0 };
                if (r.w == 0) {
                    const fw = @as(f64, @floatFromInt(r.h)) * @as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(sh));
                    return .{ @intFromFloat(@max(1, @floor(fw + 0.5))), r.h };
                }
                if (r.h == 0) {
                    const fh = @as(f64, @floatFromInt(r.w)) * @as(f64, @floatFromInt(sh)) / @as(f64, @floatFromInt(sw));
                    return .{ r.w, @intFromFloat(@max(1, @floor(fh + 0.5))) };
                }
                return .{ r.w, r.h };
            },
            .fit => |r| {
                if (r.w == 0 or r.h == 0 or sw == 0 or sh == 0) return .{ 0, 0 };
                if (sw <= r.w and sh <= r.h) return .{ sw, sh };
                const wr = @as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(r.w));
                const hr = @as(f64, @floatFromInt(sh)) / @as(f64, @floatFromInt(r.h));
                if (wr > hr) return .{ r.w, @min(@as(u32, @intFromFloat(@as(f64, @floatFromInt(sh)) / wr + 0.5)), r.h) };
                return .{ @min(@as(u32, @intFromFloat(@as(f64, @floatFromInt(sw)) / hr + 0.5)), r.w), r.h };
            },
            .fill => |r| return if (r.w == 0 or r.h == 0 or sw == 0 or sh == 0) .{ 0, 0 } else .{ r.w, r.h },
            .crop => |r| {
                const b = intersect(.{ .x0 = 0, .y0 = 0, .x1 = sw, .y1 = sh }, r);
                return .{ @intCast(b.x1 - b.x0), @intCast(b.y1 - b.y0) };
            },
            .crop_to_size => |r| {
                if (r.w == 0 or r.h == 0) return .{ 0, 0 };
                const b = cropToSizeRect(sw, sh, r.w, r.h, r.a);
                return .{ @intCast(b.x1 - b.x0), @intCast(b.y1 - b.y0) };
            },
            .rotate => |t| return if (t % 2 == 1) .{ sh, sw } else .{ sw, sh },
        }
    }

    fn draw(op: Op, dst: *Surf, src: *const Surf) !void {
        switch (op) {
            .resize => {
                try resizeDraw(dst, src, dst.w, dst.h, op.resize.f);
            },
            .fit => |r| try resizeDraw(dst, src, dst.w, dst.h, r.f),
            .fill => |r| {
                if (dst.w == 0 or dst.h == 0) return;
                const wr = @as(f64, @floatFromInt(src.w)) / @as(f64, @floatFromInt(r.w));
                const hr = @as(f64, @floatFromInt(src.h)) / @as(f64, @floatFromInt(r.h));
                var tw: u32 = undefined;
                var th: u32 = undefined;
                if (wr < hr) {
                    tw = r.w;
                    th = @max(@as(u32, @intFromFloat(@as(f64, @floatFromInt(src.h)) / wr + 0.5)), r.h);
                } else {
                    th = r.h;
                    tw = @max(@as(u32, @intFromFloat(@as(f64, @floatFromInt(src.w)) / hr + 0.5)), r.w);
                }
                var tmp = try Surf.alloc(tw, th, .n64);
                try resizeDraw(&tmp, src, tw, th, r.f);
                const b = cropToSizeRect(tw, th, r.w, r.h, r.a);
                copyImage(dst, &tmp, @intCast(b.x0), @intCast(b.y0), @intCast(b.x1 - b.x0), @intCast(b.y1 - b.y0));
            },
            .crop => |r| {
                const b = intersect(.{ .x0 = 0, .y0 = 0, .x1 = src.w, .y1 = src.h }, r);
                copyImage(dst, src, @intCast(b.x0), @intCast(b.y0), @intCast(b.x1 - b.x0), @intCast(b.y1 - b.y0));
            },
            .crop_to_size => |r| {
                const b = cropToSizeRect(src.w, src.h, r.w, r.h, r.a);
                copyImage(dst, src, @intCast(b.x0), @intCast(b.y0), @intCast(b.x1 - b.x0), @intCast(b.y1 - b.y0));
            },
            .rotate => |t| {
                for (0..src.h) |y| for (0..src.w) |x| {
                    const px = src.get(x, y);
                    const d: [2]usize = switch (t % 4) {
                        1 => .{ y, src.w - 1 - x }, // 90° counter-clockwise
                        2 => .{ src.w - 1 - x, src.h - 1 - y },
                        3 => .{ src.h - 1 - y, x },
                        else => .{ x, y },
                    };
                    dst.set(d[0], d[1], px);
                };
            },
        }
    }
};

/// gift DrawAt(tmp, frame, OverOperator) onto a new transparent NRGBA64 (what
/// Hugo does to the frame of a >8-bit AVIF before filtering it).
fn overTransparent(src: *const Surf) !Surf {
    // g.Draw(copy, src) with no filters: a copy through the pixel getter/setter
    var copy = try Surf.alloc(src.w, src.h, .n64);
    copyImage(&copy, src, 0, 0, src.w, src.h);
    var tmp = try Surf.alloc(src.w, src.h, .n64);
    for (0..src.h) |y| for (0..src.w) |x| {
        const p1 = copy.get(x, y);
        var c1 = p1[3];
        var c0: f32 = (1 - c1) * 0;
        const cs = c0 + c1;
        c0 /= cs;
        c1 /= cs;
        var px: Px = .{ 0 * c0 + p1[0] * c1, 0 * c0 + p1[1] * c1, 0 * c0 + p1[2] * c1, 0 + p1[3] * (1 - 0) };
        // Go turns NaN (0/0 for transparent pixels) into 0 in f32u16
        for (&px) |*e| if (std.math.isNan(e.*)) {
            e.* = 0;
        };
        tmp.set(x, y, px);
    };
    return tmp;
}

fn cropToSizeRect(sw: u32, sh: u32, w: u32, h: u32, a: Anchor) Rect {
    const pt = anchorPt(sw, sh, w, h, a);
    return intersect(.{ .x0 = 0, .y0 = 0, .x1 = sw, .y1 = sh }, .{ .x0 = pt[0], .y0 = pt[1], .x1 = pt[0] + w, .y1 = pt[1] + h });
}

/// gift.New(ops...).Draw(dst, src) with dst of the type Hugo's doFilter picks.
pub fn run(src_img: *const Image, ops: []const Op) !Image {
    var src = Surf.fromImage(src_img);
    if (src.k == .n64 and src_img.hdr_avif) src = try overTransparent(&src);
    if (ops.len == 0) return src_img.*;
    var cur = src;
    for (ops, 0..) |op, i| {
        const b = op.bounds(cur.w, cur.h);
        const k: SKind = if (i == ops.len - 1) Surf.dstKindFor(src.k) else .n64;
        var out = try Surf.alloc(b[0], b[1], k);
        try op.draw(&out, &cur);
        cur = out;
    }
    return cur.toImage();
}
