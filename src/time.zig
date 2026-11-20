// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: Go (BSD-3-Clause, Copyright The Go Authors) time; Hugo (Apache-2.0, Copyright The Hugo Authors); Unicode CLDR (Unicode-3.0, Copyright Unicode, Inc.).
// The original notices and licences are kept in NOTICE and licenses/.
//! Calendar math, date parsing and Go-layout formatting.
const std = @import("std");
const v = @import("value.zig");
const sys = @import("sys.zig");
pub const Time = v.Time;

pub const Civil = struct { year: i64, month: u8, day: u8, hour: u8, min: u8, sec: u8, wday: u8, yday: u16 };

pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civil(t: Time) Civil {
    const local = t.sec + t.off;
    const days = @divFloor(local, 86400);
    const rem = @mod(local, 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    if (m <= 2) y += 1;
    const jan1 = daysFromCivil(y, 1, 1);
    return .{
        .year = y,
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = @intCast(@divFloor(rem, 3600)),
        .min = @intCast(@divFloor(@mod(rem, 3600), 60)),
        .sec = @intCast(@mod(rem, 60)),
        .wday = @intCast(@mod(days + 4, 7)),
        .yday = @intCast(days - jan1 + 1),
    };
}

pub fn make(y: i64, mo: i64, d: i64, h: i64, mi: i64, s: i64, off: i32) Time {
    // normalise month overflow (AddDate support)
    var yy = y;
    var mm = mo - 1;
    yy += @divFloor(mm, 12);
    mm = @mod(mm, 12) + 1;
    return .{ .sec = daysFromCivil(yy, mm, 1) * 86400 + (d - 1) * 86400 + h * 3600 + mi * 60 + s - off, .off = off };
}

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

pub fn monthName(m: u8) []const u8 {
    return month_names[m - 1];
}

fn digits(s: []const u8, i: *usize, max: usize) ?i64 {
    var n: i64 = 0;
    var c: usize = 0;
    while (i.* < s.len and c < max and std.ascii.isDigit(s[i.*])) : (c += 1) {
        n = n * 10 + (s[i.*] - '0');
        i.* += 1;
    }
    return if (c == 0) null else n;
}

/// Parses ISO-ish dates: 2006-01-02, 2006-01-02T15:04:05Z, 2006-01-02 15:04:05 -0700, with fractions.
pub fn parse(str: []const u8) ?Time {
    const s = v.trimWs(str);
    var i: usize = 0;
    const y = digits(s, &i, 4) orelse return parseNamed(s);
    if (i != 4 or i >= s.len or s[i] != '-') return parseNamed(s);
    i += 1;
    const mo = digits(s, &i, 2) orelse return null;
    if (i >= s.len or s[i] != '-') return null;
    i += 1;
    const d = digits(s, &i, 2) orelse return null;
    var h: i64 = 0;
    var mi: i64 = 0;
    var sec: i64 = 0;
    var nsec: u32 = 0;
    var off: i32 = 0;
    if (i < s.len and (s[i] == 'T' or s[i] == 't' or s[i] == ' ')) {
        i += 1;
        h = digits(s, &i, 2) orelse return null;
        if (i < s.len and s[i] == ':') {
            i += 1;
            mi = digits(s, &i, 2) orelse return null;
            if (i < s.len and s[i] == ':') {
                i += 1;
                sec = digits(s, &i, 2) orelse return null;
                if (i < s.len and (s[i] == '.' or s[i] == ',')) {
                    i += 1;
                    var scale: u32 = 100_000_000;
                    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
                        nsec += (s[i] - '0') * scale;
                        scale /= 10;
                    }
                }
            }
        }
        while (i < s.len and s[i] == ' ') i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            const sign: i32 = if (s[i] == '-') -1 else 1;
            i += 1;
            const oh = digits(s, &i, 2) orelse return null;
            if (i < s.len and s[i] == ':') i += 1;
            const om = digits(s, &i, 2) orelse 0;
            off = sign * @as(i32, @intCast(oh * 3600 + om * 60));
        }
    }
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    var t = make(y, mo, d, h, mi, sec, off);
    t.nsec = nsec;
    return t;
}

