// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: tdewolff/minify and tdewolff/parse (MIT, Copyright Taco de Wolff).
// The original notices and licences are kept in NOTICE and licenses/.
//! Shared pieces of the tdewolff/minify port (MIT): number formatting, data
//! URIs and byte helpers, plus the dispatcher by media type that Hugo uses.
const std = @import("std");
const sys = @import("sys.zig");

pub const epsilon: f64 = 0.00001;

pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}
pub fn isNewline(c: u8) bool {
    return c == '\n' or c == '\r';
}

pub fn trimWhitespace(b: []const u8) []const u8 {
    var start: usize = b.len;
    for (b, 0..) |c, i| if (!isWhitespace(c)) {
        start = i;
        break;
    };
    var end: usize = b.len;
    var i = b.len;
    while (i > start) {
        i -= 1;
        if (!isWhitespace(b[i])) {
            end = i + 1;
            break;
        }
    }
    return b[start..end];
}

pub fn toLower(b: []const u8) []u8 {
    const o = sys.A.alloc(u8, b.len) catch unreachable;
    for (b, 0..) |c, i| o[i] = std.ascii.toLower(c);
    return o;
}

pub fn eqlFold(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// parse.ReplaceMultipleWhitespace: runs of whitespace become one space, or one
/// newline when the run contains a newline.
pub fn replaceMultipleWhitespace(b: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < b.len) {
        if (isWhitespace(b[i])) {
            var nl = isNewline(b[i]);
            i += 1;
            while (i < b.len and isWhitespace(b[i])) : (i += 1) {
                if (isNewline(b[i])) nl = true;
            }
            out.append(sys.A, if (nl) '\n' else ' ') catch {};
        } else {
            out.append(sys.A, b[i]) catch {};
            i += 1;
        }
    }
    return out.items;
}

fn lenInt(x: i64) usize {
    if (x < 0) {
        if (x == std.math.minInt(i64)) return 20;
        return 1 + lenUint(@intCast(-x));
    }
    return lenUint(@intCast(x));
}
fn lenUint(x: u64) usize {
    var n: usize = 1;
    var y = x;
    while (y >= 10) : (y /= 10) n += 1;
    return n;
}

fn parseIntPrefix(b: []const u8) struct { v: i64, n: usize } {
    var i: usize = 0;
    var neg = false;
    if (b.len > 0 and (b[0] == '+' or b[0] == '-')) {
        neg = b[0] == '-';
        i += 1;
    }
    const start = i;
    var n: u64 = 0;
    while (i < b.len and b[i] >= '0' and b[i] <= '9') : (i += 1) {
        const d: u64 = b[i] - '0';
        if (n > (@as(u64, 1) << 63) / 10 or (@as(u64, 1) << 63) - d < n * 10) return .{ .v = 0, .n = 0 };
        n = n * 10 + d;
    }
    if (i == start) return .{ .v = 0, .n = 0 };
    if (!neg and n > std.math.maxInt(i64)) return .{ .v = 0, .n = 0 };
    if (neg) {
        if (n == (@as(u64, 1) << 63)) return .{ .v = std.math.minInt(i64), .n = i };
        return .{ .v = -@as(i64, @intCast(n)), .n = i };
    }
    return .{ .v = @intCast(n), .n = i };
}

