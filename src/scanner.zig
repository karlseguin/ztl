const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Scanner = struct {
    // currently only used for unescaping strings
    scratch: std.ArrayList(u8),

    // where in src we are
    pos: u32 = 0,

    // the source that we're scanning
    src: []const u8,

    arena: Allocator,

    // arena is an ArenaAllocator managed by the caller
    pub fn init(arena: Allocator, src: []const u8) Scanner {
        return .{
            .src = src,
            .arena = arena,
            .scratch = .empty,
        };
    }


    pub fn reset(self: *Scanner, src: []const u8) void {
        self.src = src;
        self.pos = 0;
        self.scratch.clearRetainingCapacity();
    }

   // Used by our caller to figure out the position of the next token
    // might as well use this opportunity to skip the whitespace with respect
    // to our self.pos;
    pub fn skipSpaces(self: *Scanner) u32 {
        var pos = self.pos;
        const src = self.src;

        while (pos < src.len) {
            switch (src[pos]) {
                ' ', '\t', '\r', '\n' => pos += 1,
                else => break,
            }
        }
        self.pos = pos;
        return pos;
    }

    pub fn next(self: *Scanner) Error!Token {
        var pos = self.pos;
        const src = self.src;
        defer self.pos = pos;

        while (pos < src.len) {
            const b = src[pos];
            const start = pos;
            pos += 1;
            switch (b) {
                '{' => return .{.LEFT_BRACE = {}},
                '}' => return .{.RIGHT_BRACE = {}},
                '[' => return .{.LEFT_BRACKET = {}},
                ']' => return .{.RIGHT_BRACKET = {}},
                '(' => return .{.LEFT_PARENTHESIS = {}},
                ')' => return .{.RIGHT_PARENTHESIS = {}},
                '|' => return .{.PIPE = {}},
                ',' => return .{.COMMA = {}},
                '.' => return .{.DOT = {}},
                '$' => return .{.DOLLAR = {}},
                '?' => return .{.QUESTION_MARK = {}},
                '%' => switch (self.at(pos)) {
                    '{' => {
                        pos += 1;
                        return .{.PERCENT_BRACE = {}};
                    },
                    '>' => {
                        pos += 1;
                        return .{.PERCENT_GREATER = {}};
                    },
                    else => return .{.PERCENT = {}},
                },
                '+' => {
                    if (self.at(pos) == '+') {
                        pos += 1;
                        return .{.PLUS_PLUS = {}};
                    }
                    if (self.at(pos) == '=') {
                        pos += 1;
                        return .{.PLUS_EQUAL = {}};
                    }
                    return .{.PLUS = {}};
                },
                '-' => {
                    if (self.at(pos) == '-') {
                        pos += 1;
                        return .{.MINUS_MINUS = {}};
                    }
                    if (self.at(pos) == '=') {
                        pos += 1;
                        return .{.MINUS_EQUAL = {}};
                    }
                    if (self.at(pos) == '%' and self.at(pos + 1) == '>') {
                        pos += 2;
                        return .{.MINUS_PERCENT_GREATER = {}};
                    }
                    return .{.MINUS = {}};
                },
                ':' => return .{.COLON = {}},
                '*' => return .{.STAR = {}},
                ';' => return .{.SEMICOLON = {}},
                '/' => {
                    if (self.at(pos) != '/') {
                        return .{.SLASH = {}};
                    }
                    while (pos < src.len) {
                        if (src[pos] != '\n') {
                            pos += 1;
                        } else {
                            pos += 1;
                            self.pos = pos;
                            break;
                        }
                    }
                },
                '!' => {
                    if (self.at(pos) == '=') {
                        pos += 1;
                        return .{.BANG_EQUAL = {}};
                    }
                    return .{.BANG = {}};
                },
                '=' => {
                    if (self.at(pos) == '=') {
                        pos += 1;
                        return .{.EQUAL_EQUAL = {}};
                    }
                    return .{.EQUAL = {}};
                },
                '>' => {
                    if (self.at(pos) == '=') {
                        pos += 1;
                        return .{.GREATER_EQUAL = {}};
                    }
                    return .{.GREATER = {}};
                },
                '<' => switch (self.at(pos)) {
                    '=' => {
                        pos += 1;
                        return .{.LESSER_EQUAL = {}};
                    },
                    '%' => {
                        pos += 1;
                        return .{.LESSER_PERCENT = {}};
                    },
                    else => return .{.LESSER = {}},
                },
                '0'...'9' => return self.number(&pos),
                '"' => return self.string('"', &pos),
                '\'' => return self.string('\'', &pos),
                '`' => {
                    const end = std.mem.indexOfScalarPos(u8, src, pos, '`') orelse return error.UnterminatedString;
                    pos = @intCast(end + 1);
                    return .{.STRING = src[start + 1 .. end]};
                },
                'a'...'z', 'A'...'Z', '_', '@' => {
                    if (try self.identifier(&pos)) |token| {
                        return token;
                    }
                    // else an error was recorded, keep parsing
                },
                ' ', '\t', '\r', '\n' => {},
                else => return error.UnexpectedCharacter,
            }
        }

        return .{.EOF = {}};
    }

    pub fn peek(self: *Scanner) Token {
        const pos = self.pos;
        defer self.pos = pos;
        return self.next() catch unreachable;
    }

    fn at(self: *Scanner, pos: usize) u8 {
        const src = self.src;
        return if (pos < src.len) src[pos] else 0;
    }

    // TODO: Newline
    // TODO: optimize unescaping (maybe keep an array of N escape index so that
    // we can quickly copy inbetween without re-checking for \ again)
    // scanner_pos points to the first byte after the opening quote
    fn string(self: *Scanner, delimiter: u8, scanner_pos: *u32) Error!Token {
        var pos = scanner_pos.*;

        const start = pos;
        const src = self.src;

        var escape_count: usize = 0;

        while (pos < src.len) {
            const c = src[pos];
            if (c == delimiter) {
                break;
            }
            if (c == '\\') {
                pos += 2;
                escape_count += 1;
            } else {
                pos += 1;
            }
        }

        if (pos == src.len) {
            return error.UnterminatedString;
        }

        const allocator = self.arena;

        scanner_pos.* = pos + 1;
        var literal = src[start..pos];
        if (escape_count > 0) {
            var scratch = &self.scratch;
            scratch.clearRetainingCapacity();

            var i: u32 = 0;
            while (i < literal.len - 1) : (i += 1) {
                switch (literal[i]) {
                    '\\' => {
                        i += 1; // safe because our while loop is going to: i < literal.len - 1
                        switch (literal[i]) {
                            'n' => try scratch.append(allocator, '\n'),
                            'r' => try scratch.append(allocator, '\r'),
                            't' => try scratch.append(allocator, '\t'),
                            '"' => try scratch.append(allocator, '\"'),
                            '\\' => try scratch.append(allocator, '\\'),
                            '\'' => try scratch.append(allocator, '\''),
                            else => return error.InvalidEscapeSequence,
                        }
                    },
                    else => |b| try scratch.append(allocator, b),
                }
            }

            if (i < literal.len) {
                // copy the last character
                try scratch.append(allocator, literal[i]);
            }
            literal = try allocator.dupe(u8, scratch.items);
        }

        return .{.STRING = literal};
    }

    // scanner_pos points to the first byte after whatever byte triggered this
    fn number(self: *Scanner, scanner_pos: *u32) Error!Token {
        var pos = scanner_pos.*;
        const src = self.src;

        var float = false;
        const start = pos - 1;

        blk: while (pos < src.len) {
            switch (src[pos]) {
                '0'...'9' => {},
                '.' => float = true,
                else => break :blk,
            }
            pos += 1;
        }

        scanner_pos.* = pos;
        var buf = src[start..pos];

        if (float) {
            const last = buf.len - 1;
            if (buf[last] != '.') {
                const value = std.fmt.parseFloat(f64, buf) catch return error.InvalidFloat;
                return .{ .FLOAT = value };
            }
            float = false;
            scanner_pos.* = pos - 1;
            buf = buf[0..last];
        }

        const value = std.fmt.parseInt(i64, buf, 10) catch return error.InvalidInteger;
        return .{ .INTEGER = value };
    }

    fn identifier(self: *Scanner, scanner_pos: *u32) !?Token {
        var pos = scanner_pos.*;

        const start = pos - 1;
        const src = self.src;
        blk: while (pos < src.len) {
            switch (src[pos]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => pos += 1,
                else => break :blk,
            }
        }
        scanner_pos.* = pos;

        const value = src[start..pos];

        switch (value.len) {
            2 => switch (@as(u16, @bitCast(value[0..2].*))) {
                asUint("fn") => return .{.FN = {}},
                asUint("if") => return .{.IF = {}},
                asUint("or") => return .{.OR = {}},
                else => {},
            },
            3 => switch (@as(u24, @bitCast(value[0..3].*))) {
                asUint("var") => return .{.VAR = {}},
                asUint("and") => return .{.AND = {}},
                asUint("for") => return .{.FOR = {}},
                else => {},
            },
            4 => switch (@as(u32, @bitCast(value[0..4].*))) {
                asUint("else") => return .{.ELSE = {}},
                asUint("null") => return .{.NULL = {}},
                asUint("true") => return .{.BOOLEAN = true},
                else => {},
            },
            5 => switch (@as(u40, @bitCast(value[0..5].*))) {
                asUint("false") => return .{.BOOLEAN = false},
                asUint("while") => return .{.WHILE = {}},
                asUint("break") => return .{.BREAK = {}},
                else => {},
            },
            6 => switch (@as(u48, @bitCast(value[0..6].*))) {
                asUint("return") => return .{.RETURN = {}},
                asUint("orelse") => return .{.ORELSE = {}},
                else => {},
            },
            7 => switch (@as(u56, @bitCast(value[0..7].*))) {
                asUint("foreach") => return .{.FOREACH = {}},
                else => {},
            },
            8 => switch (@as(u64, @bitCast(value[0..8].*))) {
                asUint("continue") => return .{.CONTINUE = {}},
                else => {},
            },
            else => {},
        }

        if (value.len > 127) {
            // would be better to handle this in the compiler, but easier to do here.
            return error.IdentifierTooLong;
        }

        return .{.IDENTIFIER = value};
    }
};

