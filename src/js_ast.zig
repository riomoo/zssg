// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: tdewolff/parse (MIT, Copyright Taco de Wolff).
// The original notices and licences are kept in NOTICE and licenses/.
//! JavaScript AST and scopes: a port of tdewolff/parse/js ast.go (MIT).
const std = @import("std");
const sys = @import("sys.zig");
const lex = @import("js_lex.zig");
pub const TT = lex.TT;

pub fn L(comptime T: type) type {
    return std.ArrayList(T);
}

pub const OpPrec = u8;
pub const OpExpr: OpPrec = 0;
pub const OpAssign: OpPrec = 1;
pub const OpCoalesce: OpPrec = 2;
pub const OpOr: OpPrec = 3;
pub const OpAnd: OpPrec = 4;
pub const OpBitOr: OpPrec = 5;
pub const OpBitXor: OpPrec = 6;
pub const OpBitAnd: OpPrec = 7;
pub const OpEquals: OpPrec = 8;
pub const OpCompare: OpPrec = 9;
pub const OpShift: OpPrec = 10;
pub const OpAdd: OpPrec = 11;
pub const OpMul: OpPrec = 12;
pub const OpExp: OpPrec = 13;
pub const OpUnary: OpPrec = 14;
pub const OpUpdate: OpPrec = 15;
pub const OpLHS: OpPrec = 16;
pub const OpOpt: OpPrec = 17;
pub const OpCall: OpPrec = 18;
pub const OpNew: OpPrec = 19;
pub const OpMember: OpPrec = 20;
pub const OpPrimary: OpPrec = 21;

pub const DeclType = enum(u8) { NoDecl, VariableDecl, PrivateDecl, FunctionDecl, ArgumentDecl, LexicalDecl, CatchDecl, ExprDecl };

pub const Var = struct {
    data: []u8,
    link: ?*Var = null,
    uses: u16 = 0,
    decl: DeclType = .NoDecl,

    pub fn name(v0: *Var) []u8 {
        var v = v0;
        while (v.link) |l| v = l;
        return v.data;
    }
};

pub fn newVar(data: []u8, uses: u16, decl: DeclType) *Var {
    const v = sys.A.create(Var) catch unreachable;
    v.* = .{ .data = data, .uses = uses, .decl = decl };
    return v;
}

pub const VariableIndexingThreshold = 16;
const Indices = std.StringHashMap(L(i64));

