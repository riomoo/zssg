// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: tdewolff/minify and tdewolff/parse (MIT, Copyright Taco de Wolff).
// The original notices and licences are kept in NOTICE and licenses/.
//! JavaScript minifier: a port of tdewolff/minify/js (MIT), matching Hugo's
//! defaults (Version 2022, Precision 0, variable renaming on).
const std = @import("std");
const sys = @import("sys.zig");
const lex = @import("js_lex.zig");
const ast = @import("js_ast.zig");
const jsp = @import("js_parse.zig");
const min = @import("min.zig");
const Node = ast.Node;
const Var = ast.Var;
const Scope = ast.Scope;
const TT = lex.TT;
const L = ast.L;
const OpPrec = ast.OpPrec;
const A = &sys.A;

const version: i64 = 2022;
const precision: i64 = 0;
const keep_var_names = false;

fn minVersion(v: i64) bool {
    return version == 0 or v <= version;
}

pub const Options = struct { inline_: bool = false, escape_html: bool = false };

pub fn minify(src: []const u8, o: Options) ![]const u8 {
    const buf = try sys.A.dupe(u8, src);
    const tree = try jsp.parse(buf, .{ .while_to_for = true, .inline_ = o.inline_ });
    var m = M{ .renamer = Renamer.init(!keep_var_names, true), .escape_html = o.escape_html };
    m.hoistVars(&tree.block);
    tree.block.list = optimizeStmtList(tree.block.list, .function);
    for (tree.block.list.items) |item| {
        m.writeSemicolon();
        m.minifyStmt(item);
    }
    return m.out.items;
}

const BlockType = enum { default, function, iteration };
const ExpectExpr = enum { any, stmt, body };