pub const Token = union(enum) {
    AND,
    BANG,
    BANG_EQUAL,
    BOF,
    BOOLEAN: bool,
    BREAK,
    COLON,
    COMMA,
    CONTINUE,
    DOLLAR,
    DOT,
    ELSE,
    EOF,
    EQUAL,
    EQUAL_EQUAL,
    FLOAT: f64,
    FN,
    FOR,
    FOREACH,
    GREATER,
    GREATER_EQUAL,
    IDENTIFIER: []const u8,
    IF,
    INTEGER: i64,
    LEFT_BRACE,
    LEFT_BRACKET,
    LEFT_PARENTHESIS,
    LESSER,
    LESSER_EQUAL,
    LESSER_PERCENT,
    MINUS,
    MINUS_EQUAL,
    MINUS_MINUS,
    MINUS_PERCENT_GREATER,
    NULL,
    OR,
    ORELSE,
    PERCENT,
    PERCENT_BRACE,
    PERCENT_GREATER,
    PIPE,
    PLUS,
    PLUS_EQUAL,
    PLUS_PLUS,
    QUESTION_MARK,
    RETURN,
    RIGHT_BRACE,
    RIGHT_BRACKET,
    RIGHT_PARENTHESIS,
    SEMICOLON,
    SLASH,
    STAR,
    STRING: []const u8,
    VAR,
    WHILE,

    pub fn format(self: Token, writer: *std.Io.Writer) !void {
        switch (self) {
            .AND => return writer.writeAll("and"),
            .BANG => return writer.writeAll("!"),
            .BANG_EQUAL => return writer.writeAll("!="),
            .BOF => return writer.writeAll("<bof>"),
            .BOOLEAN => |v| try writer.print("boolean '{any}'", .{v}),
            .BREAK => return writer.writeAll("break"),
            .COLON => return writer.writeAll("colon"),
            .COMMA => return writer.writeAll("comma"),
            .CONTINUE => return writer.writeAll("continue"),
            .DOLLAR => return writer.writeAll("$"),
            .DOT => return writer.writeAll("."),
            .ELSE => return writer.writeAll("else"),
            .EOF => return writer.writeAll("<eof>"),
            .EQUAL => return writer.writeAll("="),
            .EQUAL_EQUAL => return writer.writeAll("=="),
            .FLOAT => |v| try writer.print("float '{d}'", .{v}),
            .FN => return writer.writeAll("fn"),
            .FOR => return writer.writeAll("for"),
            .FOREACH => return writer.writeAll("foreach"),
            .GREATER => return writer.writeAll(">"),
            .GREATER_EQUAL => return writer.writeAll(">="),
            .IDENTIFIER => |v| try writer.print("identifier '{s}'", .{v}),
            .IF => return writer.writeAll("if"),
            .INTEGER => |v| try writer.print("integer '{any}'", .{v}),
            .LEFT_BRACE => return writer.writeAll("{"),
            .LEFT_BRACKET => return writer.writeAll("["),
            .LEFT_PARENTHESIS => return writer.writeAll("("),
            .LESSER => return writer.writeAll("<"),
            .LESSER_EQUAL => return writer.writeAll("<="),
            .LESSER_PERCENT => return writer.writeAll("<%"),
            .MINUS => return writer.writeAll("-"),
            .MINUS_EQUAL => return writer.writeAll("-="),
            .MINUS_MINUS => return writer.writeAll("--"),
            .MINUS_PERCENT_GREATER => return writer.writeAll("-%>"),
            .NULL => return writer.writeAll("null"),
            .OR => return writer.writeAll("or"),
            .ORELSE => return writer.writeAll("orelse"),
            .PERCENT => return writer.writeAll("%"),
            .PERCENT_BRACE => return writer.writeAll("%{"),
            .PERCENT_GREATER => return writer.writeAll("%>"),
            .PIPE => return writer.writeAll("}"),
            .PLUS => return writer.writeAll("+"),
            .PLUS_EQUAL => return writer.writeAll("+="),
            .PLUS_PLUS => return writer.writeAll("++"),
            .QUESTION_MARK => return writer.writeAll("?"),
            .RETURN => return writer.writeAll("return"),
            .RIGHT_BRACE => return writer.writeAll("}"),
            .RIGHT_BRACKET => return writer.writeAll("]"),
            .RIGHT_PARENTHESIS => return writer.writeAll(")"),
            .SEMICOLON => return writer.writeAll(";"),
            .SLASH => return writer.writeAll("\\"),
            .STAR => return writer.writeAll("*"),
            .STRING => |v| try writer.print("string '{s}'", .{v}),
            .VAR => return writer.writeAll("var"),
            .WHILE => return writer.writeAll("while"),
        }
    }
};

