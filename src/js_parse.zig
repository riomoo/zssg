// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: tdewolff/parse (MIT, Copyright Taco de Wolff).
// The original notices and licences are kept in NOTICE and licenses/.
//! JavaScript parser: a port of tdewolff/parse/js parse.go (MIT).
const std = @import("std");
const sys = @import("sys.zig");
const lex = @import("js_lex.zig");
const ast = @import("js_ast.zig");
const Node = ast.Node;
const Var = ast.Var;
const Scope = ast.Scope;
const TT = lex.TT;
const L = ast.L;
const OpPrec = ast.OpPrec;

pub const Options = struct { while_to_for: bool = false, inline_: bool = false };

const NestedStmtLimit = 1000;
const NestedExprLimit = 1000;

pub const ParseError = error{JSParseError};

const Parser = struct {
    l: lex.Lexer,
    o: Options,
    failed: bool = false,
    msg: []const u8 = "",
    data: []u8 = &.{},
    tt: TT = lex.WhitespaceToken,
    prev_lt: bool = false,
    in: bool = true,
    await_: bool = true,
    yield_: bool = false,
    deflt: bool = false,
    retrn: bool = false,
    assume_arrow: bool = false,
    allow_directive: bool = false,
    comments: L(*Node) = .empty,
    stmt_level: usize = 0,
    expr_level: usize = 0,
    scope: ?*Scope = null,

    fn sc(p: *Parser) *Scope {
        return p.scope.?;
    }
    fn mut(p: *Parser, d: []const u8) []u8 {
        _ = p;
        return @constCast(d);
    }

    fn next(p: *Parser) void {
        p.prev_lt = false;
        var t = p.l.next();
        while (true) {
            switch (t.tt) {
                lex.WhitespaceToken => {},
                lex.LineTerminatorToken => p.prev_lt = true,
                lex.CommentToken, lex.CommentLineTerminatorToken => {
                    if (2 < t.data.len and t.data[2] == '!') {
                        p.comments.append(sys.A, ast.new(.{ .comment = p.mut(t.data) })) catch {};
                    }
                    if (t.tt == lex.CommentLineTerminatorToken) p.prev_lt = true;
                },
                else => break,
            }
            t = p.l.next();
        }
        p.tt = t.tt;
        p.data = p.mut(t.data);
    }

    fn fail(p: *Parser, in: []const u8) void {
        if (!p.failed) {
            p.failed = true;
            p.msg = in;
            p.tt = lex.ErrorToken;
        }
    }
    fn consume(p: *Parser, in: []const u8, tt: TT) bool {
        if (p.tt != tt) {
            p.fail(in);
            return false;
        }
        p.next();
        return true;
    }

    fn enterScope(p: *Parser, scope: *Scope, is_func: bool) ?*Scope {
        const parent = p.scope;
        p.scope = scope;
        scope.* = .{ .parent = parent };
        if (is_func) {
            scope.func = scope;
        } else if (parent) |par| scope.func = par.func;
        return parent;
    }
    fn exitScope(p: *Parser, parent: ?*Scope) void {
        p.sc().hoistUndeclared();
        p.scope = parent;
    }

    fn isIdentifierReference(p: *Parser, tt: TT) bool {
        return lex.isIdentifier(tt) or (!p.yield_ and tt == lex.YieldToken) or (!p.await_ and tt == lex.AwaitToken);
    }

    fn declare(p: *Parser, decl: ast.DeclType, name: []u8) ?*Var {
        return p.sc().declare(decl, name);
    }

    fn parseModule(p: *Parser, module: *Node) void {
        const blk = &module.block;
        _ = p.enterScope(&blk.scope, true);
        p.allow_directive = true;
        while (true) {
            switch (p.tt) {
                lex.ErrorToken => {
                    if (p.comments.items.len > 0) {
                        blk.list.insertSlice(sys.A, 0, p.comments.items) catch {};
                        p.comments.items.len = 0;
                    }
                    p.exitScope(null);
                    return;
                },
                lex.ImportToken => {
                    p.next();
                    if (p.tt == lex.OpenParenToken) {
                        const left = ast.new(.{ .literal = .{ .tt = lex.ImportToken, .data = @constCast("import") } });
                        p.expr_level += 1;
                        const e = p.parseExpressionSuffix(left, ast.OpExpr, ast.OpCall);
                        p.expr_level -= 1;
                        blk.list.append(sys.A, ast.new(.{ .expr_stmt = e })) catch {};
                        if (!p.prev_lt and p.tt == lex.SemicolonToken) p.next();
                    } else if (p.tt == lex.DotToken) {
                        p.next();
                        if (!p.consume("import.meta expression", lex.MetaToken)) {
                            p.exitScope(null);
                            return;
                        }
                        const left = ast.new(.import_meta);
                        p.expr_level += 1;
                        const e = p.parseExpressionSuffix(left, ast.OpExpr, ast.OpMember);
                        p.expr_level -= 1;
                        blk.list.append(sys.A, ast.new(.{ .expr_stmt = e })) catch {};
                        if (!p.prev_lt and p.tt == lex.SemicolonToken) p.next();
                    } else {
                        blk.list.append(sys.A, p.parseImportStmt()) catch {};
                    }
                },
                lex.ExportToken => blk.list.append(sys.A, p.parseExportStmt()) catch {},
                else => {
                    const s = p.parseStmt(true);
                    blk.list.append(sys.A, s orelse ast.new(.empty)) catch {};
                },
            }
        }
    }

    fn badEnd(p: *Parser) bool {
        return !p.prev_lt and p.tt != lex.SemicolonToken and p.tt != lex.CloseBraceToken and p.tt != lex.ErrorToken;
    }

    fn parseStmt(p: *Parser, allow_decl: bool) ?*Node {
        p.stmt_level += 1;
        if (NestedStmtLimit < p.stmt_level) {
            p.fail("too many nested statements");
            return null;
        }
        const allow_directive = p.allow_directive;
        p.allow_directive = false;
        var stmt: ?*Node = null;
        const tt = p.tt;
        switch (tt) {
            lex.OpenBraceToken => stmt = p.parseBlockStmt("block statement"),
            lex.ConstToken, lex.VarToken => {
                if (!allow_decl and tt == lex.ConstToken) {
                    p.fail("statement");
                    return null;
                }
                p.next();
                stmt = p.parseVarDecl(tt, true);
                if (p.badEnd()) {
                    p.fail("var statement");
                    return null;
                }
            },
            lex.LetToken => {
                const let = p.data;
                p.next();
                if (allow_decl and (lex.isIdentifier(p.tt) or p.tt == lex.YieldToken or p.tt == lex.AwaitToken or p.tt == lex.OpenBracketToken or p.tt == lex.OpenBraceToken)) {
                    stmt = p.parseVarDecl(tt, false);
                    if (p.badEnd()) {
                        p.fail("let declaration");
                        return null;
                    }
                } else if (p.tt == lex.OpenBracketToken) {
                    p.fail("unexpected let [ in single-statement context");
                    return null;
                } else {
                    stmt = ast.new(.{ .expr_stmt = p.parseIdentifierExpression(ast.OpExpr, let) });
                    if (p.badEnd()) {
                        p.fail("expression");
                        return null;
                    }
                }
            },
            lex.IfToken => {
                p.next();
                if (!p.consume("if statement", lex.OpenParenToken)) return null;
                const cond = p.parseExpression(ast.OpExpr);
                if (!p.consume("if statement", lex.CloseParenToken)) return null;
                const body = p.parseStmt(false);
                var else_body: ?*Node = null;
                if (p.tt == lex.ElseToken) {
                    p.next();
                    else_body = p.parseStmt(false);
                }
                stmt = ast.new(.{ .if_stmt = .{ .cond = cond, .body = body, .else_ = else_body } });
            },
            lex.ContinueToken, lex.BreakToken => {
                p.next();
                var label: ?[]u8 = null;
                if (!p.prev_lt and p.isIdentifierReference(p.tt)) {
                    label = p.data;
                    p.next();
                }
                stmt = ast.new(.{ .branch = .{ .tt = tt, .label = label } });
            },
            lex.WithToken => {
                p.next();
                if (!p.consume("with statement", lex.OpenParenToken)) return null;
                const cond = p.parseExpression(ast.OpExpr);
                if (!p.consume("with statement", lex.CloseParenToken)) return null;
                p.sc().func.?.has_with = true;
                stmt = ast.new(.{ .with_stmt = .{ .cond = cond, .body = p.parseStmt(false) } });
            },
            lex.DoToken => {
                p.next();
                const body = p.parseStmt(false);
                if (!p.consume("do-while statement", lex.WhileToken)) return null;
                if (!p.consume("do-while statement", lex.OpenParenToken)) return null;
                stmt = ast.new(.{ .do_while = .{ .cond = p.parseExpression(ast.OpExpr), .body = body } });
                if (!p.consume("do-while statement", lex.CloseParenToken)) return null;
            },
            lex.WhileToken => {
                p.next();
                if (!p.consume("while statement", lex.OpenParenToken)) return null;
                const cond = p.parseExpression(ast.OpExpr);
                if (!p.consume("while statement", lex.CloseParenToken)) return null;
                const body = p.parseStmt(false);
                if (p.o.while_to_for) {
                    const vd = ast.new(.{ .var_decl = .{ .tt = lex.VarToken, .scope = p.scope, .in_for = true } });
                    p.sc().func.?.var_decls.append(sys.A, vd) catch {};
                    var block: *Node = undefined;
                    if (body != null and body.?.* == .block) {
                        block = body.?;
                    } else {
                        block = ast.new(.{ .block = .{} });
                        block.block.list.append(sys.A, body orelse ast.new(.empty)) catch {};
                    }
                    stmt = ast.new(.{ .for_stmt = .{ .init = vd, .cond = cond, .post = null, .body = block } });
                } else {
                    stmt = ast.new(.{ .while_stmt = .{ .cond = cond, .body = body } });
                }
            },
            lex.ForToken => {
                p.next();
                const is_await = p.await_ and p.tt == lex.AwaitToken;
                if (is_await) p.next();
                if (!p.consume("for statement", lex.OpenParenToken)) return null;
                const body = ast.new(.{ .block = .{} });
                const parent = p.enterScope(&body.block.scope, false);
                var init: ?*Node = null;
                p.in = false;
                if (p.tt == lex.VarToken or p.tt == lex.LetToken or p.tt == lex.ConstToken) {
                    const t2 = p.tt;
                    p.next();
                    const vd = p.parseVarDecl(t2, true);
                    if (p.failed) return null;
                    const items = vd.var_decl.list.items;
                    if (p.tt != lex.SemicolonToken and (1 < items.len or items[0].default != null)) {
                        p.fail("for statement");
                        return null;
                    } else if (p.tt == lex.SemicolonToken and items[0].default == null) {
                        if (ast.asVar(items[0].binding) == null) {
                            p.fail("for statement");
                            return null;
                        }
                    }
                    init = vd;
                } else if (is_await) {
                    init = p.parseExpression(ast.OpLHS);
                } else if (p.tt != lex.SemicolonToken) {
                    init = p.parseExpression(ast.OpExpr);
                }
                p.in = true;
                const is_lhs = isLHSExpr(init);
                if (is_lhs and p.tt == lex.InToken) {
                    if (is_await) {
                        p.fail("for statement");
                        return null;
                    }
                    p.next();
                    const value = p.parseExpression(ast.OpExpr);
                    if (!p.consume("for statement", lex.CloseParenToken)) return null;
                    p.sc().markForStmt();
                    p.parseForBody(body);
                    if (init != null and init.?.* == .var_decl) init.?.var_decl.in_for_in_of = true;
                    stmt = ast.new(.{ .for_in = .{ .init = init, .value = value, .body = body } });
                } else if (is_lhs and p.tt == lex.OfToken) {
                    p.next();
                    const value = p.parseExpression(ast.OpAssign);
                    if (!p.consume("for statement", lex.CloseParenToken)) return null;
                    p.sc().markForStmt();
                    p.parseForBody(body);
                    if (init != null and init.?.* == .var_decl) init.?.var_decl.in_for_in_of = true;
                    stmt = ast.new(.{ .for_of = .{ .is_await = is_await, .init = init, .value = value, .body = body } });
                } else if (p.tt == lex.SemicolonToken) {
                    var cond: ?*Node = null;
                    var post: ?*Node = null;
                    if (is_await) {
                        p.fail("for statement");
                        return null;
                    }
                    p.next();
                    if (p.tt != lex.SemicolonToken) cond = p.parseExpression(ast.OpExpr);
                    if (!p.consume("for statement", lex.SemicolonToken)) return null;
                    if (p.tt != lex.CloseParenToken) post = p.parseExpression(ast.OpExpr);
                    if (!p.consume("for statement", lex.CloseParenToken)) return null;
                    p.sc().markForStmt();
                    p.parseForBody(body);
                    if (init == null) {
                        const vd = ast.new(.{ .var_decl = .{ .tt = lex.VarToken, .scope = p.scope, .in_for = true } });
                        p.sc().func.?.var_decls.append(sys.A, vd) catch {};
                        init = vd;
                    } else if (init.?.* == .var_decl) init.?.var_decl.in_for = true;
                    stmt = ast.new(.{ .for_stmt = .{ .init = init, .cond = cond, .post = post, .body = body } });
                } else {
                    p.fail("for statement");
                    return null;
                }
                p.exitScope(parent);
            },
            lex.SwitchToken => {
                p.next();
                if (!p.consume("switch statement", lex.OpenParenToken)) return null;
                const init = p.parseExpression(ast.OpExpr);
                if (!p.consume("switch statement", lex.CloseParenToken)) return null;
                if (!p.consume("switch statement", lex.OpenBraceToken)) return null;
                const sw = ast.new(.{ .switch_stmt = .{ .init = init } });
                const parent = p.enterScope(&sw.switch_stmt.scope, false);
                while (true) {
                    if (p.tt == lex.ErrorToken) {
                        p.fail("switch statement");
                        return null;
                    } else if (p.tt == lex.CloseBraceToken) {
                        p.next();
                        break;
                    }
                    const clause = p.tt;
                    var list: ?*Node = null;
                    if (p.tt == lex.CaseToken) {
                        p.next();
                        list = p.parseExpression(ast.OpExpr);
                    } else if (p.tt == lex.DefaultToken) {
                        p.next();
                    } else {
                        p.fail("switch statement");
                        return null;
                    }
                    if (!p.consume("switch statement", lex.ColonToken)) return null;
                    var stmts: L(*Node) = .empty;
                    while (p.tt != lex.CaseToken and p.tt != lex.DefaultToken and p.tt != lex.CloseBraceToken and p.tt != lex.ErrorToken) {
                        stmts.append(sys.A, p.parseStmt(true) orelse ast.new(.empty)) catch {};
                    }
                    sw.switch_stmt.list.append(sys.A, .{ .tt = clause, .cond = list, .list = stmts }) catch {};
                }
                p.exitScope(parent);
                stmt = sw;
            },
            lex.FunctionToken => {
                if (!allow_decl) {
                    p.fail("statement");
                    return null;
                }
                stmt = p.parseFunc(false, false);
            },
            lex.AsyncToken => {
                const async_ = p.data;
                p.next();
                if (p.tt == lex.FunctionToken and !p.prev_lt) {
                    if (!allow_decl) {
                        p.fail("statement");
                        return null;
                    }
                    stmt = p.parseFunc(true, false);
                } else {
                    stmt = ast.new(.{ .expr_stmt = p.parseAsyncExpression(ast.OpExpr, async_) });
                    if (p.badEnd()) {
                        p.fail("expression");
                        return null;
                    }
                }
            },
            lex.ClassToken => {
                if (!allow_decl) {
                    p.fail("statement");
                    return null;
                }
                stmt = p.parseAnyClass(false);
            },
            lex.ThrowToken => {
                p.next();
                if (p.prev_lt) {
                    p.fail("unexpected newline in throw statement");
                    return null;
                }
                stmt = ast.new(.{ .throw = p.parseExpression(ast.OpExpr) });
            },
            lex.TryToken => {
                p.next();
                const body = p.parseBlockStmt("try statement");
                var binding: ?*Node = null;
                var catch_: ?*Node = null;
                var finally: ?*Node = null;
                if (p.tt == lex.CatchToken) {
                    p.next();
                    catch_ = ast.new(.{ .block = .{} });
                    const parent = p.enterScope(&catch_.?.block.scope, false);
                    if (p.tt == lex.OpenParenToken) {
                        p.next();
                        binding = p.parseBinding(.CatchDecl);
                        if (!p.consume("try-catch statement", lex.CloseParenToken)) return null;
                    }
                    catch_.?.block.list = p.parseStmtList("try-catch statement");
                    p.exitScope(parent);
                } else if (p.tt != lex.FinallyToken) {
                    p.fail("try statement");
                    return null;
                }
                if (p.tt == lex.FinallyToken) {
                    p.next();
                    finally = p.parseBlockStmt("try-finally statement");
                }
                stmt = ast.new(.{ .try_stmt = .{ .body = body, .binding = binding, .catch_ = catch_, .finally = finally } });
            },
            lex.DebuggerToken => {
                stmt = ast.new(.debugger);
                p.next();
            },
            lex.SemicolonToken => {
                stmt = ast.new(.empty);
                p.next();
            },
            lex.ErrorToken => {
                return ast.new(.empty);
            },
            else => {
                if (p.retrn and p.tt == lex.ReturnToken) {
                    p.next();
                    var value: ?*Node = null;
                    if (!p.prev_lt and p.tt != lex.SemicolonToken and p.tt != lex.CloseBraceToken and p.tt != lex.ErrorToken) {
                        value = p.parseExpression(ast.OpExpr);
                    }
                    stmt = ast.new(.{ .return_stmt = value });
                } else if (p.isIdentifierReference(p.tt)) {
                    const label = p.data;
                    p.next();
                    if (p.tt == lex.ColonToken) {
                        p.next();
                        const prev_deflt = p.deflt;
                        if (p.tt == lex.FunctionToken) p.deflt = false;
                        stmt = ast.new(.{ .labelled = .{ .label = label, .value = p.parseStmt(true) } });
                        p.deflt = prev_deflt;
                    } else {
                        stmt = ast.new(.{ .expr_stmt = p.parseIdentifierExpression(ast.OpExpr, label) });
                        if (p.badEnd()) {
                            p.fail("expression");
                            return null;
                        }
                    }
                } else {
                    const e = p.parseExpression(ast.OpExpr);
                    stmt = ast.new(.{ .expr_stmt = e });
                    if (p.badEnd()) {
                        p.fail("expression");
                        return null;
                    } else if (e != null and e.?.* == .literal) {
                        const lit = e.?.literal;
                        if (allow_directive and lit.tt == lex.StringToken and lit.data.len == 12 and std.mem.eql(u8, lit.data[1..11], "use strict")) {
                            stmt = ast.new(.{ .directive = lit.data });
                            p.allow_directive = true;
                        }
                    }
                }
            },
        }
        if (!p.prev_lt and p.tt == lex.SemicolonToken) p.next();
        p.stmt_level -= 1;
        return stmt;
    }

    fn parseForBody(p: *Parser, body: *Node) void {
        if (p.tt == lex.OpenBraceToken) {
            body.block.list = p.parseStmtList("");
        } else if (p.tt != lex.SemicolonToken) {
            body.block.list = .empty;
            body.block.list.append(sys.A, p.parseStmt(false) orelse ast.new(.empty)) catch {};
        } else p.next();
    }

    fn parseStmtList(p: *Parser, in: []const u8) L(*Node) {
        var list: L(*Node) = .empty;
        const ncom = p.comments.items.len;
        if (!p.consume(in, lex.OpenBraceToken)) return list;
        while (true) {
            if (p.tt == lex.ErrorToken) {
                p.fail("");
                return list;
            } else if (p.tt == lex.CloseBraceToken) {
                p.next();
                break;
            }
            list.append(sys.A, p.parseStmt(true) orelse ast.new(.empty)) catch {};
        }
        if (ncom < p.comments.items.len) {
            var l2: L(*Node) = .empty;
            l2.appendSlice(sys.A, p.comments.items[ncom..]) catch {};
            l2.appendSlice(sys.A, list.items) catch {};
            list = l2;
            p.comments.items.len = ncom;
        }
        return list;
    }

    fn parseBlockStmt(p: *Parser, in: []const u8) *Node {
        const b = ast.new(.{ .block = .{} });
        const parent = p.enterScope(&b.block.scope, false);
        b.block.list = p.parseStmtList(in);
        p.exitScope(parent);
        return b;
    }

    fn parseImportStmt(p: *Parser) *Node {
        const n = ast.new(.{ .import_stmt = .{} });
        const is = &n.import_stmt;
        if (p.tt == lex.StringToken) {
            is.module = p.data;
            p.next();
        } else {
            var expect_clause = true;
            if (lex.isIdentifier(p.tt) or p.tt == lex.YieldToken) {
                is.default = p.data;
                p.next();
                expect_clause = p.tt == lex.CommaToken;
                if (expect_clause) p.next();
            }
            if (expect_clause and p.tt == lex.MulToken) {
                const star = p.data;
                p.next();
                if (!p.consume("import statement", lex.AsToken)) return n;
                if (!lex.isIdentifier(p.tt) and p.tt != lex.YieldToken) {
                    p.fail("import statement");
                    return n;
                }
                var l: L(ast.Alias) = .empty;
                l.append(sys.A, .{ .name = star, .binding = p.data }) catch {};
                is.list = l;
                p.next();
            } else if (expect_clause and p.tt == lex.OpenBraceToken) {
                p.next();
                var l: L(ast.Alias) = .empty;
                while (lex.isIdentifierName(p.tt) or p.tt == lex.StringToken) {
                    const t = p.tt;
                    var name: ?[]u8 = null;
                    var binding: ?[]u8 = p.data;
                    p.next();
                    if (p.tt == lex.AsToken) {
                        p.next();
                        if (!lex.isIdentifier(p.tt) and p.tt != lex.YieldToken) {
                            p.fail("import statement");
                            return n;
                        }
                        name = binding;
                        binding = p.data;
                        p.next();
                    } else if ((!lex.isIdentifier(t) and t != lex.YieldToken) or t == lex.StringToken) {
                        p.fail("import statement");
                        return n;
                    }
                    l.append(sys.A, .{ .name = name, .binding = binding }) catch {};
                    if (p.tt == lex.CommaToken) {
                        p.next();
                        if (p.tt == lex.CloseBraceToken) {
                            l.append(sys.A, .{}) catch {};
                            break;
                        }
                    }
                }
                is.list = l;
                if (!p.consume("import statement", lex.CloseBraceToken)) return n;
            } else if (expect_clause and is.default != null) {
                p.fail("import statement");
                return n;
            } else if (is.default == null) {
                p.fail("import statement");
                return n;
            }
            if (!p.consume("import statement", lex.FromToken)) return n;
            if (p.tt != lex.StringToken) {
                p.fail("import statement");
                return n;
            }
            is.module = p.data;
            p.next();
        }
        if (p.tt == lex.SemicolonToken) p.next();
        return n;
    }

    fn parseExportStmt(p: *Parser) *Node {
        const n = ast.new(.{ .export_stmt = .{} });
        const es = &n.export_stmt;
        p.next();
        const prev_yield = p.yield_;
        const prev_await = p.await_;
        const prev_deflt = p.deflt;
        p.yield_ = false;
        p.await_ = true;
        p.deflt = true;
        if (p.tt == lex.MulToken or p.tt == lex.OpenBraceToken) {
            if (p.tt == lex.MulToken) {
                const star = p.data;
                p.next();
                if (p.tt == lex.AsToken) {
                    p.next();
                    if (!lex.isIdentifierName(p.tt) and p.tt != lex.StringToken) {
                        p.fail("export statement");
                        return n;
                    }
                    es.list.append(sys.A, .{ .name = star, .binding = p.data }) catch {};
                    p.next();
                } else {
                    es.list.append(sys.A, .{ .name = null, .binding = star }) catch {};
                }
                if (p.tt != lex.FromToken) {
                    p.fail("export statement");
                    return n;
                }
            } else {
                p.next();
                while (lex.isIdentifierName(p.tt) or p.tt == lex.StringToken) {
                    var name: ?[]u8 = null;
                    var binding: ?[]u8 = p.data;
                    p.next();
                    if (p.tt == lex.AsToken) {
                        p.next();
                        if (!lex.isIdentifierName(p.tt) and p.tt != lex.StringToken) {
                            p.fail("export statement");
                            return n;
                        }
                        name = binding;
                        binding = p.data;
                        p.next();
                    }
                    es.list.append(sys.A, .{ .name = name, .binding = binding }) catch {};
                    if (p.tt == lex.CommaToken) {
                        p.next();
                        if (p.tt == lex.CloseBraceToken) {
                            es.list.append(sys.A, .{}) catch {};
                            break;
                        }
                    }
                }
                if (!p.consume("export statement", lex.CloseBraceToken)) return n;
            }
            if (p.tt == lex.FromToken) {
                p.next();
                if (p.tt != lex.StringToken) {
                    p.fail("export statement");
                    return n;
                }
                es.module = p.data;
                p.next();
            }
        } else if (p.tt == lex.VarToken or p.tt == lex.ConstToken or p.tt == lex.LetToken) {
            const t = p.tt;
            p.next();
            es.decl = p.parseVarDecl(t, false);
        } else if (p.tt == lex.FunctionToken) {
            es.decl = p.parseFunc(false, false);
        } else if (p.tt == lex.AsyncToken) {
            p.next();
            if (p.tt != lex.FunctionToken or p.prev_lt) {
                p.fail("export statement");
                return n;
            }
            es.decl = p.parseFunc(true, false);
        } else if (p.tt == lex.ClassToken) {
            es.decl = p.parseAnyClass(false);
        } else if (p.tt == lex.DefaultToken) {
            es.default = true;
            p.next();
            if (p.tt == lex.FunctionToken) {
                es.decl = p.parseFunc(false, false);
            } else if (p.tt == lex.AsyncToken) {
                const async_ = p.data;
                p.next();
                if (p.tt == lex.FunctionToken and !p.prev_lt) {
                    es.decl = p.parseFunc(true, false);
                } else {
                    es.decl = p.parseAsyncExpression(ast.OpAssign, async_);
                }
            } else if (p.tt == lex.ClassToken) {
                es.decl = p.parseAnyClass(false);
            } else {
                es.decl = p.parseExpression(ast.OpAssign);
            }
        } else {
            p.fail("export statement");
            return n;
        }
        if (p.tt == lex.SemicolonToken) p.next();
        p.yield_ = prev_yield;
        p.await_ = prev_await;
        p.deflt = prev_deflt;
        return n;
    }

    fn parseVarDecl(p: *Parser, tt: TT, can_hoist: bool) *Node {
        const n = ast.new(.{ .var_decl = .{ .tt = tt, .scope = p.scope } });
        const vd = &n.var_decl;
        var decl_type: ast.DeclType = .LexicalDecl;
        if (tt == lex.VarToken) {
            decl_type = .VariableDecl;
            if (can_hoist) p.sc().func.?.var_decls.append(sys.A, n) catch {};
        }
        while (true) {
            var be: ast.BindingElement = .{};
            be.binding = p.parseBinding(decl_type);
            if (p.tt == lex.EqToken) {
                p.next();
                be.default = p.parseExpression(ast.OpAssign);
            } else if (ast.asVar(be.binding) == null and (p.in or 0 < vd.list.items.len)) {
                p.fail("var statement");
                return n;
            } else if (tt == lex.ConstToken and (p.in or (!p.in and p.tt != lex.OfToken and p.tt != lex.InToken))) {
                p.fail("const statement");
            }
            vd.list.append(sys.A, be) catch {};
            if (p.tt == lex.CommaToken) {
                p.next();
            } else break;
        }
        return n;
    }

    fn parseFuncParams(p: *Parser, in: []const u8) ast.Params {
        var params: ast.Params = .{};
        if (!p.consume(in, lex.OpenParenToken)) return params;
        while (p.tt != lex.CloseParenToken and p.tt != lex.ErrorToken) {
            if (p.tt == lex.EllipsisToken) {
                p.next();
                params.rest = p.parseBinding(.ArgumentDecl);
                _ = p.consume(in, lex.CloseParenToken);
                return params;
            }
            params.list.append(sys.A, p.parseBindingElement(.ArgumentDecl)) catch {};
            if (p.tt != lex.CommaToken) break;
            p.next();
        }
        if (p.tt != lex.CloseParenToken) {
            p.fail(in);
            return params;
        }
        p.next();
        p.sc().markFuncArgs();
        return params;
    }

    fn parseFunc(p: *Parser, is_async: bool, expr: bool) *Node {
        p.next();
        const n = ast.new(.{ .func_decl = .{} });
        const fd = &n.func_decl;
        fd.is_async = is_async;
        fd.generator = p.tt == lex.MulToken;
        if (fd.generator) p.next();
        var name: ?[]u8 = null;
        if ((expr and (lex.isIdentifier(p.tt) or p.tt == lex.YieldToken or p.tt == lex.AwaitToken)) or (!expr and p.isIdentifierReference(p.tt))) {
            name = p.data;
            if (!expr) {
                fd.name = p.declare(.FunctionDecl, p.data);
                if (fd.name == null) {
                    p.fail("identifier has already been declared");
                    return n;
                }
            }
            p.next();
        } else if (!expr and !p.deflt) {
            p.fail("function declaration");
            return n;
        } else if (p.tt != lex.OpenParenToken) {
            p.fail("function declaration");
            return n;
        }
        const parent = p.enterScope(&fd.body.scope, true);
        const prev_await = p.await_;
        const prev_yield = p.yield_;
        const prev_retrn = p.retrn;
        p.await_ = fd.is_async;
        p.yield_ = fd.generator;
        p.retrn = true;
        if (expr and name != null) fd.name = p.declare(.ExprDecl, name.?);
        fd.params = p.parseFuncParams("function declaration");
        const prev_ad = p.allow_directive;
        p.allow_directive = true;
        fd.body.list = p.parseStmtList("function declaration");
        p.allow_directive = prev_ad;
        p.await_ = prev_await;
        p.yield_ = prev_yield;
        p.retrn = prev_retrn;
        p.exitScope(parent);
        return n;
    }

    fn parseAnyClass(p: *Parser, expr: bool) *Node {
        p.next();
        const n = ast.new(.{ .class_decl = .{} });
        const cd = &n.class_decl;
        if (lex.isIdentifier(p.tt) or p.tt == lex.YieldToken or p.tt == lex.AwaitToken) {
            if (!expr) {
                cd.name = p.declare(.LexicalDecl, p.data);
                if (cd.name == null) {
                    p.fail("identifier has already been declared");
                    return n;
                }
            } else {
                cd.name = ast.newVar(p.data, 1, .ExprDecl);
            }
            p.next();
        } else if (!expr and !p.deflt) {
            p.fail("class declaration");
            return n;
        }
        if (p.tt == lex.ExtendsToken) {
            p.next();
            cd.extends = p.parseExpression(ast.OpLHS);
        }
        if (!p.consume("class declaration", lex.OpenBraceToken)) return n;
        const parent = p.enterScope(&cd.scope, false);
        while (true) {
            if (p.tt == lex.ErrorToken) {
                p.fail("class declaration");
                return n;
            } else if (p.tt == lex.SemicolonToken) {
                p.next();
                continue;
            } else if (p.tt == lex.CloseBraceToken) {
                p.next();
                break;
            }
            cd.list.append(sys.A, p.parseClassElement()) catch {};
        }
        p.exitScope(parent);
        return n;
    }

    fn parseClassElement(p: *Parser) ast.ClassElement {
        const mn = ast.new(.{ .method_decl = .{} });
        const method = &mn.method_decl;
        var data: ?[]u8 = null;
        if (p.tt == lex.StaticToken) {
            method.static = true;
            data = p.data;
            p.next();
            if (p.tt == lex.OpenBraceToken) {
                const py = p.yield_;
                const pa = p.await_;
                const pr = p.retrn;
                p.yield_ = false;
                p.await_ = true;
                p.retrn = false;
                const elem: ast.ClassElement = .{ .static_block = p.parseBlockStmt("class static block") };
                p.yield_ = py;
                p.await_ = pa;
                p.retrn = pr;
                return elem;
            }
        }
        if (p.tt == lex.MulToken) {
            method.generator = true;
            p.next();
        } else if (p.tt == lex.AsyncToken) {
            data = p.data;
            p.next();
            if (!p.prev_lt) {
                method.is_async = true;
                if (p.tt == lex.MulToken) {
                    method.generator = true;
                    data = null;
                    p.next();
                }
            }
        } else if (p.tt == lex.GetToken) {
            method.get = true;
            data = p.data;
            p.next();
        } else if (p.tt == lex.SetToken) {
            method.set = true;
            data = p.data;
            p.next();
        }
        var is_field = false;
        if (data != null and p.tt == lex.OpenParenToken) {
            method.name.pn.literal = .{ .tt = lex.IdentifierToken, .data = data.? };
            if (method.is_async or method.get or method.set) {
                method.is_async = false;
                method.get = false;
                method.set = false;
            } else method.static = false;
        } else if (data != null and (p.tt == lex.EqToken or p.tt == lex.SemicolonToken or p.tt == lex.CloseBraceToken)) {
            method.name.pn.literal = .{ .tt = lex.IdentifierToken, .data = data.? };
            if (!method.is_async and !method.get and !method.set) method.static = false;
            is_field = true;
        } else {
            if (p.tt == lex.PrivateIdentifierToken) {
                method.name.private = p.declare(.PrivateDecl, p.data);
                if (method.name.private == null) {
                    p.fail("identifier has already been declared");
                    return .{};
                }
                p.next();
            } else {
                method.name.pn = p.parsePropertyName("method or field definition");
            }
            if ((data == null or method.static) and p.tt != lex.OpenParenToken) is_field = true;
        }
        if (is_field) {
            var init: ?*Node = null;
            if (p.tt == lex.EqToken) {
                p.next();
                init = p.parseExpression(ast.OpAssign);
            }
            return .{ .field = .{ .static = method.static, .name = method.name, .init = init } };
        }
        const parent = p.enterScope(&method.body.scope, true);
        const pa = p.await_;
        const py = p.yield_;
        const pr = p.retrn;
        p.await_ = method.is_async;
        p.yield_ = method.generator;
        p.retrn = true;
        method.params = p.parseFuncParams("method definition");
        const pad = p.allow_directive;
        p.allow_directive = true;
        method.body.list = p.parseStmtList("method function");
        p.allow_directive = pad;
        p.await_ = pa;
        p.yield_ = py;
        p.retrn = pr;
        p.exitScope(parent);
        return .{ .method = mn };
    }

    fn parsePropertyName(p: *Parser, in: []const u8) ast.PropertyName {
        var pn: ast.PropertyName = .{};
        if (lex.isIdentifierName(p.tt)) {
            pn.literal = .{ .tt = lex.IdentifierToken, .data = p.data };
            p.next();
        } else if (p.tt == lex.StringToken) {
            const inner = p.data[1 .. p.data.len - 1];
            if (asIdentifierName(inner)) {
                pn.literal = .{ .tt = lex.IdentifierToken, .data = inner };
            } else if (asDecimalLiteral(inner)) {
                pn.literal = .{ .tt = lex.DecimalToken, .data = inner };
            } else {
                pn.literal = .{ .tt = p.tt, .data = p.data };
            }
            p.next();
        } else if (lex.isNumeric(p.tt)) {
            pn.literal = .{ .tt = p.tt, .data = p.data };
            p.next();
        } else if (p.tt == lex.OpenBracketToken) {
            p.next();
            pn.computed = p.parseExpression(ast.OpAssign);
            if (!p.consume(in, lex.CloseBracketToken)) return pn;
        } else {
            p.fail(in);
        }
        return pn;
    }

    fn parseBindingElement(p: *Parser, decl: ast.DeclType) ast.BindingElement {
        var be: ast.BindingElement = .{};
        be.binding = p.parseBinding(decl);
        if (p.tt == lex.EqToken) {
            p.next();
            be.default = p.parseExpression(ast.OpAssign);
        }
        return be;
    }

    fn parseBinding(p: *Parser, decl: ast.DeclType) ?*Node {
        if (p.isIdentifierReference(p.tt)) {
            const v = p.declare(decl, p.data) orelse {
                p.fail("identifier has already been declared");
                return null;
            };
            p.next();
            return ast.newVarNode(v);
        } else if (p.tt == lex.OpenBracketToken) {
            p.next();
            const n = ast.new(.{ .binding_array = .{} });
            const arr = &n.binding_array;
            if (p.tt == lex.CommaToken) arr.list.append(sys.A, .{}) catch {};
            var last: usize = 0;
            while (p.tt != lex.CloseBracketToken) {
                while (p.tt == lex.CommaToken) {
                    p.next();
                    if (p.tt == lex.CommaToken) arr.list.append(sys.A, .{}) catch {};
                }
                if (p.tt == lex.EllipsisToken) {
                    p.next();
                    arr.rest = p.parseBinding(decl);
                    if (p.tt != lex.CloseBracketToken) {
                        p.fail("array binding pattern");
                        return n;
                    }
                    break;
                } else if (p.tt == lex.CloseBracketToken) {
                    arr.list.items.len = last;
                    break;
                }
                arr.list.append(sys.A, p.parseBindingElement(decl)) catch {};
                last = arr.list.items.len;
                if (p.tt != lex.CommaToken and p.tt != lex.CloseBracketToken) {
                    p.fail("array binding pattern");
                    return n;
                }
            }
            p.next();
            return n;
        } else if (p.tt == lex.OpenBraceToken) {
            p.next();
            const n = ast.new(.{ .binding_object = .{} });
            const obj = &n.binding_object;
            while (p.tt != lex.CloseBraceToken) {
                if (p.tt == lex.EllipsisToken) {
                    p.next();
                    if (!p.isIdentifierReference(p.tt)) {
                        p.fail("object binding pattern");
                        return n;
                    }
                    obj.rest = p.declare(decl, p.data);
                    if (obj.rest == null) {
                        p.fail("identifier has already been declared");
                        return n;
                    }
                    p.next();
                    if (p.tt != lex.CloseBraceToken) {
                        p.fail("object binding pattern");
                        return n;
                    }
                    break;
                }
                var item: ast.BindingObjectItem = .{};
                if (p.isIdentifierReference(p.tt)) {
                    const name = p.data;
                    const key = sys.A.create(ast.PropertyName) catch unreachable;
                    key.* = .{ .literal = .{ .tt = lex.IdentifierToken, .data = p.data } };
                    item.key = key;
                    p.next();
                    if (p.tt == lex.ColonToken) {
                        p.next();
                        item.value = p.parseBindingElement(decl);
                    } else {
                        key.literal.data = sys.A.dupe(u8, key.literal.data) catch unreachable;
                        const v = p.declare(decl, name) orelse {
                            p.fail("identifier has already been declared");
                            return n;
                        };
                        item.value.binding = ast.newVarNode(v);
                        if (p.tt == lex.EqToken) {
                            p.next();
                            item.value.default = p.parseExpression(ast.OpAssign);
                        }
                    }
                } else {
                    const key = sys.A.create(ast.PropertyName) catch unreachable;
                    key.* = p.parsePropertyName("object binding pattern");
                    item.key = key;
                    if (!p.consume("object binding pattern", lex.ColonToken)) return n;
                    item.value = p.parseBindingElement(decl);
                }
                obj.list.append(sys.A, item) catch {};
                if (p.tt == lex.CommaToken) {
                    p.next();
                } else if (p.tt != lex.CloseBraceToken) {
                    p.fail("object binding pattern");
                    return n;
                }
            }
            p.next();
            return n;
        }
        p.fail("binding");
        return null;
    }

    fn parseArrayLiteral(p: *Parser) *Node {
        p.next();
        var list: L(ast.Element) = .empty;
        var prev_comma = true;
        while (true) {
            if (p.tt == lex.ErrorToken) {
                p.fail("expression");
                break;
            } else if (p.tt == lex.CloseBracketToken) {
                p.next();
                break;
            } else if (p.tt == lex.CommaToken) {
                if (prev_comma) list.append(sys.A, .{}) catch {};
                prev_comma = true;
                p.next();
            } else {
                const spread = p.tt == lex.EllipsisToken;
                if (spread) p.next();
                list.append(sys.A, .{ .value = p.parseAssignExprOrParam(), .spread = spread }) catch {};
                prev_comma = false;
                if (spread and p.tt != lex.CloseBracketToken) p.assume_arrow = false;
            }
        }
        return ast.new(.{ .array = list });
    }

    fn parseObjectLiteral(p: *Parser) *Node {
        p.next();
        const n = ast.new(.{ .object = .empty });
        while (true) {
            if (p.tt == lex.ErrorToken) {
                p.fail("object literal");
                return n;
            } else if (p.tt == lex.CloseBraceToken) {
                p.next();
                break;
            }
            var property: ast.Property = .{};
            if (p.tt == lex.EllipsisToken) {
                p.next();
                property.spread = true;
                property.value = p.parseAssignExprOrParam();
                if (ast.asVar(property.value) == null or p.tt != lex.CloseBraceToken) p.assume_arrow = false;
            } else {
                var data: ?[]u8 = null;
                const mn = ast.new(.{ .method_decl = .{} });
                const method = &mn.method_decl;
                if (p.tt == lex.MulToken) {
                    p.next();
                    method.generator = true;
                } else if (p.tt == lex.AsyncToken) {
                    data = p.data;
                    p.next();
                    if (!p.prev_lt) {
                        method.is_async = true;
                        if (p.tt == lex.MulToken) {
                            p.next();
                            method.generator = true;
                            data = null;
                        }
                    } else {
                        method.name.pn.literal = .{ .tt = lex.IdentifierToken, .data = data.? };
                        data = null;
                    }
                } else if (p.tt == lex.GetToken) {
                    data = p.data;
                    p.next();
                    method.get = true;
                } else if (p.tt == lex.SetToken) {
                    data = p.data;
                    p.next();
                    method.set = true;
                }
                if (data != null and !method.generator and (p.tt == lex.EqToken or p.tt == lex.CommaToken or p.tt == lex.CloseBraceToken or p.tt == lex.ColonToken or p.tt == lex.OpenParenToken)) {
                    method.name.pn.literal = .{ .tt = lex.IdentifierToken, .data = data.? };
                    method.is_async = false;
                    method.get = false;
                    method.set = false;
                } else if (!method.name.pn.isSet()) {
                    method.name.pn = p.parsePropertyName("object literal");
                    if (!method.name.pn.isSet()) return n;
                }
                if (p.tt == lex.OpenParenToken) {
                    const parent = p.enterScope(&method.body.scope, true);
                    const pa = p.await_;
                    const py = p.yield_;
                    const pr = p.retrn;
                    p.await_ = method.is_async;
                    p.yield_ = method.generator;
                    p.retrn = true;
                    p.assume_arrow = false;
                    method.params = p.parseFuncParams("method definition");
                    method.body.list = p.parseStmtList("method definition");
                    p.await_ = pa;
                    p.yield_ = py;
                    p.retrn = pr;
                    p.exitScope(parent);
                    property.value = mn;
                } else if (p.tt == lex.ColonToken) {
                    p.next();
                    property.name = &method.name.pn;
                    property.value = p.parseAssignExprOrParam();
                } else if (method.name.pn.isComputed() or !p.isIdentifierReference(method.name.pn.literal.tt)) {
                    p.fail("object literal");
                    return n;
                } else {
                    const name = method.name.pn.literal.data;
                    method.name.pn.literal.data = sys.A.dupe(u8, name) catch unreachable;
                    property.name = &method.name.pn;
                    if (p.assume_arrow) {
                        if (p.declare(.ArgumentDecl, name)) |v| {
                            property.value = ast.newVarNode(v);
                        } else {
                            property.value = ast.newVarNode(p.sc().use(name));
                            p.assume_arrow = false;
                        }
                    } else {
                        property.value = ast.newVarNode(p.sc().use(name));
                    }
                    if (p.tt == lex.EqToken) {
                        p.next();
                        const prev = p.assume_arrow;
                        p.assume_arrow = false;
                        property.init = p.parseExpression(ast.OpAssign);
                        p.assume_arrow = prev;
                    }
                }
            }
            n.object.append(sys.A, property) catch {};
            if (p.tt == lex.CommaToken) {
                p.next();
            } else if (p.tt != lex.CloseBraceToken) {
                p.fail("object literal");
                return n;
            }
        }
        return n;
    }

    fn parseTemplateLiteral(p: *Parser, prec_left: OpPrec) *Node {
        const n = ast.new(.{ .template = .{} });
        const t = &n.template;
        t.prec = ast.OpMember;
        if (prec_left < ast.OpMember) t.prec = ast.OpCall;
        while (p.tt == lex.TemplateStartToken or p.tt == lex.TemplateMiddleToken) {
            const tpl = p.data;
            p.next();
            t.list.append(sys.A, .{ .value = tpl, .expr = p.parseExpression(ast.OpExpr) }) catch {};
        }
        if (p.tt != lex.TemplateToken and p.tt != lex.TemplateEndToken) {
            p.fail("template literal");
            return n;
        }
        t.tail = p.data;
        p.next();
        return n;
    }

    fn parseArguments(p: *Parser) ast.Args {
        p.next();
        var args: ast.Args = .{};
        while (p.tt != lex.CloseParenToken and p.tt != lex.ErrorToken) {
            const rest = p.tt == lex.EllipsisToken;
            if (rest) p.next();
            args.list.append(sys.A, .{ .value = p.parseExpression(ast.OpAssign), .rest = rest }) catch {};
            if (p.tt != lex.CloseParenToken) {
                if (p.tt != lex.CommaToken) {
                    p.fail("arguments");
                    return args;
                } else p.next();
            }
        }
        _ = p.consume("arguments", lex.CloseParenToken);
        return args;
    }

    fn parseAsyncArrowFunc(p: *Parser) *Node {
        const n = ast.new(.{ .arrow = .{} });
        const af = &n.arrow;
        const parent = p.enterScope(&af.body.scope, true);
        const pa = p.await_;
        const py = p.yield_;
        p.await_ = true;
        p.yield_ = false;
        if (lex.isIdentifier(p.tt) or (!py and p.tt == lex.YieldToken)) {
            const ref = p.declare(.ArgumentDecl, p.data).?;
            p.next();
            af.params.list.append(sys.A, .{ .binding = ast.newVarNode(ref) }) catch {};
        } else {
            af.params = p.parseFuncParams("arrow function");
        }
        af.is_async = true;
        af.body.list = p.parseArrowFuncBody();
        p.await_ = pa;
        p.yield_ = py;
        p.exitScope(parent);
        return n;
    }

    fn parseIdentifierArrowFunc(p: *Parser, v0: *Var) *Node {
        var v = v0;
        const n = ast.new(.{ .arrow = .{} });
        const af = &n.arrow;
        const parent = p.enterScope(&af.body.scope, true);
        const pa = p.await_;
        const py = p.yield_;
        p.await_ = false;
        p.yield_ = false;
        if (1 < v.uses) {
            v.uses -%= 1;
            v = p.declare(.ArgumentDecl, sys.A.dupe(u8, v.data) catch unreachable).?;
        } else {
            const par = p.sc().parent.?;
            par.undeclared.items.len -= 1;
            if (par.var_indices) |vi| {
                const index: i64 = -@as(i64, @intCast(par.undeclared.items.len)) - 1;
                var it = vi.iterator();
                while (it.next()) |e| {
                    var i: usize = 0;
                    while (i < e.value_ptr.items.len) {
                        if (e.value_ptr.items[i] == index) {
                            _ = e.value_ptr.orderedRemove(i);
                        } else i += 1;
                    }
                }
            }
            v.decl = .ArgumentDecl;
            p.sc().addDeclared(&.{v});
        }
        af.params.list.append(sys.A, .{ .binding = ast.newVarNode(v) }) catch {};
        af.body.list = p.parseArrowFuncBody();
        p.await_ = pa;
        p.yield_ = py;
        p.exitScope(parent);
        return n;
    }

    fn parseArrowFuncBody(p: *Parser) L(*Node) {
        var list: L(*Node) = .empty;
        if (p.tt != lex.ArrowToken) {
            p.fail("arrow function");
            return list;
        } else if (p.prev_lt) {
            p.fail("expression");
            return list;
        }
        p.next();
        p.sc().markFuncArgs();
        if (p.tt == lex.OpenBraceToken) {
            const pi = p.in;
            const pr = p.retrn;
            p.in = true;
            p.retrn = true;
            const pad = p.allow_directive;
            p.allow_directive = true;
            list = p.parseStmtList("arrow function");
            p.allow_directive = pad;
            p.in = pi;
            p.retrn = pr;
        } else {
            list.append(sys.A, ast.new(.{ .return_stmt = p.parseExpression(ast.OpAssign) })) catch {};
        }
        return list;
    }

    fn parseIdentifierExpression(p: *Parser, prec: OpPrec, ident: []u8) ?*Node {
        const left = ast.newVarNode(p.sc().use(ident));
        return p.parseExpressionSuffix(left, prec, ast.OpPrimary);
    }

    fn parseAsyncExpression(p: *Parser, prec: OpPrec, async_: []u8) ?*Node {
        var left: ?*Node = null;
        var prec_left = ast.OpPrimary;
        if (!p.prev_lt and p.tt == lex.FunctionToken) {
            left = p.parseFunc(true, true);
        } else if (!p.prev_lt and prec <= ast.OpAssign and (p.tt == lex.OpenParenToken or lex.isIdentifier(p.tt) or p.tt == lex.YieldToken or p.tt == lex.AwaitToken)) {
            if (p.tt == lex.AwaitToken or (p.yield_ and p.tt == lex.YieldToken)) {
                p.fail("arrow function");
                return null;
            } else if (p.tt == lex.OpenParenToken) {
                return p.parseParenthesizedExpression(prec, async_);
            }
            left = p.parseAsyncArrowFunc();
            prec_left = ast.OpAssign;
        } else {
            left = ast.newVarNode(p.sc().use(async_));
        }
        return p.parseExpressionSuffix(left, prec, prec_left);
    }

    fn unaryNode(op: TT, x: ?*Node) *Node {
        return ast.new(.{ .unary = .{ .op = op, .x = x } });
    }

    fn parseExpression(p: *Parser, prec: OpPrec) ?*Node {
        p.expr_level += 1;
        if (NestedExprLimit < p.expr_level) {
            p.fail("too many nested expressions");
            return null;
        }
        if (p.tt == lex.DivToken or p.tt == lex.DivEqToken) {
            const r = p.l.regExp();
            p.tt = r.tt;
            p.data = p.mut(r.data);
            if (p.tt == lex.ErrorToken) {
                p.fail("regular expression");
                return null;
            }
        }
        var left: ?*Node = null;
        var prec_left = ast.OpPrimary;
        if (lex.isIdentifier(p.tt) and p.tt != lex.AsyncToken) {
            left = ast.newVarNode(p.sc().use(p.data));
            p.next();
            const s = p.parseExpressionSuffix(left, prec, prec_left);
            p.expr_level -= 1;
            return s;
        } else if (lex.isNumeric(p.tt)) {
            left = ast.new(.{ .literal = .{ .tt = p.tt, .data = p.data } });
            p.next();
            const s = p.parseExpressionSuffix(left, prec, prec_left);
            p.expr_level -= 1;
            return s;
        }
        const tt = p.tt;
        switch (tt) {
            lex.StringToken, lex.ThisToken, lex.NullToken, lex.TrueToken, lex.FalseToken, lex.RegExpToken => {
                left = ast.new(.{ .literal = .{ .tt = p.tt, .data = p.data } });
                p.next();
            },
            lex.OpenBracketToken => {
                const pi = p.in;
                p.in = true;
                left = p.parseArrayLiteral();
                p.in = pi;
            },
            lex.OpenBraceToken => {
                const pi = p.in;
                p.in = true;
                left = p.parseObjectLiteral();
                p.in = pi;
            },
            lex.OpenParenToken => {
                if (ast.OpAssign < prec) {
                    p.next();
                    const pi = p.in;
                    p.in = true;
                    left = ast.new(.{ .group = p.parseExpression(ast.OpExpr) });
                    p.in = pi;
                    if (!p.consume("expression", lex.CloseParenToken)) return null;
                } else {
                    const s = p.parseParenthesizedExpression(prec, null);
                    p.expr_level -= 1;
                    return s;
                }
            },
            lex.NotToken, lex.BitNotToken, lex.TypeofToken, lex.VoidToken, lex.DeleteToken => {
                if (ast.OpUnary < prec) {
                    p.fail("expression");
                    return null;
                }
                p.next();
                left = unaryNode(tt, p.parseExpression(ast.OpUnary));
                prec_left = ast.OpUnary;
            },
            lex.AddToken, lex.SubToken, lex.IncrToken, lex.DecrToken => {
                const lim: OpPrec = if (tt == lex.AddToken or tt == lex.SubToken) ast.OpUnary else ast.OpUpdate;
                if (lim < prec) {
                    p.fail("expression");
                    return null;
                }
                p.next();
                const op: TT = switch (tt) {
                    lex.AddToken => lex.PosToken,
                    lex.SubToken => lex.NegToken,
                    lex.IncrToken => lex.PreIncrToken,
                    else => lex.PreDecrToken,
                };
                left = unaryNode(op, p.parseExpression(ast.OpUnary));
                prec_left = ast.OpUnary;
            },
            lex.AwaitToken => {
                if (p.await_ and prec <= ast.OpUnary) {
                    p.next();
                    left = unaryNode(tt, p.parseExpression(ast.OpUnary));
                    prec_left = ast.OpUnary;
                } else if (p.await_) {
                    p.fail("expression");
                    return null;
                } else {
                    left = ast.newVarNode(p.sc().use(p.data));
                    p.next();
                }
            },
            lex.NewToken => {
                p.next();
                if (p.tt == lex.DotToken) {
                    p.next();
                    if (!p.consume("new.target expression", lex.TargetToken)) return null;
                    left = ast.new(.new_target);
                    prec_left = ast.OpMember;
                } else {
                    const ne = ast.new(.{ .new = .{ .x = p.parseExpression(ast.OpNew), .args = null } });
                    if (p.tt == lex.OpenParenToken) {
                        const args = p.parseArguments();
                        if (args.list.items.len != 0) {
                            const a = sys.A.create(ast.Args) catch unreachable;
                            a.* = args;
                            ne.new.args = a;
                        }
                        prec_left = ast.OpMember;
                    } else prec_left = ast.OpNew;
                    left = ne;
                }
            },
            lex.ImportToken => {
                left = ast.new(.{ .literal = .{ .tt = p.tt, .data = p.data } });
                p.next();
                if (p.tt == lex.DotToken) {
                    p.next();
                    if (!p.consume("import.meta expression", lex.MetaToken)) return null;
                    left = ast.new(.import_meta);
                    prec_left = ast.OpMember;
                } else if (p.tt != lex.OpenParenToken) {
                    p.fail("import expression");
                    return null;
                } else if (ast.OpCall < prec) {
                    p.fail("expression");
                    return null;
                } else prec_left = ast.OpCall;
            },
            lex.SuperToken => {
                left = ast.new(.{ .literal = .{ .tt = p.tt, .data = p.data } });
                p.next();
                if (ast.OpCall < prec and p.tt != lex.DotToken and p.tt != lex.OpenBracketToken) {
                    p.fail("super expression");
                    return null;
                } else if (p.tt != lex.DotToken and p.tt != lex.OpenBracketToken and p.tt != lex.OpenParenToken) {
                    p.fail("super expression");
                    return null;
                }
                prec_left = if (ast.OpCall < prec) ast.OpMember else ast.OpCall;
            },
            lex.YieldToken => {
                if (p.yield_ and prec <= ast.OpAssign) {
                    p.next();
                    var ye: ast.YieldExpr = .{};
                    if (!p.prev_lt) {
                        ye.generator = p.tt == lex.MulToken;
                        if (ye.generator) {
                            p.next();
                            ye.x = p.parseExpression(ast.OpAssign);
                        } else if (p.tt != lex.CloseBraceToken and p.tt != lex.CloseBracketToken and p.tt != lex.CloseParenToken and p.tt != lex.ColonToken and p.tt != lex.CommaToken and p.tt != lex.SemicolonToken) {
                            ye.x = p.parseExpression(ast.OpAssign);
                        }
                    }
                    left = ast.new(.{ .yield = ye });
                    prec_left = ast.OpAssign;
                } else if (p.yield_) {
                    p.fail("expression");
                    return null;
                } else {
                    left = ast.newVarNode(p.sc().use(p.data));
                    p.next();
                }
            },
            lex.AsyncToken => {
                const async_ = p.data;
                p.next();
                const pi = p.in;
                p.in = true;
                left = p.parseAsyncExpression(prec, async_);
                p.in = pi;
            },
            lex.ClassToken => {
                const pi = p.in;
                p.in = true;
                left = p.parseAnyClass(true);
                p.in = pi;
            },
            lex.FunctionToken => {
                const pi = p.in;
                p.in = true;
                left = p.parseFunc(false, true);
                p.in = pi;
            },
            lex.TemplateToken, lex.TemplateStartToken => {
                const pi = p.in;
                p.in = true;
                left = p.parseTemplateLiteral(prec_left);
                p.in = pi;
            },
            lex.PrivateIdentifierToken => {
                if (ast.OpCompare < prec or !p.in) {
                    p.fail("expression");
                    return null;
                }
                left = ast.newVarNode(p.sc().use(p.data));
                p.next();
                if (p.tt != lex.InToken) {
                    p.fail("relational expression");
                    return null;
                }
            },
            else => {
                p.fail("expression");
                return null;
            },
        }
        const s = p.parseExpressionSuffix(left, prec, prec_left);
        p.expr_level -= 1;
        return s;
    }

    fn bin(op: TT, x: ?*Node, y: ?*Node) *Node {
        return ast.new(.{ .binary = .{ .op = op, .x = x, .y = y } });
    }

    fn parseExpressionSuffix(p: *Parser, left0: ?*Node, prec: OpPrec, prec_left0: OpPrec) ?*Node {
        var left = left0;
        var prec_left = prec_left0;
        var i: i64 = 0;
        while (true) : (i += 1) {
            if (1000 < @as(i64, @intCast(p.expr_level)) + i) {
                p.fail("too many nested expressions");
                return null;
            }
            const tt = p.tt;
            switch (tt) {
                lex.EqToken, lex.MulEqToken, lex.DivEqToken, lex.ModEqToken, lex.ExpEqToken, lex.AddEqToken, lex.SubEqToken, lex.LtLtEqToken, lex.GtGtEqToken, lex.GtGtGtEqToken, lex.BitAndEqToken, lex.BitXorEqToken, lex.BitOrEqToken, lex.AndEqToken, lex.OrEqToken, lex.NullishEqToken => {
                    if (ast.OpAssign < prec) return left;
                    if (prec_left < ast.OpLHS) {
                        p.fail("expression");
                        return null;
                    }
                    p.next();
                    left = bin(tt, left, p.parseExpression(ast.OpAssign));
                    prec_left = ast.OpAssign;
                },
                lex.LtToken, lex.LtEqToken, lex.GtToken, lex.GtEqToken, lex.InToken, lex.InstanceofToken => {
                    if (ast.OpCompare < prec or (!p.in and tt == lex.InToken)) return left;
                    if (prec_left < ast.OpCompare) {
                        p.fail("expression");
                        return null;
                    }
                    p.next();
                    left = bin(tt, left, p.parseExpression(ast.OpShift));
                    prec_left = ast.OpCompare;
                },
                lex.EqEqToken, lex.NotEqToken, lex.EqEqEqToken, lex.NotEqEqToken => {
                    if (!p.binStep(&left, &prec_left, prec, tt, ast.OpEquals, ast.OpEquals, ast.OpCompare)) return if (p.failed) null else left;
                },
                lex.AndToken => {
                    if (!p.binStep(&left, &prec_left, prec, tt, ast.OpAnd, ast.OpAnd, ast.OpBitOr)) return if (p.failed) null else left;
                },
                lex.OrToken => {
                    if (!p.binStep(&left, &prec_left, prec, tt, ast.OpOr, ast.OpOr, ast.OpAnd)) return if (p.failed) null else left;
                },
                lex.NullishToken => {
                    if (ast.OpCoalesce < prec) return left;
                    if (prec_left < ast.OpBitOr and prec_left != ast.OpCoalesce) {
                        p.fail("expression");
                        return null;
                    }
                    p.next();
                    left = bin(tt, left, p.parseExpression(ast.OpBitOr));
                    prec_left = ast.OpCoalesce;
                },
                lex.DotToken => {
                    if (prec_left < ast.OpLHS) {
                        p.fail("expression");
                        return null;
                    } else if (ast.OpMember < prec_left) prec_left = ast.OpMember;
                    p.next();
                    if (!lex.isIdentifierName(p.tt) and p.tt != lex.PrivateIdentifierToken) {
                        p.fail("dot expression");
                        return null;
                    }
                    const y = if (p.tt == lex.PrivateIdentifierToken) ast.newVarNode(p.sc().use(p.data)) else ast.new(.{ .literal = .{ .tt = lex.IdentifierToken, .data = p.data } });
                    left = ast.new(.{ .dot = .{ .x = left.?, .y = y, .prec = prec_left, .optional = false } });
                    p.next();
                },
                lex.OpenBracketToken => {
                    if (prec_left < ast.OpLHS) {
                        p.fail("expression");
                        return null;
                    } else if (ast.OpMember < prec_left) prec_left = ast.OpMember;
                    p.next();
                    const pi = p.in;
                    p.in = true;
                    left = ast.new(.{ .index = .{ .x = left.?, .y = p.parseExpression(ast.OpExpr), .prec = prec_left, .optional = false } });
                    p.in = pi;
                    if (!p.consume("index expression", lex.CloseBracketToken)) return null;
                },
                lex.OpenParenToken => {
                    if (ast.OpCall < prec) return left;
                    if (prec_left < ast.OpLHS) {
                        p.fail("expression");
                        return null;
                    } else if (ast.OpCall < prec_left) prec_left = ast.OpCall;
                    const pi = p.in;
                    p.in = true;
                    const x = left.?;
                    left = ast.new(.{ .call = .{ .x = x, .args = p.parseArguments(), .prec = prec_left, .optional = false } });
                    p.in = pi;
                },
                lex.TemplateToken, lex.TemplateStartToken => {
                    if (prec_left < ast.OpLHS) {
                        p.fail("expression");
                        return null;
                    } else if (ast.OpMember < prec_left) prec_left = ast.OpMember;
                    const pi = p.in;
                    p.in = true;
                    const t = p.parseTemplateLiteral(prec_left);
                    t.template.tag = left;
                    left = t;
                    p.in = pi;
                },
                lex.OptChainToken => {
                    if (ast.OpOpt < prec) return left;
                    if (prec_left < ast.OpLHS) {
                        p.fail("expression");
                        return null;
                    }
                    p.next();
                    if (p.tt == lex.OpenParenToken) {
                        const x = left.?;
                        left = ast.new(.{ .call = .{ .x = x, .args = p.parseArguments(), .prec = ast.OpOpt, .optional = true } });
                    } else if (p.tt == lex.OpenBracketToken) {
                        p.next();
                        left = ast.new(.{ .index = .{ .x = left.?, .y = p.parseExpression(ast.OpExpr), .prec = ast.OpOpt, .optional = true } });
                        if (!p.consume("optional chaining expression", lex.CloseBracketToken)) return null;
                    } else if (p.tt == lex.TemplateToken or p.tt == lex.TemplateStartToken) {
                        const t = p.parseTemplateLiteral(prec_left);
                        t.template.prec = ast.OpOpt;
                        t.template.tag = left;
                        t.template.optional = true;
                        left = t;
                    } else if (lex.isIdentifierName(p.tt)) {
                        left = ast.new(.{ .dot = .{ .x = left.?, .y = ast.new(.{ .literal = .{ .tt = lex.IdentifierToken, .data = p.data } }), .prec = ast.OpOpt, .optional = true } });
                        p.next();
                    } else if (p.tt == lex.PrivateIdentifierToken) {
                        left = ast.new(.{ .dot = .{ .x = left.?, .y = ast.newVarNode(p.sc().use(p.data)), .prec = ast.OpOpt, .optional = true } });
                        p.next();
                    } else {
                        p.fail("optional chaining expression");
                        return null;
                    }
                    prec_left = ast.OpOpt;
                },
                lex.IncrToken, lex.DecrToken => {
                    if (p.prev_lt or ast.OpUpdate < prec) return left;
                    if (prec_left < ast.OpLHS) {
                        p.fail("expression");
                        return null;
                    }
                    p.next();
                    left = unaryNode(if (tt == lex.IncrToken) lex.PostIncrToken else lex.PostDecrToken, left);
                    prec_left = ast.OpUpdate;
                },
                lex.ExpToken => {
                    if (ast.OpExp < prec) return left;
                    if (prec_left < ast.OpUpdate) {
                        p.fail("expression");
                        return null;
                    }
                    p.next();
                    left = bin(tt, left, p.parseExpression(ast.OpExp));
                    prec_left = ast.OpExp;
                },
                lex.MulToken, lex.DivToken, lex.ModToken => {
                    if (!p.binStep(&left, &prec_left, prec, tt, ast.OpMul, ast.OpMul, ast.OpExp)) return if (p.failed) null else left;
                },
                lex.AddToken, lex.SubToken => {
                    if (!p.binStep(&left, &prec_left, prec, tt, ast.OpAdd, ast.OpAdd, ast.OpMul)) return if (p.failed) null else left;
                },
                lex.LtLtToken, lex.GtGtToken, lex.GtGtGtToken => {
                    if (!p.binStep(&left, &prec_left, prec, tt, ast.OpShift, ast.OpShift, ast.OpAdd)) return if (p.failed) null else left;
                },
                lex.BitAndToken => {
                    if (!p.binStep(&left, &prec_left, prec, tt, ast.OpBitAnd, ast.OpBitAnd, ast.OpEquals)) return if (p.failed) null else left;
                },
                lex.BitXorToken => {
                    if (!p.binStep(&left, &prec_left, prec, tt, ast.OpBitXor, ast.OpBitXor, ast.OpBitAnd)) return if (p.failed) null else left;
                },
                lex.BitOrToken => {
                    if (!p.binStep(&left, &prec_left, prec, tt, ast.OpBitOr, ast.OpBitOr, ast.OpBitXor)) return if (p.failed) null else left;
                },
                lex.QuestionToken => {
                    if (ast.OpAssign < prec) return left;
                    if (prec_left < ast.OpCoalesce) {
                        p.fail("expression");
                        return null;
                    }
                    p.next();
                    const pi = p.in;
                    p.in = true;
                    const if_expr = p.parseExpression(ast.OpAssign);
                    p.in = pi;
                    if (!p.consume("conditional expression", lex.ColonToken)) return null;
                    const else_expr = p.parseExpression(ast.OpAssign);
                    left = ast.new(.{ .cond = .{ .cond = left, .x = if_expr, .y = else_expr } });
                    prec_left = ast.OpAssign;
                },
                lex.CommaToken => {
                    if (ast.OpExpr < prec) return left;
                    p.next();
                    if (left != null and left.?.* == .comma) {
                        const e = p.parseExpression(ast.OpAssign);
                        left.?.comma.append(sys.A, e orelse ast.new(.empty)) catch {};
                        i -= 1;
                    } else {
                        var l: L(*Node) = .empty;
                        l.append(sys.A, left orelse ast.new(.empty)) catch {};
                        const e = p.parseExpression(ast.OpAssign);
                        l.append(sys.A, e orelse ast.new(.empty)) catch {};
                        left = ast.new(.{ .comma = l });
                    }
                    prec_left = ast.OpExpr;
                },
                lex.ArrowToken => {
                    if (ast.OpAssign < prec) return left;
                    if (prec_left < ast.OpPrimary or p.prev_lt) {
                        p.fail("expression");
                        return null;
                    }
                    const v = ast.asVar(left) orelse {
                        p.fail("expression");
                        return null;
                    };
                    left = p.parseIdentifierArrowFunc(v);
                    prec_left = ast.OpAssign;
                },
                else => return left,
            }
            if (p.failed) return null;
        }
    }

    /// Shared logic for simple left-associative binary operators. Returns false when the
    /// caller must return (either because precedence ends here or on failure).
    fn binStep(p: *Parser, left: *?*Node, prec_left: *OpPrec, prec: OpPrec, tt: TT, op_prec: OpPrec, need: OpPrec, right_prec: OpPrec) bool {
        if (op_prec < prec) return false;
        if (prec_left.* < need) {
            p.fail("expression");
            return false;
        }
        p.next();
        left.* = bin(tt, left.*, p.parseExpression(right_prec));
        prec_left.* = op_prec;
        return true;
    }

    fn parseAssignExprOrParam(p: *Parser) ?*Node {
        if (p.assume_arrow and p.isIdentifierReference(p.tt)) {
            const tt = p.tt;
            const data = p.data;
            p.next();
            if (p.tt == lex.EqToken or p.tt == lex.CommaToken or p.tt == lex.CloseParenToken or p.tt == lex.CloseBraceToken or p.tt == lex.CloseBracketToken) {
                if (p.declare(.ArgumentDecl, data)) |v| {
                    p.assume_arrow = false;
                    const left = p.parseExpressionSuffix(ast.newVarNode(v), ast.OpAssign, ast.OpPrimary);
                    p.assume_arrow = true;
                    return left;
                }
            }
            p.assume_arrow = false;
            if (tt == lex.AsyncToken) return p.parseAsyncExpression(ast.OpAssign, data);
            return p.parseIdentifierExpression(ast.OpAssign, data);
        } else if (p.tt != lex.OpenBracketToken and p.tt != lex.OpenBraceToken) {
            p.assume_arrow = false;
        }
        return p.parseExpression(ast.OpAssign);
    }

    fn parseParenthesizedExpression(p: *Parser, prec: OpPrec, async_: ?[]u8) ?*Node {
        var left: ?*Node = null;
        var prec_left = ast.OpPrimary;
        p.next();
        const is_async = async_ != null;
        const an = ast.new(.{ .arrow = .{} });
        const af = &an.arrow;
        const parent = p.enterScope(&af.body.scope, true);
        const prev_assume = p.assume_arrow;
        const prev_in = p.in;
        p.assume_arrow = true;
        p.in = true;
        var rests: usize = 0;
        var args: ast.Args = .{};
        while (p.tt != lex.CloseParenToken and p.tt != lex.ErrorToken) {
            if (0 < args.list.items.len and args.list.items[args.list.items.len - 1].rest) {
                p.assume_arrow = false;
                if (!is_async) p.fail("arrow function");
            }
            const rest = p.tt == lex.EllipsisToken;
            if (rest) {
                p.next();
                rests += 1;
            }
            args.list.append(sys.A, .{ .value = p.parseAssignExprOrParam(), .rest = rest }) catch {};
            if (p.tt != lex.CommaToken) break;
            p.next();
        }
        if (p.tt != lex.CloseParenToken) {
            p.fail("expression");
            return null;
        }
        p.next();
        const is_arrow = !p.prev_lt and p.tt == lex.ArrowToken and p.assume_arrow;
        const has_last_rest = 0 < rests and p.assume_arrow;
        p.assume_arrow = prev_assume;
        p.in = prev_in;
        if (is_arrow) {
            const pa = p.await_;
            const py = p.yield_;
            p.await_ = is_async;
            p.yield_ = false;
            af.is_async = is_async;
            af.params = .{};
            for (args.list.items) |arg| {
                if (arg.rest) {
                    af.params.rest = p.exprToBinding(arg.value);
                } else {
                    af.params.list.append(sys.A, p.exprToBindingElement(arg.value)) catch {};
                }
            }
            af.body.list = p.parseArrowFuncBody();
            p.await_ = pa;
            p.yield_ = py;
            p.exitScope(parent);
            left = an;
            prec_left = ast.OpAssign;
        } else if (!is_async and (args.list.items.len == 0 or has_last_rest)) {
            p.fail("arrow function");
            return null;
        } else if ((is_async and ast.OpCall < prec) or (!is_async and 0 < rests)) {
            p.fail("expression");
            return null;
        } else {
            p.exitScope(parent);
            af.body.scope.undeclareScope();
            if (is_async) {
                const callee = ast.newVarNode(p.sc().use(async_.?));
                left = ast.new(.{ .call = .{ .x = callee, .args = args, .prec = ast.OpCall, .optional = false } });
                prec_left = ast.OpCall;
            } else {
                if (1 < args.list.items.len) {
                    var l: L(*Node) = .empty;
                    for (args.list.items) |arg| l.append(sys.A, arg.value orelse ast.new(.empty)) catch {};
                    left = ast.new(.{ .group = ast.new(.{ .comma = l }) });
                } else {
                    left = ast.new(.{ .group = args.list.items[0].value });
                }
            }
        }
        return p.parseExpressionSuffix(left, prec, prec_left);
    }

    fn exprToBindingElement(p: *Parser, expr: ?*Node) ast.BindingElement {
        var be: ast.BindingElement = .{};
        if (expr != null and expr.?.* == .binary and expr.?.binary.op == lex.EqToken) {
            be.binding = p.exprToBinding(expr.?.binary.x);
            be.default = expr.?.binary.y;
        } else be.binding = p.exprToBinding(expr);
        return be;
    }

    fn exprToBinding(p: *Parser, expr: ?*Node) ?*Node {
        const e = expr orelse return null;
        switch (e.*) {
            .var_ => return e,
            .array => |list| {
                const n = ast.new(.{ .binding_array = .{} });
                for (list.items) |item| {
                    if (item.spread) {
                        n.binding_array.rest = p.exprToBinding(item.value);
                        break;
                    }
                    n.binding_array.list.append(sys.A, p.exprToBindingElement(item.value)) catch {};
                }
                return n;
            },
            .object => |list| {
                const n = ast.new(.{ .binding_object = .{} });
                for (list.items) |item| {
                    if (item.spread) {
                        n.binding_object.rest = ast.asVar(item.value);
                        break;
                    }
                    var be = p.exprToBindingElement(item.value);
                    const v = ast.asVar(item.value);
                    if (item.name == null or (v != null and item.name.?.isIdent(v.?.data))) be.default = item.init;
                    n.binding_object.list.append(sys.A, .{ .key = item.name, .value = be }) catch {};
                }
                return n;
            },
            else => {
                p.fail("invalid parameters in arrow function");
                return null;
            },
        }
    }
};

