// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Hugo (Apache-2.0, Copyright The Hugo Authors).
// The original notices and licences are kept in NOTICE and licenses/.
//! Bindings to the embedded libavif (vendor/shim/zssg_avif.c), used when ZSSG
//! is built with -Davif=true (the default).
const std = @import("std");

pub const CImage = extern struct {
    width: u32,
    height: u32,
    depth: u32,
    rgb_depth: u32,
    row_bytes: u32,
    color_primaries: c_int,
    transfer: c_int,
    matrix: c_int,
    max_cll: c_int,
    max_pall: c_int,
    pixels: ?[*]u8,
};

extern fn zssg_avif_decode(data: [*]const u8, len: usize, out: *CImage, err: [*]u8, errlen: usize) c_int;
extern fn zssg_avif_free(p: ?*anyopaque) void;
extern fn zssg_avif_encode_rgba(pixels: [*]const u8, width: u32, height: u32, stride: u32, depth: c_int, cp: c_int, tc: c_int, mc: c_int, max_cll: c_int, max_pall: c_int, quality: f32, lossless: c_int, yuv444: c_int, speed: c_int, out: *?[*]u8, out_len: *usize, err: [*]u8, errlen: usize) c_int;
extern fn zssg_avif_encode_gray(pixels: [*]const u8, width: u32, height: u32, stride: u32, depth: c_int, quality: f32, lossless: c_int, speed: c_int, out: *?[*]u8, out_len: *usize, err: [*]u8, errlen: usize) c_int;

pub const Decoded = struct {
    img: CImage,
    /// RGBA8, or RGBA16 (host order) when img.rgb_depth == 16; owned by `a`
    pixels: []u8,
};

threadlocal var err_buf: [512]u8 = undefined;

pub fn errMsg() []const u8 {
    return std.mem.sliceTo(&err_buf, 0);
}

pub fn decode(a: std.mem.Allocator, data: []const u8) ?Decoded {
    var out: CImage = undefined;
    err_buf[0] = 0;
    if (zssg_avif_decode(data.ptr, data.len, &out, &err_buf, err_buf.len) == 0) return null;
    defer zssg_avif_free(out.pixels);
    const n = @as(usize, out.row_bytes) * out.height;
    const px = a.dupe(u8, out.pixels.?[0..n]) catch return null;
    return .{ .img = out, .pixels = px };
}

pub const EncodeOpts = struct {
    depth: u32 = 8,
    cp: i32 = 0,
    tc: i32 = 0,
    mc: i32 = 0,
    max_cll: i32 = 0,
    max_pall: i32 = 0,
    quality: f32 = 60,
    lossless: bool = false,
    yuv444: bool = false,
    speed: i32 = 10,
};

pub fn encodeRgba(a: std.mem.Allocator, pixels: []const u8, w: u32, h: u32, stride: u32, o: EncodeOpts) ?[]u8 {
    var out: ?[*]u8 = null;
    var len: usize = 0;
    err_buf[0] = 0;
    if (zssg_avif_encode_rgba(pixels.ptr, w, h, stride, @intCast(o.depth), o.cp, o.tc, o.mc, o.max_cll, o.max_pall, o.quality, @intFromBool(o.lossless), @intFromBool(o.yuv444), o.speed, &out, &len, &err_buf, err_buf.len) == 0) return null;
    defer zssg_avif_free(out);
    return a.dupe(u8, out.?[0..len]) catch null;
}

pub fn encodeGray(a: std.mem.Allocator, pixels: []const u8, w: u32, h: u32, stride: u32, o: EncodeOpts) ?[]u8 {
    var out: ?[*]u8 = null;
    var len: usize = 0;
    err_buf[0] = 0;
    if (zssg_avif_encode_gray(pixels.ptr, w, h, stride, @intCast(o.depth), o.quality, @intFromBool(o.lossless), o.speed, &out, &len, &err_buf, err_buf.len) == 0) return null;
    defer zssg_avif_free(out);
    return a.dupe(u8, out.?[0..len]) catch null;
}