/// "January 2, 2006", "Jan 2, 2006", "2 Jan 2006", RFC1123-ish "Mon, 02 Jan 2006 15:04:05 -0700"
fn parseNamed(s: []const u8) ?Time {
    var mo: ?i64 = null;
    var nums: [6]i64 = undefined;
    var nn: usize = 0;
    var off: i32 = 0;
    var it = std.mem.tokenizeAny(u8, s, " ,:");
    while (it.next()) |tok| {
        if (std.ascii.isDigit(tok[0])) {
            if (nn < 6) {
                nums[nn] = std.fmt.parseInt(i64, tok, 10) catch return null;
                nn += 1;
            }
        } else if ((tok[0] == '+' or tok[0] == '-') and tok.len == 5) {
            const n = std.fmt.parseInt(i32, tok[1..], 10) catch return null;
            off = (@divTrunc(n, 100) * 3600 + @mod(n, 100) * 60) * @as(i32, if (tok[0] == '-') -1 else 1);
        } else if (tok.len >= 3) {
            for (month_names, 1..) |mn, idx| if (v.eqi(mn[0..3], tok[0..3]) and (tok.len == 3 or v.eqi(mn, tok))) {
                mo = @intCast(idx);
            };
        }
    }
    const m = mo orelse return null;
    if (nn < 2) return null;
    var d = nums[0];
    var y = nums[1];
    if (d > 31) std.mem.swap(i64, &d, &y);
    return make(y, m, d, if (nn > 2) nums[2] else 0, if (nn > 3) nums[3] else 0, if (nn > 4) nums[4] else 0, off);
}

fn pad(b: *v.Buf, n: i64, width: usize, fill: u8) void {
    const s = v.fmt("{d}", .{n});
    var k = s.len;
    while (k < width) : (k += 1) b.ch(fill);
    b.add(s);
}

fn zone(b: *v.Buf, off: i32, colon: bool, z: bool, short: bool) void {
    if (z and off == 0) return b.ch('Z');
    const a: i32 = if (off < 0) -off else off;
    b.ch(if (off < 0) '-' else '+');
    pad(b, @divTrunc(a, 3600), 2, '0');
    if (short) return;
    if (colon) b.ch(':');
    pad(b, @divTrunc(@mod(a, 3600), 60), 2, '0');
}

