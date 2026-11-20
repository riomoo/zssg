// ZSSG — Zig Static Site Generator. Copyright (c) 2026 Riomoo/Alister.
// Licensed under +THYME (see LICENSE).
// Translated to Zig and modified for ZSSG from: tdewolff/parse (MIT, Copyright Taco de Wolff).
// The original notices and licences are kept in NOTICE and licenses/.
//! JavaScript lexer: a port of tdewolff/parse/js lex.go (MIT).
const std = @import("std");
const sys = @import("sys.zig");

pub const TT = u16;
// token types (same values as the Go code; categories are bit flags)
pub const ErrorToken: TT = 0;
pub const WhitespaceToken: TT = 1;
pub const LineTerminatorToken: TT = 2;
pub const CommentToken: TT = 3;
pub const CommentLineTerminatorToken: TT = 4;
pub const StringToken: TT = 5;
pub const TemplateToken: TT = 6;
pub const TemplateStartToken: TT = 7;
pub const TemplateMiddleToken: TT = 8;
pub const TemplateEndToken: TT = 9;
pub const RegExpToken: TT = 10;
pub const PrivateIdentifierToken: TT = 11;
pub const NumericToken: TT = 0x0100;
pub const DecimalToken: TT = 0x0101;
pub const BinaryToken: TT = 0x0102;
pub const OctalToken: TT = 0x0103;
pub const HexadecimalToken: TT = 0x0104;
pub const IntegerToken: TT = 0x0105;
pub const PunctuatorToken: TT = 0x0200;
pub const OpenBraceToken: TT = 0x0201;
pub const CloseBraceToken: TT = 0x0202;
pub const OpenParenToken: TT = 0x0203;
pub const CloseParenToken: TT = 0x0204;
pub const OpenBracketToken: TT = 0x0205;
pub const CloseBracketToken: TT = 0x0206;
pub const DotToken: TT = 0x0207;
pub const SemicolonToken: TT = 0x0208;
pub const CommaToken: TT = 0x0209;
pub const QuestionToken: TT = 0x020A;
pub const ColonToken: TT = 0x020B;
pub const ArrowToken: TT = 0x020C;
pub const EllipsisToken: TT = 0x020D;
pub const OperatorToken: TT = 0x0600;
pub const EqToken: TT = 0x0601;
pub const EqEqToken: TT = 0x0602;
pub const EqEqEqToken: TT = 0x0603;
pub const NotToken: TT = 0x0604;
pub const NotEqToken: TT = 0x0605;
pub const NotEqEqToken: TT = 0x0606;
pub const LtToken: TT = 0x0607;
pub const LtEqToken: TT = 0x0608;
pub const LtLtToken: TT = 0x0609;
pub const LtLtEqToken: TT = 0x060A;
pub const GtToken: TT = 0x060B;
pub const GtEqToken: TT = 0x060C;
pub const GtGtToken: TT = 0x060D;
pub const GtGtEqToken: TT = 0x060E;
pub const GtGtGtToken: TT = 0x060F;
pub const GtGtGtEqToken: TT = 0x0610;
pub const AddToken: TT = 0x0611;
pub const AddEqToken: TT = 0x0612;
pub const IncrToken: TT = 0x0613;
pub const SubToken: TT = 0x0614;
pub const SubEqToken: TT = 0x0615;
pub const DecrToken: TT = 0x0616;
pub const MulToken: TT = 0x0617;
pub const MulEqToken: TT = 0x0618;
pub const ExpToken: TT = 0x0619;
pub const ExpEqToken: TT = 0x061A;
pub const DivToken: TT = 0x061B;
pub const DivEqToken: TT = 0x061C;
pub const ModToken: TT = 0x061D;
pub const ModEqToken: TT = 0x061E;
pub const BitAndToken: TT = 0x061F;
pub const BitOrToken: TT = 0x0620;
pub const BitXorToken: TT = 0x0621;
pub const BitNotToken: TT = 0x0622;
pub const BitAndEqToken: TT = 0x0623;
pub const BitOrEqToken: TT = 0x0624;
pub const BitXorEqToken: TT = 0x0625;
pub const AndToken: TT = 0x0626;
pub const OrToken: TT = 0x0627;
pub const NullishToken: TT = 0x0628;
pub const AndEqToken: TT = 0x0629;
pub const OrEqToken: TT = 0x062A;
pub const NullishEqToken: TT = 0x062B;
pub const OptChainToken: TT = 0x062C;
pub const PosToken: TT = 0x062D;
pub const NegToken: TT = 0x062E;
pub const PreIncrToken: TT = 0x062F;
pub const PreDecrToken: TT = 0x0630;
pub const PostIncrToken: TT = 0x0631;
pub const PostDecrToken: TT = 0x0632;
pub const ReservedToken: TT = 0x0800;
pub const AwaitToken: TT = 0x0801;
pub const BreakToken: TT = 0x0802;
pub const CaseToken: TT = 0x0803;
pub const CatchToken: TT = 0x0804;
pub const ClassToken: TT = 0x0805;
pub const ConstToken: TT = 0x0806;
pub const ContinueToken: TT = 0x0807;
pub const DebuggerToken: TT = 0x0808;
pub const DefaultToken: TT = 0x0809;
pub const DeleteToken: TT = 0x080A;
pub const DoToken: TT = 0x080B;
pub const ElseToken: TT = 0x080C;
pub const EnumToken: TT = 0x080D;
pub const ExportToken: TT = 0x080E;
pub const ExtendsToken: TT = 0x080F;
pub const FalseToken: TT = 0x0810;
pub const FinallyToken: TT = 0x0811;
pub const ForToken: TT = 0x0812;
pub const FunctionToken: TT = 0x0813;
pub const IfToken: TT = 0x0814;
pub const ImportToken: TT = 0x0815;
pub const InToken: TT = 0x0816;
pub const InstanceofToken: TT = 0x0817;
pub const NewToken: TT = 0x0818;
pub const NullToken: TT = 0x0819;
pub const ReturnToken: TT = 0x081A;
pub const SuperToken: TT = 0x081B;
pub const SwitchToken: TT = 0x081C;
pub const ThisToken: TT = 0x081D;
pub const ThrowToken: TT = 0x081E;
pub const TrueToken: TT = 0x081F;
pub const TryToken: TT = 0x0820;
pub const TypeofToken: TT = 0x0821;
pub const YieldToken: TT = 0x0822;
pub const VarToken: TT = 0x0823;
pub const VoidToken: TT = 0x0824;
pub const WhileToken: TT = 0x0825;
pub const WithToken: TT = 0x0826;
pub const IdentifierToken: TT = 0x1000;
pub const AsToken: TT = 0x1001;
pub const AsyncToken: TT = 0x1002;
pub const FromToken: TT = 0x1003;
pub const GetToken: TT = 0x1004;
pub const ImplementsToken: TT = 0x1005;
pub const InterfaceToken: TT = 0x1006;
pub const LetToken: TT = 0x1007;
pub const MetaToken: TT = 0x1008;
pub const OfToken: TT = 0x1009;
pub const PackageToken: TT = 0x100A;
pub const PrivateToken: TT = 0x100B;
pub const ProtectedToken: TT = 0x100C;
pub const PublicToken: TT = 0x100D;
pub const SetToken: TT = 0x100E;
pub const StaticToken: TT = 0x100F;
pub const TargetToken: TT = 0x1010;