pub fn isLHSExpr(n: ?*Node) bool {
    const e = n orelse return true;
    return switch (e.*) {
        .comma, .cond, .yield, .arrow, .binary, .unary => false,
        else => true,
    };
}

pub fn asIdentifierName(b: []const u8) bool {
    if (b.len == 0) return false;
    const c0 = b[0];
    if (!((c0 >= 'a' and c0 <= 'z') or (c0 >= 'A' and c0 <= 'Z') or c0 == '$' or c0 == '_')) return false;
    for (b[1..]) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '$' or c == '_' or (c >= '0' and c <= '9'))) return false;
    }
    return true;
}

pub fn asDecimalLiteral(b: []const u8) bool {
    if (b.len == 0 or ((b[0] < '0' or '9' < b[0]) and (b[0] != '.' or b.len == 1))) return false;
    if (b[0] == '0') return b.len == 1;
    var i: usize = 1;
    while (i < b.len and '0' <= b[i] and b[i] <= '9') i += 1;
    if (i < b.len and b[i] == '.' and b[0] != '.') {
        i += 1;
        while (i < b.len and '0' <= b[i] and b[i] <= '9') i += 1;
    }
    return i == b.len;
}

/// Parses JavaScript source. `src` must be a mutable copy: the minifier rewrites
/// identifiers and strings in place, as the Go original does.
pub fn parse(src: []u8, o: Options) ParseError!*Node {
    var p = Parser{ .l = .{ .s = src }, .o = o };
    const module = ast.new(.{ .block = .{} });
    if (o.inline_) {
        p.next();
        p.retrn = true;
        p.allow_directive = true;
        _ = p.enterScope(&module.block.scope, true);
        while (p.tt != lex.ErrorToken) {
            module.block.list.append(sys.A, p.parseStmt(true) orelse ast.new(.empty)) catch {};
        }
        p.exitScope(null);
    } else {
        var shebang: ?[]u8 = null;
        if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
            var i: usize = 2;
            while (i < src.len and src[i] != '\n' and src[i] != '\r') i += 1;
            shebang = src[0..i];
            p.l.pos = i;
            p.l.start = i;
        }
        p.next();
        p.parseModule(module);
        if (shebang) |sb| module.block.list.insert(sys.A, 0, ast.new(.{ .comment = sb })) catch {};
    }
    if (p.failed or (p.l.err and p.l.pos < p.l.s.len)) return error.JSParseError;
    return module;
}