/// Format using a Go reference layout ("Mon Jan 2 15:04:05 MST 2006") or a Hugo :date_xxx token.
pub fn format(t: Time, layout_in: []const u8) []const u8 {
    var layout = layout_in;
    if (v.eq(layout, ":date_full")) layout = "Monday, January 2, 2006";
    if (v.eq(layout, ":date_long")) layout = "January 2, 2006";
    if (v.eq(layout, ":date_medium")) layout = "Jan 2, 2006";
    if (v.eq(layout, ":date_short")) layout = "1/2/06";
    if (v.eq(layout, ":time_full") or v.eq(layout, ":time_long")) layout = "3:04:05 pm MST";
    if (v.eq(layout, ":time_medium")) layout = "3:04:05 pm";
    if (v.eq(layout, ":time_short")) layout = "3:04 pm";
    const c = civil(t);
    var b: v.Buf = .{};
    var i: usize = 0;
    const L = layout;
    while (i < L.len) {
        const r = L[i..];
        if (v.startsWith(r, "January")) {
            b.add(month_names[c.month - 1]);
            i += 7;
        } else if (v.startsWith(r, "Jan")) {
            b.add(month_names[c.month - 1][0..3]);
            i += 3;
        } else if (v.startsWith(r, "Monday")) {
            b.add(day_names[c.wday]);
            i += 6;
        } else if (v.startsWith(r, "Mon")) {
            b.add(day_names[c.wday][0..3]);
            i += 3;
        } else if (v.startsWith(r, "MST")) {
            if (t.off == 0) b.add("UTC") else zone(&b, t.off, false, false, true);
            i += 3;
        } else if (v.startsWith(r, "2006")) {
            pad(&b, c.year, 4, '0');
            i += 4;
        } else if (v.startsWith(r, "Z07:00")) {
            zone(&b, t.off, true, true, false);
            i += 6;
        } else if (v.startsWith(r, "Z0700")) {
            zone(&b, t.off, false, true, false);
            i += 5;
        } else if (v.startsWith(r, "-07:00")) {
            zone(&b, t.off, true, false, false);
            i += 6;
        } else if (v.startsWith(r, "-0700")) {
            zone(&b, t.off, false, false, false);
            i += 5;
        } else if (v.startsWith(r, "-07")) {
            zone(&b, t.off, false, false, true);
            i += 3;
        } else if (v.startsWith(r, "002")) {
            pad(&b, c.yday, 3, '0');
            i += 3;
        } else if (v.startsWith(r, "01")) {
            pad(&b, c.month, 2, '0');
            i += 2;
        } else if (v.startsWith(r, "02")) {
            pad(&b, c.day, 2, '0');
            i += 2;
        } else if (v.startsWith(r, "03")) {
            pad(&b, if (c.hour % 12 == 0) 12 else c.hour % 12, 2, '0');
            i += 2;
        } else if (v.startsWith(r, "04")) {
            pad(&b, c.min, 2, '0');
            i += 2;
        } else if (v.startsWith(r, "05")) {
            pad(&b, c.sec, 2, '0');
            i += 2;
        } else if (v.startsWith(r, "06")) {
            pad(&b, @mod(c.year, 100), 2, '0');
            i += 2;
        } else if (v.startsWith(r, "15")) {
            pad(&b, c.hour, 2, '0');
            i += 2;
        } else if (v.startsWith(r, "_2")) {
            pad(&b, c.day, 2, ' ');
            i += 2;
        } else if (v.startsWith(r, "PM")) {
            b.add(if (c.hour >= 12) "PM" else "AM");
            i += 2;
        } else if (v.startsWith(r, "pm")) {
            b.add(if (c.hour >= 12) "pm" else "am");
            i += 2;
        } else if ((r[0] == '.' or r[0] == ',') and r.len > 1 and (r[1] == '0' or r[1] == '9')) {
            var n: usize = 1;
            while (n < r.len and r[n] == r[1]) n += 1;
            if (n < r.len and std.ascii.isDigit(r[n])) {
                b.ch(r[0]);
                i += 1;
                continue;
            }
            const frac = v.fmt("{d:0>9}", .{t.nsec});
            if (r[1] == '0') {
                b.ch(r[0]);
                b.add(frac[0..@min(n - 1, 9)]);
            } else {
                const tr = std.mem.trimEnd(u8, frac[0..@min(n - 1, 9)], "0");
                if (tr.len > 0) {
                    b.ch(r[0]);
                    b.add(tr);
                }
            }
            i += n;
        } else if (r[0] == '1') {
            pad(&b, c.month, 1, '0');
            i += 1;
        } else if (r[0] == '2') {
            pad(&b, c.day, 1, '0');
            i += 1;
        } else if (r[0] == '3') {
            pad(&b, if (c.hour % 12 == 0) 12 else c.hour % 12, 1, '0');
            i += 1;
        } else if (r[0] == '4') {
            pad(&b, c.min, 1, '0');
            i += 1;
        } else if (r[0] == '5') {
            pad(&b, c.sec, 1, '0');
            i += 1;
        } else {
            b.ch(r[0]);
            i += 1;
        }
    }
    return b.str();
}

pub fn toString(t: Time) []const u8 {
    if (t.zero) return "0001-01-01 00:00:00 +0000 UTC";
    return format(t, "2006-01-02 15:04:05 -0700 MST");
}

pub const zero: Time = .{ .sec = -62135596800, .zero = true };