fn isV(n: ?*Node) ?*Var {
    return ast.asVar(n);
}
fn tag(n: ?*Node) ?std.meta.Tag(Node) {
    const x = n orelse return null;
    return std.meta.activeTag(x.*);
}
fn newN(n: Node) *Node {
    return ast.new(n);
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const M = struct {
    out: std.ArrayList(u8) = .empty,
    prev: []const u8 = "",
    needs_semicolon: bool = false,
    needs_space: bool = false,
    expect_expr: ExpectExpr = .any,
    grouped_stmt: bool = false,
    in_for: bool = false,
    space_before: u8 = 0,
    escape_html: bool = false,
    renamer: Renamer,

    fn raw(m: *M, b: []const u8) void {
        m.out.appendSlice(sys.A, b) catch {};
    }

    fn write(m: *M, b: []const u8) void {
        if ((m.needs_space and lex.isIdentifierContinueStr(b)) or (b.len > 0 and m.space_before == b[0])) m.raw(" ");
        m.raw(b);
        m.prev = b;
        m.needs_space = false;
        m.expect_expr = .any;
        m.space_before = 0;
    }
    fn writeSpaceAfterIdent(m: *M) void {
        if (lex.isIdentifierEndStr(m.prev) or (1 < m.prev.len and m.prev[0] == '/')) m.raw(" ");
    }
    fn writeSpaceBeforeIdent(m: *M) void {
        m.needs_space = true;
    }
    fn writeSpaceBefore(m: *M, c: u8) void {
        m.space_before = c;
    }
    fn requireSemicolon(m: *M) void {
        m.needs_semicolon = true;
    }
    fn writeSemicolon(m: *M) void {
        if (m.needs_semicolon) {
            m.raw(";");
            m.needs_semicolon = false;
            m.needs_space = false;
        }
    }
    fn prevLast(m: *M) u8 {
        return if (m.prev.len > 0) m.prev[m.prev.len - 1] else 0;
    }

    fn minifyStmt(m: *M, n: *Node) void {
        switch (n.*) {
            .expr_stmt => |v| {
                m.expect_expr = .stmt;
                m.minifyExpr(v, ast.OpExpr);
                if (m.grouped_stmt) {
                    m.write(")");
                    m.grouped_stmt = false;
                }
                m.requireSemicolon();
            },
            .var_decl => {
                m.minifyVarDecl(n, false);
                m.requireSemicolon();
            },
            .if_stmt => |*s| {
                const has_if = !isEmptyStmt(s.body);
                const has_else = !isEmptyStmt(s.else_);
                if (!has_if and !has_else) return;
                m.write("if(");
                m.minifyExpr(s.cond, ast.OpExpr);
                m.write(")");
                if (!has_if and has_else) {
                    m.requireSemicolon();
                } else if (has_if) {
                    if (has_else and endsInIf(s.body)) {
                        m.write("{");
                        m.minifyStmt(s.body.?);
                        m.write("}");
                        m.needs_semicolon = false;
                    } else m.minifyStmt(s.body.?);
                }
                if (has_else) {
                    m.writeSemicolon();
                    m.write("else");
                    m.writeSpaceBeforeIdent();
                    m.minifyStmt(s.else_.?);
                }
            },
            .block => |*b| {
                m.renamer.renameScope(&b.scope);
                m.minifyBlockStmt(b);
            },
            .return_stmt => |v| {
                m.write("return");
                m.writeSpaceBeforeIdent();
                m.minifyExpr(v, ast.OpExpr);
                m.requireSemicolon();
            },
            .labelled => |s| {
                m.write(s.label);
                m.write(":");
                m.minifyStmtOrBlock(s.value, .default);
            },
            .branch => |s| {
                m.write(lex.ttBytes(s.tt));
                if (s.label) |lb| {
                    m.write(" ");
                    m.write(lb);
                }
                m.requireSemicolon();
            },
            .with_stmt => |s| {
                m.write("with(");
                m.minifyExpr(s.cond, ast.OpExpr);
                m.write(")");
                m.minifyStmtOrBlock(s.body, .default);
            },
            .do_while => |s| {
                m.write("do");
                m.writeSpaceBeforeIdent();
                m.minifyStmtOrBlock(s.body, .iteration);
                m.writeSemicolon();
                m.write("while(");
                m.minifyExpr(s.cond, ast.OpExpr);
                m.write(")");
            },
            .while_stmt => |s| {
                m.write("while(");
                m.minifyExpr(s.cond, ast.OpExpr);
                m.write(")");
                m.minifyStmtOrBlock(s.body, .iteration);
            },
            .for_stmt => |*s| {
                const body = &s.body.block;
                body.list = optimizeStmtList(body.list, .iteration);
                m.renamer.renameScope(&body.scope);
                m.write("for(");
                m.in_for = true;
                if (tag(s.init) == .var_decl) m.minifyVarDecl(s.init.?, true) else m.minifyExpr(s.init, ast.OpLHS);
                m.in_for = false;
                m.write(";");
                m.minifyExpr(s.cond, ast.OpExpr);
                m.write(";");
                m.minifyExpr(s.post, ast.OpExpr);
                m.write(")");
                m.minifyBlockAsStmt(body);
            },
            .for_in => |*s| {
                const body = &s.body.block;
                body.list = optimizeStmtList(body.list, .iteration);
                m.renamer.renameScope(&body.scope);
                m.write("for(");
                m.in_for = true;
                if (tag(s.init) == .var_decl) m.minifyVarDecl(s.init.?, false) else m.minifyExpr(s.init, ast.OpLHS);
                m.in_for = false;
                m.writeSpaceAfterIdent();
                m.write("in");
                m.writeSpaceBeforeIdent();
                m.minifyExpr(s.value, ast.OpExpr);
                m.write(")");
                m.minifyBlockAsStmt(body);
            },
            .for_of => |*s| {
                const body = &s.body.block;
                body.list = optimizeStmtList(body.list, .iteration);
                m.renamer.renameScope(&body.scope);
                m.write(if (s.is_await) "for await(" else "for(");
                m.in_for = true;
                if (tag(s.init) == .var_decl) m.minifyVarDecl(s.init.?, false) else m.minifyExpr(s.init, ast.OpLHS);
                m.in_for = false;
                m.writeSpaceAfterIdent();
                m.write("of");
                m.writeSpaceBeforeIdent();
                m.minifyExpr(s.value, ast.OpAssign);
                m.write(")");
                m.minifyBlockAsStmt(body);
            },
            .switch_stmt => |*s| {
                m.write("switch(");
                m.minifyExpr(s.init, ast.OpExpr);
                m.write("){");
                m.needs_semicolon = false;
                for (s.list.items) |*c| c.list = optimizeStmtList(c.list, .default);
                m.renamer.renameScope(&s.scope);
                for (s.list.items) |c| {
                    m.writeSemicolon();
                    m.write(lex.ttBytes(c.tt));
                    if (c.cond) |cond| {
                        m.writeSpaceBeforeIdent();
                        m.minifyExpr(cond, ast.OpExpr);
                    }
                    m.write(":");
                    for (c.list.items) |item| {
                        m.writeSemicolon();
                        m.minifyStmt(item);
                    }
                }
                m.write("}");
                m.needs_semicolon = false;
            },
            .throw => |v| {
                m.write("throw");
                m.writeSpaceBeforeIdent();
                m.minifyExpr(v, ast.OpExpr);
                m.requireSemicolon();
            },
            .try_stmt => |*s| {
                m.write("try");
                const body = &s.body.block;
                body.list = optimizeStmtList(body.list, .default);
                m.renamer.renameScope(&body.scope);
                m.minifyBlockStmt(body);
                if (s.catch_) |cn| {
                    const c = &cn.block;
                    m.write("catch");
                    c.list = optimizeStmtList(c.list, .default);
                    if (isV(s.binding)) |v| {
                        if (v.uses == 1 and minVersion(2019)) {
                            if (c.scope.declared.items.len > 0) _ = c.scope.declared.orderedRemove(0);
                            s.binding = null;
                        }
                    }
                    m.renamer.renameScope(&c.scope);
                    if (s.binding) |b| {
                        m.write("(");
                        m.minifyBinding(b);
                        m.write(")");
                    }
                    m.minifyBlockStmt(c);
                }
                if (s.finally) |fnode| {
                    const f = &fnode.block;
                    m.write("finally");
                    f.list = optimizeStmtList(f.list, .default);
                    m.renamer.renameScope(&f.scope);
                    m.minifyBlockStmt(f);
                }
            },
            .func_decl => m.minifyFuncDecl(n, false),
            .class_decl => m.minifyClassDecl(&n.class_decl),
            .debugger => {
                m.write("debugger");
                m.requireSemicolon();
            },
            .empty => {},
            .import_stmt => |s| {
                if (s.default != null or s.list == null or 0 < s.list.?.items.len) {
                    m.write("import");
                    if (s.default) |d| {
                        m.write(" ");
                        m.write(d);
                        if (s.list != null) m.write(",") else m.write(" ");
                    }
                    if (s.list) |list| {
                        if (list.items.len == 1 and list.items[0].name != null and eql(list.items[0].name.?, "*")) {
                            m.writeSpaceBeforeIdent();
                            m.minifyAlias(list.items[0]);
                            m.write(" ");
                        } else {
                            m.write("{");
                            for (list.items, 0..) |item, i| {
                                if (i != 0) m.write(",");
                                m.minifyAlias(item);
                            }
                            m.write("}");
                        }
                    }
                    if (s.default != null or s.list != null) m.write("from");
                    m.write(minifyString(s.module, false, m.escape_html));
                    m.requireSemicolon();
                }
            },
            .export_stmt => |s| {
                m.write("export");
                if (s.decl) |decl| {
                    if (s.default) {
                        m.write(" default");
                        m.writeSpaceBeforeIdent();
                        m.minifyExpr(decl, ast.OpAssign);
                        if (decl.* != .func_decl and decl.* != .class_decl) m.requireSemicolon();
                    } else {
                        m.writeSpaceBeforeIdent();
                        m.minifyStmt(decl);
                    }
                } else {
                    const list = s.list.items;
                    if (list.len == 1 and ((list[0].name != null and eql(list[0].name.?, "*")) or (list[0].name == null and list[0].binding != null and eql(list[0].binding.?, "*")))) {
                        m.writeSpaceBeforeIdent();
                        m.minifyAlias(list[0]);
                        if (s.module != null and list[0].name != null) m.write(" ");
                    } else if (0 < list.len) {
                        m.write("{");
                        for (list, 0..) |item, i| {
                            if (i != 0) m.write(",");
                            m.minifyAlias(item);
                        }
                        m.write("}");
                    }
                    if (s.module) |mod| {
                        m.write("from");
                        m.write(minifyString(mod, false, m.escape_html));
                    }
                    m.requireSemicolon();
                }
            },
            .directive => |v| {
                v[0] = '"';
                v[v.len - 1] = '"';
                m.write(v);
                m.requireSemicolon();
            },
            .comment => |v| {
                m.write(v);
                if (v.len > 1 and v[1] == '/') m.write("\n");
            },
            else => {},
        }
    }

    fn minifyBlockStmt(m: *M, b: *ast.Block) void {
        m.write("{");
        m.needs_semicolon = false;
        for (b.list.items) |item| {
            m.writeSemicolon();
            m.minifyStmt(item);
        }
        m.write("}");
        m.needs_semicolon = false;
    }

    fn minifyBlockAsStmt(m: *M, b: *ast.Block) void {
        var has_lexical = false;
        const start = @min(b.scope.num_for_decls, b.scope.declared.items.len);
        for (b.scope.declared.items[start..]) |v| {
            if (v.decl == .LexicalDecl) {
                has_lexical = true;
                break;
            }
        }
        if (1 < b.list.items.len or has_lexical) {
            m.minifyBlockStmt(b);
        } else if (b.list.items.len == 1) {
            m.minifyStmt(b.list.items[0]);
        } else {
            m.write(";");
            m.needs_semicolon = false;
        }
    }

    fn minifyStmtOrBlock(m: *M, i: ?*Node, bt: BlockType) void {
        if (tag(i) == .block) {
            const b = &i.?.block;
            b.list = optimizeStmtList(b.list, bt);
            m.renamer.renameScope(&b.scope);
            m.minifyBlockAsStmt(b);
        } else {
            var l: L(*Node) = .empty;
            l.append(sys.A, i orelse newN(.empty)) catch {};
            const list = optimizeStmtList(l, bt);
            if (list.items.len == 1) {
                m.minifyStmt(list.items[0]);
            } else if (list.items.len == 0) {
                m.write(";");
                m.needs_semicolon = false;
            } else {
                var b: ast.Block = .{ .list = list };
                m.minifyBlockStmt(&b);
            }
        }
    }

    fn minifyAlias(m: *M, alias: ast.Alias) void {
        if (alias.name) |name| {
            if (name.len > 0 and (name[0] == '"' or name[0] == '\'')) {
                m.write(minifyString(name, false, m.escape_html));
            } else m.write(name);
            if (!eql(name, "*")) m.write(" ");
            m.write("as ");
        }
        if (alias.binding) |b| {
            if (b.len > 0 and (b[0] == '"' or b[0] == '\'')) {
                m.write(minifyString(b, false, m.escape_html));
            } else m.write(b);
        }
    }

    fn minifyParams(m: *M, params: ast.Params, remove_unused: bool) void {
        var j = params.list.items.len;
        if (remove_unused and params.rest == null) {
            while (0 < j) : (j -= 1) {
                const v = isV(params.list.items[j - 1].binding);
                if (v == null or 1 < v.?.uses) break;
            }
        }
        m.write("(");
        for (params.list.items[0..j], 0..) |item, i| {
            if (i != 0) m.write(",");
            m.minifyBindingElement(item);
        }
        if (params.rest) |rest| {
            if (params.list.items.len != 0) m.write(",");
            m.write("...");
            m.minifyBinding(rest);
        }
        m.write(")");
    }

    fn minifyArguments(m: *M, args: ast.Args) void {
        m.write("(");
        for (args.list.items, 0..) |item, i| {
            if (i != 0) m.write(",");
            if (item.rest) m.write("...");
            m.minifyExpr(item.value, ast.OpAssign);
        }
        m.write(")");
    }

    fn minifyVarDecl(m: *M, n: *Node, only_defines: bool) void {
        const decl = &n.var_decl;
        if (decl.list.items.len == 0) return;
        if (decl.tt == lex.ErrorToken) {
            var first = true;
            for (decl.list.items) |item| {
                if (item.default != null or !only_defines) {
                    if (!first) m.write(",");
                    m.minifyBindingElement(item);
                    first = false;
                }
            }
        } else {
            m.optimizeVarOrder(decl);
            m.write(lex.ttBytes(decl.tt));
            m.writeSpaceBeforeIdent();
            for (decl.list.items, 0..) |item, i| {
                if (i != 0) m.write(",");
                m.minifyBindingElement(item);
            }
        }
    }

    fn minifyFuncDecl(m: *M, n: *Node, in_expr: bool) void {
        const decl = &n.func_decl;
        const parent_rename = m.renamer.rename;
        m.renamer.rename = !decl.body.scope.has_with and !keep_var_names;
        m.hoistVars(&decl.body);
        decl.body.list = optimizeStmtList(decl.body.list, .function);
        if (decl.is_async) m.write("async ");
        m.write("function");
        if (decl.generator) m.write("*");
        if (in_expr) m.renamer.renameScope(&decl.body.scope);
        if (decl.name) |name| {
            if (!in_expr or 1 < name.uses) {
                if (!decl.generator) m.write(" ");
                m.write(name.data);
            }
        }
        if (!in_expr) m.renamer.renameScope(&decl.body.scope);
        m.minifyParams(decl.params, true);
        m.minifyBlockStmt(&decl.body);
        m.renamer.rename = parent_rename;
    }

    fn minifyClassElementName(m: *M, name: ast.ClassElementName) void {
        if (name.private) |p| m.write(p.data) else m.minifyPropertyName(name.pn);
    }

    fn minifyMethodDecl(m: *M, decl: *ast.MethodDecl) void {
        const parent_rename = m.renamer.rename;
        m.renamer.rename = !decl.body.scope.has_with and !keep_var_names;
        m.hoistVars(&decl.body);
        decl.body.list = optimizeStmtList(decl.body.list, .function);
        if (decl.static) {
            m.write("static");
            m.writeSpaceBeforeIdent();
        }
        if (decl.is_async) {
            m.write("async");
            if (decl.generator) m.write("*") else m.writeSpaceBeforeIdent();
        } else if (decl.generator) {
            m.write("*");
        } else if (decl.get) {
            m.write("get");
            m.writeSpaceBeforeIdent();
        } else if (decl.set) {
            m.write("set");
            m.writeSpaceBeforeIdent();
        }
        m.minifyClassElementName(decl.name);
        m.renamer.renameScope(&decl.body.scope);
        m.minifyParams(decl.params, !decl.set);
        m.minifyBlockStmt(&decl.body);
        m.renamer.rename = parent_rename;
    }

    fn minifyArrowFunc(m: *M, decl: *ast.ArrowFunc) void {
        const parent_rename = m.renamer.rename;
        m.renamer.rename = !decl.body.scope.has_with and !keep_var_names;
        m.hoistVars(&decl.body);
        decl.body.list = optimizeStmtList(decl.body.list, .function);
        m.renamer.renameScope(&decl.body.scope);
        if (decl.is_async) m.write("async");
        var remove_parens = false;
        if (decl.params.rest == null and decl.params.list.items.len == 1 and decl.params.list.items[0].default == null) {
            if (decl.params.list.items[0].binding == null) {
                remove_parens = true;
            } else if (isV(decl.params.list.items[0].binding) != null) remove_parens = true;
        }
        if (remove_parens) {
            if (decl.is_async and decl.params.list.items[0].binding != null) m.write(" ");
            m.minifyBindingElement(decl.params.list.items[0]);
        } else {
            const pif = m.in_for;
            m.in_for = false;
            m.minifyParams(decl.params, true);
            m.in_for = pif;
        }
        m.write("=>");
        var remove_braces = false;
        const items = decl.body.list.items;
        if (0 < items.len) {
            const last = items[items.len - 1];
            if (last.* == .return_stmt and last.return_stmt != null) {
                var list: L(*Node) = .empty;
                remove_braces = true;
                for (items[0 .. items.len - 1]) |item| {
                    if (item.* == .expr_stmt) {
                        list.append(sys.A, item.expr_stmt orelse newN(.empty)) catch {};
                    } else {
                        remove_braces = false;
                        break;
                    }
                }
                if (remove_braces) {
                    list.append(sys.A, last.return_stmt.?) catch {};
                    var expr = list.items[0];
                    if (1 < list.items.len) expr = newN(.{ .comma = list });
                    expr = newN(.{ .group = expr });
                    m.expect_expr = .body;
                    m.minifyExpr(expr, ast.OpAssign);
                    if (m.grouped_stmt) {
                        m.write(")");
                        m.grouped_stmt = false;
                    }
                }
            } else if (last.* == .return_stmt) {
                decl.body.list.items.len -= 1;
            }
        }
        if (!remove_braces) m.minifyBlockStmt(&decl.body);
        m.renamer.rename = parent_rename;
    }

    fn minifyClassDecl(m: *M, decl: *ast.ClassDecl) void {
        m.write("class");
        if (decl.name) |name| {
            m.write(" ");
            m.write(name.data);
        }
        if (decl.extends) |ext| {
            m.write(" extends");
            m.writeSpaceBeforeIdent();
            m.minifyExpr(ext, ast.OpLHS);
        }
        m.renamer.renameClassScope(&decl.scope);
        m.write("{");
        m.needs_semicolon = false;
        for (decl.list.items) |item| {
            m.writeSemicolon();
            if (item.static_block) |sb| {
                m.write("static");
                m.minifyBlockStmt(&sb.block);
            } else if (item.method) |mn| {
                m.minifyMethodDecl(&mn.method_decl);
            } else {
                if (item.field.static) {
                    m.write("static");
                    if (!item.field.name.pn.isComputed() and item.field.name.pn.literal.tt == lex.IdentifierToken) m.write(" ");
                }
                m.minifyClassElementName(item.field.name);
                if (item.field.init) |init| {
                    m.write("=");
                    m.minifyExpr(init, ast.OpAssign);
                }
                m.requireSemicolon();
            }
        }
        m.write("}");
        m.needs_semicolon = false;
    }

    fn minifyPropertyName(m: *M, name: ast.PropertyName) void {
        if (name.computed) |c| {
            m.write("[");
            m.minifyExpr(c, ast.OpAssign);
            m.write("]");
        } else if (name.literal.tt == lex.StringToken) {
            m.write(minifyString(name.literal.data, false, m.escape_html));
        } else m.write(name.literal.data);
    }

    fn minifyProperty(m: *M, property: ast.Property) void {
        if (property.spread) {
            m.write("...");
        } else if (property.name) |pn| {
            const v = isV(property.value);
            if (v == null or !pn.isIdent(v.?.name())) {
                m.minifyPropertyName(pn.*);
                m.write(":");
            }
        }
        m.minifyExpr(property.value, ast.OpAssign);
        if (property.init) |init| {
            m.write("=");
            m.minifyExpr(init, ast.OpAssign);
        }
    }

    fn minifyBindingElement(m: *M, el: ast.BindingElement) void {
        if (el.binding) |b| {
            const pif = m.in_for;
            m.in_for = false;
            m.minifyBinding(b);
            m.in_for = pif;
            if (el.default) |d| {
                m.write("=");
                m.minifyExpr(d, ast.OpAssign);
            }
        }
    }

    fn minifyBinding(m: *M, n: *Node) void {
        switch (n.*) {
            .var_ => |v| m.write(v.data),
            .binding_array => |b| {
                m.write("[");
                for (b.list.items, 0..) |item, i| {
                    if (i != 0) m.write(",");
                    m.minifyBindingElement(item);
                }
                if (b.rest) |rest| {
                    if (0 < b.list.items.len) m.write(",");
                    m.write("...");
                    m.minifyBinding(rest);
                }
                m.write("]");
            },
            .binding_object => |b| {
                m.write("{");
                for (b.list.items, 0..) |item, i| {
                    if (i != 0) m.write(",");
                    const key = item.key.?;
                    if (key.isComputed()) {
                        m.minifyPropertyName(key.*);
                        m.write(":");
                    } else {
                        const v = isV(item.value.binding);
                        if (v == null or !key.isIdent(v.?.data)) {
                            m.minifyPropertyName(key.*);
                            m.write(":");
                        }
                    }
                    m.minifyBindingElement(item.value);
                }
                if (b.rest) |rest| {
                    if (0 < b.list.items.len) m.write(",");
                    m.write("...");
                    m.write(rest.data);
                }
                m.write("}");
            },
            else => {},
        }
    }

    fn minifyExpr(m: *M, in: ?*Node, prec: OpPrec) void {
        var i = in orelse return;
        if (i.* == .cond) {
            i = m.optimizeCondExpr(i, prec) orelse return;
        } else if (i.* == .unary) {
            i = optimizeUnaryExpr(i, prec);
        }
        switch (i.*) {
            .var_ => |v0| {
                var v = v0;
                while (v.link) |l| v = l;
                const data = v.data;
                if (v.decl == .NoDecl and eql(data, "undefined")) {
                    m.write(if (ast.OpMember < prec) "(0[0])" else "0[0]");
                } else if (v.decl == .NoDecl and eql(data, "Infinity")) {
                    m.write(if (ast.OpMul < prec) "(1/0)" else "1/0");
                } else m.write(data);
            },
            .literal => |*lit| {
                const tt = lit.tt;
                if (tt == lex.DecimalToken or tt == lex.IntegerToken) {
                    m.write(decimalNumber(lit.data));
                } else if (tt == lex.BinaryToken) {
                    m.write(radixNumber(lit.data, 2));
                } else if (tt == lex.OctalToken) {
                    m.write(radixNumber(lit.data, 8));
                } else if (tt == lex.HexadecimalToken) {
                    m.write(radixNumber(lit.data, 16));
                } else if (tt == lex.TrueToken) {
                    m.write(if (ast.OpUnary < prec) "(!0)" else "!0");
                } else if (tt == lex.FalseToken) {
                    m.write(if (ast.OpUnary < prec) "(!1)" else "!1");
                } else if (tt == lex.StringToken) {
                    m.write(minifyString(lit.data, minVersion(2015), m.escape_html));
                } else if (tt == lex.RegExpToken) {
                    if (m.escape_html and m.prevLast() == '<' and 7 <= lit.data.len and std.ascii.eqlIgnoreCase(lit.data[0..7], "/script")) m.write(" ");
                    m.write(minifyRegExp(lit.data, m.escape_html));
                } else m.write(lit.data);
            },
            .binary => {
                m.minifyBinary(i, prec);
            },
            .unary => |*e| {
                if (e.op == lex.PostIncrToken or e.op == lex.PostDecrToken) {
                    m.minifyExpr(e.x, unaryPrec(e.op));
                    m.write(lex.ttBytes(e.op));
                } else if (e.op == lex.VoidToken and !hasSideEffects(e.x)) {
                    m.write("0[0]");
                } else {
                    const is_lt_not = e.op == lex.NotToken and m.prevLast() == '<';
                    m.write(lex.ttBytes(e.op));
                    if (e.op == lex.DeleteToken or e.op == lex.VoidToken or e.op == lex.TypeofToken or e.op == lex.AwaitToken) {
                        m.writeSpaceBeforeIdent();
                    } else if (e.op == lex.PosToken) {
                        m.writeSpaceBefore('+');
                    } else if (e.op == lex.NegToken or (is_lt_not and m.escape_html)) {
                        m.writeSpaceBefore('-');
                    } else if (e.op == lex.NotToken) {
                        if (tag(e.x) == .literal) {
                            const lit = &e.x.?.literal;
                            if (lit.tt == lex.StringToken) {
                                m.write(if (lit.data.len == 2) "0" else "1");
                                return;
                            } else if (lit.tt == lex.RegExpToken) {
                                m.write("1");
                                return;
                            } else if (lit.tt == lex.DecimalToken or lit.tt == lex.IntegerToken) {
                                if (lit.data.len > 0 and lit.data[lit.data.len - 1] == 'n') lit.data = lit.data[0 .. lit.data.len - 1];
                                const num = min.number(lit.data, precision);
                                m.write(if (num.len == 1 and num[0] == '0') "0" else "1");
                                return;
                            }
                        }
                    }
                    m.minifyExpr(e.x, unaryPrec(e.op));
                }
            },
            .dot => |e| {
                var ydata: []const u8 = "";
                switch (e.y.*) {
                    .literal => |l| ydata = l.data,
                    .var_ => |v0| {
                        var v = v0;
                        while (v.link) |l| v = l;
                        ydata = v.data;
                    },
                    else => {},
                }
                if (e.x.* == .group) {
                    if (tag(e.x.group) == .literal) {
                        const lit = e.x.group.?.literal;
                        if (lit.tt == lex.DecimalToken or lit.tt == lex.IntegerToken) {
                            if (lit.tt == lex.DecimalToken) {
                                m.write(min.number(lit.data, precision));
                            } else {
                                m.write(lit.data);
                                m.write(".");
                            }
                            m.write(".");
                            m.write(ydata);
                            return;
                        }
                    }
                }
                var pi = e.prec;
                if (pi == ast.OpMember and prec < ast.OpMember) pi = ast.OpCall;
                m.minifyExpr(e.x, pi);
                if (e.optional) {
                    m.write("?");
                } else {
                    const last = m.prevLast();
                    if ('0' <= last and last <= '9') {
                        var is_int = true;
                        for (m.prev[0 .. m.prev.len - 1]) |c| {
                            if (c < '0' or '9' < c) {
                                is_int = false;
                                break;
                            }
                        }
                        if (is_int) m.write(".");
                    }
                }
                m.write(".");
                m.write(ydata);
            },
            .group => |*gx| {
                if (tag(gx.*) == .cond) {
                    gx.* = m.optimizeCondExpr(gx.*.?, ast.OpExpr);
                }
                const pi = exprPrec(gx.*);
                if (prec <= pi or (pi == ast.OpCoalesce and prec == ast.OpBitOr)) {
                    m.minifyExpr(gx.*, prec);
                } else {
                    const pif = m.in_for;
                    m.in_for = false;
                    m.write("(");
                    m.minifyExpr(gx.*, ast.OpExpr);
                    m.write(")");
                    m.in_for = pif;
                }
            },
            .array => |list| {
                const pif = m.in_for;
                m.in_for = false;
                m.write("[");
                for (list.items, 0..) |item, k| {
                    if (k != 0) m.write(",");
                    if (item.spread) m.write("...");
                    m.minifyExpr(item.value, ast.OpAssign);
                }
                if (0 < list.items.len and list.items[list.items.len - 1].value == null) m.write(",");
                m.write("]");
                m.in_for = pif;
            },
            .object => |list| {
                const pif = m.in_for;
                m.in_for = false;
                const grouped = m.expect_expr != .any;
                m.write(if (grouped) "({" else "{");
                for (list.items, 0..) |item, k| {
                    if (k != 0) m.write(",");
                    m.minifyProperty(item);
                }
                m.write("}");
                if (grouped) m.grouped_stmt = true;
                m.in_for = pif;
            },
            .template => |e| {
                if (e.tag) |t| {
                    var pi = e.prec;
                    if (pi == ast.OpMember and prec < ast.OpMember) pi = ast.OpCall;
                    m.minifyExpr(t, pi);
                    if (e.optional) m.write("?.");
                }
                const pif = m.in_for;
                m.in_for = false;
                for (e.list.items) |item| {
                    if (e.tag == null) {
                        m.write(replaceEscapes(item.value, '`', 1, 2, m.escape_html));
                    } else m.write(item.value);
                    m.minifyExpr(item.expr, ast.OpExpr);
                }
                if (e.tag == null) {
                    m.write(replaceEscapes(e.tail, '`', 1, 1, m.escape_html));
                } else m.write(e.tail);
                m.in_for = pif;
            },
            .new => |e| {
                if (e.args == null and ast.OpLHS < prec and prec != ast.OpNew) {
                    m.write("(new");
                    m.writeSpaceBeforeIdent();
                    m.minifyExpr(e.x, ast.OpNew);
                    m.write(")");
                } else {
                    m.write("new");
                    m.writeSpaceBeforeIdent();
                    if (e.args) |args| {
                        m.minifyExpr(e.x, ast.OpMember);
                        m.minifyArguments(args.*);
                    } else m.minifyExpr(e.x, ast.OpNew);
                }
            },
            .new_target => {
                m.write("new.target");
                m.writeSpaceBeforeIdent();
            },
            .import_meta => {
                m.write("import.meta");
                m.writeSpaceBeforeIdent();
            },
            .yield => |e| {
                m.write("yield");
                m.writeSpaceBeforeIdent();
                if (e.x) |x| {
                    if (e.generator) {
                        m.write("*");
                        m.minifyExpr(x, ast.OpAssign);
                    } else {
                        const v = isV(x);
                        if (v == null or !eql(v.?.name(), "undefined") or v.?.decl != .NoDecl) m.minifyExpr(x, ast.OpAssign);
                    }
                }
            },
            .call => m.minifyCall(i, prec),
            .index => |e| {
                if (m.expect_expr == .stmt) {
                    if (isV(e.x)) |v| {
                        if (eql(v.name(), "let")) m.write("!");
                    }
                }
                var pi = e.prec;
                if (pi == ast.OpMember and prec < ast.OpMember) pi = ast.OpCall;
                m.minifyExpr(e.x, pi);
                if (e.optional) m.write("?.");
                if (tag(e.y) == .literal) {
                    const lit = e.y.?.literal;
                    if (lit.tt == lex.StringToken and 2 < lit.data.len) {
                        const inner = lit.data[1 .. lit.data.len - 1];
                        if (jsp.asIdentifierName(inner)) {
                            if (!e.optional) m.write(".");
                            m.write(inner);
                            return;
                        } else if (jsp.asDecimalLiteral(inner)) {
                            m.write("[");
                            m.write(min.number(inner, 0));
                            m.write("]");
                            return;
                        }
                    }
                }
                const pif = m.in_for;
                m.in_for = false;
                m.write("[");
                m.minifyExpr(e.y, ast.OpExpr);
                m.write("]");
                m.in_for = pif;
            },
            .cond => |e| {
                m.minifyExpr(e.cond, ast.OpCoalesce);
                m.write("?");
                m.minifyExpr(e.x, ast.OpAssign);
                m.write(":");
                m.minifyExpr(e.y, ast.OpAssign);
            },
            .var_decl => m.minifyVarDecl(i, true),
            .func_decl => {
                const grouped = m.expect_expr == .stmt and prec != ast.OpExpr;
                if (grouped) {
                    m.write("(");
                } else if (m.expect_expr == .stmt) m.write("!");
                const pif = m.in_for;
                const pgs = m.grouped_stmt;
                m.in_for = false;
                m.grouped_stmt = false;
                m.minifyFuncDecl(i, true);
                m.in_for = pif;
                m.grouped_stmt = pgs;
                if (grouped) m.write(")");
            },
            .arrow => |*a| {
                const pgs = m.grouped_stmt;
                m.grouped_stmt = false;
                m.minifyArrowFunc(a);
                m.grouped_stmt = pgs;
            },
            .method_decl => |*md| {
                const pgs = m.grouped_stmt;
                m.grouped_stmt = false;
                m.minifyMethodDecl(md);
                m.grouped_stmt = pgs;
            },
            .class_decl => |*cd| {
                if (m.expect_expr == .stmt) m.write("!");
                const pif = m.in_for;
                const pgs = m.grouped_stmt;
                m.in_for = false;
                m.grouped_stmt = false;
                m.minifyClassDecl(cd);
                m.in_for = pif;
                m.grouped_stmt = pgs;
            },
            .comma => |list| {
                for (list.items, 0..) |item, k| {
                    if (k != 0) m.write(",");
                    m.minifyExpr(item, ast.OpAssign);
                }
            },
            else => {},
        }
    }

    fn minifyBinary(m: *M, node: *Node, prec: OpPrec) void {
        var n = node;
        mergeBinaryExpr(n);
        var e = &n.binary;
        if (e.x == null) {
            m.minifyExpr(e.y, prec);
            return;
        }
        var prec_left = binaryLeftPrec(e.op);
        if (prec <= ast.OpExpr) {
            if (tag(e.x) == .group) {
                const gx = e.x.?.group;
                if (tag(gx) == .comma) {
                    const cl = gx.?.comma.items;
                    if (ast.OpAnd <= exprPrec(cl[cl.len - 1])) {
                        e.x = gx;
                        prec_left = ast.OpExpr;
                    }
                }
            }
        }
        if (e.op == lex.InstanceofToken or e.op == lex.InToken) {
            const group = e.op == lex.InToken and m.in_for;
            if (group) m.write("(");
            m.minifyExpr(e.x, prec_left);
            m.writeSpaceAfterIdent();
            m.write(lex.ttBytes(e.op));
            m.writeSpaceBeforeIdent();
            m.minifyExpr(e.y, binaryRightPrec(e.op));
            if (group) m.write(")");
            return;
        }
        if (isUndefinedOrNullVar(n)) |r| {
            const op: TT = if (r.not) lex.NotEqToken else lex.EqEqToken;
            n = newN(.{ .binary = .{ .op = op, .x = ast.newVarNode(r.v), .y = newN(.{ .literal = .{ .tt = lex.NullToken, .data = @constCast("null") } }) } });
            e = &n.binary;
        }
        if (e.op == lex.EqEqEqToken or e.op == lex.NotEqEqToken) {
            if (tag(e.x) == .unary and e.x.?.unary.op == lex.TypeofToken) {
                if (tag(e.y) == .literal and e.y.?.literal.tt == lex.StringToken) {
                    e.op = if (e.op == lex.EqEqEqToken) lex.EqEqToken else lex.NotEqToken;
                }
            } else if (tag(e.y) == .unary and e.y.?.unary.op == lex.TypeofToken) {
                if (tag(e.x) == .literal and e.x.?.literal.tt == lex.StringToken) {
                    e.op = if (e.op == lex.EqEqEqToken) lex.EqEqToken else lex.NotEqToken;
                }
            }
        } else if (e.op == lex.AndToken) {
            if ((isTrue(e.x) or isFalse(e.y)) and !hasSideEffects(e.x)) {
                m.minifyExpr(e.y, prec);
                return;
            } else if ((isTrue(e.y) or isFalse(e.x)) and !hasSideEffects(e.y)) {
                m.minifyExpr(e.x, prec);
                return;
            }
        } else if (e.op == lex.OrToken) {
            if ((isTrue(e.x) or isFalse(e.y)) and !hasSideEffects(e.y)) {
                m.minifyExpr(e.x, prec);
                return;
            } else if ((isTrue(e.y) or isFalse(e.x)) and !hasSideEffects(e.x)) {
                m.minifyExpr(e.y, prec);
                return;
            }
        } else if (e.op == lex.EqToken) {
            if (isV(e.x)) |left| {
                if (tag(e.y) == .binary) {
                    const right = &e.y.?.binary;
                    var y: ?*Node = null;
                    var var_left = false;
                    if (isV(right.x)) |v| {
                        if (v == left) {
                            y = right.y;
                            var_left = true;
                        }
                    }
                    if (y == null) {
                        if (isV(right.y)) |v| {
                            if (v == left) y = right.x;
                        }
                    }
                    if (y) |yy| {
                        if (yy.* == .literal) {
                            const lit = yy.literal;
                            if ((right.op == lex.AddToken or (var_left and right.op == lex.SubToken)) and lit.tt == lex.IntegerToken and lit.data.len == 1 and lit.data[0] == '1') {
                                m.write(if (right.op == lex.AddToken) "++" else "--");
                                m.minifyExpr(e.x, ast.OpUnary);
                                return;
                            }
                        }
                    }
                }
            }
        }
        m.minifyExpr(e.x, prec_left);
        if (e.op == lex.GtToken and m.prevLast() == '-') m.write(" ");
        m.write(lex.ttBytes(e.op));
        if (e.op == lex.AddToken) {
            m.writeSpaceBefore('+');
        } else if (e.op == lex.SubToken) {
            m.writeSpaceBefore('-');
        } else if (e.op == lex.DivToken) {
            m.writeSpaceBefore('/');
        }
        m.minifyExpr(e.y, binaryRightPrec(e.op));
    }

    fn minifyCall(m: *M, n: *Node, prec: OpPrec) void {
        const e = &n.call;
        const args = e.args.list.items;
        if (isV(e.x)) |v| {
            if (v.decl == .NoDecl and eql(v.data, "Number") and args.len == 1) {
                const a0 = args[0].value;
                if (tag(a0) == .literal) {
                    const lit = &a0.?.literal;
                    if (lit.tt == lex.TrueToken) {
                        m.write("1");
                        return;
                    } else if (lit.tt == lex.FalseToken or lit.tt == lex.NullToken) {
                        m.write("0");
                        return;
                    } else if (lit.tt == lex.DecimalToken) {
                        m.minifyExpr(a0, prec);
                        return;
                    } else if (lit.tt == lex.IntegerToken or lit.tt == lex.BinaryToken or lit.tt == lex.OctalToken or lit.tt == lex.HexadecimalToken) {
                        if (lit.data.len > 0 and lit.data[lit.data.len - 1] == 'n') lit.data = lit.data[0 .. lit.data.len - 1];
                        m.minifyExpr(a0, prec);
                        return;
                    }
                } else if (isV(a0)) |av| {
                    if (av.decl == .NoDecl and eql(av.data, "undefined")) {
                        m.write("NaN");
                        return;
                    }
                }
            }
        } else if (e.x.* == .dot) {
            const dot = e.x.dot;
            if (isV(dot.x)) |x| {
                if (x.decl == .NoDecl and eql(x.data, "Math") and dot.y.* == .literal) {
                    const yd = dot.y.literal.data;
                    if (eql(yd, "pow")) {
                        if (args.len == 2) {
                            if (ast.OpExp < prec) m.write("(");
                            m.minifyExpr(newN(.{ .group = args[0].value }), ast.OpUpdate);
                            m.write("**");
                            m.minifyExpr(newN(.{ .group = args[1].value }), ast.OpExp);
                            if (ast.OpExp < prec) m.write(")");
                            return;
                        }
                    } else if (eql(yd, "trunc")) {
                        if (args.len == 1) {
                            if (ast.OpBitOr < prec) m.write("(");
                            m.minifyExpr(newN(.{ .group = args[0].value }), ast.OpBitOr);
                            m.write("|");
                            m.write("0");
                            if (ast.OpBitOr < prec) m.write(")");
                            return;
                        }
                    } else if (eql(yd, "abs")) {
                        if (args.len == 1) {
                            const group_len: usize = if (ast.OpAssign < prec) 2 else 0;
                            if (isV(args[0].value)) |v| {
                                if (v.data.len * 2 + group_len + 5 < 10) {
                                    if (ast.OpAssign < prec) m.write("(");
                                    m.minifyExpr(args[0].value, ast.OpCoalesce);
                                    m.write("<0?-");
                                    m.minifyExpr(args[0].value, ast.OpAssign);
                                    m.write(":");
                                    m.minifyExpr(args[0].value, ast.OpAssign);
                                    if (ast.OpAssign < prec) m.write(")");
                                    return;
                                }
                            }
                        }
                    } else if (eql(yd, "sqrt")) {
                        if (args.len == 1) {
                            if (ast.OpExp < prec) m.write("(");
                            m.minifyExpr(newN(.{ .group = args[0].value }), ast.OpUpdate);
                            m.write("**.5");
                            if (ast.OpExp < prec) m.write(")");
                            return;
                        }
                    }
                }
            }
        }
        var pi = e.prec;
        if (pi == ast.OpMember and prec < ast.OpMember) pi = ast.OpCall;
        m.minifyExpr(e.x, pi);
        const pif = m.in_for;
        m.in_for = false;
        if (e.optional) m.write("?.");
        m.minifyArguments(e.args);
        m.in_for = pif;
    }

    fn optimizeCondExpr(m: *M, n: *Node, prec: OpPrec) ?*Node {
        _ = m;
        const e = &n.cond;
        if (tag(e.cond) == .unary and e.cond.?.unary.op == lex.NotToken) {
            const un1 = e.cond.?.unary;
            if (tag(un1.x) == .unary and un1.x.?.unary.op == lex.NotToken) {
                if (isBooleanExpr(un1.x.?.unary.x)) e.cond = un1.x.?.unary.x;
            } else {
                e.cond = un1.x;
                const t = e.x;
                e.x = e.y;
                e.y = t;
            }
        }
        const final_cond = finalExpr(e.cond);
        if (isTruthy(e.cond)) |truthy| {
            return if (truthy) e.x else e.y;
        }
        if (isEqualExpr(final_cond, e.x) and (exprPrec(final_cond) < ast.OpAssign or binaryLeftPrec(lex.OrToken) <= exprPrec(final_cond)) and (exprPrec(e.y) < ast.OpAssign or binaryRightPrec(lex.OrToken) <= exprPrec(e.y))) {
            return bin(lex.OrToken, groupExpr(e.cond, binaryLeftPrec(lex.OrToken)), e.y);
        } else if (isEqualExpr(final_cond, e.y) and (exprPrec(final_cond) < ast.OpAssign or binaryLeftPrec(lex.AndToken) <= exprPrec(final_cond)) and (exprPrec(e.x) < ast.OpAssign or binaryRightPrec(lex.AndToken) <= exprPrec(e.x))) {
            return bin(lex.AndToken, groupExpr(e.cond, binaryLeftPrec(lex.AndToken)), e.x);
        } else if (isEqualExpr(e.x, e.y)) {
            var l: L(*Node) = .empty;
            l.append(sys.A, e.cond orelse newN(.empty)) catch {};
            l.append(sys.A, e.x orelse newN(.empty)) catch {};
            return groupExpr(newN(.{ .comma = l }), prec);
        } else {
            if (minVersion(2020)) {
                if (toNullishExpr(n)) |ne| return ne;
            }
            if (tag(e.x) == .call and tag(e.y) == .call) {
                const cx = &e.x.?.call;
                const cy = &e.y.?.call;
                if (cx.args.list.items.len == 1 and cy.args.list.items.len == 1 and !cx.args.list.items[0].rest and !cy.args.list.items[0].rest and isEqualExpr(cx.x, cy.x)) {
                    e.x = cx.args.list.items[0].value;
                    e.y = cy.args.list.items[0].value;
                    var args: ast.Args = .{};
                    args.list.append(sys.A, .{ .value = n, .rest = false }) catch {};
                    return newN(.{ .call = .{ .x = cx.x, .args = args, .prec = ast.OpCall, .optional = false } });
                }
            }
            const true_x = isTrue(e.x);
            const false_x = isFalse(e.x);
            const true_y = isTrue(e.y);
            const false_y = isFalse(e.y);
            if ((true_x and false_y) or (false_x and true_y)) {
                return optimizeBooleanExpr(e.cond, false_x, prec);
            } else if (true_x or true_y) {
                const cond = optimizeBooleanExpr(e.cond, true_y, binaryLeftPrec(lex.OrToken));
                if (true_y) return bin(lex.OrToken, cond, groupExpr(e.x, binaryRightPrec(lex.OrToken)));
                return bin(lex.OrToken, cond, groupExpr(e.y, binaryRightPrec(lex.OrToken)));
            } else if (false_x or false_y) {
                const cond = optimizeBooleanExpr(e.cond, false_x, binaryLeftPrec(lex.AndToken));
                if (false_x) return bin(lex.AndToken, cond, groupExpr(e.y, binaryRightPrec(lex.AndToken)));
                return bin(lex.AndToken, cond, groupExpr(e.x, binaryRightPrec(lex.AndToken)));
            } else if (tag(e.x) == .cond and isEqualExpr(e.y, e.x.?.cond.y)) {
                const ce = e.x.?.cond;
                return newN(.{ .cond = .{ .cond = bin(lex.AndToken, groupExpr(e.cond, binaryLeftPrec(lex.AndToken)), groupExpr(ce.cond, binaryRightPrec(lex.AndToken))), .x = ce.x, .y = e.y } });
            } else if (prec <= ast.OpExpr) {
                if (tag(e.cond) == .group) {
                    const gx = e.cond.?.group;
                    if (tag(gx) == .comma) {
                        const cl = gx.?.comma.items;
                        if (ast.OpCoalesce <= exprPrec(cl[cl.len - 1])) {
                            e.cond = cl[cl.len - 1];
                            cl[cl.len - 1] = n;
                            return gx;
                        }
                    }
                }
            }
        }
        return n;
    }

    // ------------------------------------------------------------ vars

    fn countHoistLength(m: *M, b: ?*Node) i64 {
        _ = m;
        var refs: L(*Var) = .empty;
        appendBindingVars(&refs, b);
        return @as(i64, @intCast(refs.items.len)) * 2;
    }

    fn hoistVars(m: *M, body: *ast.Block) void {
        const vds = body.scope.var_decls.items;
        if (1 < vds.len) {
            var best: usize = 0;
            const scores = sys.A.alloc(i64, vds.len) catch return;
            @memset(scores, 0);
            const hoist = sys.A.alloc(bool, vds.len) catch return;
            @memset(hoist, false);
            for (vds, 0..) |vdn, i| {
                const vd = &vdn.var_decl;
                hoist[i] = true;
                if (vd.in_for_in_of) continue;
                var n: i64 = 0;
                var score: i64 = 3;
                var n_arrays: i64 = 0;
                var n_objects: i64 = 0;
                var has_defs = false;
                for (vd.list.items) |item| {
                    if (item.default != null) {
                        if (tag(item.binding) == .binding_object) {
                            n_objects += 1;
                        } else if (tag(item.binding) == .binding_array) n_arrays += 1;
                        score -= m.countHoistLength(item.binding);
                        has_defs = true;
                        n += 1;
                    }
                }
                if (n_arrays == 0 and n_objects == 0) score += 1;
                if (!has_defs and vd.in_for) score -= 1;
                if (n_objects != 0 and !vd.in_for and n_objects == n) score -= 2;
                if (score < scores[best] or vds[best].var_decl.in_for_in_of) best = i;
                if (score < 0) hoist[i] = false;
                scores[i] = score;
            }
            if (vds[best].var_decl.in_for_in_of) return;
            const decl = &vds[best].var_decl;
            if (10000 < decl.list.items.len) return;
            hoist[best] = false;
            var orig: L(*Var) = .empty;
            for (decl.list.items) |item| appendBindingVars(&orig, item.binding);
            var j: usize = 0;
            var refs: L(*Var) = .empty;
            for (vds, 0..) |vdn, i| {
                if (!hoist[i]) continue;
                const vd = &vdn.var_decl;
                vd.tt = lex.ErrorToken;
                for (vd.list.items) |item| {
                    refs.items.len = 0;
                    appendBindingVars(&refs, item.binding);
                    var bes: L(ast.BindingElement) = .empty;
                    refloop: for (refs.items) |ref| {
                        for (orig.items) |v| if (ref == v) continue :refloop;
                        bes.append(sys.A, .{ .binding = ast.newVarNode(ref), .default = null }) catch {};
                        orig.append(sys.A, ref) catch {};
                        var s: ?*Scope = decl.scope;
                        while (s != null and s.? != s.?.func) {
                            s.?.addUndeclaredUnique(ref);
                            s = s.?.parent;
                        }
                        if (item.default != null) ref.uses +%= 1;
                    }
                    if (i < best) {
                        decl.list.insertSlice(sys.A, j, bes.items) catch {};
                        j += bes.items.len;
                    } else {
                        decl.list.appendSlice(sys.A, bes.items) catch {};
                    }
                }
            }
        }
    }

    fn optimizeVarOrder(m: *M, decl: *ast.VarDecl) void {
        const list = decl.list.items;
        if (decl.tt == lex.VarToken) {
            var start: usize = 0;
            for (list, 0..) |item, i| {
                if (isV(item.binding) == null) {
                    if (i == 1) {
                        const t = list[0];
                        list[0] = list[1];
                        list[1] = t;
                    } else if (1 < i) {
                        std.mem.copyBackwards(ast.BindingElement, list[1 .. i + 1], list[0..i]);
                        list[0] = item;
                    }
                    start = 1;
                    break;
                }
            }
            const ctx = VarOrderCtx{ .r = &m.renamer };
            goStableSort(list[start..], ctx);
        } else if (list.len > 0 and isV(list[0].binding) != null) {
            var refs: L(*Var) = .empty;
            var bindings: L(*Var) = .empty;
            for (list, 0..) |item, i| {
                if (isV(item.binding) == null) {
                    if (i != 0) {
                        var interferes = false;
                        if (item.default) |d| {
                            refs.items.len = 0;
                            appendExprVars(&refs, d);
                            for (refs.items) |ref| {
                                for (bindings.items) |b| if (b == ref) {
                                    interferes = true;
                                };
                            }
                        }
                        if (!interferes) {
                            if (i == 1) {
                                const t = list[0];
                                list[0] = list[1];
                                list[1] = t;
                            } else {
                                std.mem.copyBackwards(ast.BindingElement, list[1 .. i + 1], list[0..i]);
                                list[0] = item;
                            }
                            break;
                        }
                    } else break;
                }
                appendBindingVars(&bindings, item.binding);
            }
        }
    }
};

const VarOrderCtx = struct {
    r: *Renamer,
    fn cmp(c: VarOrderCtx, a: ast.BindingElement, b: ast.BindingElement) i32 {
        if (a.default == null and b.default == null) {
            const va = isV(a.binding);
            const vb = isV(b.binding);
            if (va != null and va.?.data.len == 1 and vb != null and vb.?.data.len == 1) {
                const oa = c.r.order(va.?.data[0]);
                const ob = c.r.order(vb.?.data[0]);
                if (oa < ob) return -1;
                if (ob < oa) return 1;
                return 0;
            }
        } else if (a.default == null) {
            return -1;
        } else if (b.default == null) return 1;
        return 0;
    }
    fn lessThan(c: VarOrderCtx, a: ast.BindingElement, b: ast.BindingElement) bool {
        return c.cmp(a, b) < 0;
    }
};

// Go's slices.SortStableFunc (insertion sort blocks + SymMerge); the comparator
// is not transitive, so the exact algorithm matters.
const BE = ast.BindingElement;
fn sLess(c: VarOrderCtx, d: []BE, i: usize, j: usize) bool {
    return c.cmp(d[i], d[j]) < 0;
}
fn sSwap(d: []BE, i: usize, j: usize) void {
    const t = d[i];
    d[i] = d[j];
    d[j] = t;
}
fn sInsertion(d: []BE, a: usize, b: usize, c: VarOrderCtx) void {
    var i = a + 1;
    while (i < b) : (i += 1) {
        var j = i;
        while (j > a and sLess(c, d, j, j - 1)) : (j -= 1) sSwap(d, j, j - 1);
    }
}
fn goStableSort(d: []BE, c: VarOrderCtx) void {
    const n = d.len;
    var bs: usize = 20;
    var a: usize = 0;
    var b: usize = bs;
    while (b <= n) {
        sInsertion(d, a, b, c);
        a = b;
        b += bs;
    }
    sInsertion(d, a, n, c);
    while (bs < n) {
        a = 0;
        b = 2 * bs;
        while (b <= n) {
            symMerge(d, a, a + bs, b, c);
            a = b;
            b += 2 * bs;
        }
        const m = a + bs;
        if (m < n) symMerge(d, a, m, n, c);
        bs *= 2;
    }
}
fn swapRange(d: []BE, a: usize, b: usize, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) sSwap(d, a + i, b + i);
}
fn rotate(d: []BE, a: usize, m: usize, b: usize) void {
    var i = m - a;
    var j = b - m;
    while (i != j) {
        if (i > j) {
            swapRange(d, m - i, m, j);
            i -= j;
        } else {
            swapRange(d, m - i, m + j - i, i);
            j -= i;
        }
    }
    swapRange(d, m - i, m, i);
}
fn symMerge(d: []BE, a: usize, m: usize, b: usize, c: VarOrderCtx) void {
    if (m - a == 1) {
        var i = m;
        var j = b;
        while (i < j) {
            const h = (i + j) >> 1;
            if (sLess(c, d, h, a)) i = h + 1 else j = h;
        }
        var k = a;
        while (k + 1 < i) : (k += 1) sSwap(d, k, k + 1);
        return;
    }
    if (b - m == 1) {
        var i = a;
        var j = m;
        while (i < j) {
            const h = (i + j) >> 1;
            if (!sLess(c, d, m, h)) i = h + 1 else j = h;
        }
        var k = m;
        while (k > i) : (k -= 1) sSwap(d, k, k - 1);
        return;
    }
    const mid = (a + b) >> 1;
    const n = mid + m;
    var start: usize = undefined;
    var r: usize = undefined;
    if (m > mid) {
        start = n - b;
        r = mid;
    } else {
        start = a;
        r = m;
    }
    const p = n - 1;
    while (start < r) {
        const cc = (start + r) >> 1;
        if (!sLess(c, d, p - cc, cc)) start = cc + 1 else r = cc;
    }
    const end = n - start;
    if (start < m and m < end) rotate(d, start, m, end);
    if (a < start and start < mid) symMerge(d, a, start, mid, c);
    if (mid < end and end < b) symMerge(d, mid, end, b, c);
}