pub const Scope = struct {
    parent: ?*Scope = null,
    func: ?*Scope = null,
    declared: L(*Var) = .empty,
    undeclared: L(*Var) = .empty,
    var_indices: ?*Indices = null,
    var_decls: L(*Node) = .empty,
    num_for_decls: usize = 0,
    num_func_args: usize = 0,
    num_arg_uses: usize = 0,
    is_global_or_func: bool = false,
    has_with: bool = false,

    fn idx(s: *Scope, name: []const u8) []i64 {
        if (s.var_indices.?.getPtr(name)) |p| return p.items;
        return &.{};
    }
    fn idxAppend(s: *Scope, name: []const u8, v: i64) void {
        const gop = s.var_indices.?.getOrPut(name) catch unreachable;
        if (!gop.found_existing) {
            // keys must be copies: identifiers are renamed in place later
            gop.key_ptr.* = sys.A.dupe(u8, name) catch unreachable;
            gop.value_ptr.* = .empty;
        }
        gop.value_ptr.append(sys.A, v) catch unreachable;
    }

    pub fn declare(s0: *Scope, decl: DeclType, name: []u8) ?*Var {
        var s = s0;
        var cur = s0;
        if (decl == .VariableDecl or decl == .FunctionDecl) {
            while (s != s.func.?) {
                if (s.findDeclared(name, false)) |v| {
                    if (v.decl != decl and v.decl != .CatchDecl) return null;
                }
                s = s.parent.?;
            }
        }
        if (s.findDeclared(name, true)) |v| {
            if ((@intFromEnum(DeclType.ArgumentDecl) < @intFromEnum(v.decl) or @intFromEnum(DeclType.FunctionDecl) < @intFromEnum(decl)) and v.decl != .ExprDecl) return null;
            if (v.decl == .ExprDecl) v.decl = decl;
            v.uses +%= 1;
            while (s != cur) {
                cur.addUndeclaredUnique(v);
                cur = cur.parent.?;
            }
            return v;
        }
        var found: ?*Var = null;
        if (decl != .ArgumentDecl) {
            if (s.var_indices != null) {
                for (s.idx(name)) |index| {
                    if (index < -@as(i64, @intCast(s.num_arg_uses))) {
                        const uv = s.undeclared.items[@intCast(-index - 1)];
                        if (0 < uv.uses and uv.decl == .NoDecl) {
                            found = uv;
                            break;
                        }
                    }
                }
            } else {
                var i: usize = s.num_arg_uses;
                while (i < s.undeclared.items.len) : (i += 1) {
                    const uv = s.undeclared.items[i];
                    if (0 < uv.uses and uv.decl == .NoDecl and std.mem.eql(u8, name, uv.data)) {
                        found = uv;
                        _ = s.undeclared.orderedRemove(i);
                        break;
                    }
                }
            }
        }
        const v = if (found) |f| blk: {
            f.decl = decl;
            break :blk f;
        } else newVar(name, 0, decl);
        v.uses +%= 1;
        s.addDeclared(&.{v});
        while (s != cur) {
            cur.addUndeclaredUnique(v);
            cur = cur.parent.?;
        }
        return v;
    }

    pub fn use(s: *Scope, name: []u8) *Var {
        var v = s.findDeclared(name, false);
        if (v == null) {
            v = s.findUndeclared(name);
            if (v == null) {
                v = newVar(name, 0, .NoDecl);
                s.addUndeclared(&.{v.?});
            }
        }
        v.?.uses +%= 1;
        return v.?;
    }

    pub fn findDeclared(s: *Scope, name: []const u8, skip_for: bool) ?*Var {
        const start: usize = if (skip_for) s.num_for_decls else 0;
        if (s.var_indices != null) {
            const ind = s.idx(name);
            var i = ind.len;
            while (i > 0) {
                i -= 1;
                if (@as(i64, @intCast(start)) <= ind[i]) return s.declared.items[@intCast(ind[i])];
                if (0 <= ind[i]) break;
            }
            return null;
        }
        var i = s.declared.items.len;
        while (i > start) {
            i -= 1;
            const v = s.declared.items[i];
            if (std.mem.eql(u8, name, v.data)) return v;
        }
        return null;
    }

    pub fn findUndeclared(s: *Scope, name: []const u8) ?*Var {
        if (s.var_indices != null) {
            for (s.idx(name)) |index| {
                if (index < 0) {
                    const v = s.undeclared.items[@intCast(-index - 1)];
                    if (0 < v.uses) return v;
                }
            }
            return null;
        }
        for (s.undeclared.items) |v| {
            if (0 < v.uses and std.mem.eql(u8, name, v.data)) return v;
        }
        return null;
    }

    pub fn addUndeclaredUnique(s: *Scope, v: *Var) void {
        if (s.var_indices != null) {
            for (s.idx(v.data)) |index| {
                if (index < 0 and s.undeclared.items[@intCast(-index - 1)] == v) return;
            }
        } else {
            for (s.undeclared.items) |o| if (o == v) return;
        }
        s.addUndeclared(&.{v});
    }

    fn buildVarIndices(s: *Scope) void {
        const m = sys.A.create(Indices) catch unreachable;
        m.* = Indices.init(sys.A);
        s.var_indices = m;
        for (s.declared.items, 0..) |v, i| s.idxAppend(v.data, @intCast(i));
        for (s.undeclared.items, 0..) |v, i| s.idxAppend(v.data, -@as(i64, @intCast(i)) - 1);
    }

    pub fn addDeclared(s: *Scope, vs: []const *Var) void {
        s.declared.appendSlice(sys.A, vs) catch unreachable;
        if (s.var_indices != null) {
            const offset = s.declared.items.len - vs.len;
            for (vs, 0..) |v, i| s.idxAppend(v.data, @intCast(offset + i));
        } else if (VariableIndexingThreshold <= s.declared.items.len + s.undeclared.items.len) {
            s.buildVarIndices();
        }
    }

    pub fn addUndeclared(s: *Scope, vs: []const *Var) void {
        s.undeclared.appendSlice(sys.A, vs) catch unreachable;
        if (s.var_indices != null) {
            const offset: i64 = @intCast(s.undeclared.items.len - vs.len + 1);
            for (vs, 0..) |v, i| s.idxAppend(v.data, -offset - @as(i64, @intCast(i)));
        } else if (VariableIndexingThreshold <= s.declared.items.len + s.undeclared.items.len) {
            s.buildVarIndices();
        }
    }

    pub fn markForStmt(s: *Scope) void {
        s.num_for_decls = s.declared.items.len;
        s.num_arg_uses = s.undeclared.items.len;
    }
    pub fn markFuncArgs(s: *Scope) void {
        s.num_func_args = s.declared.items.len;
        s.num_arg_uses = s.undeclared.items.len;
    }

    pub fn hoistUndeclared(s: *Scope) void {
        if (s.var_indices != null) {
            var n: usize = 0;
            const num_arg_uses = s.num_arg_uses;
            outer: for (s.undeclared.items, 0..) |v, i| {
                if (v.decl != .NoDecl) {
                    for (s.idx(v.data)) |index| {
                        if (0 <= index and s.declared.items[@intCast(index)] == v) {
                            if (i < num_arg_uses) s.num_arg_uses -= 1;
                            continue :outer;
                        }
                    }
                }
                s.undeclared.items[n] = v;
                n += 1;
            }
            if (n != s.undeclared.items.len) {
                s.undeclared.items.len = n;
                s.buildVarIndices();
            }
        }
        const parent = s.parent orelse return;
        var hoist: L(*Var) = .empty;
        loop: for (s.undeclared.items, 0..) |vorig, j| {
            if (0 < vorig.uses and vorig.decl == .NoDecl) {
                if (parent.var_indices != null) {
                    const ind = parent.idx(vorig.data);
                    var i = ind.len;
                    while (i > 0) {
                        i -= 1;
                        if (0 <= ind[i]) {
                            const v = parent.declared.items[@intCast(ind[i])];
                            v.uses +%= vorig.uses;
                            vorig.link = v;
                            s.undeclared.items[j] = v;
                            continue :loop;
                        }
                    }
                    for (ind) |index| {
                        if (index < 0) {
                            const v = parent.undeclared.items[@intCast(-index - 1)];
                            if (0 < v.uses) {
                                v.uses +%= vorig.uses;
                                vorig.link = v;
                                s.undeclared.items[j] = v;
                                continue :loop;
                            }
                        }
                    }
                    hoist.append(sys.A, vorig) catch unreachable;
                } else {
                    if (parent.findDeclared(vorig.data, false)) |v| {
                        v.uses +%= vorig.uses;
                        vorig.link = v;
                        s.undeclared.items[j] = v;
                    } else if (parent.findUndeclared(vorig.data)) |v| {
                        v.uses +%= vorig.uses;
                        vorig.link = v;
                        s.undeclared.items[j] = v;
                    } else hoist.append(sys.A, vorig) catch unreachable;
                }
            }
        }
        if (hoist.items.len > 0) parent.addUndeclared(hoist.items);
    }

    pub fn undeclareScope(s: *Scope) void {
        const parent = s.parent.?;
        var hoist: L(*Var) = .empty;
        loop: for (s.declared.items) |vorig| {
            if (parent.var_indices != null) {
                const ind = parent.idx(vorig.data);
                var i = ind.len;
                while (i > 0) {
                    i -= 1;
                    if (0 <= ind[i]) {
                        const v = parent.declared.items[@intCast(ind[i])];
                        v.uses +%= vorig.uses;
                        vorig.link = v;
                        continue :loop;
                    }
                }
                for (ind) |index| {
                    if (index < 0) {
                        const v = parent.undeclared.items[@intCast(-index - 1)];
                        if (0 < v.uses) {
                            v.uses +%= vorig.uses;
                            vorig.link = v;
                            continue :loop;
                        }
                    }
                }
                vorig.decl = .NoDecl;
                hoist.append(sys.A, vorig) catch unreachable;
            } else {
                if (parent.findDeclared(vorig.data, false)) |v| {
                    v.uses +%= vorig.uses;
                    vorig.link = v;
                } else if (parent.findUndeclared(vorig.data)) |v| {
                    v.uses +%= vorig.uses;
                    vorig.link = v;
                } else {
                    vorig.decl = .NoDecl;
                    hoist.append(sys.A, vorig) catch unreachable;
                }
            }
        }
        if (hoist.items.len > 0) parent.addUndeclared(hoist.items);
        s.declared.items.len = 0;
        s.undeclared.items.len = 0;
        s.var_indices = null;
    }

    pub fn unscope(s: *Scope) void {
        s.parent.?.addDeclared(s.declared.items);
        s.declared = .empty;
        s.undeclared = .empty;
        s.var_indices = null;
    }
};