pub fn isNumeric(tt: TT) bool {
    return tt & 0x0100 != 0;
}
pub fn isPunctuator(tt: TT) bool {
    return tt & 0x0200 != 0;
}
pub fn isOperator(tt: TT) bool {
    return tt & 0x0400 != 0;
}
pub fn isIdentifierName(tt: TT) bool {
    return tt & 0x1800 != 0;
}
pub fn isReservedWord(tt: TT) bool {
    return tt & 0x0800 != 0;
}
pub fn isIdentifier(tt: TT) bool {
    return tt & 0x1000 != 0;
}

const keyword_list = [_]struct { []const u8, TT }{
    .{ "await", AwaitToken },       .{ "break", BreakToken },         .{ "case", CaseToken },           .{ "catch", CatchToken },
    .{ "class", ClassToken },       .{ "const", ConstToken },         .{ "continue", ContinueToken },   .{ "debugger", DebuggerToken },
    .{ "default", DefaultToken },   .{ "delete", DeleteToken },       .{ "do", DoToken },               .{ "else", ElseToken },
    .{ "enum", EnumToken },         .{ "export", ExportToken },       .{ "extends", ExtendsToken },     .{ "false", FalseToken },
    .{ "finally", FinallyToken },   .{ "for", ForToken },             .{ "function", FunctionToken },   .{ "if", IfToken },
    .{ "import", ImportToken },     .{ "in", InToken },               .{ "instanceof", InstanceofToken }, .{ "new", NewToken },
    .{ "null", NullToken },         .{ "return", ReturnToken },       .{ "super", SuperToken },         .{ "switch", SwitchToken },
    .{ "this", ThisToken },         .{ "throw", ThrowToken },         .{ "true", TrueToken },           .{ "try", TryToken },
    .{ "typeof", TypeofToken },     .{ "yield", YieldToken },         .{ "var", VarToken },             .{ "void", VoidToken },
    .{ "while", WhileToken },       .{ "with", WithToken },           .{ "as", AsToken },               .{ "async", AsyncToken },
    .{ "from", FromToken },         .{ "get", GetToken },             .{ "implements", ImplementsToken }, .{ "interface", InterfaceToken },
    .{ "let", LetToken },           .{ "meta", MetaToken },           .{ "of", OfToken },               .{ "package", PackageToken },
    .{ "private", PrivateToken },   .{ "protected", ProtectedToken }, .{ "public", PublicToken },       .{ "set", SetToken },
    .{ "static", StaticToken },     .{ "target", TargetToken },
};