// ---------------------------------------------------------------- renamer

const identStartLen = 54;
const identContinueLen = 64;

const Renamer = struct {
    ident_start: []const u8,
    ident_continue: []const u8,
    rename: bool,

    fn init(rename: bool, use_char_freq: bool) Renamer {
        if (use_char_freq) return .{
            .ident_start = "etnsoiarclduhmfpgvbjy_wOxCEkASMFTzDNLRPHIBV$WUKqYGXQZJ",
            .ident_continue = "etnsoiarcldu14023hm8f6pg57v9bjy_wOxCEkASMFTzDNLRPHIBV$WUKqYGXQZJ",
            .rename = rename,
        };
        return .{
            .ident_start = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$",
            .ident_continue = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$0123456789",
            .rename = rename,
        };
    }
    fn order(r: *Renamer, c: u8) usize {
        return std.mem.indexOfScalar(u8, r.ident_start, c) orelse 0;
    }

    fn renameScope(r: *Renamer, scope: *Scope) void {
        if (!r.rename) return;
        var i: usize = 0;
        const d = scope.declared.items;
        goSortByUses(d[@min(scope.num_func_args, d.len)..]);
        for (d) |v| {
            v.data = r.getName(v.data, i);
            i += 1;
            while (r.isReserved(v.data, scope)) {
                v.data = r.getName(v.data, i);
                i += 1;
            }
        }
    }

    fn renameClassScope(r: *Renamer, scope: *Scope) void {
        if (!r.rename) return;
        var i: usize = 0;
        goSortByUses(scope.declared.items);
        for (scope.declared.items) |v| {
            const nm = r.getName(v.data[1..], i);
            const out = sys.A.alloc(u8, nm.len + 1) catch return;
            out[0] = v.data[0];
            @memcpy(out[1..], nm);
            v.data = out;
            i += 1;
        }
    }

    fn isReserved(r: *Renamer, name: []const u8, scope: *Scope) bool {
        _ = r;
        if (1 < name.len) {
            if (lex.keyword(name) != null) return true;
        }
        for (scope.undeclared.items) |v0| {
            var v = v0;
            while (v.link) |l| v = l;
            if (eql(v.data, name)) return true;
        }
        return false;
    }

    fn getName(r: *Renamer, name: []u8, index0: usize) []u8 {
        var index = index0;
        if (index < identStartLen) {
            if (name.len >= 1) {
                name[0] = r.ident_start[index];
                return name[0..1];
            }
            const nb = sys.A.alloc(u8, 1) catch unreachable;
            nb[0] = r.ident_start[index];
            return nb;
        }
        index -= identStartLen;
        var n: usize = 2;
        while (true) {
            var offset: usize = identStartLen;
            var k: usize = 0;
            while (k < n - 1) : (k += 1) offset *= identContinueLen;
            if (index < offset) break;
            index -= offset;
            n += 1;
        }
        const out = if (name.len < n) (sys.A.alloc(u8, n) catch unreachable) else name[0..n];
        out[0] = r.ident_start[index % identStartLen];
        index /= identStartLen;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            out[k] = r.ident_continue[index % identContinueLen];
            index /= identContinueLen;
        }
        return out;
    }
};