/// minify.Decimal: shortest decimal representation without exponents.
pub fn decimal(num_in: []const u8, prec: i64) []const u8 {
    if (num_in.len <= 1) return num_in;
    const num = sys.A.alloc(u8, num_in.len + 2) catch return num_in;
    @memcpy(num[0..num_in.len], num_in);
    var neg = false;
    var start: usize = 0;
    var dot: isize = -1;
    var end: usize = num_in.len;
    if (num[0] == '+' or num[0] == '-') {
        neg = num[0] == '-';
        start += 1;
    }
    for (num[start..end], 0..) |c, i| if (c == '.') {
        dot = @intCast(start + i);
        break;
    };
    if (dot == -1) dot = @intCast(end);
    while (start < end - 1 and num[start] == '0') start += 1;
    var i: isize = @as(isize, @intCast(end)) - 1;
    while (dot < i) : (i -= 1) {
        if (num[@intCast(i)] != '0') {
            end = @intCast(i + 1);
            break;
        }
    }
    const d: usize = @intCast(dot);
    if (i == dot) {
        end = d;
        if (start == end) {
            num[start] = '0';
            return num[start .. start + 1];
        }
    } else if (start == end - 1 and num[start] == '0') {
        return num[start..end];
    }
    if (0 < prec and d <= start + @as(usize, @intCast(prec))) {
        var prec_end = start + @as(usize, @intCast(prec)) + 1;
        if (d == start) {
            var digit = start + 1;
            while (digit < end and num[digit] == '0') digit += 1;
            prec_end = digit + @as(usize, @intCast(prec));
        }
        if (prec_end < end) {
            end = prec_end;
            var j: isize = @as(isize, @intCast(end)) - 1;
            var inc = '5' <= num[end];
            while (@as(isize, @intCast(start)) < j) : (j -= 1) {
                const ju: usize = @intCast(j);
                if (ju == d) {} else if (inc and num[ju] != '9') {
                    num[ju] += 1;
                    inc = false;
                    break;
                } else if (inc and ju < d) {
                    num[ju] = '0';
                } else if (!inc and (ju < d or num[ju] != '0')) break;
            }
            if (j < dot) end = d else end = @intCast(j + 1);
            if (inc) {
                if (d == start and end == start + 1) {
                    num[start] = '1';
                } else if (num[start] == '9') {
                    num[start] = '1';
                    num[start + 1] = '0';
                    end += 1;
                } else num[start] += 1;
            }
        }
    }
    if (neg) {
        start -= 1;
        num[start] = '-';
    }
    return num[start..end];
}