pub fn keyword(s: []const u8) ?TT {
    for (keyword_list) |k| if (std.mem.eql(u8, k[0], s)) return k[1];
    return null;
}

/// Source text of a token type (for operators and keywords).
pub fn ttBytes(tt: TT) []const u8 {
    const ops = [_][]const u8{ "Operator", "=", "==", "===", "!", "!=", "!==", "<", "<=", "<<", "<<=", ">", ">=", ">>", ">>=", ">>>", ">>>=", "+", "+=", "++", "-", "-=", "--", "*", "*=", "**", "**=", "/", "/=", "%", "%=", "&", "|", "^", "~", "&=", "|=", "^=", "&&", "||", "??", "&&=", "||=", "??=", "?.", "+", "-", "++", "--", "++", "--" };
    if (tt & 0xFF00 == 0x0600) {
        const i = tt & 0xFF;
        if (i < ops.len) return ops[i];
    }
    const puncts = [_][]const u8{ "Punctuator", "{", "}", "(", ")", "[", "]", ".", ";", ",", "?", ":", "=>", "..." };
    if (tt & 0xFF00 == 0x0200) {
        const i = tt & 0xFF;
        if (i < puncts.len) return puncts[i];
    }
    for (keyword_list) |k| if (k[1] == tt) return k[0];
    return "";
}

fn isIdStartCp(r: u21) bool {
    if (r < 0x80) return (r >= 'a' and r <= 'z') or (r >= 'A' and r <= 'Z') or r == '$' or r == '_';
    // Unicode letters (approximation of Lu/Ll/Lt/Lm/Lo/Nl)
    if (r == 0xAA or r == 0xB5 or r == 0xBA) return true;
    if (r >= 0xC0 and r <= 0x24F and r != 0xD7 and r != 0xF7) return true;
    if (r >= 0x370 and r <= 0x3FF and r != 0x37E and r != 0x387) return true;
    if (r >= 0x400 and r <= 0x52F) return true;
    if (r >= 0x531 and r <= 0x587) return true;
    if (r >= 0x5D0 and r <= 0x5EA) return true;
    if (r >= 0x620 and r <= 0x64A) return true;
    if (r >= 0x900 and r <= 0x939) return true;
    if (r >= 0x1E00 and r <= 0x1FFF) return true;
    if (r >= 0x3040 and r <= 0x30FF) return true;
    if (r >= 0x3400 and r <= 0x9FFF) return true;
    if (r >= 0xAC00 and r <= 0xD7A3) return true;
    if (r >= 0xF900 and r <= 0xFAFF) return true;
    if (r >= 0x10000 and r <= 0x2FFFF) return true;
    return false;
}
fn isIdContCp(r: u21) bool {
    if (isIdStartCp(r)) return true;
    if (r < 0x80) return r >= '0' and r <= '9';
    if (r == 0x200C or r == 0x200D) return true;
    if (r >= 0x300 and r <= 0x36F) return true;
    if (r >= 0x660 and r <= 0x669) return true;
    return false;
}
fn isZsCp(r: u21) bool {
    return r == 0xA0 or r == 0xFEFF or r == 0x1680 or (r >= 0x2000 and r <= 0x200A) or r == 0x202F or r == 0x205F or r == 0x3000;
}