pub const Error = error {
    OutOfMemory,
    UnterminatedString,
    UnexpectedCharacter,
    InvalidFloat,
    InvalidInteger,
    InvalidEscapeSequence,
    IdentifierTooLong
};

pub fn asUint(comptime string: anytype) @Int(
    .unsigned,
    @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
) {
    const byteLength = @bitSizeOf(@TypeOf(string.*)) / 8 - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}

const t = @import("t.zig");
test "scanner: empty" {
    try expectTokens("", &.{});
    try expectTokens("  ", &.{});
    try expectTokens("//", &.{});
    try expectTokens("// hi", &.{});
}

test "scanner: simple tokens" {
    try expectTokens(" { /  } [ ]\t (\t\t\r),.-+*;", &.{
        .{ .LEFT_BRACE = {} },
        .{ .SLASH = {} },
        .{ .RIGHT_BRACE = {} },
        .{ .LEFT_BRACKET = {} },
        .{ .RIGHT_BRACKET = {} },
        .{ .LEFT_PARENTHESIS = {} },
        .{ .RIGHT_PARENTHESIS = {} },
        .{ .COMMA = {} },
        .{ .DOT = {} },
        .{ .MINUS = {} },
        .{ .PLUS = {} },
        .{ .STAR = {} },
        .{ .SEMICOLON = {} },
    });
}