// Go's sort.Sort (pdqsort) specialised for VarsByUses, so that ties are
// broken exactly like the Go minifier.
fn vLess(d: []*Var, i: usize, j: usize) bool {
    return d[i].uses > d[j].uses;
}
fn vSwap(d: []*Var, i: usize, j: usize) void {
    const t = d[i];
    d[i] = d[j];
    d[j] = t;
}
fn goSortByUses(d: []*Var) void {
    const n = d.len;
    if (n <= 1) return;
    const limit = std.math.log2_int(usize, n) + 1;
    pdqsort(d, 0, n, limit);
}
fn insertionSort(d: []*Var, a: usize, b: usize) void {
    var i = a + 1;
    while (i < b) : (i += 1) {
        var j = i;
        while (j > a and vLess(d, j, j - 1)) : (j -= 1) vSwap(d, j, j - 1);
    }
}
fn siftDown(d: []*Var, lo: usize, hi: usize, first: usize) void {
    var root = lo;
    while (true) {
        var child = 2 * root + 1;
        if (child >= hi) return;
        if (child + 1 < hi and vLess(d, first + child, first + child + 1)) child += 1;
        if (!vLess(d, first + root, first + child)) return;
        vSwap(d, first + root, first + child);
        root = child;
    }
}
fn heapSort(d: []*Var, a: usize, b: usize) void {
    const first = a;
    const hi = b - a;
    var i: isize = @as(isize, @intCast((hi - 1) / 2));
    while (i >= 0) : (i -= 1) siftDown(d, @intCast(i), hi, first);
    var k: isize = @as(isize, @intCast(hi)) - 1;
    while (k >= 0) : (k -= 1) {
        vSwap(d, first, first + @as(usize, @intCast(k)));
        siftDown(d, 0, @intCast(k), first);
    }
}
const Hint = enum { unknown, increasing, decreasing };
fn pdqsort(d: []*Var, a0: usize, b0: usize, limit0: usize) void {
    var a = a0;
    var b = b0;
    var limit = limit0;
    var was_balanced = true;
    var was_partitioned = true;
    while (true) {
        const length = b - a;
        if (length <= 12) {
            insertionSort(d, a, b);
            return;
        }
        if (limit == 0) {
            heapSort(d, a, b);
            return;
        }
        if (!was_balanced) {
            breakPatterns(d, a, b);
            limit -= 1;
        }
        var cp = choosePivot(d, a, b);
        if (cp.hint == .decreasing) {
            reverseRange(d, a, b);
            cp.pivot = (b - 1) - (cp.pivot - a);
            cp.hint = .increasing;
        }
        if (was_balanced and was_partitioned and cp.hint == .increasing) {
            if (partialInsertionSort(d, a, b)) return;
        }
        if (a > 0 and !vLess(d, a - 1, cp.pivot)) {
            a = partitionEqual(d, a, b, cp.pivot);
            continue;
        }
        const pr = partition(d, a, b, cp.pivot);
        was_partitioned = pr.already;
        const mid = pr.mid;
        const left_len = mid - a;
        const right_len = b - mid;
        const bal = length / 8;
        if (left_len < right_len) {
            was_balanced = left_len >= bal;
            pdqsort(d, a, mid, limit);
            a = mid + 1;
        } else {
            was_balanced = right_len >= bal;
            pdqsort(d, mid + 1, b, limit);
            b = mid;
        }
    }
}
fn partition(d: []*Var, a: usize, b: usize, pivot: usize) struct { mid: usize, already: bool } {
    vSwap(d, a, pivot);
    var i: isize = @intCast(a + 1);
    var j: isize = @as(isize, @intCast(b)) - 1;
    const A_ = a;
    while (i <= j and vLess(d, @intCast(i), A_)) i += 1;
    while (i <= j and !vLess(d, @intCast(j), A_)) j -= 1;
    if (i > j) {
        vSwap(d, @intCast(j), A_);
        return .{ .mid = @intCast(j), .already = true };
    }
    vSwap(d, @intCast(i), @intCast(j));
    i += 1;
    j -= 1;
    while (true) {
        while (i <= j and vLess(d, @intCast(i), A_)) i += 1;
        while (i <= j and !vLess(d, @intCast(j), A_)) j -= 1;
        if (i > j) break;
        vSwap(d, @intCast(i), @intCast(j));
        i += 1;
        j -= 1;
    }
    vSwap(d, @intCast(j), A_);
    return .{ .mid = @intCast(j), .already = false };
}
fn partitionEqual(d: []*Var, a: usize, b: usize, pivot: usize) usize {
    vSwap(d, a, pivot);
    var i: isize = @intCast(a + 1);
    var j: isize = @as(isize, @intCast(b)) - 1;
    while (true) {
        while (i <= j and !vLess(d, a, @intCast(i))) i += 1;
        while (i <= j and vLess(d, a, @intCast(j))) j -= 1;
        if (i > j) break;
        vSwap(d, @intCast(i), @intCast(j));
        i += 1;
        j -= 1;
    }
    return @intCast(i);
}
fn partialInsertionSort(d: []*Var, a: usize, b: usize) bool {
    var i = a + 1;
    var step: usize = 0;
    while (step < 5) : (step += 1) {
        while (i < b and !vLess(d, i, i - 1)) i += 1;
        if (i == b) return true;
        if (b - a < 50) return false;
        vSwap(d, i, i - 1);
        if (i - a >= 2) {
            var j = i - 1;
            while (j >= 1) : (j -= 1) {
                if (!vLess(d, j, j - 1)) break;
                vSwap(d, j, j - 1);
            }
        }
        if (b - i >= 2) {
            var j = i + 1;
            while (j < b) : (j += 1) {
                if (!vLess(d, j, j - 1)) break;
                vSwap(d, j, j - 1);
            }
        }
    }
    return false;
}
fn breakPatterns(d: []*Var, a: usize, b: usize) void {
    const length = b - a;
    if (length >= 8) {
        var random: u64 = length;
        const modulus: usize = @as(usize, 1) << @intCast(std.math.log2_int(usize, length) + 1);
        var idx = a + (length / 4) * 2 - 1;
        while (idx <= a + (length / 4) * 2 + 1) : (idx += 1) {
            random ^= random << 13;
            random ^= random >> 7;
            random ^= random << 17;
            var other: usize = @intCast(random & (modulus - 1));
            if (other >= length) other -= length;
            vSwap(d, idx, a + other);
        }
    }
}
fn choosePivot(d: []*Var, a: usize, b: usize) struct { pivot: usize, hint: Hint } {
    const l = b - a;
    var swaps: usize = 0;
    var i = a + l / 4 * 1;
    var j = a + l / 4 * 2;
    var k = a + l / 4 * 3;
    if (l >= 8) {
        if (l >= 50) {
            i = medianAdjacent(d, i, &swaps);
            j = medianAdjacent(d, j, &swaps);
            k = medianAdjacent(d, k, &swaps);
        }
        j = median(d, i, j, k, &swaps);
    }
    return switch (swaps) {
        0 => .{ .pivot = j, .hint = .increasing },
        12 => .{ .pivot = j, .hint = .decreasing },
        else => .{ .pivot = j, .hint = .unknown },
    };
}
fn median(d: []*Var, a0: usize, b0: usize, c0: usize, swaps: *usize) usize {
    var a = a0;
    var b = b0;
    var c = c0;
    if (vLess(d, b, a)) {
        swaps.* += 1;
        const t = a;
        a = b;
        b = t;
    }
    if (vLess(d, c, b)) {
        swaps.* += 1;
        const t = b;
        b = c;
        c = t;
    }
    if (vLess(d, b, a)) {
        swaps.* += 1;
        const t = a;
        a = b;
        b = t;
    }
    return b;
}
fn medianAdjacent(d: []*Var, a: usize, swaps: *usize) usize {
    return median(d, a - 1, a, a + 1, swaps);
}
fn reverseRange(d: []*Var, a: usize, b: usize) void {
    var i = a;
    var j = b - 1;
    while (i < j) {
        vSwap(d, i, j);
        i += 1;
        j -= 1;
    }
}

