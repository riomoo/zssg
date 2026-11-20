// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
//! Thin system layer: every std.Io / fs / process call ZSSG makes lives here,
//! so the rest of the code base is insulated from std churn between Zig releases.
const std = @import("std");

/// The allocator for the current thread: the build's arena on the main thread,
/// a per-job arena on image worker threads.
pub threadlocal var A: std.mem.Allocator = undefined;
/// On image worker threads: warnings are collected here (page allocator) and
/// reported by the main thread.
pub threadlocal var worker_msgs: ?*std.ArrayList([]const u8) = null;
/// The build's arena (main thread only, or under `lock`).
pub var main_A: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;
pub var environ: *std.process.Environ.Map = undefined;

const Dir = std.Io.Dir;

pub fn readFile(path: []const u8) ?[]u8 {
    return Dir.cwd().readFileAlloc(io, path, A, .unlimited) catch null;
}

pub fn mkdirAll(path: []const u8) void {
    if (path.len == 0) return;
    Dir.cwd().createDirPath(io, path) catch {};
}

pub fn dirname(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) if (path[i - 1] == '/') return path[0 .. i - 1];
    return "";
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    mkdirAll(dirname(path));
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub const Kind = enum { file, dir, none };

pub fn kindOf(path: []const u8) Kind {
    const st = Dir.cwd().statFile(io, path, .{}) catch return .none;
    return switch (st.kind) {
        .directory => .dir,
        else => .file,
    };
}

pub fn exists(path: []const u8) bool {
    return kindOf(path) != .none;
}

pub const Stat = struct { size: u64, mtime: i64 };

pub fn stat(path: []const u8) ?Stat {
    const st = Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .size = st.size, .mtime = st.mtime.toSeconds() };
}

pub const Entry = struct { name: []const u8, is_dir: bool };

fn entryLess(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Sorted directory listing; empty slice if the directory does not exist.
pub fn listDir(path: []const u8) []Entry {
    var out: std.ArrayList(Entry) = .empty;
    var d = Dir.cwd().openDir(io, if (path.len == 0) "." else path, .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        var is_dir = e.kind == .directory;
        if (e.kind == .sym_link) {
            const full = std.fmt.allocPrint(A, "{s}/{s}", .{ path, e.name }) catch continue;
            is_dir = kindOf(full) == .dir;
        }
        out.append(A, .{ .name = A.dupe(u8, e.name) catch continue, .is_dir = is_dir }) catch {};
    }
    std.mem.sort(Entry, out.items, {}, entryLess);
    return out.items;
}

/// Recursive listing of files, paths relative to `root`, '/' separated, sorted.
pub fn walk(root: []const u8) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    walkInto(root, "", &out);
    return out.items;
}

fn walkInto(root: []const u8, rel: []const u8, out: *std.ArrayList([]const u8)) void {
    const full = if (rel.len == 0) root else std.fmt.allocPrint(A, "{s}/{s}", .{ root, rel }) catch return;
    for (listDir(full)) |e| {
        const r = if (rel.len == 0) e.name else std.fmt.allocPrint(A, "{s}/{s}", .{ rel, e.name }) catch continue;
        if (e.is_dir) walkInto(root, r, out) else out.append(A, r) catch {};
    }
}

pub fn copyFile(src: []const u8, dst: []const u8) !void {
    mkdirAll(dirname(dst));
    try Dir.copyFile(Dir.cwd(), src, Dir.cwd(), dst, io, .{});
}

pub fn removeTree(path: []const u8) void {
    Dir.cwd().deleteTree(io, path) catch {};
}

pub fn nowSeconds() i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

pub fn nowMillis() i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

pub fn getenv(name: []const u8) ?[]const u8 {
    return environ.get(name);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(A, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}

pub fn eprint(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(A, fmt, args) catch return;
    std.Io.File.stderr().writeStreamingAll(io, s) catch {};
}

pub const RunResult = struct { ok: bool, stdout: []const u8, stderr: []const u8 };

/// Run an external program (used for Dart Sass). Returns null if it cannot be spawned.
pub fn run(argv: []const []const u8) ?RunResult {
    const r = std.process.run(A, io, .{ .argv = argv }) catch return null;
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = r.stdout, .stderr = r.stderr };
}

/// Directory for temporary files (outside the project, so tools that scan the
/// project tree do not see them).
pub fn tmpDir() []const u8 {
    return getenv("TMPDIR") orelse "/tmp";
}

pub const RunCode = struct { code: i32, stdout: []const u8, stderr: []const u8 };

/// Like run, but reports the exit code (-1 when killed by a signal).
pub fn runCode(argv: []const []const u8) ?RunCode {
    const r = std.process.run(A, io, .{ .argv = argv }) catch return null;
    const code: i32 = switch (r.term) {
        .exited => |c| c,
        else => -1,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

/// Absolute real path (symlinks resolved); the input if it cannot be resolved.
pub fn absPath(path: []const u8) []const u8 {
    return Dir.cwd().realPathFileAlloc(io, path, A) catch path;
}

/// Absolute path without resolving symlinks (relative paths joined to the cwd).
pub fn absNoResolve(path: []const u8) []const u8 {
    if (path.len > 0 and path[0] == '/') return std.fs.path.resolve(A, &.{path}) catch path;
    const cwd = std.process.currentPathAlloc(io, A) catch return path;
    return std.fs.path.resolve(A, &.{ cwd, path }) catch path;
}

var pid_counter: std.atomic.Value(u32) = .init(0);
/// A per-run unique number for temporary file names.
pub fn pid() u64 {
    const n = pid_counter.fetchAdd(1, .monotonic) + 1;
    return @as(u64, @intCast(@mod(nowMillis(), 1000000))) * 100000 + n;
}

/// Reads at most `max` bytes from the start of a file.
pub fn readFilePrefix(path: []const u8, max: usize) ?[]u8 {
    const f = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const buf = A.alloc(u8, max) catch return null;
    const n = f.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..n];
}

// ---- threads (image workers)

pub const Mutex = std.Io.Mutex;
pub const Condition = std.Io.Condition;
pub fn lock(m: *Mutex) void {
    m.lockUncancelable(io);
}
pub fn unlock(m: *Mutex) void {
    m.unlock(io);
}
pub fn wait(c: *Condition, m: *Mutex) void {
    c.waitUncancelable(io, m);
}
pub fn broadcast(c: *Condition) void {
    c.broadcast(io);
}
pub fn cpuCount() usize {
    return std.Thread.getCpuCount() catch 1;
}
pub fn spawn(comptime f: anytype, args: anytype) ?std.Thread {
    return std.Thread.spawn(.{}, f, args) catch null;
}