test "scanner: multibyte tokens" {
    try expectTokens("><! = == != >=\t<= ", &.{
        .{ .GREATER = {} },
        .{ .LESSER = {} },
        .{ .BANG = {} },
        .{ .EQUAL = {} },
        .{ .EQUAL_EQUAL = {} },
        .{ .BANG_EQUAL = {} },
        .{ .GREATER_EQUAL = {} },
        .{ .LESSER_EQUAL = {} },
    });
}

test "scanner: string literals" {
    // double quotes
    try expectTokens("\"\"", &.{.{ .STRING = "" }});

    try expectTokens("\"hello world\" == \"Goodbye moon\"", &.{
        .{ .STRING = "hello world" },
        .{ .EQUAL_EQUAL = {} },
        .{ .STRING = "Goodbye moon" },
    });

    try expectTokens("\" \\n \\r \\t \\\" \\' \\\\ \"", &.{.{ .STRING = " \n \r \t \" ' \\ " }});

    try expectTokens("\"\\'\"", &.{.{ .STRING = "'" }});

    try expectTokens("\"abc\"  +  \"123\\'x\"", &.{
        .{ .STRING = "abc" },
        .{ .PLUS = {} },
        .{ .STRING = "123'x" },
    });

    {
        try expectError(error.UnterminatedString, "\"abc 123");
        try expectError(error.UnterminatedString, "\"ab\\\"");
        try expectError(error.InvalidEscapeSequence, " \"   \\a \" ");
    }

    // single quotes
    try expectTokens("''", &.{.{ .STRING = "" }});

    try expectTokens("'hello world' == 'Goodbye moon'", &.{
        .{ .STRING = "hello world" },
        .{ .EQUAL_EQUAL = {} },
        .{ .STRING = "Goodbye moon" },
    });

    try expectTokens("' \\n \\r \\t \\\" \\' \\\\ '", &.{.{ .STRING = " \n \r \t \" ' \\ " }});

    try expectTokens("'\\''", &.{.{ .STRING = "'" }});

    try expectTokens("'abc'  +  '123\\\"x'", &.{
        .{ .STRING = "abc" },
        .{ .PLUS = {} },
        .{ .STRING = "123\"x" },
    });

    {
        try expectError(error.UnterminatedString, "'abc 123");
        try expectError(error.UnterminatedString, "'ab\\\'");
        try expectError(error.InvalidEscapeSequence, " '   \\a ' ");
    }

    // backticks
    try expectTokens("``", &.{.{ .STRING = "" }});

    try expectTokens("`hello world`", &.{.{ .STRING = "hello world" }});

    try expectTokens("`hello\"world`", &.{.{ .STRING = "hello\"world" }});

    try expectTokens("`hel\\nlo` `world`", &.{
        .{ .STRING = "hel\\nlo" },
        .{ .STRING = "world" },
    });
}