// ---------------------------------------------------------------- var helpers

fn bindingUsed(b: ?*Node) bool {
    const n = b orelse return false;
    switch (n.*) {
        .var_ => |v| return 1 < v.uses,
        .binding_array => |ba| {
            for (ba.list.items) |item| if (item.binding != null and bindingUsed(item.binding)) return true;
            if (ba.rest != null and bindingUsed(ba.rest)) return true;
        },
        .binding_object => |bo| {
            for (bo.list.items) |item| if (item.value.binding != null and bindingUsed(item.value.binding)) return true;
            if (bo.rest) |r| return 1 < r.uses;
        },
        else => {},
    }
    return false;
}

fn appendBindingVars(vs: *L(*Var), b: ?*Node) void {
    const n = b orelse return;
    switch (n.*) {
        .var_ => |v| vs.append(sys.A, v) catch {},
        .binding_array => |ba| {
            for (ba.list.items) |item| if (item.binding != null) appendBindingVars(vs, item.binding);
            if (ba.rest != null) appendBindingVars(vs, ba.rest);
        },
        .binding_object => |bo| {
            for (bo.list.items) |item| if (item.value.binding != null) appendBindingVars(vs, item.value.binding);
            if (bo.rest) |r| vs.append(sys.A, r) catch {};
        },
        else => {},
    }
}

fn appendParamDefaults(vs: *L(*Var), params: ast.Params) void {
    for (params.list.items) |p| appendExprVars(vs, p.default);
}

fn appendExprVars(vs: *L(*Var), e: ?*Node) void {
    const n = e orelse return;
    switch (n.*) {
        .var_ => |v| vs.append(sys.A, v) catch {},
        .array => |l| for (l.items) |item| appendExprVars(vs, item.value),
        .object => |l| for (l.items) |item| {
            if (item.name != null and item.name.?.computed != null) appendExprVars(vs, item.name.?.computed);
            appendExprVars(vs, item.value);
            if (item.init) |init| appendExprVars(vs, init);
        },
        .template => |t| {
            appendExprVars(vs, t.tag);
            for (t.list.items) |item| appendExprVars(vs, item.expr);
        },
        .group => |g| appendExprVars(vs, g),
        .index => |x| {
            appendExprVars(vs, x.x);
            appendExprVars(vs, x.y);
        },
        .dot => |x| {
            appendExprVars(vs, x.x);
            appendExprVars(vs, x.y);
        },
        .new => |x| {
            appendExprVars(vs, x.x);
            if (x.args) |a| for (a.list.items) |item| appendExprVars(vs, item.value);
        },
        .call => |x| {
            appendExprVars(vs, x.x);
            for (x.args.list.items) |item| appendExprVars(vs, item.value);
        },
        .unary => |x| appendExprVars(vs, x.x),
        .binary => |x| {
            appendExprVars(vs, x.x);
            appendExprVars(vs, x.y);
        },
        .cond => |x| {
            appendExprVars(vs, x.cond);
            appendExprVars(vs, x.x);
            appendExprVars(vs, x.y);
        },
        .yield => |x| appendExprVars(vs, x.x),
        .comma => |l| for (l.items) |item| appendExprVars(vs, item),
        .arrow => |*x| {
            appendParamDefaults(vs, x.params);
            vs.appendSlice(sys.A, x.body.scope.undeclared.items) catch {};
        },
        .func_decl => |*x| {
            appendParamDefaults(vs, x.params);
            vs.appendSlice(sys.A, x.body.scope.undeclared.items) catch {};
        },
        .class_decl => |*x| {
            appendExprVars(vs, x.extends);
            for (x.list.items) |item| {
                if (item.static_block) |sb| {
                    vs.appendSlice(sys.A, sb.block.scope.undeclared.items) catch {};
                } else if (item.method) |mn| {
                    appendParamDefaults(vs, mn.method_decl.params);
                    vs.appendSlice(sys.A, mn.method_decl.body.scope.undeclared.items) catch {};
                } else {
                    if (item.field.name.private == null and item.field.name.pn.computed != null) appendExprVars(vs, item.field.name.pn.computed);
                    if (item.field.init) |init| appendExprVars(vs, init);
                }
            }
        },
        else => {},
    }
}

fn hasDefines(v: *ast.VarDecl) bool {
    for (v.list.items) |item| if (item.default != null) return true;
    return false;
}