// ---------------------------------------------------------------- locale-aware formatting

const loc = @import("locales_data.zig");

fn findLocale(lang: []const u8) ?*const loc.Locale {
    var buf: [32]u8 = undefined;
    if (lang.len == 0 or lang.len > buf.len) return null;
    for (lang, 0..) |ch, i| buf[i] = if (ch == '_') '-' else std.ascii.toLower(ch);
    const l = buf[0..lang.len];
    for (&loc.locales) |*x| if (std.mem.eql(u8, x.id, l)) return x;
    if (std.mem.indexOfScalar(u8, l, '-')) |d| {
        for (&loc.locales) |*x| if (std.mem.eql(u8, x.id, l[0..d])) return x;
    }
    return null;
}

fn replaceAll(s: []const u8, from: []const u8, to: []const u8) []const u8 {
    if (from.len == 0 or std.mem.eql(u8, from, to)) return s;
    return std.mem.replaceOwned(u8, sys.A, s, from, to) catch s;
}

/// Hugo's htime.TimeFormatter: Go layout formatting with month and weekday names
/// translated for the language, and :date_* layouts from CLDR patterns.
pub fn formatLocale(t: Time, layout: []const u8, lang: []const u8) []const u8 {
    const l = findLocale(lang) orelse findLocale("en").?;
    if (layout.len > 0 and layout[0] == ':') {
        const k = layout[1..];
        const pat: ?[]const u8 = if (std.ascii.eqlIgnoreCase(k, "date_full")) l.date_full else if (std.ascii.eqlIgnoreCase(k, "date_long")) l.date_long else if (std.ascii.eqlIgnoreCase(k, "date_medium")) l.date_medium else if (std.ascii.eqlIgnoreCase(k, "date_short")) l.date_short else null;
        if (pat) |p| return cldrFormat(t, p, l);
    }
    var s = format(t, layout);
    const c = civil(t);
    if (v.indexOf(layout, "January") != null) {
        s = replaceAll(s, month_names[c.month - 1], l.months[c.month - 1]);
    } else if (v.indexOf(layout, "Jan") != null) {
        s = replaceAll(s, month_names[c.month - 1][0..3], l.months_abbr[c.month - 1]);
    }
    if (v.indexOf(layout, "Monday") != null) {
        s = replaceAll(s, day_names[c.wday], l.days[c.wday]);
    } else if (v.indexOf(layout, "Mon") != null) {
        s = replaceAll(s, day_names[c.wday][0..3], l.days_abbr[c.wday]);
    }
    return s;
}

fn cldrFormat(t: Time, pat: []const u8, l: *const loc.Locale) []const u8 {
    const c = civil(t);
    var b: v.Buf = .{};
    var i: usize = 0;
    while (i < pat.len) {
        const ch = pat[i];
        if (ch == '\'') {
            if (i + 1 < pat.len and pat[i + 1] == '\'') {
                b.ch('\'');
                i += 2;
                continue;
            }
            var j = i + 1;
            while (j < pat.len and pat[j] != '\'') : (j += 1) b.ch(pat[j]);
            i = j + 1;
            continue;
        }
        if (std.ascii.isAlphabetic(ch)) {
            var j = i;
            while (j < pat.len and pat[j] == ch) j += 1;
            const n = j - i;
            switch (ch) {
                'y' => if (n == 2) pad(&b, @mod(c.year, 100), 2, '0') else pad(&b, c.year, n, '0'),
                'M', 'L' => if (n >= 4) b.add(l.months[c.month - 1]) else if (n == 3) b.add(l.months_abbr[c.month - 1]) else pad(&b, c.month, n, '0'),
                'd' => pad(&b, c.day, n, '0'),
                'E', 'c' => if (n >= 4) b.add(l.days[c.wday]) else b.add(l.days_abbr[c.wday]),
                else => b.add(pat[i..j]),
            }
            i = j;
            continue;
        }
        b.ch(ch);
        i += 1;
    }
    return b.str();
}