pub const Lexer = struct {
    s: []const u8,
    pos: usize = 0,
    start: usize = 0,
    err: bool = false,
    prev_line_terminator: bool = true,
    prev_numeric: bool = false,
    level: i64 = 0,
    template_levels: std.ArrayList(i64) = .empty,

    pub fn peek(l: *const Lexer, n: usize) u8 {
        return if (l.pos + n < l.s.len) l.s[l.pos + n] else 0;
    }
    fn eof(l: *const Lexer) bool {
        return l.pos >= l.s.len;
    }
    fn shift(l: *Lexer) []const u8 {
        const r = l.s[l.start..l.pos];
        l.start = l.pos;
        return r;
    }
    fn peekRune(l: *const Lexer) struct { r: u21, n: usize } {
        if (l.pos >= l.s.len) return .{ .r = 0, .n = 0 };
        const c = l.s[l.pos];
        if (c < 0x80) return .{ .r = c, .n = 1 };
        const n = std.unicode.utf8ByteSequenceLength(c) catch return .{ .r = 0xFFFD, .n = 1 };
        if (l.pos + n > l.s.len) return .{ .r = 0xFFFD, .n = 1 };
        const r = std.unicode.utf8Decode(l.s[l.pos .. l.pos + n]) catch return .{ .r = 0xFFFD, .n = 1 };
        return .{ .r = r, .n = n };
    }

    pub fn regExp(l: *Lexer) struct { tt: TT, data: []const u8 } {
        if (0 < l.pos and l.s[l.pos - 1] == '/') {
            l.pos -= 1;
        } else if (1 < l.pos and l.s[l.pos - 1] == '=' and l.s[l.pos - 2] == '/') {
            l.pos -= 2;
        } else {
            l.err = true;
            return .{ .tt = ErrorToken, .data = "" };
        }
        l.start = l.pos;
        if (l.consumeRegExp()) return .{ .tt = RegExpToken, .data = l.shift() };
        l.err = true;
        return .{ .tt = ErrorToken, .data = "" };
    }

    pub fn next(l: *Lexer) struct { tt: TT, data: []const u8 } {
        l.err = false;
        const prev_lt = l.prev_line_terminator;
        l.prev_line_terminator = false;
        const prev_num = l.prev_numeric;
        l.prev_numeric = false;
        const c = l.peek(0);
        switch (c) {
            ' ', '\t', 0x0b, 0x0c => {
                l.pos += 1;
                while (l.consumeWhitespace()) {}
                l.prev_line_terminator = prev_lt;
                return .{ .tt = WhitespaceToken, .data = l.shift() };
            },
            '\n', '\r' => {
                l.pos += 1;
                while (l.consumeLineTerminator()) {}
                l.prev_line_terminator = true;
                return .{ .tt = LineTerminatorToken, .data = l.shift() };
            },
            '>', '=', '!', '+', '*', '%', '&', '|', '^', '~', '?' => {
                const tt = l.consumeOperator();
                if (tt != ErrorToken) return .{ .tt = tt, .data = l.shift() };
            },
            '0'...'9', '.' => {
                const tt = l.consumeNumeric();
                if (tt != ErrorToken or l.pos != l.start) {
                    l.prev_numeric = true;
                    return .{ .tt = tt, .data = l.shift() };
                } else if (c == '.') {
                    l.pos += 1;
                    if (l.peek(0) == '.' and l.peek(1) == '.') {
                        l.pos += 2;
                        return .{ .tt = EllipsisToken, .data = l.shift() };
                    }
                    return .{ .tt = DotToken, .data = l.shift() };
                }
            },
            ',' => {
                l.pos += 1;
                return .{ .tt = CommaToken, .data = l.shift() };
            },
            ';' => {
                l.pos += 1;
                return .{ .tt = SemicolonToken, .data = l.shift() };
            },
            '(' => {
                l.level += 1;
                l.pos += 1;
                return .{ .tt = OpenParenToken, .data = l.shift() };
            },
            ')' => {
                l.level -= 1;
                l.pos += 1;
                return .{ .tt = CloseParenToken, .data = l.shift() };
            },
            '/' => {
                const tt = l.consumeComment();
                if (tt != ErrorToken or l.err) {
                    if (l.err) return .{ .tt = ErrorToken, .data = "" };
                    return .{ .tt = tt, .data = l.shift() };
                }
                const tt2 = l.consumeOperator();
                if (tt2 != ErrorToken) return .{ .tt = tt2, .data = l.shift() };
            },
            '{' => {
                l.level += 1;
                l.pos += 1;
                return .{ .tt = OpenBraceToken, .data = l.shift() };
            },
            '}' => {
                l.level -= 1;
                if (l.template_levels.items.len != 0 and l.level == l.template_levels.items[l.template_levels.items.len - 1]) {
                    const tt = l.consumeTemplate();
                    return .{ .tt = tt, .data = l.shift() };
                }
                l.pos += 1;
                return .{ .tt = CloseBraceToken, .data = l.shift() };
            },
            ':' => {
                l.pos += 1;
                return .{ .tt = ColonToken, .data = l.shift() };
            },
            '\'', '"' => {
                const tt = l.consumeString();
                return .{ .tt = tt, .data = l.shift() };
            },
            ']' => {
                l.pos += 1;
                return .{ .tt = CloseBracketToken, .data = l.shift() };
            },
            '[' => {
                l.pos += 1;
                return .{ .tt = OpenBracketToken, .data = l.shift() };
            },
            '<', '-' => {
                if (l.consumeHTMLComment(prev_lt)) return .{ .tt = CommentToken, .data = l.shift() };
                const tt = l.consumeOperator();
                if (tt != ErrorToken) return .{ .tt = tt, .data = l.shift() };
            },
            '`' => {
                l.template_levels.append(sys.A, l.level) catch {};
                const tt = l.consumeTemplate();
                return .{ .tt = tt, .data = l.shift() };
            },
            '#' => {
                l.pos += 1;
                if (l.consumeIdentifier()) return .{ .tt = PrivateIdentifierToken, .data = l.shift() };
            },
            else => {
                if (l.consumeIdentifier()) {
                    if (prev_num) {
                        l.err = true;
                        return .{ .tt = ErrorToken, .data = "" };
                    }
                    if (keyword(l.s[l.start..l.pos])) |k| return .{ .tt = k, .data = l.shift() };
                    return .{ .tt = IdentifierToken, .data = l.shift() };
                }
                if (0xC0 <= c) {
                    if (l.consumeWhitespace()) {
                        while (l.consumeWhitespace()) {}
                        l.prev_line_terminator = prev_lt;
                        return .{ .tt = WhitespaceToken, .data = l.shift() };
                    } else if (l.consumeLineTerminator()) {
                        while (l.consumeLineTerminator()) {}
                        l.prev_line_terminator = true;
                        return .{ .tt = LineTerminatorToken, .data = l.shift() };
                    }
                } else if (c == 0 and l.eof()) return .{ .tt = ErrorToken, .data = "" };
            },
        }
        l.err = true;
        const pr = l.peekRune();
        l.pos += @max(pr.n, 1);
        return .{ .tt = ErrorToken, .data = l.shift() };
    }

    fn consumeWhitespace(l: *Lexer) bool {
        const c = l.peek(0);
        if (c == ' ' or c == '\t' or c == 0x0b or c == 0x0c) {
            l.pos += 1;
            return true;
        } else if (0xC0 <= c) {
            const pr = l.peekRune();
            if (isZsCp(pr.r)) {
                l.pos += pr.n;
                return true;
            }
        }
        return false;
    }
    pub fn isLineTerminator(l: *const Lexer) bool {
        const c = l.peek(0);
        if (c == '\n' or c == '\r') return true;
        return c == 0xE2 and l.peek(1) == 0x80 and (l.peek(2) == 0xA8 or l.peek(2) == 0xA9);
    }
    fn consumeLineTerminator(l: *Lexer) bool {
        const c = l.peek(0);
        if (c == '\n') {
            l.pos += 1;
            return true;
        } else if (c == '\r') {
            l.pos += if (l.peek(1) == '\n') 2 else 1;
            return true;
        } else if (c == 0xE2 and l.peek(1) == 0x80 and (l.peek(2) == 0xA8 or l.peek(2) == 0xA9)) {
            l.pos += 3;
            return true;
        }
        return false;
    }
    fn digit(l: *Lexer) bool {
        const c = l.peek(0);
        if (c >= '0' and c <= '9') {
            l.pos += 1;
            return true;
        }
        return false;
    }
    fn hexDigit(l: *Lexer) bool {
        const c = l.peek(0);
        if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
            l.pos += 1;
            return true;
        }
        return false;
    }
    fn binDigit(l: *Lexer) bool {
        const c = l.peek(0);
        if (c == '0' or c == '1') {
            l.pos += 1;
            return true;
        }
        return false;
    }
    fn octDigit(l: *Lexer) bool {
        const c = l.peek(0);
        if (c >= '0' and c <= '7') {
            l.pos += 1;
            return true;
        }
        return false;
    }
    fn consumeUnicodeEscape(l: *Lexer) bool {
        if (l.peek(0) != '\\' or l.peek(1) != 'u') return false;
        const mark = l.pos;
        l.pos += 2;
        if (l.peek(0) == '{') {
            l.pos += 1;
            if (l.hexDigit()) {
                while (l.hexDigit()) {}
                if (l.peek(0) == '}') {
                    l.pos += 1;
                    return true;
                }
            }
            l.pos = mark;
            return false;
        } else if (!l.hexDigit() or !l.hexDigit() or !l.hexDigit() or !l.hexDigit()) {
            l.pos = mark;
            return false;
        }
        return true;
    }
    fn singleLineComment(l: *Lexer) void {
        while (true) {
            const c = l.peek(0);
            if (c == '\r' or c == '\n' or (c == 0 and l.eof())) break;
            if (0xC0 <= c) {
                const pr = l.peekRune();
                if (pr.r == 0x2028 or pr.r == 0x2029) break;
            }
            l.pos += 1;
        }
    }
    fn consumeHTMLComment(l: *Lexer, prev_lt: bool) bool {
        const c = l.peek(0);
        if (c == '<' and l.peek(1) == '!' and l.peek(2) == '-' and l.peek(3) == '-') {
            l.pos += 4;
            l.singleLineComment();
            return true;
        } else if (prev_lt and c == '-' and l.peek(1) == '-' and l.peek(2) == '>') {
            l.pos += 3;
            l.singleLineComment();
            return true;
        }
        return false;
    }
    fn consumeComment(l: *Lexer) TT {
        const c = l.peek(1);
        if (c == '/') {
            l.pos += 2;
            l.singleLineComment();
            return CommentToken;
        } else if (c == '*') {
            l.pos += 2;
            var tt = CommentToken;
            while (true) {
                const d = l.peek(0);
                if (d == '*' and l.peek(1) == '/') {
                    l.pos += 2;
                    break;
                } else if (d == 0 and l.eof()) {
                    l.err = true;
                    return ErrorToken;
                } else if (l.consumeLineTerminator()) {
                    l.prev_line_terminator = true;
                    tt = CommentLineTerminatorToken;
                } else l.pos += 1;
            }
            return tt;
        }
        return ErrorToken;
    }
    fn consumeOperator(l: *Lexer) TT {
        const c = l.peek(0);
        l.pos += 1;
        if (l.peek(0) == '=') {
            l.pos += 1;
            if (l.peek(0) == '=' and (c == '!' or c == '=')) {
                l.pos += 1;
                return if (c == '!') NotEqEqToken else EqEqEqToken;
            }
            return switch (c) {
                '=' => EqEqToken,
                '!' => NotEqToken,
                '<' => LtEqToken,
                '>' => GtEqToken,
                '+' => AddEqToken,
                '-' => SubEqToken,
                '*' => MulEqToken,
                '/' => DivEqToken,
                '%' => ModEqToken,
                '&' => BitAndEqToken,
                '|' => BitOrEqToken,
                '^' => BitXorEqToken,
                else => ErrorToken,
            };
        } else if (l.peek(0) == c and (c == '+' or c == '-' or c == '*' or c == '&' or c == '|' or c == '?' or c == '<')) {
            l.pos += 1;
            if (l.peek(0) == '=' and c != '+' and c != '-') {
                l.pos += 1;
                return switch (c) {
                    '<' => LtLtEqToken,
                    '*' => ExpEqToken,
                    '&' => AndEqToken,
                    '|' => OrEqToken,
                    '?' => NullishEqToken,
                    else => ErrorToken,
                };
            }
            return switch (c) {
                '<' => LtLtToken,
                '+' => IncrToken,
                '-' => DecrToken,
                '*' => ExpToken,
                '&' => AndToken,
                '|' => OrToken,
                '?' => NullishToken,
                else => ErrorToken,
            };
        } else if (c == '?' and l.peek(0) == '.' and (l.peek(1) < '0' or l.peek(1) > '9')) {
            l.pos += 1;
            return OptChainToken;
        } else if (c == '=' and l.peek(0) == '>') {
            l.pos += 1;
            return ArrowToken;
        } else if (c == '>' and l.peek(0) == '>') {
            l.pos += 1;
            if (l.peek(0) == '>') {
                l.pos += 1;
                if (l.peek(0) == '=') {
                    l.pos += 1;
                    return GtGtGtEqToken;
                }
                return GtGtGtToken;
            } else if (l.peek(0) == '=') {
                l.pos += 1;
                return GtGtEqToken;
            }
            return GtGtToken;
        }
        return switch (c) {
            '=' => EqToken,
            '!' => NotToken,
            '<' => LtToken,
            '>' => GtToken,
            '+' => AddToken,
            '-' => SubToken,
            '*' => MulToken,
            '/' => DivToken,
            '%' => ModToken,
            '&' => BitAndToken,
            '|' => BitOrToken,
            '^' => BitXorToken,
            '~' => BitNotToken,
            '?' => QuestionToken,
            else => ErrorToken,
        };
    }
    fn idStartByte(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '$' or c == '_';
    }
    fn idByte(c: u8) bool {
        return idStartByte(c) or (c >= '0' and c <= '9');
    }
    fn consumeIdentifier(l: *Lexer) bool {
        const c = l.peek(0);
        if (idStartByte(c)) {
            l.pos += 1;
        } else if (0xC0 <= c) {
            const pr = l.peekRune();
            if (isIdStartCp(pr.r)) l.pos += pr.n else return false;
        } else if (!l.consumeUnicodeEscape()) return false;
        while (true) {
            const d = l.peek(0);
            if (idByte(d)) {
                l.pos += 1;
            } else if (0xC0 <= d) {
                const pr = l.peekRune();
                if (isIdContCp(pr.r)) l.pos += pr.n else break;
            } else if (!l.consumeUnicodeEscape()) break;
        }
        return true;
    }
    fn numSep(l: *Lexer, f: *const fn (*Lexer) bool) bool {
        if (l.peek(0) != '_') return false;
        l.pos += 1;
        if (!f(l)) {
            l.pos -= 1;
            return false;
        }
        return true;
    }
    fn consumeNumeric(l: *Lexer) TT {
        const first = l.peek(0);
        if (first == '0') {
            l.pos += 1;
            const x = l.peek(0);
            if (x == 'x' or x == 'X') {
                l.pos += 1;
                if (l.hexDigit()) {
                    while (l.hexDigit() or l.numSep(hexDigit)) {}
                    if (l.peek(0) == 'n') l.pos += 1;
                    return HexadecimalToken;
                }
                l.pos -= 1;
                return IntegerToken;
            } else if (x == 'b' or x == 'B') {
                l.pos += 1;
                if (l.binDigit()) {
                    while (l.binDigit() or l.numSep(binDigit)) {}
                    if (l.peek(0) == 'n') l.pos += 1;
                    return BinaryToken;
                }
                l.pos -= 1;
                return IntegerToken;
            } else if (x == 'o' or x == 'O') {
                l.pos += 1;
                if (l.octDigit()) {
                    while (l.octDigit() or l.numSep(octDigit)) {}
                    if (l.peek(0) == 'n') l.pos += 1;
                    return OctalToken;
                }
                l.pos -= 1;
                return IntegerToken;
            } else if (x == 'n') {
                l.pos += 1;
                return IntegerToken;
            } else if (x >= '0' and x <= '9') {
                l.err = true;
                return ErrorToken;
            }
        } else if (first != '.') {
            while (l.digit() or l.numSep(digit)) {}
        }
        var c = l.peek(0);
        if (c == '.') {
            l.pos += 1;
            if (l.digit()) {
                while (l.digit() or l.numSep(digit)) {}
                c = l.peek(0);
            } else if (first == '.') {
                l.pos -= 1;
                return ErrorToken;
            } else c = l.peek(0);
        } else if (c == 'n') {
            l.pos += 1;
            return IntegerToken;
        } else if (c != 'e' and c != 'E') return IntegerToken;
        if (c == 'e' or c == 'E') {
            l.pos += 1;
            c = l.peek(0);
            if (c == '+' or c == '-') l.pos += 1;
            if (!l.digit()) {
                l.err = true;
                return ErrorToken;
            }
            while (l.digit() or l.numSep(digit)) {}
        }
        return DecimalToken;
    }
    fn consumeString(l: *Lexer) TT {
        const delim = l.peek(0);
        l.pos += 1;
        while (true) {
            const c = l.peek(0);
            if (c == delim and !(c == 0 and l.eof())) {
                l.pos += 1;
                break;
            } else if (c == '\\') {
                l.pos += 1;
                if (!l.consumeLineTerminator()) {
                    const d = l.peek(0);
                    if (d == delim or d == '\\') l.pos += 1;
                }
                continue;
            } else if (c == '\n' or c == '\r' or (c == 0 and l.eof())) {
                l.err = true;
                return ErrorToken;
            }
            l.pos += 1;
        }
        return StringToken;
    }
    fn consumeRegExp(l: *Lexer) bool {
        l.pos += 1;
        var in_class = false;
        while (true) {
            const c = l.peek(0);
            if (!in_class and c == '/') {
                l.pos += 1;
                break;
            } else if (c == '[') {
                in_class = true;
            } else if (c == ']') {
                in_class = false;
            } else if (c == '\\') {
                l.pos += 1;
                if (l.isLineTerminator() or (l.peek(0) == 0 and l.eof())) return false;
            } else if (l.isLineTerminator() or (c == 0 and l.eof())) return false;
            l.pos += 1;
        }
        while (true) {
            const c = l.peek(0);
            if (idByte(c)) {
                l.pos += 1;
            } else if (0xC0 <= c) {
                const pr = l.peekRune();
                if (isIdContCp(pr.r)) l.pos += pr.n else break;
            } else break;
        }
        return true;
    }
    fn consumeTemplate(l: *Lexer) TT {
        const continuation = l.peek(0) == '}';
        l.pos += 1;
        while (true) {
            const c = l.peek(0);
            if (c == '`') {
                l.template_levels.items.len -= 1;
                l.pos += 1;
                return if (continuation) TemplateEndToken else TemplateToken;
            } else if (c == '$' and l.peek(1) == '{') {
                l.level += 1;
                l.pos += 2;
                return if (continuation) TemplateMiddleToken else TemplateStartToken;
            } else if (c == '\\') {
                l.pos += 1;
                if (l.peek(0) != 0) l.pos += 1;
                continue;
            } else if (c == 0 and l.eof()) {
                l.err = true;
                return ErrorToken;
            }
            l.pos += 1;
        }
    }
};

pub fn isIdentifierStartStr(b: []const u8) bool {
    if (b.len == 0) return false;
    const c = b[0];
    if (c < 0x80) return c == '$' or c == '\\' or c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    const n = std.unicode.utf8ByteSequenceLength(c) catch return false;
    const r = std.unicode.utf8Decode(b[0..@min(n, b.len)]) catch return false;
    return isIdStartCp(r);
}
pub fn isIdentifierContinueStr(b: []const u8) bool {
    if (b.len == 0) return false;
    const c = b[0];
    if (c < 0x80) return c == '$' or c == '\\' or c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
    const n = std.unicode.utf8ByteSequenceLength(c) catch return false;
    const r = std.unicode.utf8Decode(b[0..@min(n, b.len)]) catch return false;
    return isIdContCp(r);
}
pub fn isIdentifierEndStr(b: []const u8) bool {
    if (b.len == 0) return false;
    var i = b.len - 1;
    while (i > 0 and (b[i] & 0xC0) == 0x80) i -= 1;
    return isIdentifierContinueStr(b[i..]);
}