test "scanner: numeric literals" {
    try expectTokens("0 1 84 581 12348 893819838298 377178209854757", &.{
        .{ .INTEGER = 0 },
        .{ .INTEGER = 1 },
        .{ .INTEGER = 84 },
        .{ .INTEGER = 581 },
        .{ .INTEGER = 12348 },
        .{ .INTEGER = 893819838298 },
        .{ .INTEGER = 377178209854757 },
    });

    try expectTokens("-581", &.{
        .{ .MINUS = {} },
        .{ .INTEGER = 581 },
    });

    try expectTokens("1.1 3.14159 0.399132785 -49.2291", &.{
        .{ .FLOAT = 1.1 },
        .{ .FLOAT = 3.14159 },
        .{ .FLOAT = 0.399132785 },
        .{ .MINUS = {} },
        .{ .FLOAT = 49.2291 },
    });

    try expectError(error.InvalidFloat, " \n 1.2.3");
}

test "scanner: identifier" {
    try expectTokens("cat _VAR hello_world ice9 I9c__302_nadudDD___", &.{
        .{ .IDENTIFIER = "cat" },
        .{ .IDENTIFIER = "_VAR" },
        .{ .IDENTIFIER = "hello_world" },
        .{ .IDENTIFIER = "ice9" },
        .{ .IDENTIFIER = "I9c__302_nadudDD___" },
    });
}

test "scanner: keyword" {
    try expectTokens("and else false fn if null or return true var while", &.{
        .{ .AND = {} },
        .{ .ELSE = {} },
        .{ .BOOLEAN = false },
        .{ .FN = {} },
        .{ .IF = {} },
        .{ .NULL = {} },
        .{ .OR = {} },
        .{ .RETURN = {} },
        .{ .BOOLEAN = true },
        .{ .VAR = {} },
        .{ .WHILE = {} },
    });
}

test "scanner: comments" {
    {
        try expectTokens(
            \\// this might not work\n
            \\ 1.2
            \\ >  // should this be >= ?
            \\ 1.1
        , &.{
            .{ .FLOAT = 1.2 },
            .{ .GREATER = {} },
            .{ .FLOAT = 1.1 },
        });
    }
}

test "scanner: misc" {
    try expectTokens("cat == 9", &.{
        .{ .IDENTIFIER = "cat" },
        .{ .EQUAL_EQUAL = {} },
        .{ .INTEGER = 9 },
    });
}

test "scanner: errors" {
    try expectError(error.UnexpectedCharacter, "~");
}

fn expectTokens(src: []const u8, expected: []const Token) !void {
    defer t.reset();
    var scanner = Scanner.init(t.arena.allocator(), src);

    for (expected) |e| {
        const token = try scanner.next();
        try t.expectString(@tagName(e), @tagName(token));
        switch (e) {
            .STRING => |str| try t.expectString(str, token.STRING),
            .IDENTIFIER => |str| try t.expectString(str, token.IDENTIFIER),
            else => try t.expectEqual(e, token),
        }
    }
    const last = try scanner.next();
    try t.expectEqual(.EOF, last);
}

fn expectError(expected: anyerror, src: []const u8) !void {
    defer t.reset();
    var scanner = Scanner.init(t.arena.allocator(), src);

    while (true) {
        const token = scanner.next() catch |err| {
            try t.expectEqual(expected, err);
            return;
        };
        if (token == .EOF) break;
    }
    return error.NoError;
}