/// minify.Number: shortest representation, using exponents when shorter.
pub fn number(num_in: []const u8, prec: i64) []const u8 {
    if (num_in.len <= 1) return num_in;
    const N = num_in.len;
    const num = sys.A.alloc(u8, N + 24) catch return num_in;
    @memcpy(num[0..N], num_in);
    var neg = false;
    var start: isize = 0;
    var dot: isize = -1;
    var end: isize = @intCast(N);
    var orig_exp: i64 = 0;
    if (num[0] == '+' or num[0] == '-') {
        neg = num[0] == '-';
        start += 1;
    }
    {
        var k: usize = @intCast(start);
        while (k < N) : (k += 1) {
            const c = num[k];
            if (c == '.') {
                dot = @intCast(k);
            } else if (c == 'e' or c == 'E') {
                end = @intCast(k);
                var e = k + 1;
                if (e < N and num[e] == '+') e += 1;
                const r = parseIntPrefix(num_in[e..]);
                if (r.n > 0) orig_exp = r.v else return num_in;
                break;
            }
        }
    }
    if (dot == -1) dot = end;
    while (start < end - 1 and num[@intCast(start)] == '0') start += 1;
    var i: isize = end - 1;
    while (dot < i) : (i -= 1) {
        if (num[@intCast(i)] != '0') {
            end = i + 1;
            break;
        }
    }
    if (i == dot) {
        end = dot;
        if (start == end) {
            num[@intCast(start)] = '0';
            return num[@intCast(start)..@intCast(start + 1)];
        }
    } else if (start == end - 1 and num[@intCast(start)] == '0') {
        return num[@intCast(start)..@intCast(end)];
    }
    if (0 < prec) {
        var prec_end: isize = start + @as(isize, @intCast(prec));
        if (dot == start) {
            var digit = start + 1;
            while (digit < end and num[@intCast(digit)] == '0') digit += 1;
            prec_end = digit + @as(isize, @intCast(prec));
        } else if (dot < prec_end) prec_end += 1;
        if (prec_end < end and (dot < end or 1 < dot - prec_end + orig_exp)) {
            end = prec_end;
            var inc = '5' <= num[@intCast(end)];
            if (dot == end) inc = end + 1 < @as(isize, @intCast(N)) and '5' <= num[@intCast(end + 1)];
            if (prec_end < dot) {
                orig_exp += dot - prec_end;
                dot = prec_end;
            }
            var j: isize = end - 1;
            while (start < j) : (j -= 1) {
                const ju: usize = @intCast(j);
                if (j == dot) {} else if (inc and num[ju] != '9') {
                    num[ju] += 1;
                    inc = false;
                    break;
                } else if (!inc and num[ju] != '0') break;
            }
            end = j + 1;
            if (end < dot) {
                orig_exp += dot - end;
                dot = end;
            }
            if (inc) {
                const su: usize = @intCast(start);
                if (dot == start) {
                    num[su] = '1';
                    dot = start + 1;
                } else if (num[su] == '9') {
                    num[su] = '1';
                    orig_exp += 1;
                } else num[su] += 1;
            }
        }
    }
    var n: isize = 0;
    var norm_exp: i64 = 0;
    if (start == end) {
        return num_in;
    } else if (dot == start) {
        i = dot + 1;
        while (i < end) : (i += 1) {
            if (num[@intCast(i)] != '0') {
                n = end - i;
                norm_exp = dot - i + 1;
                break;
            }
        }
    } else if (dot == end) {
        norm_exp = end - start;
        i = end - 1;
        while (start <= i) : (i -= 1) {
            if (num[@intCast(i)] != '0') {
                n = i + 1 - start;
                end = i + 1;
                break;
            }
        }
    } else {
        n = end - start - 1;
        norm_exp = dot - start;
    }
    norm_exp += orig_exp;
    var int_exp: i64 = norm_exp - n;
    const len_int_exp: isize = @intCast(lenInt(int_exp));
    const len_norm_exp: isize = @intCast(lenInt(norm_exp));
    const B = struct {
        fn copy(buf: []u8, dst: isize, src_a: isize, src_b: isize) void {
            if (src_b <= src_a) return;
            const len: usize = @intCast(src_b - src_a);
            std.mem.copyForwards(u8, buf[@intCast(dst)..][0..len], buf[@intCast(src_a)..@intCast(src_b)]);
        }
        fn copyBack(buf: []u8, dst: isize, src_a: isize, src_b: isize) void {
            if (src_b <= src_a) return;
            const len: usize = @intCast(src_b - src_a);
            std.mem.copyBackwards(u8, buf[@intCast(dst)..][0..len], buf[@intCast(src_a)..@intCast(src_b)]);
        }
    };
    if (n <= norm_exp) {
        if (dot < end) {
            if (dot == start) {
                start = end - n;
            } else if (dot - start < end - dot - 1) {
                B.copyBack(num, start + 1, start, dot);
                start += 1;
            } else {
                B.copy(num, dot, dot + 1, end);
                end -= 1;
            }
        }
        if (n + 3 <= norm_exp) {
            num[@intCast(end)] = 'e';
            end += 1;
            var k: isize = end + len_int_exp - 1;
            while (end <= k) : (k -= 1) {
                num[@intCast(k)] = @intCast(@as(u8, @intCast(@mod(int_exp, 10))) + '0');
                int_exp = @divTrunc(int_exp, 10);
            }
            end += len_int_exp;
        } else if (n + 2 == norm_exp) {
            num[@intCast(end)] = '0';
            num[@intCast(end + 1)] = '0';
            end += 2;
        } else if (n + 1 == norm_exp) {
            num[@intCast(end)] = '0';
            end += 1;
        }
    } else if (norm_exp < -3 and len_norm_exp < len_int_exp and dot < end) {
        const zeroes: isize = @intCast(-norm_exp + orig_exp);
        if (0 < zeroes) {
            B.copy(num, start + 1, start + 1 + zeroes, end);
            end -= zeroes;
        } else if (zeroes < 0) {
            B.copyBack(num, start + 1, start, dot);
            num[@intCast(start)] = '.';
        } else return num_in;
        num[@intCast(end)] = 'e';
        num[@intCast(end + 1)] = '-';
        end += 2;
        var k: isize = end + len_norm_exp - 2;
        while (end <= k) : (k -= 1) {
            num[@intCast(k)] = @intCast(@as(i64, '0') - @rem(norm_exp, 10));
            norm_exp = @divTrunc(norm_exp, 10);
        }
        end += len_norm_exp - 1;
    } else if (-len_int_exp <= norm_exp) {
        const zeroes: isize = @intCast(-norm_exp);
        if (0 < zeroes) {
            var new_dot = end - n - zeroes - 1;
            if (new_dot != dot) {
                const d = start - new_dot;
                if (0 < d) {
                    if (dot < end) {
                        B.copyBack(num, dot + 1 + d, dot + 1, end);
                        if (start < dot) B.copyBack(num, start + d + 1, start, dot);
                    } else if (start < dot) {
                        B.copyBack(num, start + d, start, dot);
                    }
                    new_dot = start;
                    end += d;
                } else start += -d;
                num[@intCast(new_dot)] = '.';
                var z: isize = 0;
                while (z < zeroes) : (z += 1) num[@intCast(new_dot + 1 + z)] = '0';
            }
        } else {
            if (end <= dot) {
                dot = end;
                end += 1;
            } else if (dot == start) {
                dot = end - n - 1;
                start = dot;
            }
            const new_dot: isize = start + @as(isize, @intCast(norm_exp));
            if (dot < new_dot) {
                B.copy(num, dot, dot + 1, new_dot + 1);
            } else if (new_dot < dot) {
                B.copyBack(num, new_dot + 1, new_dot, dot);
            }
            num[@intCast(new_dot)] = '.';
        }
    } else {
        var new_end = end;
        if (dot == start) {
            new_end = dot + n;
        } else new_end -= 1;
        new_end += 1 + len_int_exp;
        var exp = int_exp;
        var len_exp = len_int_exp;
        if (new_end < @as(isize, @intCast(N))) {
            if (dot < end) {
                if (dot == start) {
                    B.copy(num, start, end - n, end);
                    end = start + n;
                } else {
                    B.copy(num, dot, dot + 1, end);
                    end -= 1;
                }
            }
        } else {
            exp = orig_exp;
            len_exp = @intCast(lenInt(orig_exp));
        }
        num[@intCast(end)] = 'e';
        num[@intCast(end + 1)] = '-';
        end += 2;
        var k: isize = end + len_exp - 2;
        while (end <= k) : (k -= 1) {
            num[@intCast(k)] = @intCast(@as(i64, '0') - @rem(exp, 10));
            exp = @divTrunc(exp, 10);
        }
        end += len_exp - 1;
    }
    if (neg) {
        start -= 1;
        num[@intCast(start)] = '-';
    }
    return num[@intCast(start)..@intCast(end)];
}