// ---------------------------------------------------------------- nodes

pub const Literal = struct { tt: TT = 0, data: []u8 = &.{} };
pub const PropertyName = struct {
    literal: Literal = .{},
    computed: ?*Node = null,
    pub fn isSet(n: PropertyName) bool {
        return n.computed != null or n.literal.tt != lex.ErrorToken;
    }
    pub fn isComputed(n: PropertyName) bool {
        return n.computed != null;
    }
    pub fn isIdent(n: PropertyName, data: []const u8) bool {
        return n.computed == null and n.literal.tt == lex.IdentifierToken and std.mem.eql(u8, data, n.literal.data);
    }
};
pub const BindingElement = struct { binding: ?*Node = null, default: ?*Node = null };
pub const BindingArray = struct { list: L(BindingElement) = .empty, rest: ?*Node = null };
pub const BindingObjectItem = struct { key: ?*PropertyName = null, value: BindingElement = .{} };
pub const BindingObject = struct { list: L(BindingObjectItem) = .empty, rest: ?*Var = null };
pub const VarDecl = struct { tt: TT, list: L(BindingElement) = .empty, scope: ?*Scope = null, in_for: bool = false, in_for_in_of: bool = false };
pub const Params = struct { list: L(BindingElement) = .empty, rest: ?*Node = null };
pub const Block = struct { list: L(*Node) = .empty, scope: Scope = .{} };
pub const FuncDecl = struct { is_async: bool = false, generator: bool = false, name: ?*Var = null, params: Params = .{}, body: Block = .{} };
pub const ClassElementName = struct { pn: PropertyName = .{}, private: ?*Var = null };
pub const MethodDecl = struct { static: bool = false, is_async: bool = false, generator: bool = false, get: bool = false, set: bool = false, name: ClassElementName = .{}, params: Params = .{}, body: Block = .{} };
pub const Field = struct { static: bool = false, name: ClassElementName = .{}, init: ?*Node = null };
pub const ClassElement = struct { static_block: ?*Node = null, method: ?*Node = null, field: Field = .{} };
pub const ClassDecl = struct { name: ?*Var = null, extends: ?*Node = null, list: L(ClassElement) = .empty, scope: Scope = .{} };
pub const Element = struct { value: ?*Node = null, spread: bool = false };
pub const Property = struct { name: ?*PropertyName = null, spread: bool = false, value: ?*Node = null, init: ?*Node = null };
pub const TemplatePart = struct { value: []u8, expr: ?*Node };
pub const TemplateExpr = struct { tag: ?*Node = null, list: L(TemplatePart) = .empty, tail: []u8 = &.{}, prec: OpPrec = 0, optional: bool = false };
pub const IndexExpr = struct { x: *Node, y: ?*Node, prec: OpPrec, optional: bool };
pub const DotExpr = struct { x: *Node, y: *Node, prec: OpPrec, optional: bool };
pub const Arg = struct { value: ?*Node, rest: bool };
pub const Args = struct { list: L(Arg) = .empty };
pub const NewExpr = struct { x: ?*Node, args: ?*Args };
pub const CallExpr = struct { x: *Node, args: Args, prec: OpPrec, optional: bool };
pub const UnaryExpr = struct { op: TT, x: ?*Node };
pub const BinaryExpr = struct { op: TT, x: ?*Node, y: ?*Node };
pub const CondExpr = struct { cond: ?*Node, x: ?*Node, y: ?*Node };
pub const YieldExpr = struct { generator: bool = false, x: ?*Node = null };
pub const ArrowFunc = struct { is_async: bool = false, params: Params = .{}, body: Block = .{} };
pub const CaseClause = struct { tt: TT, cond: ?*Node, list: L(*Node) };
pub const Alias = struct { name: ?[]u8 = null, binding: ?[]u8 = null };