fn addDefinition(decl: *ast.VarDecl, binding: ?*Node, value: ?*Node, forward: bool) void {
    if (decl.tt != lex.ErrorToken) {
        var vars: L(*Var) = .empty;
        appendBindingVars(&vars, binding);
        remove: for (vars.items) |vbind| {
            for (decl.list.items, 0..) |item, i| {
                if (isV(item.binding)) |v| {
                    if (item.default == null and v == vbind) {
                        v.uses -%= 1;
                        _ = decl.list.orderedRemove(i);
                        continue :remove;
                    }
                }
            }
            if (value != null) {
                for (decl.scope.?.func.?.var_decls.items) |d2n| {
                    const d2 = &d2n.var_decl;
                    if (!d2.in_for_in_of) {
                        for (d2.list.items, 0..) |item, i| {
                            if (isV(item.binding)) |v| {
                                if (item.default == null and v == vbind) {
                                    v.uses -%= 1;
                                    _ = d2.list.orderedRemove(i);
                                    continue :remove;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    const item: ast.BindingElement = .{ .binding = binding, .default = value };
    if (forward) {
        decl.list.insert(sys.A, 0, item) catch {};
    } else decl.list.append(sys.A, item) catch {};
}

fn mergeVarDecls(dst: *ast.VarDecl, src: *ast.VarDecl, forward: bool) void {
    if (forward) std.mem.reverse(ast.BindingElement, src.list.items);
    var j: usize = 0;
    while (j < src.list.items.len) : (j += 1) {
        addDefinition(dst, src.list.items[j].binding, src.list.items[j].default, forward);
    }
    src.list.items.len = 0;
}

fn mergeVarDeclExprStmt(decl: *ast.VarDecl, expr_stmt: *Node, forward: bool) bool {
    const value = expr_stmt.expr_stmt orelse return false;
    switch (value.*) {
        .var_decl => |*d2| {
            mergeVarDecls(decl, d2, forward);
            return true;
        },
        .comma => |*cl| {
            var n: usize = 0;
            const len = cl.items.len;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const item = if (forward) cl.items[len - i - 1] else cl.items[i];
                if (item.* == .var_decl) {
                    mergeVarDecls(decl, &item.var_decl, forward);
                    n += 1;
                    continue;
                } else if (item.* == .binary and item.binary.op == lex.EqToken) {
                    if (isV(item.binary.x)) |v| {
                        if (v.decl == .VariableDecl) {
                            addDefinition(decl, item.binary.x, item.binary.y, forward);
                            n += 1;
                            continue;
                        }
                    }
                }
                break;
            }
            const merge = n == len;
            if (!forward) {
                const rest = cl.items[n..];
                std.mem.copyForwards(*Node, cl.items[0..rest.len], rest);
                cl.items.len = rest.len;
            } else cl.items.len = len - n;
            return merge;
        },
        .binary => |b| {
            if (b.op == lex.EqToken) {
                if (isV(b.x)) |v| {
                    if (v.decl == .VariableDecl) {
                        addDefinition(decl, b.x, b.y, forward);
                        return true;
                    }
                }
            }
        },
        else => {},
    }
    return false;
}

// ---------------------------------------------------------------- statement lists

fn isEmptyStmt(s: ?*Node) bool {
    const n = s orelse return true;
    switch (n.*) {
        .empty => return true,
        .block => |b| {
            for (b.list.items) |item| if (!isEmptyStmt(item)) return false;
            return true;
        },
        else => return false,
    }
}
fn isFlowStmt(s: ?*Node) bool {
    const t = tag(s) orelse return false;
    return t == .return_stmt or t == .throw or t == .branch;
}
fn lastStmt(s: ?*Node) ?*Node {
    if (tag(s) == .block and s.?.block.list.items.len > 0) {
        const l = s.?.block.list.items;
        return lastStmt(l[l.len - 1]);
    }
    return s;
}
fn endsInIf(s: ?*Node) bool {
    const n = s orelse return false;
    switch (n.*) {
        .if_stmt => |x| {
            if (x.else_ == null) return optimizeStmt(n).* == .if_stmt;
            return endsInIf(x.else_);
        },
        .block => |b| if (b.list.items.len > 0) return endsInIf(b.list.items[b.list.items.len - 1]),
        .labelled => |x| return endsInIf(x.value),
        .with_stmt => |x| return endsInIf(x.body),
        .while_stmt => |x| return endsInIf(x.body),
        .for_stmt => |x| return endsInIf(x.body),
        .for_in => |x| return endsInIf(x.body),
        .for_of => |x| return endsInIf(x.body),
        else => {},
    }
    return false;
}

fn exprStmt(v: ?*Node) *Node {
    return newN(.{ .expr_stmt = v });
}

fn optimizeStmt(n: *Node) *Node {
    switch (n.*) {
        .if_stmt => |*s| {
            if (isTruthy(s.cond)) |truthy| {
                if (truthy) {
                    if (hasSideEffects(s.cond)) {
                        s.else_ = null;
                        return n;
                    }
                    return optimizeStmt(s.body orelse newN(.empty));
                }
                if (isEmptyStmt(s.else_)) {
                    if (hasSideEffects(s.cond)) return exprStmt(s.cond);
                    return newN(.empty);
                } else if (hasSideEffects(s.cond)) {
                    if (tag(s.cond) == .unary and s.cond.?.unary.op == lex.NotToken) {
                        s.cond = s.cond.?.unary.x;
                    } else s.cond = newN(.{ .unary = .{ .op = lex.NotToken, .x = s.cond } });
                    s.body = s.else_;
                    s.else_ = null;
                    return n;
                }
                return optimizeStmt(s.else_.?);
            }
            s.body = optimizeStmt(s.body orelse newN(.empty));
            if (s.else_) |e| s.else_ = optimizeStmt(e);
            var has_if = !isEmptyStmt(s.body);
            var has_else = !isEmptyStmt(s.else_);
            if (tag(s.cond) == .unary and s.cond.?.unary.op == lex.NotToken and has_else) {
                s.cond = s.cond.?.unary.x;
                const t = s.body;
                s.body = s.else_;
                s.else_ = t;
                const th = has_if;
                has_if = has_else;
                has_else = th;
            }
            if (!has_if and !has_else) {
                if (hasSideEffects(s.cond)) return exprStmt(s.cond);
                return newN(.empty);
            } else if (has_if and !has_else) {
                if (tag(s.body) == .expr_stmt) {
                    const xv = s.body.?.expr_stmt;
                    if (tag(s.cond) == .unary and s.cond.?.unary.op == lex.NotToken) {
                        const left = groupExpr(s.cond.?.unary.x, binaryLeftPrec(lex.OrToken));
                        const right = groupExpr(xv, binaryRightPrec(lex.OrToken));
                        return exprStmt(bin(lex.OrToken, left, right));
                    }
                    const left = groupExpr(s.cond, binaryLeftPrec(lex.AndToken));
                    const right = groupExpr(xv, binaryRightPrec(lex.AndToken));
                    return exprStmt(bin(lex.AndToken, left, right));
                } else if (tag(s.body) == .if_stmt and isEmptyStmt(s.body.?.if_stmt.else_)) {
                    const x = s.body.?.if_stmt;
                    const left = groupExpr(s.cond, binaryLeftPrec(lex.AndToken));
                    const right = groupExpr(x.cond, binaryRightPrec(lex.AndToken));
                    s.cond = bin(lex.AndToken, left, right);
                    s.body = x.body;
                    return n;
                }
            } else if (!has_if and has_else) {
                if (tag(s.else_) == .expr_stmt) {
                    const left = groupExpr(s.cond, binaryLeftPrec(lex.OrToken));
                    const right = groupExpr(s.else_.?.expr_stmt, binaryRightPrec(lex.OrToken));
                    return exprStmt(bin(lex.OrToken, left, right));
                }
            } else {
                if (tag(s.body) == .expr_stmt and tag(s.else_) == .expr_stmt) {
                    return exprStmt(condExpr(s.cond, s.body.?.expr_stmt, s.else_.?.expr_stmt));
                }
                if (tag(s.body) == .return_stmt and tag(s.else_) == .return_stmt) {
                    const xr = s.body.?.return_stmt;
                    const yr = s.else_.?.return_stmt;
                    if (xr == null and yr == null) {
                        const z = newN(.{ .literal = .{ .tt = lex.NumericToken, .data = @constCast("0") } });
                        return newN(.{ .return_stmt = commaExpr(s.cond, newN(.{ .unary = .{ .op = lex.VoidToken, .x = z } })) });
                    } else if (xr != null and yr != null) {
                        return newN(.{ .return_stmt = condExpr(s.cond, xr, yr) });
                    }
                    return n;
                }
                if (tag(s.body) == .throw and tag(s.else_) == .throw) {
                    return newN(.{ .throw = condExpr(s.cond, s.body.?.throw, s.else_.?.throw) });
                }
            }
        },
        .var_decl => |*d| {
            if (d.tt == lex.ErrorToken) {
                for (d.list.items) |item| if (item.default != null) return exprStmt(n);
                return newN(.empty);
            }
            return n;
        },
        .block => |*b| {
            b.list = optimizeStmtList(b.list, .default);
            if (b.list.items.len == 1) {
                const only = b.list.items[0];
                if (only.* == .class_decl) {
                    return newN(.empty);
                } else if (only.* == .var_decl and only.var_decl.tt != lex.VarToken) {
                    var exprs: L(*Node) = .empty;
                    for (only.var_decl.list.items) |item| {
                        if (bindingUsed(item.binding)) {
                            return n;
                        } else if (item.default != null and hasSideEffects(item.default)) {
                            exprs.append(sys.A, item.default.?) catch {};
                        }
                    }
                    if (exprs.items.len == 0) return newN(.empty);
                    if (exprs.items.len == 1) return exprStmt(exprs.items[0]);
                    return exprStmt(newN(.{ .comma = exprs }));
                }
                return optimizeStmt(only);
            } else if (b.list.items.len == 0) return newN(.empty);
            return n;
        },
        else => {},
    }
    return n;
}

fn optimizeStmtList(list0: L(*Node), bt: BlockType) L(*Node) {
    var list = list0;
    if (list.items.len == 0) return list;
    var j: usize = 0;
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i].* == .if_stmt and !isEmptyStmt(list.items[i].if_stmt.else_)) {
            const ifs = &list.items[i].if_stmt;
            if (tag(ifs.cond) == .unary and ifs.cond.?.unary.op == lex.NotToken and isFlowStmt(lastStmt(ifs.else_))) {
                ifs.cond = ifs.cond.?.unary.x;
                const t = ifs.body;
                ifs.body = ifs.else_;
                ifs.else_ = t;
            }
            if (isFlowStmt(lastStmt(ifs.body))) {
                if (tag(ifs.else_) == .block) {
                    const eb = &ifs.else_.?.block;
                    eb.scope.unscope();
                    list.insertSlice(sys.A, i + 1, eb.list.items) catch {};
                } else {
                    list.insert(sys.A, i + 1, ifs.else_.?) catch {};
                }
                list.items[i].if_stmt.else_ = null;
            }
        }
        list.items[i] = optimizeStmt(list.items[i]);
        if (list.items[i].* == .empty) continue;
        const items = list.items;
        if (0 < j) {
            const prev = items[j - 1];
            const cur = items[i];
            if (prev.* == .expr_stmt) {
                const lv = prev.expr_stmt;
                switch (cur.*) {
                    .expr_stmt => |*rv| {
                        rv.* = commaExpr(lv, rv.*);
                        j -= 1;
                    },
                    .return_stmt => |*rv| {
                        if (rv.* != null) {
                            rv.* = commaExpr(lv, rv.*);
                            j -= 1;
                        }
                    },
                    .throw => |*rv| {
                        rv.* = commaExpr(lv, rv.*);
                        j -= 1;
                    },
                    .for_stmt => |*fs| {
                        if (fs.init == null) {
                            fs.init = lv;
                            j -= 1;
                        } else if (fs.init.?.* == .var_decl) {
                            const d = &fs.init.?.var_decl;
                            if (d.list.items.len == 0) {
                                fs.init = lv;
                                j -= 1;
                            } else if (d.tt == lex.VarToken or d.tt == lex.ErrorToken) {
                                if (mergeVarDeclExprStmt(d, prev, true)) j -= 1;
                            }
                        }
                    },
                    .while_stmt => |ws| {
                        var body: *Node = undefined;
                        if (tag(ws.body) == .block) {
                            body = ws.body.?;
                        } else {
                            body = newN(.{ .block = .{} });
                            body.block.list.append(sys.A, ws.body orelse newN(.empty)) catch {};
                        }
                        items[i] = newN(.{ .for_stmt = .{ .init = lv, .cond = ws.cond, .post = null, .body = body } });
                        j -= 1;
                    },
                    .switch_stmt => |*ss| {
                        ss.init = commaExpr(lv, ss.init);
                        j -= 1;
                    },
                    .with_stmt => |*ws| {
                        ws.cond = commaExpr(lv, ws.cond);
                        j -= 1;
                    },
                    .if_stmt => |*is| {
                        is.cond = commaExpr(lv, is.cond);
                        j -= 1;
                    },
                    .var_decl => |*vd| {
                        if (vd.tt == lex.VarToken) {
                            if (mergeVarDeclExprStmt(vd, prev, true)) j -= 1;
                        }
                    },
                    else => {},
                }
            } else if (prev.* == .var_decl) {
                const left = &prev.var_decl;
                if (cur.* == .var_decl and left.tt == cur.var_decl.tt) {
                    var nl: L(ast.BindingElement) = .empty;
                    nl.appendSlice(sys.A, left.list.items) catch {};
                    nl.appendSlice(sys.A, cur.var_decl.list.items) catch {};
                    cur.var_decl.list = nl;
                    j -= 1;
                    const scope = left.scope.?.func.?;
                    for (scope.var_decls.items, 0..) |d, k| {
                        if (d == prev) {
                            _ = scope.var_decls.orderedRemove(k);
                            break;
                        }
                    }
                } else if (left.tt == lex.VarToken) {
                    if (cur.* == .expr_stmt) {
                        if (mergeVarDeclExprStmt(left, cur, false)) {
                            items[i] = items[j - 1];
                            j -= 1;
                        }
                    } else if (cur.* == .for_stmt) {
                        const fs = &cur.for_stmt;
                        if (fs.init == null) {
                            fs.init = prev;
                            j -= 1;
                        } else if (fs.init.?.* == .var_decl) {
                            const d = &fs.init.?.var_decl;
                            if (d.tt == lex.ErrorToken and !hasDefines(d)) {
                                fs.init = prev;
                                j -= 1;
                            } else if (d.tt == lex.VarToken or d.tt == lex.ErrorToken) {
                                mergeVarDecls(left, d, false);
                                d.tt = lex.VarToken;
                                fs.init = prev;
                                j -= 1;
                            }
                        }
                    } else if (cur.* == .while_stmt) {
                        const ws = cur.while_stmt;
                        var body: *Node = undefined;
                        if (tag(ws.body) == .block) {
                            body = ws.body.?;
                        } else {
                            body = newN(.{ .block = .{} });
                            body.block.list.append(sys.A, ws.body orelse newN(.empty)) catch {};
                        }
                        items[i] = newN(.{ .for_stmt = .{ .init = prev, .cond = ws.cond, .post = null, .body = body } });
                        j -= 1;
                    }
                }
            }
        }
        items[j] = items[i];
        // MergeIfReturnThrow
        while (0 < j) {
            const ifn = items[j - 1];
            if (ifn.* != .if_stmt) break;
            const ifs = &ifn.if_stmt;
            if (isEmptyStmt(ifs.body) == isEmptyStmt(ifs.else_)) break;
            const cur = items[j];
            var again = false;
            if (cur.* == .return_stmt) {
                if (cur.return_stmt == null) {
                    if (tag(ifs.body) == .return_stmt and ifs.body.?.return_stmt == null) {
                        items[j - 1] = exprStmt(ifs.cond);
                    } else if (tag(ifs.else_) == .return_stmt and ifs.else_.?.return_stmt == null) {
                        items[j - 1] = exprStmt(ifs.cond);
                    }
                } else {
                    if (tag(ifs.body) == .return_stmt and ifs.body.?.return_stmt != null) {
                        cur.return_stmt = condExpr(ifs.cond, ifs.body.?.return_stmt, cur.return_stmt);
                        items[j - 1] = cur;
                        j -= 1;
                        again = true;
                    } else if (tag(ifs.else_) == .return_stmt and ifs.else_.?.return_stmt != null) {
                        cur.return_stmt = condExpr(ifs.cond, cur.return_stmt, ifs.else_.?.return_stmt);
                        items[j - 1] = cur;
                        j -= 1;
                        again = true;
                    }
                }
            } else if (cur.* == .throw) {
                if (tag(ifs.body) == .throw) {
                    cur.throw = condExpr(ifs.cond, ifs.body.?.throw, cur.throw);
                    items[j - 1] = cur;
                    j -= 1;
                    again = true;
                } else if (tag(ifs.else_) == .throw) {
                    cur.throw = condExpr(ifs.cond, cur.throw, ifs.else_.?.throw);
                    items[j - 1] = cur;
                    j -= 1;
                    again = true;
                }
            }
            if (!again) break;
        }
        j += 1;
    }
    if (0 < j) {
        const items = list.items;
        if (bt == .function) {
            const last = items[j - 1];
            if (last.* == .return_stmt) {
                if (last.return_stmt == null or isUndefined(last.return_stmt)) {
                    j -= 1;
                } else if (tag(last.return_stmt) == .comma) {
                    const cl = &last.return_stmt.?.comma;
                    if (isUndefined(cl.items[cl.items.len - 1])) {
                        if (cl.items.len == 2) {
                            items[j - 1] = exprStmt(cl.items[0]);
                        } else cl.items.len -= 1;
                    }
                }
            }
        } else if (bt == .iteration) {
            const last = items[j - 1];
            if (last.* == .branch and last.branch.tt == lex.ContinueToken and last.branch.label == null) j -= 1;
        }
    }
    list.items.len = j;
    return list;
}

// ---------------------------------------------------------------- expression utils

fn unaryPrec(op: TT) OpPrec {
    return switch (op) {
        lex.PostIncrToken, lex.PostDecrToken => ast.OpLHS,
        else => ast.OpUnary,
    };
}
fn unaryOpPrec(op: TT) OpPrec {
    return switch (op) {
        lex.PostIncrToken, lex.PostDecrToken, lex.PreIncrToken, lex.PreDecrToken => ast.OpUpdate,
        lex.NotToken, lex.BitNotToken, lex.TypeofToken, lex.VoidToken, lex.DeleteToken, lex.PosToken, lex.NegToken, lex.AwaitToken => ast.OpUnary,
        else => 0,
    };
}
fn isAssignOp(op: TT) bool {
    return switch (op) {
        lex.EqToken, lex.MulEqToken, lex.DivEqToken, lex.ModEqToken, lex.ExpEqToken, lex.AddEqToken, lex.SubEqToken, lex.LtLtEqToken, lex.GtGtEqToken, lex.GtGtGtEqToken, lex.BitAndEqToken, lex.BitXorEqToken, lex.BitOrEqToken, lex.AndEqToken, lex.OrEqToken, lex.NullishEqToken => true,
        else => false,
    };
}
fn binaryLeftPrec(op: TT) OpPrec {
    if (isAssignOp(op)) return ast.OpLHS;
    return switch (op) {
        lex.ExpToken => ast.OpUpdate,
        lex.MulToken, lex.DivToken, lex.ModToken => ast.OpMul,
        lex.AddToken, lex.SubToken => ast.OpAdd,
        lex.LtLtToken, lex.GtGtToken, lex.GtGtGtToken => ast.OpShift,
        lex.LtToken, lex.LtEqToken, lex.GtToken, lex.GtEqToken, lex.InToken, lex.InstanceofToken => ast.OpCompare,
        lex.EqEqToken, lex.NotEqToken, lex.EqEqEqToken, lex.NotEqEqToken => ast.OpEquals,
        lex.BitAndToken => ast.OpBitAnd,
        lex.BitXorToken => ast.OpBitXor,
        lex.BitOrToken => ast.OpBitOr,
        lex.AndToken => ast.OpAnd,
        lex.OrToken => ast.OpOr,
        lex.NullishToken => ast.OpBitOr,
        else => ast.OpExpr,
    };
}
fn binaryRightPrec(op: TT) OpPrec {
    if (isAssignOp(op)) return ast.OpAssign;
    return switch (op) {
        lex.ExpToken, lex.MulToken, lex.DivToken, lex.ModToken => ast.OpExp,
        lex.AddToken, lex.SubToken => ast.OpMul,
        lex.LtLtToken, lex.GtGtToken, lex.GtGtGtToken => ast.OpAdd,
        lex.LtToken, lex.LtEqToken, lex.GtToken, lex.GtEqToken, lex.InToken, lex.InstanceofToken => ast.OpShift,
        lex.EqEqToken, lex.NotEqToken, lex.EqEqEqToken, lex.NotEqEqToken => ast.OpCompare,
        lex.BitAndToken => ast.OpEquals,
        lex.BitXorToken => ast.OpBitAnd,
        lex.BitOrToken => ast.OpBitXor,
        lex.AndToken => ast.OpAnd,
        lex.OrToken => ast.OpOr,
        lex.NullishToken => ast.OpBitOr,
        lex.CommaToken => ast.OpAssign,
        else => ast.OpExpr,
    };
}
fn binaryOpPrec(op: TT) OpPrec {
    if (op == lex.AndEqToken or op == lex.OrEqToken or op == lex.NullishEqToken) return 0; // not in Go's map
    if (isAssignOp(op)) return ast.OpAssign;
    return switch (op) {
        lex.ExpToken => ast.OpExp,
        lex.MulToken, lex.DivToken, lex.ModToken => ast.OpMul,
        lex.AddToken, lex.SubToken => ast.OpAdd,
        lex.LtLtToken, lex.GtGtToken, lex.GtGtGtToken => ast.OpShift,
        lex.LtToken, lex.LtEqToken, lex.GtToken, lex.GtEqToken, lex.InToken, lex.InstanceofToken => ast.OpCompare,
        lex.EqEqToken, lex.NotEqToken, lex.EqEqEqToken, lex.NotEqEqToken => ast.OpEquals,
        lex.BitAndToken => ast.OpBitAnd,
        lex.BitXorToken => ast.OpBitXor,
        lex.BitOrToken => ast.OpBitOr,
        lex.AndToken => ast.OpAnd,
        lex.OrToken => ast.OpOr,
        lex.NullishToken => ast.OpCoalesce,
        else => ast.OpExpr,
    };
}

fn exprPrec(e: ?*Node) OpPrec {
    const n = e orelse return ast.OpExpr;
    return switch (n.*) {
        .var_, .literal, .array, .object, .func_decl, .class_decl => ast.OpPrimary,
        .unary => |u| unaryOpPrec(u.op),
        .binary => |b| binaryOpPrec(b.op),
        .new => |x| if (x.args == null) ast.OpNew else ast.OpMember,
        .template => |t| if (t.tag == null) ast.OpPrimary else t.prec,
        .dot => |x| x.prec,
        .index => |x| x.prec,
        .new_target, .import_meta => ast.OpMember,
        .call => |x| x.prec,
        .cond, .yield, .arrow => ast.OpAssign,
        .group => |g| exprPrec(g),
        else => ast.OpExpr,
    };
}

fn hasSideEffects(e: ?*Node) bool {
    const n = e orelse return true;
    switch (n.*) {
        .var_ => return true,
        .literal, .func_decl, .class_decl, .arrow, .new_target, .import_meta => return false,
        .new, .call, .yield => return true,
        .group => |g| return hasSideEffects(g),
        .dot, .index => return true,
        .cond => |c| return hasSideEffects(c.cond) or hasSideEffects(c.x) or hasSideEffects(c.y),
        .comma => |l| {
            for (l.items) |item| if (hasSideEffects(item)) return true;
            return true; // Go falls through to `return true`
        },
        .array => |l| {
            for (l.items) |item| if (hasSideEffects(item.value)) return true;
            return false;
        },
        .object => |l| {
            for (l.items) |item| {
                if (hasSideEffects(item.value) or (item.init != null and hasSideEffects(item.init)) or (item.name != null and item.name.?.isComputed() and hasSideEffects(item.name.?.computed))) return true;
            }
            return false;
        },
        .template => |t| {
            if (t.tag != null and hasSideEffects(t.tag)) return true;
            if (t.tag == null) {
                // hasSideEffects(nil) is true in Go (falls through to the default)
                return true;
            }
            for (t.list.items) |item| if (hasSideEffects(item.expr)) return true;
            return false;
        },
        .unary => |u| {
            if (u.op == lex.DeleteToken or u.op == lex.PreIncrToken or u.op == lex.PreDecrToken or u.op == lex.PostIncrToken or u.op == lex.PostDecrToken) return true;
            return hasSideEffects(u.x);
        },
        .binary => |b| {
            if (binaryOpPrec(b.op) == ast.OpAssign) return true;
            return hasSideEffects(b.x) or hasSideEffects(b.y);
        },
        else => return true,
    }
}

fn groupExpr(i: ?*Node, prec: OpPrec) ?*Node {
    const pi = exprPrec(i);
    if (tag(i) != .group and pi < prec and (pi != ast.OpCoalesce or prec != ast.OpBitOr)) return newN(.{ .group = i });
    return i;
}
fn bin(op: TT, x: ?*Node, y: ?*Node) *Node {
    return newN(.{ .binary = .{ .op = op, .x = x, .y = y } });
}
fn condExpr(cond: ?*Node, x: ?*Node, y: ?*Node) *Node {
    if (tag(cond) == .comma) {
        const cl = &cond.?.comma;
        const last = cl.items.len - 1;
        cl.items[last] = newN(.{ .cond = .{ .cond = groupExpr(cl.items[last], ast.OpCoalesce), .x = groupExpr(x, ast.OpAssign), .y = groupExpr(y, ast.OpAssign) } });
        return cond.?;
    }
    return newN(.{ .cond = .{ .cond = groupExpr(cond, ast.OpCoalesce), .x = groupExpr(x, ast.OpAssign), .y = groupExpr(y, ast.OpAssign) } });
}
fn commaExpr(x: ?*Node, y: ?*Node) *Node {
    var c: *Node = undefined;
    if (tag(x) == .comma) {
        c = x.?;
    } else {
        c = newN(.{ .comma = .empty });
        c.comma.append(sys.A, x orelse newN(.empty)) catch {};
    }
    if (tag(y) == .comma) {
        c.comma.appendSlice(sys.A, y.?.comma.items) catch {};
    } else c.comma.append(sys.A, y orelse newN(.empty)) catch {};
    return c;
}
fn innerExpr(in0: ?*Node) ?*Node {
    var i = in0;
    while (tag(i) == .group) i = i.?.group;
    return i;
}
fn finalExpr(in0: ?*Node) ?*Node {
    var i = innerExpr(in0);
    if (tag(i) == .comma) {
        const l = i.?.comma.items;
        i = l[l.len - 1];
    }
    if (tag(i) == .binary and i.?.binary.op == lex.EqToken) i = i.?.binary.x;
    return i;
}
fn isTrue(in0: ?*Node) bool {
    const i = innerExpr(in0);
    if (tag(i) == .literal and i.?.literal.tt == lex.TrueToken) return true;
    if (tag(i) == .unary and i.?.unary.op == lex.NotToken) return isFalsy(i.?.unary.x) orelse false;
    return false;
}
fn isFalse(in0: ?*Node) bool {
    const i = innerExpr(in0);
    if (tag(i) == .literal) return i.?.literal.tt == lex.FalseToken;
    if (tag(i) == .unary and i.?.unary.op == lex.NotToken) return isTruthy(i.?.unary.x) orelse false;
    return false;
}
fn isEqualExpr(a0: ?*Node, b0: ?*Node) bool {
    const a = isV(innerExpr(a0)) orelse return false;
    const b = isV(innerExpr(b0)) orelse return false;
    return eql(a.name(), b.name());
}

fn toNullishExpr(n: *Node) ?*Node {
    const ce = &n.cond;
    const r = isUndefinedOrNullVar(ce.cond) orelse return null;
    var left = ce.x;
    var right = ce.y;
    if (r.not) {
        const t = left;
        left = right;
        right = t;
    }
    const vnode = ast.newVarNode(r.v);
    if (isEqualExpr(vnode, right)) {
        return bin(lex.NullishToken, groupExpr(right, binaryLeftPrec(lex.NullishToken)), groupExpr(left, binaryRightPrec(lex.NullishToken)));
    } else if (isUndefined(left)) {
        var expr = right;
        var parent: ?*Node = null;
        while (true) {
            const prev = expr;
            const t = tag(expr) orelse break;
            switch (t) {
                .call => expr = expr.?.call.x,
                .dot => expr = expr.?.dot.x,
                .index => expr = expr.?.index.x,
                .template => expr = expr.?.template.tag,
                else => break,
            }
            parent = prev;
        }
        if (parent != null and isEqualExpr(vnode, expr)) {
            switch (parent.?.*) {
                .call => |*x| x.optional = true,
                .dot => |*x| x.optional = true,
                .index => |*x| x.optional = true,
                .template => |*x| x.optional = true,
                else => {},
            }
            return right;
        }
    }
    return null;
}

const UNV = struct { v: *Var, not: bool };
fn isUndefinedOrNullVar(in0: ?*Node) ?UNV {
    const i = innerExpr(in0);
    if (tag(i) != .binary) return null;
    const b = i.?.binary;
    if (b.op == lex.OrToken or b.op == lex.AndToken) {
        const eq_op: TT = if (b.op == lex.AndToken) lex.NotEqToken else lex.EqEqToken;
        const eqeq_op: TT = if (b.op == lex.AndToken) lex.NotEqEqToken else lex.EqEqEqToken;
        const lx = innerExpr(b.x);
        const ry = innerExpr(b.y);
        if (tag(lx) == .binary and tag(ry) == .binary) {
            const left = lx.?.binary;
            const right = ry.?.binary;
            if ((left.op == eq_op or left.op == eqeq_op) and (right.op == eq_op or right.op == eqeq_op)) {
                var lv: ?*Var = null;
                var rv: ?*Var = null;
                if (isV(left.x) != null and isUndefinedOrNull(left.y)) {
                    lv = isV(left.x);
                } else if (isV(left.y) != null and isUndefinedOrNull(left.x)) lv = isV(left.y);
                if (isV(right.x) != null and isUndefinedOrNull(right.y)) {
                    rv = isV(right.x);
                } else if (isV(right.y) != null and isUndefinedOrNull(right.x)) rv = isV(right.y);
                if (lv != null and lv == rv) return .{ .v = lv.?, .not = b.op == lex.AndToken };
            }
        }
    } else if (b.op == lex.EqEqToken or b.op == lex.NotEqToken) {
        var v: ?*Var = null;
        if (isV(b.x) != null and isUndefinedOrNull(b.y)) {
            v = isV(b.x);
        } else if (isV(b.y) != null and isUndefinedOrNull(b.x)) v = isV(b.y);
        if (v) |vv| return .{ .v = vv, .not = b.op == lex.NotEqToken };
    }
    return null;
}
fn isUndefinedOrNull(in0: ?*Node) bool {
    const i = innerExpr(in0);
    if (tag(i) == .literal) return i.?.literal.tt == lex.NullToken;
    return isUndefined(i);
}
fn isUndefined(in0: ?*Node) bool {
    const i = innerExpr(in0);
    if (isV(i)) |v| return eql(v.name(), "undefined");
    if (tag(i) == .unary and i.?.unary.op == lex.VoidToken) return !hasSideEffects(i.?.unary.x);
    return false;
}
fn isTruthy(i: ?*Node) ?bool {
    if (isFalsy(i)) |f| return !f;
    return null;
}
fn isFalsy(in0: ?*Node) ?bool {
    var negated = false;
    var i = in0;
    while (true) {
        if (tag(i) == .group) {
            i = i.?.group;
        } else if (tag(i) == .unary and i.?.unary.op == lex.NotToken) {
            i = i.?.unary.x;
            negated = !negated;
        } else break;
    }
    if (tag(i) == .literal) {
        const lit = i.?.literal;
        const tt = lit.tt;
        if (tt == lex.FalseToken or tt == lex.NullToken or (tt == lex.StringToken and lit.data.len == 0)) return !negated;
        if (tt == lex.TrueToken or tt == lex.StringToken) return negated;
        if (tt == lex.DecimalToken or tt == lex.BinaryToken or tt == lex.OctalToken or tt == lex.HexadecimalToken or tt == lex.IntegerToken) {
            for (lit.data) |c| {
                if (c == 'e' or c == 'E' or c == 'n') break;
                if (c != '0' and c != '.' and c != 'x' and c != 'X' and c != 'b' and c != 'B' and c != 'o' and c != 'O') return negated;
            }
            return !negated;
        }
    } else if (isUndefined(i)) {
        return !negated;
    } else if (isV(i)) |v| {
        if (eql(v.name(), "NaN")) return !negated;
    }
    return null;
}
fn isBooleanExpr(e: ?*Node) bool {
    const n = e orelse return false;
    return switch (n.*) {
        .unary => |u| u.op == lex.NotToken,
        .binary => |b| blk: {
            const op = binaryOpPrec(b.op);
            if (op == ast.OpAnd or op == ast.OpOr) break :blk isBooleanExpr(b.x) and isBooleanExpr(b.y);
            break :blk op == ast.OpCompare or op == ast.OpEquals;
        },
        .literal => |l| l.tt == lex.TrueToken or l.tt == lex.FalseToken,
        .group => |g| isBooleanExpr(g),
        else => false,
    };
}
fn invertBooleanOp(op: TT) TT {
    return switch (op) {
        lex.EqEqToken => lex.NotEqToken,
        lex.NotEqToken => lex.EqEqToken,
        lex.EqEqEqToken => lex.NotEqEqToken,
        lex.NotEqEqToken => lex.EqEqEqToken,
        else => lex.ErrorToken,
    };
}
fn optimizeBooleanExpr(e: ?*Node, invert: bool, prec: OpPrec) ?*Node {
    if (invert) {
        if (tag(e) == .binary and binaryOpPrec(e.?.binary.op) == ast.OpEquals) {
            e.?.binary.op = invertBooleanOp(e.?.binary.op);
            return e;
        }
        return optimizeUnaryExpr(newN(.{ .unary = .{ .op = lex.NotToken, .x = groupExpr(e, ast.OpUnary) } }), prec);
    } else if (isBooleanExpr(e)) {
        return groupExpr(e, prec);
    }
    return newN(.{ .unary = .{ .op = lex.NotToken, .x = newN(.{ .unary = .{ .op = lex.NotToken, .x = groupExpr(e, ast.OpUnary) } }) } });
}
fn optimizeUnaryExpr(n: *Node, prec: OpPrec) *Node {
    const e = n.unary;
    if (e.op != lex.NotToken) return n;
    var invert = true;
    var e2 = e.x;
    while (true) {
        if (tag(e2) == .unary and e2.?.unary.op == lex.NotToken) {
            invert = !invert;
            e2 = e2.?.unary.x;
        } else if (tag(e2) == .group) {
            e2 = e2.?.group;
        } else break;
    }
    if (!invert and isBooleanExpr(e2)) {
        return groupExpr(e2, prec).?;
    } else if (tag(e2) == .binary and invert) {
        const b = &e2.?.binary;
        if (binaryOpPrec(b.op) == ast.OpEquals) {
            b.op = invertBooleanOp(b.op);
            return groupExpr(e2, prec).?;
        } else if (b.op == lex.AndToken or b.op == lex.OrToken) {
            const op: TT = if (b.op == lex.AndToken) lex.OrToken else lex.AndToken;
            const prec_inside = binaryOpPrec(op);
            const needs_group = prec_inside < prec and (prec_inside != ast.OpCoalesce or prec != ast.OpBitOr);
            var score: i64 = 3;
            if (needs_group) score -= 2;
            score -= 2;
            var is_eq_x = false;
            var is_eq_y = false;
            if (tag(b.x) == .binary and binaryOpPrec(b.x.?.binary.op) == ast.OpEquals) {
                score += 1;
                is_eq_x = true;
            }
            if (tag(b.y) == .binary and binaryOpPrec(b.y.?.binary.op) == ast.OpEquals) {
                score += 1;
                is_eq_y = true;
            }
            var ngx = false;
            var ngy = false;
            if (!is_eq_x and binaryLeftPrec(b.op) <= exprPrec(b.x) and exprPrec(b.x) < ast.OpUnary) {
                score -= 2;
                ngx = true;
            }
            if (!is_eq_y and binaryRightPrec(b.op) <= exprPrec(b.y) and exprPrec(b.y) < ast.OpUnary) {
                score -= 2;
                ngy = true;
            }
            if (op == lex.OrToken) {
                if (exprPrec(b.x) == ast.OpOr) score += 2;
                if (exprPrec(b.y) == ast.OpAnd) score += 2;
            }
            if (0 < score) {
                b.op = op;
                if (is_eq_x) b.x.?.binary.op = invertBooleanOp(b.x.?.binary.op);
                if (is_eq_y) b.y.?.binary.op = invertBooleanOp(b.y.?.binary.op);
                if (ngx) b.x = newN(.{ .group = b.x });
                if (ngy) b.y = newN(.{ .group = b.y });
                if (!is_eq_x) b.x = newN(.{ .unary = .{ .op = lex.NotToken, .x = b.x } });
                if (!is_eq_y) b.y = newN(.{ .unary = .{ .op = lex.NotToken, .x = b.y } });
                if (needs_group) return newN(.{ .group = e2 });
                return e2.?;
            }
        }
    }
    return n;
}

fn mergeBinaryExpr(n0: *Node) void {
    var n = n0;
    while (n.binary.op == lex.AddToken) {
        const expr = &n.binary;
        if (tag(expr.y) == .literal and expr.y.?.literal.tt == lex.StringToken) {
            var left = expr;
            var strings: L(*ast.Literal) = .empty;
            strings.append(sys.A, &expr.y.?.literal) catch {};
            while (left.op == lex.AddToken) {
                if (50 < strings.items.len) return;
                if (tag(left.x) == .literal and left.x.?.literal.tt == lex.StringToken) {
                    strings.append(sys.A, &left.x.?.literal) catch {};
                    left.x = null;
                } else if (tag(left.x) == .binary) {
                    const nl = &left.x.?.binary;
                    if (tag(nl.y) == .literal and nl.y.?.literal.tt == lex.StringToken) {
                        strings.append(sys.A, &nl.y.?.literal) catch {};
                        left = nl;
                        continue;
                    }
                }
                break;
            }
            const s = strings.items;
            if (1 < s.len) {
                var b: std.ArrayList(u8) = .empty;
                const lastd = s[s.len - 1].data;
                b.appendSlice(sys.A, lastd[0 .. lastd.len - 1]) catch {};
                var k = s.len - 2;
                while (0 < k) : (k -= 1) b.appendSlice(sys.A, s[k].data[1 .. s[k].data.len - 1]) catch {};
                b.appendSlice(sys.A, s[0].data[1..]) catch {};
                b.items[b.items.len - 1] = b.items[0];
                expr.x = left.x;
                expr.y.?.literal.data = b.items;
            }
        }
        if (tag(n.binary.x) != .binary) break;
        n = n.binary.x.?;
    }
}

// ---------------------------------------------------------------- literals

fn isHexDigit(b: u8) bool {
    return ('0' <= b and b <= '9') or ('a' <= b and b <= 'f') or ('A' <= b and b <= 'F');
}

fn minifyString(b0: []u8, allow_template: bool, escape_html: bool) []u8 {
    const b = b0;
    if (b.len < 3) return @constCast("\"\"");
    var single: usize = 0;
    var double: usize = 0;
    var backtick: usize = 0;
    var newlines: usize = 0;
    var dollars: usize = 0;
    var i: usize = 1;
    while (i < b.len - 1) : (i += 1) {
        const c = b[i];
        if (c == '\'') {
            single += 1;
        } else if (c == '"') {
            double += 1;
        } else if (c == '`') {
            backtick += 1;
        } else if (c == '$' and i + 1 < b.len and b[i + 1] == '{') {
            dollars += 1;
        } else if (c == '\\' and i + 1 < b.len) {
            const d = b[i + 1];
            if (d == 'n') {
                newlines += 1;
            } else if ('1' <= d and d <= '9' and i + 2 < b.len) {
                if (d == '1' and b[i + 2] == '2') {
                    newlines += 1;
                } else if (d == '4' and b[i + 2] == '2') {
                    double += 1;
                } else if (d == '4' and b[i + 2] == '7') {
                    single += 1;
                } else if (i + 3 < b.len and d == '1' and b[i + 2] == '4' and b[i + 3] == '0') backtick += 1;
            } else if (d == 'x' and i + 3 < b.len) {
                if (b[i + 2] == '0' and b[i + 3] | 0x20 == 'a') {
                    newlines += 1;
                } else if (b[i + 2] == '2' and b[i + 3] == '2') {
                    double += 1;
                } else if (b[i + 2] == '2' and b[i + 3] == '7') {
                    single += 1;
                } else if (b[i + 2] == '6' and b[i + 3] == '0') backtick += 1;
            } else if (d == 'u' and i + 5 < b.len and b[i + 2] == '0' and b[i + 3] == '0') {
                if (b[i + 4] == '0' and b[i + 5] | 0x20 == 'a') {
                    newlines += 1;
                } else if (b[i + 4] == '2' and b[i + 5] == '2') {
                    double += 1;
                } else if (b[i + 4] == '2' and b[i + 5] == '7') {
                    single += 1;
                } else if (b[i + 4] == '6' and b[i + 5] == '0') backtick += 1;
            } else if (d == 'u' and i + 4 < b.len and b[i + 2] == '{') {
                var j = i + 3;
                while (j < b.len and b[j] == '0') j += 1;
                if (j + 1 < b.len and b[j] | 0x20 == 'a' and b[j + 1] == '}') {
                    newlines += 1;
                } else if (j + 2 < b.len and b[j + 2] == '}') {
                    if (b[j] == '2' and b[j + 1] == '2') {
                        double += 1;
                    } else if (b[j] == '2' and b[j + 1] == '7') {
                        single += 1;
                    } else if (b[j] == '6' and b[j + 1] == '0') backtick += 1;
                }
            }
        }
    }
    var quote: u8 = '"';
    var quotes = double;
    if (double < single) {
        quote = '"';
    } else if (single < double) {
        quote = '\'';
        quotes = single;
    }
    if (allow_template and backtick + dollars < quotes + newlines) quote = '`';
    b[0] = quote;
    b[b.len - 1] = quote;
    return replaceEscapes(b, quote, 1, 1, escape_html);
}

fn insertAt(b: []u8, i: usize, c: u8) []u8 {
    const nb = sys.A.alloc(u8, b.len + 1) catch return b;
    @memcpy(nb[0..i], b[0..i]);
    nb[i] = c;
    @memcpy(nb[i + 1 ..], b[i..]);
    return nb;
}

fn replaceEscapes(b0: []u8, quote: u8, prefix: usize, suffix: usize, escape_html: bool) []u8 {
    var b = b0;
    var j: usize = 0;
    var start: usize = 0;
    var i: usize = prefix;
    while (i + suffix < b.len) : (i += 1) {
        const c0 = b[i];
        if (c0 == '\\') {
            const c = b[i + 1];
            if (c == quote or c == '\\' or c == 'r' or (quote != '`' and c == 'n') or (c == '0' and (b.len - suffix <= i + 2 or b[i + 2] < '0' or '7' < b[i + 2]))) {
                i += 1;
                continue;
            }
            var n: usize = 1;
            if (c == '\n' or c == '\r' or (c == 0xE2 and i + 3 < b.len - 1 and b[i + 2] == 0x80 and (b[i + 3] == 0xA8 or b[i + 3] == 0xA9))) {
                if (c == 0xE2) {
                    n = 4;
                } else if (c == '\r' and i + 2 < b.len - 1 and b[i + 2] == '\n') {
                    n = 3;
                } else n = 2;
            } else if (c == 'x') {
                if (i + 3 < b.len - 1 and isHexDigit(b[i + 2]) and b[i + 2] < '8' and isHexDigit(b[i + 3]) and (!(b[i + 2] == '0' and b[i + 3] == '0') or i + 3 == b.len or (b[i + 3] != '\\' and (b[i + 3] < '0' and '7' < b[i + 3])))) {
                    b[i] = std.fmt.parseInt(u8, b[i + 2 .. i + 4], 16) catch 0;
                    n = 4;
                    if (b[i] == '\\' or b[i] == quote or b[i] == '\r' or (quote != '`' and b[i] == '\n') or b[i] == 0) {
                        if (b[i] == '\n') {
                            b[i + 1] = 'n';
                        } else if (b[i] == '\r') {
                            b[i + 1] = 'r';
                        } else b[i + 1] = b[i];
                        b[i] = '\\';
                        i += 1;
                        n -= 1;
                    }
                    i += 1;
                    n -= 1;
                } else {
                    i += 1;
                    continue;
                }
            } else if (c == 'u' and i + 2 < b.len) {
                var l = i + 2;
                if (b[i + 2] == '{') l += 1;
                var r = l;
                while (r < b.len and (b[i + 2] == '{' or r < l + 4)) : (r += 1) {
                    const d = b[r];
                    if (d < '0' or ('9' < d and d < 'A') or ('F' < d and d < 'a') or 'f' < d) break;
                }
                if ((b[i + 2] == '{' and (6 < r - l or b.len <= r or b[r] != '}')) or (b[i + 2] != '{' and r - l != 4)) {
                    i += 1;
                    continue;
                }
                const num = std.fmt.parseInt(i64, b[l..r], 16) catch {
                    i += 1;
                    continue;
                };
                if (0x10FFFF <= num) {
                    i += 1;
                    continue;
                }
                n = 2 + r - l;
                if (b[i + 2] == '{') n += 2;
                if (num == 0) {
                    if (r == b.len or (b[r] != '\\' and (b[r] < '0' and '7' < b[r]))) {
                        b[i + 1] = '0';
                        i += 2;
                        n -= 2;
                    } else {
                        b[i + 1] = 'x';
                        b[i + 2] = '0';
                        b[i + 3] = '0';
                        i += 4;
                        n -= 4;
                    }
                } else if (num != 13 and (quote == '`' or num != 10)) {
                    const cp: u21 = @intCast(num);
                    const mlen = std.unicode.utf8CodepointSequenceLength(cp) catch {
                        i += 1;
                        continue;
                    };
                    if (num >= 0xD800 and num <= 0xDFFF) {
                        // Go's utf8.RuneLen returns -1 for surrogates
                        i += 1;
                        continue;
                    }
                    if (num < 256 and quote == @as(u8, @intCast(num))) {
                        b[i] = '\\';
                        i += 1;
                        n -= 1;
                    }
                    _ = std.unicode.utf8Encode(cp, b[i .. i + mlen]) catch {};
                    i += mlen;
                    n -= mlen;
                } else {
                    b[i + 1] = if (num == 10) 'n' else 'r';
                    i += 2;
                    n -= 2;
                }
            } else if ('0' <= c and c <= '7') {
                var num: u8 = c - '0';
                n += 1;
                if (i + 2 < b.len - 1 and '0' <= b[i + 2] and b[i + 2] <= '7') {
                    num = num *% 8 +% (b[i + 2] - '0');
                    n += 1;
                    if (num < 32 and i + 3 < b.len - 1 and '0' <= b[i + 3] and b[i + 3] <= '7') {
                        num = num *% 8 +% (b[i + 3] - '0');
                        n += 1;
                    }
                }
                b[i] = num;
                if (num == 0 or num == '\\' or num == quote or num == '\r' or (quote != '`' and num == '\n')) {
                    if (num == 0) {
                        b[i + 1] = '0';
                    } else if (num == '\n') {
                        b[i + 1] = 'n';
                    } else if (num == '\r') {
                        b[i + 1] = 'r';
                    } else b[i + 1] = b[i];
                    b[i] = '\\';
                    i += 1;
                    n -= 1;
                }
                i += 1;
                n -= 1;
            } else if (quote == '`' and c == 'n') {
                b[i] = '\n';
                i += 1;
            } else if (c == 't') {
                b[i] = '\t';
                i += 1;
            } else if (c == 'f') {
                b[i] = 0x0c;
                i += 1;
            } else if (c == 'v') {
                b[i] = 0x0b;
                i += 1;
            } else if (c == 'b') {
                b[i] = 0x08;
                i += 1;
            }
            if (start != 0) {
                std.mem.copyForwards(u8, b[j .. j + (i - start)], b[start..i]);
                j += i - start;
            } else j = i;
            start = i + n;
            i = i + n - 1;
        } else if (c0 == quote or (c0 == '$' and quote == '`' and ((i + 1 < b.len and b[i + 1] == '{') or (i + 2 < b.len and b[i + 1] == '\\' and b[i + 2] == '{')))) {
            if (j < start) {
                std.mem.copyForwards(u8, b[j .. j + (i - start)], b[start..i]);
                j += i - start;
                b[j] = '\\';
                j += 1;
                start = i;
            } else {
                b = insertAt(b, i, '\\');
                i += 1;
                b[i] = c0;
            }
        }
    }
    if (start != 0) {
        std.mem.copyForwards(u8, b[j .. j + (b.len - start)], b[start..]);
        j += b.len - start;
        b = b[0..j];
    }
    if (escape_html) {
        var k: usize = 0;
        while (k < b.len) : (k += 1) {
            if (b[k] == '<') {
                if (k + 3 < b.len and eql(b[k + 1 .. k + 4], "!--")) {
                    b = insertAt(b, k + 1, '\\');
                } else if (k + 7 < b.len and std.ascii.eqlIgnoreCase(b[k + 1 .. k + 8], "/script")) {
                    b = insertAt(b, k + 1, '\\');
                }
            }
        }
    }
    return b;
}

const regexp_escape = blk: {
    var t = @as([256]bool, @splat(false));
    for ("$()*+./0123456789?BDPSW[\\]^bcdfknprstuvwx{|}") |c| t[c] = true;
    break :blk t;
};
const regexp_class_escape = blk: {
    var t = @as([256]bool, @splat(false));
    for ("0123456789DPSW\\]bcdfnprstuvwx") |c| t[c] = true;
    break :blk t;
};

fn minifyRegExp(b0: []const u8, escape_html: bool) []u8 {
    var b = sys.A.dupe(u8, b0) catch return @constCast(b0);
    var in_class = false;
    var after_dash: usize = 0;
    var i_class: usize = 0;
    var i: usize = 1;
    while (i + 1 < b.len) : (i += 1) {
        if (in_class) after_dash += 1;
        if (b[i] == '\\') {
            const c = b[i + 1];
            var escape = true;
            if (in_class) {
                escape = regexp_class_escape[c] or (c == '-' and 2 < after_dash and i + 2 < b.len and b[i + 2] != ']') or (c == '^' and i == i_class + 1);
            } else escape = regexp_escape[c];
            if (!escape) {
                std.mem.copyForwards(u8, b[i .. b.len - 1], b[i + 1 ..]);
                b = b[0 .. b.len - 1];
                if (in_class and 2 < after_dash and c == '-') {
                    after_dash = 0;
                } else if (in_class and c == '^') after_dash = 1;
            } else i += 1;
        } else if (b[i] == '[') {
            if (b[i + 1] == '^') i += 1;
            after_dash = 1;
            in_class = true;
            i_class = i;
        } else if (in_class and b[i] == ']') {
            in_class = false;
        } else if (in_class and 2 < after_dash and b[i] == '-') after_dash = 0;
    }
    if (escape_html) {
        var k: usize = 0;
        while (k < b.len) : (k += 1) {
            if (b[k] == '<') {
                if (k + 4 <= b.len and eql(b[k + 1 .. k + 4], "!--")) {
                    b = insertAt(b, k + 1, '\\');
                    k += 3;
                } else if (k + 8 <= b.len and std.ascii.eqlIgnoreCase(b[k + 1 .. k + 8], "/script")) {
                    b = insertAt(b, k + 1, '\\');
                    k += 9;
                }
            }
        }
    }
    return b;
}

fn removeUnderscores(num: []const u8) struct { b: []u8, suffix: bool } {
    var out: std.ArrayList(u8) = .empty;
    for (num) |c| if (c != '_') out.append(sys.A, c) catch {};
    if (out.items.len > 0 and out.items[out.items.len - 1] == 'n') return .{ .b = out.items[0 .. out.items.len - 1], .suffix = true };
    return .{ .b = out.items, .suffix = false };
}

fn decimalNumber(num: []const u8) []const u8 {
    const r = removeUnderscores(num);
    if (r.suffix) return std.mem.concat(sys.A, u8, &.{ r.b, "n" }) catch r.b;
    return min.number(r.b, precision);
}

fn radixNumber(num: []const u8, radix: u8) []const u8 {
    const r = removeUnderscores(num);
    const b = r.b;
    const too_long = switch (radix) {
        2 => b.len <= 2 or 65 < b.len,
        8 => b.len <= 2 or 23 < b.len,
        else => b.len <= 2 or 12 < b.len or (b.len == 12 and (('D' < b[2] and b[2] <= 'F') or 'd' < b[2])),
    };
    if (too_long) {
        if (r.suffix) return std.mem.concat(sys.A, u8, &.{ b, "n" }) catch b;
        return b;
    }
    var n: i64 = 0;
    for (b[2..]) |c| {
        n *%= radix;
        if (c <= '9') {
            n +%= c - '0';
        } else if (c <= 'F') {
            n +%= 10 + @as(i64, c - 'A');
        } else n +%= 10 + @as(i64, c - 'a');
    }
    const s = std.fmt.allocPrint(sys.A, "{d}", .{n}) catch return b;
    if (r.suffix) return std.mem.concat(sys.A, u8, &.{ s, "n" }) catch s;
    return min.number(s, precision);
}