const data_uri_table = blk: {
    var t = @as([256]bool, @splat(true));
    for (0x21..0x7f) |c| t[c] = false;
    for ("\"#%&<>[\\]^`{|}") |c| t[c] = true;
    t[0x7f] = true;
    t[' '] = true;
    break :blk t;
};

fn decodeUrl(b: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < b.len) : (i += 1) {
        if (b[i] == '%' and i + 2 < b.len) {
            if (std.fmt.parseInt(u8, b[i + 1 .. i + 3], 16)) |x| {
                out.append(sys.A, x) catch {};
                i += 2;
                continue;
            } else |_| {}
        }
        out.append(sys.A, b[i]) catch {};
    }
    return out.items;
}

/// minify.DataURI: re-encodes a data: URI in its shortest form (the payload is
/// minified with the minifier for its media type when one exists).
pub fn dataUri(uri: []const u8) []const u8 {
    if (!(uri.len > 5 and std.mem.eql(u8, uri[0..5], "data:"))) return uri;
    const body = uri[5..];
    var in_b64 = false;
    var mediatype: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var data: []const u8 = undefined;
    var found = false;
    for (body, 0..) |c, j| {
        if (c == '=' or c == ';' or c == ',') {
            if (c != '=' and std.mem.eql(u8, trimWhitespace(body[i..j]), "base64")) {
                if (mediatype.items.len > 0) mediatype.items.len -= 1;
                in_b64 = true;
                i = j;
            } else if (c != ',') {
                mediatype.appendSlice(sys.A, trimWhitespace(body[i..j])) catch {};
                mediatype.append(sys.A, c) catch {};
                i = j + 1;
            } else mediatype.appendSlice(sys.A, trimWhitespace(body[i..j])) catch {};
            if (c == ',') {
                if (mediatype.items.len == 0 or mediatype.items[0] == ';') {
                    mediatype.clearRetainingCapacity();
                    mediatype.appendSlice(sys.A, "text/plain") catch {};
                }
                const raw = body[j + 1 ..];
                if (in_b64) {
                    const dec = std.base64.standard.Decoder;
                    const n = dec.calcSizeForSlice(raw) catch return uri;
                    const out = sys.A.alloc(u8, n) catch return uri;
                    dec.decode(out, raw) catch return uri;
                    data = out;
                } else data = decodeUrl(raw);
                found = true;
                break;
            }
        }
    }
    if (!found) return uri;
    data = minifyByMime(mediatype.items, data) orelse data;
    const b64_len = ";base64".len + std.base64.standard.Encoder.calcSize(data.len);
    var ascii_len = data.len;
    for (data) |c| {
        if (data_uri_table[c]) ascii_len += 2;
        if (ascii_len > b64_len) break;
    }
    if (uri.len < b64_len and uri.len < ascii_len) return uri;
    var mt: []const u8 = mediatype.items;
    var enc: std.ArrayList(u8) = .empty;
    if (b64_len < ascii_len) {
        const o = sys.A.alloc(u8, std.base64.standard.Encoder.calcSize(data.len)) catch return uri;
        enc.appendSlice(sys.A, std.base64.standard.Encoder.encode(o, data)) catch {};
        mt = std.mem.concat(sys.A, u8, &.{ mt, ";base64" }) catch mt;
    } else {
        for (data) |c| {
            if (data_uri_table[c]) {
                enc.append(sys.A, '%') catch {};
                enc.append(sys.A, "0123456789ABCDEF"[c >> 4]) catch {};
                enc.append(sys.A, "0123456789ABCDEF"[c & 15]) catch {};
            } else enc.append(sys.A, c) catch {};
        }
    }
    if (mt.len >= 10 and eqlFold(mt[0..10], "text/plain")) mt = mt[10..];
    const cs = ";charset=us-ascii";
    var k: usize = 0;
    while (k + cs.len <= mt.len) : (k += 1) {
        if (mt[k] == ';' and eqlFold(mt[k + 1 .. k + cs.len], cs[1..]) and (k + cs.len >= mt.len or mt[k + cs.len] == ';')) {
            mt = std.mem.concat(sys.A, u8, &.{ mt[0..k], mt[k + cs.len ..] }) catch mt;
            break;
        }
    }
    return std.mem.concat(sys.A, u8, &.{ "data:", mt, ",", enc.items }) catch uri;
}