pub const Node = union(enum) {
    // bindings / expressions
    var_: *Var,
    binding_array: BindingArray,
    binding_object: BindingObject,
    var_decl: VarDecl,
    func_decl: FuncDecl,
    class_decl: ClassDecl,
    method_decl: MethodDecl,
    literal: Literal,
    array: L(Element),
    object: L(Property),
    template: TemplateExpr,
    group: ?*Node,
    index: IndexExpr,
    dot: DotExpr,
    new_target,
    import_meta,
    new: NewExpr,
    call: CallExpr,
    unary: UnaryExpr,
    binary: BinaryExpr,
    cond: CondExpr,
    yield: YieldExpr,
    arrow: ArrowFunc,
    comma: L(*Node),
    // statements
    comment: []u8,
    block: Block,
    empty,
    expr_stmt: ?*Node,
    if_stmt: struct { cond: ?*Node, body: ?*Node, else_: ?*Node },
    do_while: struct { cond: ?*Node, body: ?*Node },
    while_stmt: struct { cond: ?*Node, body: ?*Node },
    for_stmt: struct { init: ?*Node, cond: ?*Node, post: ?*Node, body: *Node },
    for_in: struct { init: ?*Node, value: ?*Node, body: *Node },
    for_of: struct { is_await: bool, init: ?*Node, value: ?*Node, body: *Node },
    switch_stmt: struct { init: ?*Node, list: L(CaseClause) = .empty, scope: Scope = .{} },
    branch: struct { tt: TT, label: ?[]u8 },
    return_stmt: ?*Node,
    with_stmt: struct { cond: ?*Node, body: ?*Node },
    labelled: struct { label: []u8, value: ?*Node },
    throw: ?*Node,
    try_stmt: struct { body: *Node, binding: ?*Node, catch_: ?*Node, finally: ?*Node },
    debugger,
    import_stmt: struct { list: ?L(Alias) = null, default: ?[]u8 = null, module: []u8 = &.{} },
    export_stmt: struct { list: L(Alias) = .empty, module: ?[]u8 = null, default: bool = false, decl: ?*Node = null },
    directive: []u8,
};

pub fn new(n: Node) *Node {
    const p = sys.A.create(Node) catch unreachable;
    p.* = n;
    return p;
}
pub fn newVarNode(v: *Var) *Node {
    return new(.{ .var_ = v });
}

/// Returns the Var when the node is a variable reference.
pub fn asVar(n: ?*Node) ?*Var {
    const x = n orelse return null;
    return switch (x.*) {
        .var_ => |v| v,
        else => null,
    };
}