/// Minifies `data` with the minifier registered for the media type (as
/// Hugo's minifier client does); null when none applies or it fails.
pub fn minifyByMime(mediatype: []const u8, data: []const u8) ?[]const u8 {
    const mt = blk: {
        const semi = std.mem.indexOfScalar(u8, mediatype, ';') orelse mediatype.len;
        break :blk std.mem.trim(u8, mediatype[0..semi], " ");
    };
    if (eqlFold(mt, "text/css")) return @import("min_css.zig").minify(data, false) catch null;
    if (eqlFold(mt, "text/html")) return @import("min_html.zig").minify(data) catch null;
    if (eqlFold(mt, "application/json") or eqlFold(mt, "application/manifest+json") or eqlFold(mt, "application/ld+json")) return @import("min_json.zig").minify(data) catch null;
    if (isJsMime(mt)) return @import("min_js.zig").minify(data, .{}) catch null;
    if (std.mem.eql(u8, mt, "image/svg+xml")) return @import("min_svg.zig").minifySvg(data, false) catch null;
    if (isXmlMime(mt)) return @import("min_svg.zig").minifyXml(data) catch null;
    return null;
}

/// Hugo's JS minifier regexp: ^(application|text)/(x-)?(java|ecma)script$
pub fn isJsMime(mt: []const u8) bool {
    var rest = mt;
    if (std.mem.startsWith(u8, rest, "application/")) {
        rest = rest[12..];
    } else if (std.mem.startsWith(u8, rest, "text/")) {
        rest = rest[5..];
    } else return false;
    if (std.mem.startsWith(u8, rest, "x-")) rest = rest[2..];
    return std.mem.eql(u8, rest, "javascript") or std.mem.eql(u8, rest, "ecmascript");
}

pub fn isCssMime(mt: []const u8) bool {
    return std.mem.eql(u8, mt, "text/css");
}
/// Hugo media types with the "xml" suffix.
pub fn isXmlMime(mt: []const u8) bool {
    return std.mem.eql(u8, mt, "application/xml") or std.mem.eql(u8, mt, "text/xml") or std.mem.eql(u8, mt, "application/rss+xml");
}

pub const JsError = error{JSMinifyError};
/// Minify JavaScript; escape_html is set for <script> elements without a type.
pub fn minifyJs(data: []const u8, escape_html: bool) JsError![]const u8 {
    return @import("min_js.zig").minify(data, .{ .escape_html = escape_html }) catch error.JSMinifyError;
}

/// JavaScript in event handler attributes (minified inline).
pub fn minifyInlineJs(src: []const u8) ?[]const u8 {
    return @import("min_js.zig").minify(src, .{ .inline_ = true }) catch null;
}
