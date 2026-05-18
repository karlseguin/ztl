const std = @import("std");
const ztl = @import("ztl.zig");

const Allocator = std.mem.Allocator;

const asUint = @import("scanner.zig").asUint;
const config = @import("config.zig");
const Value = @import("value.zig").Value;
const Token = @import("scanner.zig").Token;
const Scanner = @import("scanner.zig").Scanner;
const Method = @import("vm.zig").Method;
const Property = @import("vm.zig").Property;
const OpCode = @import("byte_code.zig").OpCode;
const ByteCode = @import("byte_code.zig").ByteCode;
const ErrorReport = @import("error_report.zig").Compile;

pub const Opts = struct {
    key: []const u8 = "",
    error_report: ?*ErrorReport = null,
};

pub const PartialResult = union(enum) {
    src: []const u8,
};

pub fn Compiler(comptime A: type) type {
    const App = switch (@typeInfo(A)) {
        .@"struct" => A,
        .pointer => |ptr| ptr.child,
        .void => void,
        else => @compileError("Template App must be a struct, got: " ++ @tagName(@typeInfo(A))),
    };

    if (std.meta.hasMethod(App, "partial")) {
        const partial_fn = @typeInfo(@TypeOf(App.partial)).@"fn";
        const params = partial_fn.params;

        const valid_parameters = blk: {
            if (params.len == 4) {
                break :blk params[0].type.? == A and
                    params[1].type.? == Allocator and
                    params[2].type.? == []const u8 and
                    params[3].type.? == []const u8;
            }
            break :blk false;
        };

        if (valid_parameters == false) {
            @compileError("The " ++ @typeName(App) ++ ".partial() method must have the following signature:\npub fn partial(self: @This(), template_key: []const u8, include_key: []const u8) !?PartialResult");
        }
    }

    const MAX_LOCALS = config.extract(App, "max_locals");
    const ESCAPE_BY_DEFAULT = config.extract(App, "escape_by_default");
    const DEDUPLICATE_STRING_LITERALS = config.extract(A, "deduplicate_string_literals");

    const CustomFunctions = ztl.Functions(App);

    const CustomFunctionLookup: std.StaticStringMap(CustomFunctionMeta) = if (App == void or @hasDecl(App, "ZtlFunctions") == false) blk: {
        break :blk std.StaticStringMap(CustomFunctionMeta).initComptime(.{});
    } else blk: {
        const fields = @typeInfo(CustomFunctions).@"enum".fields;
        var metas: [fields.len]struct { []const u8, CustomFunctionMeta } = undefined;
        for (fields, 0..) |field, i| {
            metas[i] = .{ field.name, .{
                .function_id = field.value,
                .arity = @field(App.ZtlFunctions, field.name),
            } };
        }
        break :blk std.StaticStringMap(CustomFunctionMeta).initComptime(metas);
    };

    return struct {
        err: ?[]const u8,

        mode: Mode,

        // the ByteCode that our compiler is generating
        writer: ByteCode(A),

        // Arena for memory that can be discarded after compilation. This arena, and
        // its allocator, are NOT used for anything to do with byte code generation.
        // Their main goal is for generating errors.
        arena: Allocator,

        // will be set when compile() is called
        scanner: Scanner = undefined,

        // we just need to keep track of our current token and the
        // previous token to successfully parsed.
        current: Token,
        previous: Token,
        error_pos: u32,

        // a stack of includes, used to track restoring the compiler/scanner state
        // after the include is included, as well as the src/name of the include
        // for error reporting purposes
        includes: std.ArrayList(Include),

        functions: std.StringHashMapUnmanaged(Function),
        function_calls: std.ArrayList(Function.Call),

        // Used to track the scope that we're in
        // Also assigned to a local to determine in what scope the local can be used
        scopes: std.ArrayList(Scope),
        locals: std.ArrayList(Local),

        // list of @global variables
        globals: std.StringHashMapUnmanaged(usize),

        // Used to dedupe string literals. Stores the data_start value of
        // a given string. Can be turned off by setting zt_deduplicatestring_literals = false;
        string_literals: std.StringHashMapUnmanaged(u32),

        // Jumping is one of the messier parts of the code. So we try to put as
        // much of the logic into its own struct.
        jumper: Jumper(A),

        app: A,
        opts: Opts,
        global_mode: GlobalMode,

        const Self = @This();

        // we expect allocator to be an arena
        pub fn init(
            allocator: Allocator,
            app: A,
            opts: Opts,
        ) !Self {
            return .{
                .app = app,
                .err = null,
                .opts = opts,
                .scopes = .empty,
                .locals = .empty,
                .globals = .empty,
                .includes = .empty,
                .functions = .empty,
                .mode = .literal,
                .arena = allocator,
                .function_calls = .empty,
                .string_literals = .empty,
                .global_mode = .normal,
                .jumper = Jumper(A).init(allocator),
                .writer = try ByteCode(A).init(allocator),
                .error_pos = 0,
                .current = .{ .BOF = {} },
                .previous = .{ .BOF = {} },
            };
        }

        pub fn compile(self: *Self, src: []const u8) Error!void {
            errdefer |err| if (self.opts.error_report) |er| {
                var msg = self.err;
                if (msg == null) {
                    if (err == error.UnexpectedCharacter) {
                        msg = std.fmt.allocPrint(self.arena, "('{c}')", .{src[self.error_pos]}) catch null;
                    }
                }

                var src_of_err = src;
                var include_key: ?[]const u8 = null;
                if (self.includes.getLastOrNull()) |include| {
                    src_of_err = include.src;
                    include_key = include.key;
                }

                er.* = .{
                    .err = err,
                    .src = src_of_err,
                    .pos = self.error_pos,
                    .message = msg orelse "",
                    .include_key = include_key,
                };
            };
            var writer = &self.writer;

            self.scanner = Scanner.init(self.arena, src);
            writer.beginScript();
            try self.beginScope(false);

            while (self.current != .EOF) {
                try self.declaration();
            }
            try self.verifyEndState();

            var it = self.functions.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.code_pos == null) {
                    try self.setErrorFmt("Function '{s}' is unknown", .{kv.key_ptr.*});
                    return error.UnknownFunction;
                }
            }

            for (self.function_calls.items) |fc| {
                const arity = self.functions.get(fc.name).?.arity.?;
                if (fc.arity != arity) {
                    try self.setErrorWrongArity(fc.name, arity, fc.arity);
                    return error.WrongParameterCount;
                }
            }

            try writer.null();
            try writer.op(.RETURN);
        }

        fn verifyEndState(self: *Self) error{UnexpectedEOF}!void {
            if (self.mode == .code or self.mode == .output) {
                self.err = "Missing expected end tag, '%>'";
                return error.UnexpectedEOF;
            }
        }

        fn advance(self: *Self) !void {
            self.previous = self.current;

            var scanner = &self.scanner;
            self.error_pos = scanner.skipSpaces();
            self.current = try scanner.next();
        }

        fn consumeSemicolon(self: *Self, allow_close_tag: bool) !void {
            if (try self.match(.SEMICOLON)) {
                return;
            }
            if (allow_close_tag) {
                const current = self.current;
                if (current == .PERCENT_GREATER or current == .MINUS_PERCENT_GREATER) {
                    return;
                }
            }

            try self.setExpectationError("semicolon (';')");
            return error.UnexpectedToken;
        }

        fn consume(self: *Self, expected: std.meta.Tag(Token), comptime message: []const u8) Error!void {
            if (try self.match(expected)) {
                return;
            }
            try self.setExpectationError(message);
            return error.UnexpectedToken;
        }

        fn match(self: *Self, expected: std.meta.Tag(Token)) !bool {
            if (@intFromEnum(self.current) == @intFromEnum(expected)) {
                try self.advance();
                return true;
            }
            return false;
        }

        fn declaration(self: *Self) Error!void {
            switch (self.mode) {
                .literal, .literal_strip_left => try self.literal(),
                .output => {
                    var op_code = if (ESCAPE_BY_DEFAULT) OpCode.OUTPUT_ESCAPE else OpCode.OUTPUT;
                    if (self.current == .IDENTIFIER) {
                        const maybe_keyword = self.current.IDENTIFIER;
                        if (ESCAPE_BY_DEFAULT) {
                            if (std.mem.eql(u8, maybe_keyword, "safe")) {
                                op_code = .OUTPUT;
                                try self.advance();
                            }
                        } else if (std.mem.eql(u8, maybe_keyword, "escape")) {
                            op_code = .OUTPUT_ESCAPE;
                            try self.advance();
                        }
                    }

                    // skip empty
                    if (try self.match(.PERCENT_GREATER)) {
                        self.mode = .literal;
                        return;
                    }
                    if (try self.match(.MINUS_PERCENT_GREATER)) {
                        self.mode = .literal_strip_left;
                        return;
                    }

                    while (self.mode == .output) {
                        try self.expression();
                    }
                    try self.writer.op(op_code);
                },
                .code => switch (self.current) {
                    .PERCENT_GREATER => {
                        self.mode = .literal;
                        return;
                    },
                    .MINUS_PERCENT_GREATER => {
                        self.mode = .literal_strip_left;
                        return;
                    },
                    .VAR => {
                        try self.advance();
                        return self.variableInitialization();
                    },
                    .FN => {
                        try self.advance();
                        const writer = &self.writer;

                        try self.consume(.IDENTIFIER, "function name");
                        const name = self.previous.IDENTIFIER;
                        if (name[0] == '@') {
                            try self.setErrorFmt("Function name cannot begin with '@' ('{s}')", .{name});
                            return error.ReservedFunction;
                        }
                        if (CustomFunctionLookup.get(name) != null) {
                            try self.setErrorFmt("Function '{s}' reserved by custom application function", .{name});
                            return error.ReservedFunction;
                        }

                        try self.consume(.LEFT_PARENTHESIS, "'(' after function name'");

                        try self.beginScope(false);
                        var arity: u16 = 0;
                        if (try self.match(.RIGHT_PARENTHESIS) == false) {
                            // parse argument list
                            const scope_depth = self.scopeDepth();
                            var locals = &self.locals;
                            while (true) {
                                arity += 1;
                                if (arity > 255) {
                                    try self.setErrorMaxArity(name);
                                    return error.WrongParameterCount;
                                }

                                try self.consume(.IDENTIFIER, "variable name");

                                // Function parameters are just locals to the function
                                // The way the VM loads them means that they'll be
                                // "initialized" in the caller.
                                const variable_name = self.previous.IDENTIFIER;
                                try locals.append(self.arena, .{
                                    .depth = scope_depth,
                                    .name = variable_name,
                                });

                                if (try self.match(.RIGHT_PARENTHESIS)) {
                                    break;
                                }
                                try self.consume(.COMMA, "parameter separator (',')");
                            }
                        }

                        try self.consume(.LEFT_BRACE, "'{{' before function body");

                        {
                            const gop = try self.functions.getOrPut(self.arena, name);
                            if (gop.found_existing) {
                                if (gop.value_ptr.code_pos != null) {
                                    try self.setErrorFmt("Function '{s}' already declared", .{name});
                                    return error.FunctionRedeclared;
                                }
                            } else {
                                gop.value_ptr.* = try self.newFunction(name);
                            }
                        }

                        try writer.beginFunction(name);
                        try self.block();
                        if (self.currentScope().has_return == false) {
                            try writer.null();
                            try writer.op(.RETURN);
                        }
                        try self.endScope(true);

                        {
                            // don't try to to reuse `gop` a few lines up.
                            // the map can change (via the recusive self.block call)
                            // and that will invalidate gop.
                            const entry = self.functions.getPtr(name).?;
                            entry.arity = @intCast(arity);
                            entry.code_pos = try writer.endFunction(entry.data_pos, @intCast(arity));
                        }
                    },
                    else => return self.statement(),
                },
            }
        }

        fn literal(self: *Self) Error!void {
            var writer = &self.writer;
            var scanner = &self.scanner;

            var pos = scanner.pos;
            var start = pos;
            const src = scanner.src;

            if (src.len == 0) {
                return self.advance();
            }

            const end: u32 = @intCast(src.len - 1);

            while (true) {
                const idx: u32 = @intCast(std.mem.indexOfScalarPos(u8, src, pos, '%') orelse end);
                if (idx == end) {
                    var lit = src[start..];
                    if (self.mode == .literal_strip_left) {
                        lit = std.mem.trimStart(u8, lit, &std.ascii.whitespace);
                    }
                    if (lit.len > 0) {
                        _ = try writer.string(lit);
                        try writer.op(.OUTPUT);
                    }

                    scanner.pos = @intCast(src.len);
                    return self.advance();
                }

                if (idx == 0 or src[idx - 1] != '<') {
                    pos = idx + 1;
                    // start stays the same
                    continue;
                }

                var next = src[idx + 1]; // safe because we checked if idx == end earlier
                if (next == '%') {
                    // <%% -> <%

                    var lit = src[start..idx];
                    if (self.mode == .literal_strip_left) {
                        lit = std.mem.trimStart(u8, lit, &std.ascii.whitespace);
                        self.mode = .literal;
                    }
                    if (lit.len > 0) {
                        _ = try writer.string(lit);
                        try writer.op(.OUTPUT);
                    }
                    pos = idx + 1;
                    start = pos;
                    continue;
                }

                var lit = src[start .. idx - 1];
                // skip the %
                pos = idx + 1;

                if (next == '-' and pos != end) {
                    pos += 1;
                    next = src[pos];
                    lit = std.mem.trimEnd(u8, lit, &std.ascii.whitespace);
                }

                if (self.mode == .literal_strip_left) {
                    lit = std.mem.trimStart(u8, lit, &std.ascii.whitespace);
                    self.mode = .literal;
                }

                if (lit.len > 0) {
                    _ = try writer.string(lit);
                    try writer.op(.OUTPUT);
                }

                if (next != '=') {
                    self.mode = .code;
                    scanner.pos = pos;
                } else {
                    self.mode = .output;
                    scanner.pos = pos + 1;
                }
                try self.advance();
                return;
            }
        }

        fn variableInitialization(self: *Self) Error!void {
            try self.variableDeclaration(false);

            try self.consume(.EQUAL, "assignment operator ('=')");
            try self.expression();
            try self.consumeSemicolon(true);

            // prevents things like: var count = count + 1;
            self.locals.items[self.locals.items.len - 1].depth = self.scopeDepth();
        }

        fn variableDeclaration(self: *Self, give_scope: bool) Error!void {
            // "var" already consumed
            try self.consume(.IDENTIFIER, "variable name");

            var locals = &self.locals;

            if (locals.items.len == MAX_LOCALS) {
                try self.setErrorFmt("Maximum number of local variable ({d}) exceeded", .{MAX_LOCALS});
                return error.MaximumLocalsDeclared;
            }

            const name = self.previous.IDENTIFIER;
            const scope_depth = self.scopeDepth();

            if (self.localVariableIndex(name)) |idx| {
                if (locals.items[idx].depth == scope_depth) {
                    try self.setErrorFmt("Variable '{s}' already declared", .{name});
                    return error.VariableRedeclared;
                }
            }

            if (comptime config.shouldDebug(App, .full) == true) {
                try self.writer.debugVariableName(name, @intCast(locals.items.len));
            }

            try locals.append(self.arena, .{
                .name = name,
                .depth = if (give_scope) scope_depth else null,
            });
        }

        fn statement(self: *Self) Error!void {
            const scope = self.currentScope();
            if (scope.has_return) {
                self.setError("Unreachable code detected");
                return error.UnreachableCode;
            }

            var writer = &self.writer;
            var jumper = &self.jumper;
            switch (self.current) {
                .LEFT_BRACE => {
                    try self.advance();
                    try self.beginScope(true);
                    try self.block();
                    return self.endScope(false);
                },
                .IF => {
                    try self.advance();
                    try self.consume(.LEFT_PARENTHESIS, "opening parenthesis ('(')");
                    try self.expression();
                    try self.consume(.RIGHT_PARENTHESIS, "closing parenthesis (')')");

                    const jump_if_false = try jumper.forward(self, .JUMP_IF_FALSE_POP);

                    try self.statement();

                    if (try self.match(.ELSE)) {
                        const jump_if_true = try jumper.forward(self, .JUMP);
                        try jump_if_false.goto();
                        try self.statement();
                        return jump_if_true.goto();
                    }
                    return jump_if_false.goto();
                },
                .FOR => {
                    try self.advance();
                    try self.consume(.LEFT_PARENTHESIS, "opening parenthesis ('(')");

                    // initializer variable needs its own scope

                    try self.beginScope(true);

                    if (try self.match(.VAR)) {
                        try self.variableInitialization();
                    } else if (try self.match(.SEMICOLON) == false) {
                        try self.expression();
                        try self.consumeSemicolon(false);
                        try writer.pop();
                    }

                    // this is where we jump back to after every loop
                    const jump_loop_top = jumper.backward(self);

                    // if we have a condition, we'll need to jump to the end of
                    // the for loop if/when it becomes false.
                    var jump_loop_false: ?Jumper(A).Forward = null;
                    if (try self.match(.SEMICOLON) == false) {
                        // we have a condition!
                        try self.expression();
                        try self.consumeSemicolon(false);

                        jump_loop_false = try jumper.forward(self, .JUMP_IF_FALSE_POP);
                    }

                    var incr: []const u8 = &.{};
                    if (try self.match(.RIGHT_PARENTHESIS) == false) {
                        // increment
                        writer.beginCapture();
                        try self.expression();
                        try writer.pop();
                        // need to dupe, because the temp space used by scanner
                        // to capture might get reused (in a nested for, for example)
                        // because we use the value later on.
                        incr = try self.arena.dupe(u8, writer.endCapture());
                        try self.consume(.RIGHT_PARENTHESIS, "closing parenthesis (')')");
                    }

                    // body

                    const breakable_scope = try jumper.newBreakableScope(self);
                    defer breakable_scope.deinit();

                    try self.statement();

                    // Continue here. NOT at the top of the loop, because we need
                    // to execute the increment step. (But note that after incr
                    // is called, the code naturally jumps back to the top)
                    try breakable_scope.continueHere();

                    try writer.write(incr);

                    // back to condition check
                    try jump_loop_top.goto();

                    if (jump_loop_false) |jlf| {
                        // this is where we exit when the condition is false
                        try jlf.goto();
                    }
                    // any breaks we have registered for this loop will jump here
                    try breakable_scope.breakHere();
                    return self.endScope(false);
                },
                .FOREACH => {
                    try self.advance();
                    try self.consume(.LEFT_PARENTHESIS, "opening parenthesis ('(')");

                    // iterators need their own scope
                    try self.beginScope(true);

                    var iterable_count: u16 = 0;
                    while (true) {
                        iterable_count += 1;
                        try self.expression();
                        if (try self.match(.RIGHT_PARENTHESIS)) {
                            break;
                        }
                        try self.consume(.COMMA, "iteratable separator (',')");
                    }

                    if (iterable_count == 0) {
                        self.setError("foreach requires at least 1 value to iterate");
                        return error.InvalidIterableCount;
                    }

                    if (iterable_count > 8) {
                        self.setError("foreach cannot iterate over more tha 8 values");
                        return error.InvalidIterableCount;
                    }

                    try self.locals.appendNTimes(self.arena, .{
                        .name = "",
                        .depth = self.scopeDepth(),
                    }, iterable_count);

                    const breakable_scope = try jumper.newBreakableScope(self);
                    defer breakable_scope.deinit();

                    try self.beginScope(true);

                    try self.consume(.PIPE, "variable group start ('|')");
                    var variable_count: u16 = 0;
                    while (true) {
                        variable_count += 1;
                        try self.variableDeclaration(true);
                        if (try self.match(.PIPE)) {
                            break;
                        }
                        try self.consume(.COMMA, "variable separator (',')");
                    }

                    if (iterable_count != variable_count) {
                        try self.setErrorFmt("foreach must have the same number of iterables as variables (iterables: {d}, variables: {d})", .{ iterable_count, variable_count });
                        return error.InvalidIterableCount;
                    }

                    try writer.opWithData(.FOREACH, &.{@intCast(iterable_count)});

                    // this is where we jump back to after every loop
                    const jump_loop_top = jumper.backward(self);

                    // this SEEMS wrong, but it's how our foreach works with
                    // continue and break. On a normal loop, we'll jump back here
                    // and pop off the iterable variables. This only works because
                    // on the initial loop, the FOREACH will inject N dummy values
                    // (so that these pops are safe on the 1st iteration).
                    // On continue (and break), the typical continue/break scope
                    // restoration works (that is, they issue their own POPs).
                    // For break, that's fine, because it'll just exit the loop.
                    // For continue, it works only because our conitnue will
                    // jump AFTER these POPs (since the continue will issue its
                    // own pops).
                    // This is necessary because, as-is, break and continue follow
                    // the same scope-restoration logic (which works fine for FOR
                    // and WHILE, but requires this hack for FOREACH).
                    for (0..variable_count) |_| {
                        try writer.pop();
                    }

                    const continue_pos = writer.currentPos();

                    try writer.opWithData(.FOREACH_ITERATE, &.{@intCast(iterable_count)});
                    const jump_if_false = try jumper.forward(self, .JUMP_IF_FALSE_POP);

                    // BODY
                    try self.statement();

                    try breakable_scope.continueAt(continue_pos);

                    // back to condition check
                    try jump_loop_top.goto();
                    try jump_if_false.goto();

                    // any breaks we have registered for this loop will jump here
                    try breakable_scope.breakHere();

                    _ = self.scopes.pop();
                    self.locals.items.len -= variable_count;
                    return self.endScope(false);
                },
                .WHILE => {
                    try self.advance();
                    const jump_loop_top = jumper.backward(self); // at the end of each iteration, we want to jump back here

                    try self.consume(.LEFT_PARENTHESIS, "opening parenthesis ('(')");
                    try self.expression();
                    try self.consume(.RIGHT_PARENTHESIS, "closing parenthesis (')')");

                    const breakable_scope = try jumper.newBreakableScope(self);
                    defer breakable_scope.deinit();

                    const jump_if_false = try jumper.forward(self, .JUMP_IF_FALSE_POP);
                    try self.statement();
                    try breakable_scope.continueAt(jump_loop_top.jump_to);
                    try jump_loop_top.goto();

                    try jump_if_false.goto(); // if our condition is false, this is where we want to jump to

                    return breakable_scope.breakHere();
                },
                .RETURN => {
                    try self.advance();
                    if (try self.match(.SEMICOLON)) {
                        try writer.op(.RETURN);
                    } else {
                        try self.expression();
                        try self.consumeSemicolon(true);
                        try writer.op(.RETURN);
                    }
                    scope.has_return = true;
                    return;
                },
                .BREAK => {
                    try self.advance();
                    var break_count: usize = 1;
                    if (try self.match(.INTEGER)) {
                        const value = self.previous.INTEGER;
                        if (value < 0) {
                            try self.setErrorFmt("break count must be a positive integer, got {d}", .{value});
                            return error.InvalidBreakCount;
                        }
                        break_count = @intCast(value);
                    }
                    try self.consumeSemicolon(true);
                    return self.jumper.insertBreak(self, break_count);
                },
                .CONTINUE => {
                    try self.advance();
                    var continue_count: usize = 1;
                    if (try self.match(.INTEGER)) {
                        const value = self.previous.INTEGER;
                        if (value < 0) {
                            try self.setErrorFmt("continue count must be a positive integer, got {d}", .{value});
                            return error.InvalidContinueCount;
                        }
                        continue_count = @intCast(value);
                    }
                    try self.consumeSemicolon(true);
                    return self.jumper.insertContinue(self, continue_count);
                },
                .IDENTIFIER => |name| blk: {
                    if (name[0] != '@' or self.scanner.peek() != .LEFT_PARENTHESIS) {
                        // a normal expression
                        break :blk;
                    }

                    // skip the identifier (we already have its name)
                    try self.advance();

                    // skip the left parenthesis
                    try self.advance();

                    // If we're here, we've already consumed the left parenthesis
                    if (std.mem.eql(u8, name, "@print")) {
                        const arity = try self.parameterList(32);
                        try self.consumeSemicolon(true);
                        return self.writer.opWithData(.PRINT, &.{arity});
                    }

                    if (std.mem.eql(u8, name, "@include")) {
                        // @include is complicated.
                        // We turn the contents of the included file into a function.
                        // Which lets us "include" the file just by issuing a CALL
                        // like any other function.
                        // But, we have to handle a few things differently:

                        // 1) Our self.scanner doesn't know anything about this
                        // included code. So we have to "pause" the current
                        // compilation, load the included src, compile it, and
                        // then restore/resume the original code.
                        //
                        // 2) We need to translate globals within the include
                        // to local hash gets.

                        if (std.meta.hasMethod(App, "partial") == false) {
                            self.setError(@typeName(App) ++ " dot not have a 'partial' method. @include cannot be used");
                            return error.PartialsNotConfigured;
                        }

                        const include_key = switch (self.current) {
                            .STRING => |str| str,
                            else => {
                                try self.setExpectationError("partial name (a string literal)");
                                return error.Invalid;
                            },
                        };

                        for (self.includes.items) |incl| {
                            if (std.mem.eql(u8, include_key, incl.key)) {
                                return error.IncludeLoopDetected;
                            }
                        }

                        try self.advance();
                        if (try self.match(.COMMA)) {
                            const arity = try self.parameterList(1);
                            std.debug.assert(arity == 1);
                        } else {
                            try self.consume(.RIGHT_PARENTHESIS, "Expected closing parenthesis ')'");
                            // forcing an empy map makes implementing @include a lot easier
                            // specifically, it makes it easy to handle @globals in the include
                            // template.
                            try self.writer.initializeMap(0);
                        }
                        try self.consumeSemicolon(true);

                        // We give the include a unique function name. Since user-defined functions
                        // can't begin with '@', this won't conflict.
                        const include_fn_name = try std.fmt.allocPrint(self.arena, "@include {s}", .{include_key});

                        const gop = try self.functions.getOrPut(self.arena, include_fn_name);
                        if (gop.found_existing) {
                            // unlikely, but this file has already been included. So there isn't anything
                            // more to do but to call it.
                            return self.writer.opWithData(.CALL, std.mem.asBytes(&gop.value_ptr.data_pos));
                        }

                        // Ask the app for the include source
                        const result = self.app.partial(self.arena, self.opts.key, include_key) catch |err| {
                            try self.setErrorFmt("Failed to load partial: '{s}'. Load Error: {}", .{ include_key, err });
                            return error.PartialLoadError;
                        } orelse {
                            try self.setErrorFmt("Unknown partial: '{s}'", .{include_key});
                            return error.PartialUnknown;
                        };

                        // This kind of resets our compiler and scanner to now
                        // parse the included src. It captures the current state
                        // so that it can be restored once we're done.
                        try self.beginInclude(include_key, result.src);

                        try self.beginScope(false);
                        try self.locals.append(self.arena, .{ .name = include_fn_name, .depth = 0 });
                        gop.value_ptr.* = try self.newFunction(include_fn_name);
                        try writer.beginFunction(include_fn_name);

                        while (self.current != .EOF) {
                            try self.declaration();
                        }
                        try self.verifyEndState();
                        try writer.null();
                        try writer.op(.RETURN);

                        // do not defer this.
                        // We won't want this to be called on error, since we
                        // want to self.includes to contain our include so that
                        // we can report a better error
                        self.endInclude();

                        gop.value_ptr.arity = 1;
                        gop.value_ptr.code_pos = try writer.endFunction(gop.value_ptr.data_pos, 1);

                        try self.endScope(true);
                        return self.writer.opWithData(.CALL, std.mem.asBytes(&gop.value_ptr.data_pos));
                    }
                    try self.setErrorFmt("Function '{s}' is not a built-in function", .{name});
                    return error.UnknownBuiltin;
                },
                else => {},
            }

            try self.expression();
            try self.consumeSemicolon(true);
            try writer.pop();
        }

        fn block(self: *Self) Error!void {
            while (true) {
                switch (self.current) {
                    .RIGHT_BRACE => return self.advance(),
                    .EOF => {
                        try self.setExpectationError("closing block ('}}')");
                        return error.UnexpectedEOF;
                    },
                    else => try self.declaration(),
                }
            }
        }

        fn expression(self: *Self) Error!void {
            return self.parsePrecedence(.ASSIGNMENT);
        }

        fn parsePrecedence(self: *Self, precedence: Precedence) Error!void {
            if (self.mode == .output) {
                const semicolon = self.current == .SEMICOLON;
                if (semicolon) {
                    try self.advance();
                }
                if (self.current == .PERCENT_GREATER) {
                    self.mode = .literal;
                    return;
                }
                if (self.current == .MINUS_PERCENT_GREATER) {
                    self.mode = .literal_strip_left;
                    return;
                }
                if (semicolon) {
                    try self.setExpectationError("Closing output tag '%>'");
                    return error.Invalid;
                }
            }

            try self.advance();
            const can_assign = @intFromEnum(precedence) <= @intFromEnum(Precedence.ASSIGNMENT);
            {
                const rule = ParseRule(Self).get(self.previous);
                if (rule.prefix) |prefix| {
                    try prefix(self, can_assign);
                } else {
                    try self.setExpectationError("an expression");
                    return error.Invalid;
                }
            }

            const nprec = @intFromEnum(precedence);
            while (true) {
                const rule = ParseRule(Self).get(self.current);
                if (nprec > rule.precedence) {
                    break;
                }
                try self.advance();
                try rule.infix.?(self, can_assign);
            }
        }

        fn grouping(self: *Self, _: bool) Error!void {
            try self.expression();
            return self.consume(.RIGHT_PARENTHESIS, "Expected closing parenthesis ')'");
        }

        fn binary(self: *Self, _: bool) Error!void {
            const previous = self.previous;
            const rule = ParseRule(Self).get(previous);
            try self.parsePrecedence(@enumFromInt(rule.precedence + 1));

            switch (previous) {
                .PLUS => try self.writer.op(.ADD),
                .MINUS => try self.writer.op(.SUBTRACT),
                .STAR => try self.writer.op(.MULTIPLY),
                .SLASH => try self.writer.op(.DIVIDE),
                .EQUAL_EQUAL => try self.writer.op(.EQUAL),
                .BANG_EQUAL => try self.writer.op2(.EQUAL, .NOT),
                .GREATER => try self.writer.op(.GREATER),
                .GREATER_EQUAL => try self.writer.op2(.LESSER, .NOT),
                .LESSER => try self.writer.op(.LESSER),
                .LESSER_EQUAL => try self.writer.op2(.GREATER, .NOT),
                .PERCENT => try self.writer.op(.MODULUS),
                else => unreachable,
            }
        }

        fn unary(self: *Self, _: bool) Error!void {
            const previous = self.previous;

            try self.expression();
            switch (previous) {
                .BANG => try self.writer.op(.NOT),
                .MINUS => try self.writer.op(.NEGATE),
                else => unreachable,
            }
        }

        fn number(self: *Self, _: bool) Error!void {
            switch (self.previous) {
                .INTEGER => |value| try self.writer.i64(value),
                .FLOAT => |value| try self.writer.f64(value),
                else => unreachable,
            }
        }

        fn boolean(self: *Self, _: bool) Error!void {
            return self.writer.bool(self.previous.BOOLEAN);
        }

        fn string(self: *Self, _: bool) Error!void {
            const string_token = self.previous.STRING;
            return self.stringLiteral(string_token);
        }

        fn stringLiteral(self: *Self, lit: []const u8) !void {
            if (DEDUPLICATE_STRING_LITERALS == false) {
                _ = try self.writer.string(lit);
                return;
            }

            if (self.string_literals.get(lit)) |data_start| {
                return self.writer.stringRef(data_start);
            }

            const data_start = try self.writer.string(lit);
            try self.string_literals.put(self.arena, lit, data_start);
        }

        fn @"null"(self: *Self, _: bool) Error!void {
            return self.writer.null();
        }

        fn identifier(self: *Self, can_assign: bool) Error!void {
            if (self.current == .LEFT_PARENTHESIS) {
                return self.call();
            }
            return self.variable(can_assign);
        }

        fn variable(self: *Self, can_assign: bool) Error!void {
            const writer = &self.writer;
            const name = self.previous.IDENTIFIER;
            const is_global = name[0] == '@';

            var idx: usize = undefined;
            if (is_global) switch (self.global_mode) {
                .function => {
                    try self.setErrorFmt("Globals are not allowed in functions: '{s}'", .{name});
                    return error.GlobalInFunction;
                },
                .include => {
                    // the included value is always the first parameter in the function stack
                    try writer.getVariable(0, false);
                    // trim off the '@'
                    try self.stringLiteral(name[1..]);
                    return self.indexOperation(can_assign);
                },
                .normal => {
                    const gop = try self.globals.getOrPut(self.arena, name);
                    if (gop.found_existing) {
                        idx = gop.value_ptr.*;
                    } else {
                        // -1 because we've already put this one in
                        idx = self.globals.count() - 1;
                        gop.value_ptr.* = idx;
                        if (comptime config.shouldDebug(App, .full) == true) {
                            try self.writer.debugGlobalVariableName(name, @intCast(idx));
                        }
                    }
                },
            } else {
                idx = self.localVariableIndex(name) orelse {
                    try self.setErrorFmt("Variable '{s}' is unknown", .{name});
                    return error.UnknownVariable;
                };

                if (self.locals.items[idx].depth == null) {
                    try self.setErrorFmt("Variable '{s}' used before being initialized", .{name});
                    return error.VaraibleNotInitialized;
                }
            }

            if (can_assign) {
                if (try self.match(.EQUAL)) {
                    try self.expression();
                    return writer.setVariable(@intCast(idx), is_global);
                }

                if (try self.match(.PLUS_EQUAL)) {
                    switch (self.current) {
                        .INTEGER => |n| switch (n) {
                            -1 => {
                                try self.advance();
                                return writer.incr(@intCast(idx), is_global, 0);
                            },
                            1...10 => {
                                try self.advance();
                                return writer.incr(@intCast(idx), is_global, @intCast(n));
                            },
                            else => {},
                        },
                        else => {},
                    }

                    try writer.getVariable(@intCast(idx), is_global);
                    try self.expression();
                    try writer.op(.ADD);
                    try writer.setVariable(@intCast(idx), is_global);
                    return;
                }

                if (try self.match(.MINUS_EQUAL)) {
                    switch (self.current) {
                        .INTEGER => |n| switch (n) {
                            1 => {
                                try self.advance();
                                return writer.incr(@intCast(idx), is_global, 0);
                            },
                            else => {},
                        },
                        else => {},
                    }
                    try writer.getVariable(@intCast(idx), is_global);
                    try self.expression();
                    try writer.op(.SUBTRACT);
                    try writer.setVariable(@intCast(idx), is_global);
                    return;
                }
            }

            if (try self.match(.PLUS_PLUS)) {
                return writer.incr(@intCast(idx), is_global, 1);
            }

            if (try self.match(.MINUS_MINUS)) {
                return writer.incr(@intCast(idx), is_global, 0);
            }

            return writer.getVariable(@intCast(idx), is_global);
        }

        fn array(self: *Self, _: bool) Error!void {
            var value_count: u32 = 0;
            if (try self.match(.RIGHT_BRACKET) == false) {
                while (true) {
                    value_count += 1;
                    try self.expression();
                    if (try self.match(.RIGHT_BRACKET)) {
                        break;
                    }
                    try self.consume(.COMMA, "value separator (',')");
                }
            }
            try self.writer.initializeArray(value_count);
        }

        fn map(self: *Self, _: bool) Error!void {
            var entry_count: u32 = 0;
            var writer = &self.writer;
            if (try self.match(.RIGHT_BRACE) == false) {
                while (true) {
                    entry_count += 1;
                    const current_token = self.current;
                    switch (current_token) {
                        .INTEGER => |k| try writer.i64(k),
                        .IDENTIFIER => |k| try self.stringLiteral(k),
                        .STRING => |k| try self.stringLiteral(k),
                        else => {
                            try self.setErrorFmt("Map key must be an integer, string or identifier, got {f} ({s})", .{ current_token, @tagName(current_token) });
                            return error.InvalidMapKeyType;
                        },
                    }
                    try self.advance();
                    try self.consume(.COLON, "key : value separator (':')");
                    try self.expression();
                    if (try self.match(.RIGHT_BRACE)) {
                        break;
                    }
                    try self.consume(.COMMA, "value separator (',')");
                    if (try self.match(.RIGHT_BRACE)) {
                        break;
                    }
                }
            }
            try self.writer.initializeMap(entry_count);
        }

        fn index(self: *Self, can_assign: bool) Error!void {
            try self.expression();
            try self.consume(.RIGHT_BRACKET, "left bracket (']')");

            return self.indexOperation(can_assign);
        }

        fn indexOperation(self: *Self, can_assign: bool) Error!void {
            const writer = &self.writer;
            if (can_assign) {
                if (try self.match(.EQUAL)) {
                    try self.expression();
                    return writer.op(.INDEX_SET);
                }

                if (try self.match(.PLUS_EQUAL)) {
                    try self.expression();
                    return writer.op(.INCR_REF);
                }

                if (try self.match(.MINUS_EQUAL)) {
                    try self.expression();
                    return writer.op2(.NEGATE, .INCR_REF);
                }

                if (try self.match(.PLUS_PLUS)) {
                    try writer.i64(1);
                    return writer.op(.INCR_REF);
                }

                if (try self.match(.MINUS_MINUS)) {
                    try writer.i64(-1);
                    return writer.op(.INCR_REF);
                }
            }

            return writer.op(.INDEX_GET);
        }

        fn call(self: *Self) Error!void {
            const name = self.previous.IDENTIFIER;
            if (name[0] == '@') blk: {
                const builtins_with_return: []const []const u8 = &.{};
                for (builtins_with_return) |allowed| {
                    if (std.mem.eql(u8, name, allowed)) {
                        break :blk;
                    }
                }
                try self.setErrorFmt("Builtin function '{s}' does not produce a value", .{name});
                return error.BuiltinNotAnExpression;
            }

            try self.advance(); // consume '(

            const arity = try self.parameterList(255);
            if (CustomFunctionLookup.get(name)) |cf| {
                if (cf.arity != arity) {
                    try self.setErrorWrongArity(name, cf.arity, @intCast(arity));
                    return error.WrongParameterCount;
                }

                var buf: [3]u8 = undefined;
                buf[0] = @intCast(arity);
                @memcpy(buf[1..], std.mem.asBytes(&cf.function_id));
                return self.writer.opWithData(.CALL_ZIG, &buf);
            }

            const gop = try self.functions.getOrPut(self.arena, name);
            if (gop.found_existing == false) {
                gop.value_ptr.* = try self.newFunction(name);
            }
            try self.function_calls.append(self.arena, .{ .name = name, .arity = @intCast(arity) });
            return self.writer.opWithData(.CALL, std.mem.asBytes(&gop.value_ptr.data_pos));
        }

        fn dot(self: *Self, _: bool) Error!void {
            try self.consume(.IDENTIFIER, "property name");
            const name = self.previous.IDENTIFIER;

            if (try self.match(.LEFT_PARENTHESIS)) {
                return self.method(name);
            }
            return self.property(name);
        }

        fn method(self: *Self, name: []const u8) Error!void {
            var _method: ?Method = null;

            const arity = try self.parameterList(5);

            switch (name.len) {
                3 => switch (@as(u24, @bitCast(name[0..3].*))) {
                    asUint("pop") => _method = .POP,
                    else => {},
                },
                4 => switch (@as(u32, @bitCast(name[0..4].*))) {
                    asUint("last") => _method = .LAST,
                    asUint("sort") => _method = .SORT,
                    else => {},
                },
                5 => switch (@as(u40, @bitCast(name[0..5].*))) {
                    asUint("first") => _method = .FIRST,
                    else => {},
                },
                6 => switch (@as(u48, @bitCast(name[0..6].*))) {
                    asUint("append") => _method = .APPEND,
                    asUint("remove") => _method = .REMOVE,
                    asUint("concat") => _method = .CONCAT,
                    else => {},
                },
                7 => switch (@as(u56, @bitCast(name[0..7].*))) {
                    asUint("indexOf") => _method = .INDEX_OF,
                    else => {},
                },
                8 => switch (@as(u64, @bitCast(name[0..8].*))) {
                    asUint("contains") => _method = .CONTAINS,
                    asUint("removeAt") => _method = .REMOVE_AT,
                    asUint("toString") => _method = .TO_STRING,
                    else => {},
                },
                else => {},
            }

            const m = _method orelse {
                try self.setErrorFmt("'{s}' is not a valid method", .{name});
                return error.UnknownMethod;
            };

            try self.verifyMethodArity(m, arity);

            var buf: [3]u8 = undefined;
            const method_id: u16 = @intFromEnum(m);
            buf[0] = arity;
            @memcpy(buf[1..3], std.mem.asBytes(&method_id));
            return self.writer.opWithData(.METHOD, &buf);
        }

        fn verifyMethodArity(self: *Self, m: Method, arity: u8) !void {
            const expected: u8 = switch (m) {
                .POP => 0,
                .LAST => 0,
                .FIRST => 0,
                .APPEND => 1,
                .REMOVE => 1,
                .REMOVE_AT => 1,
                .CONTAINS => 1,
                .INDEX_OF => 1,
                .SORT => 0,
                .CONCAT => 1,
                .TO_STRING => 0,
            };

            if (expected != arity) {
                try self.setErrorWrongArity(m.name(), expected, arity);
                return error.WrongParameterCount;
            }
        }

        fn property(self: *Self, name: []const u8) Error!void {
            var _property: ?Property = null;
            switch (name.len) {
                3 => switch (@as(u24, @bitCast(name[0..3].*))) {
                    asUint("len") => _property = .LEN,
                    asUint("key") => _property = .KEY,
                    else => {},
                },
                5 => switch (@as(u40, @bitCast(name[0..5].*))) {
                    asUint("value") => _property = .VALUE,
                    else => {},
                },
                else => {},
            }

            const p = _property orelse {
                try self.setErrorFmt("'{s}' is not a valid field", .{name});
                return error.UnknownField;
            };

            const property_id: u16 = @intFromEnum(p);
            return self.writer.opWithData(.PROPERTY_GET, std.mem.asBytes(&property_id));
        }

        fn @"and"(self: *Self, _: bool) Error!void {
            // shortcircuit, the left side is already executed, if it's false, we
            // can skip the rest.
            const jump_if_false = try self.jumper.forward(self, .JUMP_IF_FALSE);
            try self.parsePrecedence(.AND);
            try jump_if_false.goto();
        }

        fn @"or"(self: *Self, _: bool) Error!void {
            const writer = &self.writer;
            // Rather than add a new op (JUMP_IF_TRUE), we can simulate this by
            // combining JUMP_IF_FALSE to jump over a JUMP. IF the left side (
            // which we've already executed) is true, the JUMP_IF_FALSE will
            // be skipped, and we'll execute the JUMP, which will skip the
            // right of the conditions. In other words, the JUMP_IS_FALSE only
            // exists to jump over the JUMP, which exists to shortcircuit on true.
            const jump_if_false = try self.jumper.forward(self, .JUMP_IF_FALSE);

            // the above jump_if_false only exists to skip over this jump
            // and this jump only exists to shortcircuit the condition because the condition is true
            const jump_if_true = try self.jumper.forward(self, .JUMP);
            try jump_if_false.goto();
            try writer.pop();
            try self.parsePrecedence(.OR);
            try jump_if_true.goto();
        }

        fn @"orelse"(self: *Self, _: bool) Error!void {
            const writer = &self.writer;
            try writer.op(.PUSH);
            try writer.null();
            try writer.op(.EQUAL);

            const jump_if_false = try self.jumper.forward(self, .JUMP_IF_FALSE_POP);
            try writer.pop(); // pop off the left hand side (which was false)
            try self.parsePrecedence(.OR);
            try jump_if_false.goto();
        }

        fn ternary(self: *Self, _: bool) Error!void {
            const jump_if_false = try self.jumper.forward(self, .JUMP_IF_FALSE_POP);
            try self.expression();
            try self.consume(.COLON, "colon (':')");

            const jump_if_true = try self.jumper.forward(self, .JUMP);
            try jump_if_false.goto();
            try self.expression();
            try jump_if_true.goto();
        }

        fn localVariableIndex(self: *const Self, name: []const u8) ?usize {
            const locals = self.locals.items;
            const local_scope_start = self.currentScope().local_start;
            var idx = locals.len;
            while (idx > local_scope_start) {
                idx -= 1;
                const local = locals[idx];
                if (std.mem.eql(u8, name, local.name)) {
                    return idx - local_scope_start;
                }
            }

            return null;
        }

        fn newFunction(self: *Self, name: []const u8) Error!Function {
            const data_pos = try self.writer.newFunction(name);
            return .{
                .arity = null,
                .code_pos = null,
                .data_pos = data_pos,
            };
        }

        fn scopeDepth(self: *const Self) usize {
            return self.scopes.items.len;
        }

        fn currentScope(self: *const Self) *Scope {
            return &self.scopes.items[self.scopes.items.len - 1];
        }

        fn beginScope(self: *Self, inherit_locals: bool) !void {
            try self.scopes.append(self.arena, .{
                .has_return = false,
                .local_start = if (inherit_locals) self.currentScope().local_start else self.locals.items.len,
            });
        }

        // Fast_pop is true when we're returning from a function.
        // In this case, locals added by the functions don't need to be
        // individually popped, the VM can simply restore the stack back to
        // the caller's previous state.
        fn endScope(self: *Self, comptime fast_pop: bool) !void {
            const scope_pop_count = self.scopePopCount(self.scopeDepth() - 1);
            _ = self.scopes.pop();

            self.locals.items.len -= scope_pop_count;
            if (fast_pop) {
                return;
            }
            var writer = &self.writer;
            for (0..scope_pop_count) |_| {
                try writer.pop();
            }
        }

        // Returns the number of variables declared, up to this point, in the
        // current scope. Used in endScope to pop off all block-scoped variables.
        // Used in break & continue, which both must pop off any block-scoped variables.
        fn scopePopCount(self: *Self, depth: usize) usize {
            const locals = self.locals.items;

            var i = locals.len;
            while (i > 0) {
                i -= 1;
                if (locals[i].depth.? <= depth) {
                    return locals.len - i - 1;
                }
            }
            return locals.len;
        }

        // @includes are complicated. They're mostly handled like a function, but
        // within an almost-new compiler instance. Specifically, we need the
        // scanner to start iterating through the included src, which isn't part
        // of the original source we currently have.
        // This code "snapshots" the current state of the compiler and scanner
        // saving it in the `self.includes` arraylist (which acts like a stack).
        // It then sets the current state as-if we're parsing new code (the included
        // source).
        // When we're done, we'll call `endInclude` to pop this state off our
        // `self.includes` stack and restore it.
        // Some of this is also being tracked to try and report better errors
        // if they happen within the include.
        fn beginInclude(self: *Self, include_key: []const u8, src: []const u8) !void {
            try self.includes.append(self.arena, .{
                .src = src,
                .key = include_key,
                .restore_src = self.scanner.src,
                .restore_pos = self.scanner.pos,
                .restore_current = self.current,
                .restore_previous = self.previous,
                .restore_global_mode = self.global_mode,
            });

            self.scanner.reset(src);
            self.mode = .literal;
            self.previous = .{ .BOF = {} };
            self.current = .{ .BOF = {} };
            self.global_mode = .include;
        }

        fn endInclude(self: *Self) void {
            const include = self.includes.pop().?;
            self.mode = .code;
            self.scanner.src = include.restore_src;
            self.scanner.pos = include.restore_pos;
            self.current = include.restore_current;
            self.previous = include.restore_previous;
            self.global_mode = include.restore_global_mode;
        }

        fn parameterList(self: *Self, max_arity: u8) !u8 {
            if (try self.match(.RIGHT_PARENTHESIS)) {
                return 0;
            }
            var arity: u8 = 0;
            while (true) {
                if (arity == max_arity) {
                    try self.setErrorFmt("call supports up to {d} parameters, got {d}", .{ max_arity, arity });
                    return error.WrongParameterCount;
                }
                arity += 1;
                try self.expression();
                if (try self.match(.RIGHT_PARENTHESIS)) {
                    break;
                }
                try self.consume(.COMMA, "parameter separator (',')");
            }
            return arity;
        }

        fn setExpectationError(self: *Self, comptime message: []const u8) Error!void {
            const current_token = self.current;
            return self.setErrorFmt("Expected " ++ message ++ ", got {f} ({s})", .{ current_token, @tagName(current_token) });
        }

        fn setErrorMaxArity(self: *Self, name: []const u8) !void {
            return self.setErrorFmt("Function '{s}' has more than 255 parameters", .{name});
        }

        fn setErrorWrongArity(self: *Self, name: []const u8, expected: u8, actual: u8) !void {
            return self.setErrorFmt("Function '{s}' expects {d} parameter{s}, but called with {d}", .{ name, expected, if (expected == 1) "" else "s", actual });
        }

        fn setErrorFmt(self: *Self, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
            self.err = try std.fmt.allocPrint(self.arena, fmt, args);
        }

        fn setError(self: *Self, desc: []const u8) void {
            self.err = desc;
        }
    };
}

const Mode = enum {
    code, // <% ... %>
    output, // <%= ... %>
    literal, // everything NOT in the above
    literal_strip_left,
};

const GlobalMode = enum {
    // globals are allowed
    normal,
    // globals aren't allowed
    function,
    // an include called with a single parameter, globals are translated to local hash gets
    include,
};

pub const Error = error{
    UnexpectedToken,
    UnknownFunction,
    WrongParameterCount,
    ReservedFunction,
    FunctionRedeclared,
    MaximumLocalsDeclared,
    VariableRedeclared,
    UnreachableCode,
    InvalidContinue,
    InvalidContinueCount,
    InvalidBreak,
    InvalidBreakCount,
    UnknownVariable,
    VaraibleNotInitialized,
    InvalidMapKeyType,
    UnknownMethod,
    UnknownField,
    JumpTooBig,
    InvalidIterableCount,
    UnexpectedEOF,
    Invalid,
    UnknownBuiltin,
    BuiltinNotAnExpression,
    PartialsNotConfigured,
    PartialLoadError,
    PartialUnknown,
    IncludeLoopDetected,
    GlobalInFunction,
} || @import("scanner.zig").Error;

// For top-level functions we store a small function header in the bytecode's
// data section. This indirection allows the function to be called before its
// declared by giving the function header a known location.
// The first time we see a call to `sum()` we can reserve space in the data
// section:
//   0010 0 0 0 0 0
// i.e:
//   at address 0x10 of our data (arbitrary for this example), we reserve 5 bytes
//   (function metadata is always 5 bytes).
// And we can generate a Op.Call with operand 0x10
//
// When the function is actually declared, we can fill in those 5 bytes
// The first is the arity, and the other 4 is the address of the actual function
// code.
const Function = struct {
    arity: ?u8 = null,
    data_pos: u32,
    code_pos: ?u32 = null,

    // used at the end of compilation to make sure all function calls had
    // the correct arity (we can't do this at the function call itself, since
    // we might not know the correct arity yet)
    const Call = struct {
        arity: u8,
        name: []const u8,
    };
};

const CustomFunctionMeta = struct {
    arity: u8,
    function_id: u16,
};

const Include = struct {
    // When the include ends, all the things we need to restore
    restore_src: []const u8,
    restore_pos: u32,
    restore_current: Token,
    restore_previous: Token,
    restore_global_mode: GlobalMode,

    // the include key
    key: []const u8,

    // the include source
    src: []const u8,
};

// The messiest thing our compiler does is deal with JUMP (and its variants).
// 1 - When we're jumping ahead (like when a condition is false), we don't yet know
// where we're jumping to.
// 2 - When we're jumping behind (like when we're returning to the top of the loop),
// then we need to capture the address we intend to jump back to, and insert
// it into the jump.
// 3 - break and continue add a bunch of complexity.
//     - Both need to pop any values of the scope they are breaking/continuing
//     - For a for, a continue jumps forwards to the increment step (which
//       then jumps back to the top of the loop), but for a while, a continue
//       jumps back to the top of the loop
//     - break and continue both take a jump count, i.e. break 2, which makes the
//       above even more complicated.
fn Jumper(comptime App: type) type {
    return struct {
        arena: Allocator,

        // We replace a break; with a JUMP command, but the location where
        // we are jumping to isn't known yet. So we leave an empty placeholder
        // something like {JUMP, 0, 0} and we register the position of the
        // placeholder. Once we know where the break should jump to, we can
        // fill in all placeholders.
        // The position is u32, but the jump address is i16, because the jump
        // is relative to the current position, and we only allow jumping i16
        // bytes (negative because we can jump negative)
        // This is a list of lists, because..
        //   The outer list is like a stack, since we can have nested loops
        //   every new for/while adds a new entry
        //   The inner lists is because 1 loop can have multiple breaks
        //   so we potentially need to register/fill multiple JUMP locations
        break_scopes: std.ArrayList(std.ArrayList(u32)),

        // Same as breaks. In the case of a "while" loop, a continue will jump
        // back to the top of the loop. But in the case of a "for" loop, the
        // continue will jump forwards to the increment part of the loop (and
        // then jump back to the top)
        continue_scopes: std.ArrayList(std.ArrayList(u32)),

        // For each scope, we record how deep we should pop on a break/continue
        pop_depths: std.ArrayList(usize),

        const Self = @This();

        fn init(arena: Allocator) Self {
            return .{ .arena = arena, .pop_depths = .empty, .break_scopes = .empty, .continue_scopes = .empty };
        }

        fn forward(_: *const Self, compiler: *Compiler(App), op_code: OpCode) !Forward {
            const writer = &compiler.writer;

            try writer.op(op_code);
            // create placeholder for jump address
            const jump_from = writer.currentPos();
            try writer.write(&.{ 0, 0 });

            return .{
                .compiler = compiler,
                .jump_from = jump_from,
            };
        }

        fn backward(_: *const Self, compiler: *Compiler(App)) Backward {
            return .{
                .compiler = compiler,
                .jump_to = compiler.writer.currentPos(),
            };
        }

        fn newBreakableScope(self: *Self, compiler: *Compiler(App)) !BreakableScope {
            try self.break_scopes.append(self.arena, .empty);
            try self.continue_scopes.append(self.arena, .empty);
            try self.pop_depths.append(self.arena, compiler.scopeDepth());
            return .{
                .jumper = self,
                .compiler = compiler,
            };
        }

        fn insertBreak(self: *Self, compiler: *Compiler(App), levels: usize) !void {
            return self.recordBreakable(compiler, levels, self.break_scopes.items, "break");
        }

        fn insertContinue(self: *Self, compiler: *Compiler(App), levels: usize) !void {
            return self.recordBreakable(compiler, levels, self.continue_scopes.items, "continue");
        }

        fn recordBreakable(self: *Self, compiler: *Compiler(App), levels: usize, list: []std.ArrayList(u32), comptime op: []const u8) !void {
            const pop_depths = self.pop_depths.items;
            if (levels > pop_depths.len) {
                if (pop_depths.len == 0) {
                    compiler.setError("'" ++ op ++ "' cannot be used outside of loop");
                    return if (comptime std.mem.eql(u8, op, "continue")) error.InvalidBreak else error.InvalidContinue;
                }
                try compiler.setErrorFmt("'" ++ op ++ " {d}' is invalid (current loop nesting: {d})", .{ levels, pop_depths.len });
                return if (comptime std.mem.eql(u8, op, "continue")) error.InvalidBreakCount else error.InvalidContinueCount;
            }

            // so we want to revert the scope by N levels. To figure this out,
            // we look at what the recorded scope was N levels ago. Every time
            // we enter a breakable scope, we record its depth, and on break/continue
            // we can use that recorded depths to know how many values we need
            // to pop from the stack.
            const target_scope = pop_depths[pop_depths.len - levels];
            const pop_count = compiler.scopePopCount(target_scope);

            // TODO: Add POPN op?
            const writer = &compiler.writer;
            for (0..pop_count) |_| {
                try writer.pop();
            }

            try writer.op(.JUMP);
            // create placeholder for jump address
            const jump_from = writer.currentPos();
            try writer.write(&.{ 0, 0 });

            var target = &list[list.len - levels];
            return target.append(self.arena, jump_from);
        }

        const Forward = struct {
            jump_from: u32,
            compiler: *Compiler(App),

            pub fn goto(self: Forward) !void {
                const writer = &self.compiler.writer;

                // this is where we're jumping from. It's the start of the 2-byte
                // address containing the jump delta.
                const jump_from = self.jump_from;

                // this is where we want to jump to
                const jump_to = writer.currentPos();

                std.debug.assert(jump_to > jump_from);

                // +2 because we need to jump over the jump_from location itself
                const relative: i64 = jump_to - @as(i64, jump_from);
                if (relative > 32_767) {
                    self.compiler.setError("Jump size exceeded maximum allowed value");
                    return error.JumpTooBig;
                }

                return writer.insertInt(i16, jump_from, @intCast(relative));
            }
        };

        const Backward = struct {
            jump_to: u32,
            compiler: *Compiler(App),

            pub fn goto(self: Backward) !void {
                const writer = &self.compiler.writer;

                // This is where we're jumping to
                const jump_to = self.jump_to;

                // This is where we're jumping from (+1 since we need to jump
                // back over the JUMP instruction we're writing).
                const jump_from = writer.currentPos() + 1;

                const relative: i64 = -(@as(i64, jump_from) - jump_to);
                if (relative < -32_768) {
                    self.compiler.setError("Jump size exceeded maximum allowed value");
                    return error.JumpTooBig;
                }
                var relative_i16: i16 = @intCast(relative);

                try writer.op(.JUMP);
                return writer.write(std.mem.asBytes(&relative_i16));
            }
        };

        const BreakableScope = struct {
            jumper: *Jumper(App),
            compiler: *Compiler(App),

            fn deinit(self: BreakableScope) void {
                _ = self.jumper.pop_depths.pop();
                _ = self.jumper.break_scopes.pop();
                _ = self.jumper.continue_scopes.pop();
            }

            fn breakHere(self: BreakableScope) !void {
                return self.insertJumps(self.jumper.break_scopes.getLast().items, self.compiler.writer.currentPos());
            }

            fn continueHere(self: BreakableScope) !void {
                return self.insertJumps(self.jumper.continue_scopes.getLast().items, self.compiler.writer.currentPos());
            }

            fn continueAt(self: BreakableScope, jump_to: u32) !void {
                return self.insertJumps(self.jumper.continue_scopes.getLast().items, jump_to);
            }

            fn insertJumps(self: BreakableScope, list: []u32, jump_to: u32) !void {
                var writer = &self.compiler.writer;

                for (list) |jump_from| {
                    const relative: i64 = @as(i64, jump_to) - jump_from;
                    if (relative > 32_767 or relative < -32_768) {
                        self.compiler.setError("Jump size exceeded maximum allowed value");
                        return error.JumpTooBig;
                    }
                    const relative_i16: i16 = @intCast(relative);
                    writer.insertInt(i16, jump_from, @intCast(relative_i16));
                }
            }
        };
    };
}

fn ParseRule(comptime C: type) type {
    return struct {
        infix: ?*const fn (*C, bool) Error!void,
        prefix: ?*const fn (*C, bool) Error!void,
        precedence: i32,

        const Self = @This();

        inline fn get(token_type: Token) *const Self {
            return &rules[@intFromEnum(token_type)];
        }

        const rules = buildParseRules(&.{
            .{ Token.AND, C.@"and", null, Precedence.AND },
            .{ Token.BANG, null, C.unary, Precedence.NONE },
            .{ Token.BANG_EQUAL, C.binary, null, Precedence.EQUALITY },
            .{ Token.BOOLEAN, null, C.boolean, Precedence.NONE },
            .{ Token.COMMA, null, null, Precedence.NONE },
            .{ Token.DOT, C.dot, null, Precedence.CALL },
            .{ Token.ELSE, null, null, Precedence.NONE },
            .{ Token.EOF, null, null, Precedence.NONE },
            .{ Token.EQUAL, null, null, Precedence.NONE },
            .{ Token.EQUAL_EQUAL, C.binary, null, Precedence.EQUALITY },
            .{ Token.FLOAT, null, C.number, Precedence.NONE },
            .{ Token.GREATER, C.binary, null, Precedence.COMPARISON },
            .{ Token.GREATER_EQUAL, C.binary, null, Precedence.COMPARISON },
            .{ Token.IDENTIFIER, null, C.identifier, Precedence.NONE },
            .{ Token.IF, null, null, Precedence.NONE },
            .{ Token.INTEGER, null, C.number, Precedence.NONE },
            .{ Token.LEFT_BRACE, null, null, Precedence.NONE },
            .{ Token.LEFT_BRACKET, C.index, C.array, Precedence.CALL },
            .{ Token.LEFT_PARENTHESIS, null, C.grouping, Precedence.NONE },
            .{ Token.LESSER, C.binary, null, Precedence.COMPARISON },
            .{ Token.LESSER_EQUAL, C.binary, null, Precedence.COMPARISON },
            .{ Token.MINUS, C.binary, C.unary, Precedence.TERM },
            .{ Token.NULL, null, C.null, Precedence.NONE },
            .{ Token.OR, C.@"or", null, Precedence.OR },
            .{ Token.ORELSE, C.@"orelse", null, Precedence.OR },
            .{ Token.PERCENT, C.binary, null, Precedence.FACTOR },
            .{ Token.PERCENT_BRACE, null, C.map, Precedence.CALL },
            .{ Token.PLUS, C.binary, null, Precedence.TERM },
            .{ Token.QUESTION_MARK, C.ternary, null, Precedence.OR },
            .{ Token.RETURN, null, null, Precedence.NONE },
            .{ Token.RIGHT_BRACE, null, null, Precedence.NONE },
            .{ Token.RIGHT_PARENTHESIS, null, null, Precedence.NONE },
            .{ Token.SEMICOLON, null, null, Precedence.NONE },
            .{ Token.SLASH, C.binary, null, Precedence.FACTOR },
            .{ Token.STAR, C.binary, null, Precedence.FACTOR },
            .{ Token.STRING, null, C.string, Precedence.NONE },
            .{ Token.VAR, null, null, Precedence.NONE },
        });

        fn buildParseRules(definitions: anytype) [maxRuleIndex(Token)]Self {
            var _rules: [maxRuleIndex(Token)]Self = undefined;
            for (&_rules) |*r| {
                r.* = .{
                    .infix = null,
                    .prefix = null,
                    .precedence = 0,
                };
            }
            for (definitions) |definition| {
                const index = @intFromEnum(definition.@"0");
                _rules[index] = .{
                    .infix = definition.@"1",
                    .prefix = definition.@"2",
                    .precedence = @intFromEnum(definition.@"3"),
                };
            }
            return _rules;
        }
    };
}

const Precedence = enum {
    NONE,
    ASSIGNMENT, // =
    OR, // or
    AND, // and
    EQUALITY, // == !=
    COMPARISON, // < > <= >=
    TERM, // + -
    FACTOR, // * / %
    UNARY, // ! -
    CALL, // . ()
    PRIMARY,
};

fn maxRuleIndex(comptime E: type) usize {
    var max: usize = 0;
    for (@typeInfo(@typeInfo(E).@"union".tag_type.?).@"enum".fields) |f| {
        max = @max(max, f.value);
    }
    return max + 1;
}

const Scope = struct {
    has_return: bool,
    local_start: usize,
};

const Local = struct {
    name: []const u8,
    depth: ?usize,
};

const disassemble = @import("byte_code.zig").disassemble;

const t = @import("t.zig");

test "tests:afterEach" {
    t.reset();
}

test "Compiler: local limit" {
    defer t.reset();

    const App = struct {
        pub const ZtlConfig = struct {
            pub const max_locals = 3;
        };
    };

    try testErrorWithApp(App, .{}, "Maximum number of local variable (3) exceeded",
        \\ var a = 1;
        \\ var b = 1;
        \\ var c = 1;
        \\ var d = 1;
    );

    try testReturnValueWithApp(App, .{}, .{ .i64 = 11 },
        \\ var a = 1;
        \\ var b = 1;
        \\ var c = 1;
        \\ return 11;
    );
}

test "Compiler: arithmetic" {
    try testReturnValue(.{ .i64 = 9 }, "return 1 + 8;");
    try testReturnValue(.{ .i64 = -1 }, "return 10 - 11;");
    try testReturnValue(.{ .i64 = 14 }, "return 2 * 7;");
    try testReturnValue(.{ .i64 = 2 }, "return 18 / 9;");

    try testReturnValue(.{ .i64 = 17 }, "return 2 + 5 * 3;");
    try testReturnValue(.{ .i64 = 21 }, "return (2 + 5) * 3;");
    try testReturnValue(.{ .i64 = 13 }, "return 2 * 5 + 3;");

    try testReturnValue(.{ .f64 = 4.5 }, "return 1.2 + 3.3;");
    try testReturnValue(.{ .f64 = 5.3 }, "return 2 + 3.3;");
    try testReturnValue(.{ .f64 = 5.3 }, "return 3.3 + 2;");
    try testReturnValue(.{ .f64 = 1.0 }, "return 1.1 - 0.1;");
    try testReturnValue(.{ .f64 = -1.2999999999999998 }, "return 2 - 3.3;");
    try testReturnValue(.{ .f64 = 1.2999999999999998 }, "return 3.3 - 2;");
    try testReturnValue(.{ .f64 = 3.9599999999999995 }, "return 1.2 * 3.3;");
    try testReturnValue(.{ .f64 = 20.4 }, "return 5.1 * 4;");
    try testReturnValue(.{ .f64 = 20.4 }, "return 4 * 5.1;");
    try testReturnValue(.{ .f64 = 0.36363636363636365 }, "return 1.2 / 3.3;");
    try testReturnValue(.{ .f64 = 1.275 }, "return 5.1 / 4;");
    try testReturnValue(.{ .f64 = 0.7843137254901962 }, "return 4 / 5.1;");
}

test "Compiler: not" {
    try testReturnValue(.{ .bool = true }, "return !false;");
    try testReturnValue(.{ .bool = false }, "return !true;");
}

test "Compiler: comparison int" {
    try testReturnValue(.{ .bool = true }, "return 1 == 1;");
    try testReturnValue(.{ .bool = false }, "return 1 == 2;");
    try testReturnValue(.{ .bool = false }, "return 1 != 1;");
    try testReturnValue(.{ .bool = true }, "return 1 != 2;");

    try testReturnValue(.{ .bool = false }, "return 1 > 1;");
    try testReturnValue(.{ .bool = false }, "return 1 > 2;");
    try testReturnValue(.{ .bool = true }, "return 2 > 1;");

    try testReturnValue(.{ .bool = true }, "return 1 >= 1;");
    try testReturnValue(.{ .bool = false }, "return 1 >= 2;");
    try testReturnValue(.{ .bool = true }, "return 2 >= 1;");

    try testReturnValue(.{ .bool = false }, "return 1 < 1;");
    try testReturnValue(.{ .bool = true }, "return 1 < 2;");
    try testReturnValue(.{ .bool = false }, "return 2 < 1;");

    try testReturnValue(.{ .bool = true }, "return 1 <= 1;");
    try testReturnValue(.{ .bool = true }, "return 1 <= 2;");
    try testReturnValue(.{ .bool = false }, "return 2 <= 1;");
}

test "Compiler: comparison float" {
    try testReturnValue(.{ .bool = true }, "return 1.13 == 1.13;");
    try testReturnValue(.{ .bool = false }, "return 1.13 == 2.08;");
    try testReturnValue(.{ .bool = false }, "return 1.13 != 1.13;");
    try testReturnValue(.{ .bool = true }, "return 1.13 != 2.08;");

    try testReturnValue(.{ .bool = false }, "return 1.13 > 1.13;");
    try testReturnValue(.{ .bool = false }, "return 1.13 > 2.08;");
    try testReturnValue(.{ .bool = true }, "return 2.08 > 1.13;");

    try testReturnValue(.{ .bool = true }, "return 1.13 >= 1.13;");
    try testReturnValue(.{ .bool = false }, "return 1.13 >= 2.08;");
    try testReturnValue(.{ .bool = true }, "return 2.08 >= 1.13;");

    try testReturnValue(.{ .bool = false }, "return 1.13 < 1.13;");
    try testReturnValue(.{ .bool = true }, "return 1.13 < 2.08;");
    try testReturnValue(.{ .bool = false }, "return 2.08 < 1.13;");

    try testReturnValue(.{ .bool = true }, "return 1.13 <= 1.13;");
    try testReturnValue(.{ .bool = true }, "return 1.13 <= 2.08;");
    try testReturnValue(.{ .bool = false }, "return 2.08 <= 1.13;");
}

test "Compiler: comparison int - float" {
    try testReturnValue(.{ .bool = true }, "return 1 == 1.0;");
    try testReturnValue(.{ .bool = false }, "return 1 == 1.1;");
    try testReturnValue(.{ .bool = false }, "return 1 != 1.0;");
    try testReturnValue(.{ .bool = true }, "return 1 != 1.1;");

    try testReturnValue(.{ .bool = false }, "return 1 > 1.0;");
    try testReturnValue(.{ .bool = false }, "return 1 > 2.0;");
    try testReturnValue(.{ .bool = true }, "return 2 > 1.9;");

    try testReturnValue(.{ .bool = true }, "return 1 >= 1.0;");
    try testReturnValue(.{ .bool = false }, "return 1 >= 2.0;");
    try testReturnValue(.{ .bool = true }, "return 2 >= 1.98;");

    try testReturnValue(.{ .bool = false }, "return 1 < 1.0;");
    try testReturnValue(.{ .bool = true }, "return 1 < 1.01;");
    try testReturnValue(.{ .bool = false }, "return 2 < 1.99;");

    try testReturnValue(.{ .bool = true }, "return 1 <= 1.0;");
    try testReturnValue(.{ .bool = true }, "return 1 <= 1.01;");
    try testReturnValue(.{ .bool = false }, "return 2 <= 1.99;");
}

test "Compiler: comparison float - int" {
    try testReturnValue(.{ .bool = true }, "return 1.0 == 1;");
    try testReturnValue(.{ .bool = false }, "return 1.1 == 1;");
    try testReturnValue(.{ .bool = false }, "return 1.0 != 1;");
    try testReturnValue(.{ .bool = true }, "return 1.1 != 1;");

    try testReturnValue(.{ .bool = false }, "return 1.0 > 1;");
    try testReturnValue(.{ .bool = false }, "return 1.9 > 2;");
    try testReturnValue(.{ .bool = true }, "return 2.1 > 2;");

    try testReturnValue(.{ .bool = true }, "return 1.0 >= 1;");
    try testReturnValue(.{ .bool = false }, "return 1.9 >= 2;");
    try testReturnValue(.{ .bool = true }, "return 2.1 >= 2;");

    try testReturnValue(.{ .bool = false }, "return 1.0 < 1;");
    try testReturnValue(.{ .bool = true }, "return 0.99 < 1;");
    try testReturnValue(.{ .bool = false }, "return 2.1 < 2;");

    try testReturnValue(.{ .bool = true }, "return 1.0 <= 1;");
    try testReturnValue(.{ .bool = true }, "return 3.99 <= 4;");
    try testReturnValue(.{ .bool = false }, "return 10.1 <= 10;");
}

test "Compiler: comparison bool" {
    try testReturnValue(.{ .bool = true }, "return true == true;");
    try testReturnValue(.{ .bool = true }, "return false == false;");
    try testReturnValue(.{ .bool = false }, "return true == false;");
    try testReturnValue(.{ .bool = false }, "return false == true;");

    try testReturnValue(.{ .bool = false }, "return true != true;");
    try testReturnValue(.{ .bool = false }, "return false != false;");
    try testReturnValue(.{ .bool = true }, "return true != false;");
    try testReturnValue(.{ .bool = true }, "return false != true;");
}

test "Compiler: comparison null" {
    try testReturnValue(.{ .bool = true }, "return null == null;");
    try testReturnValue(.{ .bool = false }, "return null != null;");

    try testReturnValue(.{ .bool = false }, "return 0 == null;");
    try testReturnValue(.{ .bool = false }, "return 0.0 == null;");
    try testReturnValue(.{ .bool = false }, "return 1 == null;");
    try testReturnValue(.{ .bool = false }, "return 1.1 == null;");
    try testReturnValue(.{ .bool = false }, "return `` == null;");
    try testReturnValue(.{ .bool = false }, "return `abc` == null;");
    try testReturnValue(.{ .bool = false }, "return true == null;");
    try testReturnValue(.{ .bool = false }, "return false == null;");

    try testReturnValue(.{ .bool = true }, "return 0 != null;");
    try testReturnValue(.{ .bool = true }, "return 0.0 != null;");
    try testReturnValue(.{ .bool = true }, "return 1 != null;");
    try testReturnValue(.{ .bool = true }, "return 1.1 != null;");
    try testReturnValue(.{ .bool = true }, "return `` != null;");
    try testReturnValue(.{ .bool = true }, "return `abc` != null;");
    try testReturnValue(.{ .bool = true }, "return true != null;");
    try testReturnValue(.{ .bool = true }, "return false != null;");
}

test "Compiler: comparison string" {
    try testReturnValue(.{ .bool = true }, "return `abc` == `abc`;");
    try testReturnValue(.{ .bool = false }, "return `abc` == `123`;");
    try testReturnValue(.{ .bool = false }, "return `abc` == `ABC`;");

    try testReturnValue(.{ .bool = false }, "return `abc` != `abc`;");
    try testReturnValue(.{ .bool = true }, "return `abc` != `123`;");
    try testReturnValue(.{ .bool = true }, "return `abc` != `ABC`;");

    try testReturnValue(.{ .bool = false }, "return `abc` < `abc`;");
    try testReturnValue(.{ .bool = false }, "return `abc` > `abc`;");
    try testReturnValue(.{ .bool = true }, "return `abc` <= `abc`;");
    try testReturnValue(.{ .bool = true }, "return `abc` >= `abc`;");

    try testReturnValue(.{ .bool = false }, "return `abc` < `ABC`;");
    try testReturnValue(.{ .bool = false }, "return `abc` <= `ABC`;");
    try testReturnValue(.{ .bool = true }, "return `ABC` <= `abc`;");
    try testReturnValue(.{ .bool = true }, "return `ABC` <= `abc`;");

    try testReturnValue(.{ .bool = true }, "return `abc` > `ABC`;");
    try testReturnValue(.{ .bool = true }, "return `abc` >= `ABC`;");
    try testReturnValue(.{ .bool = false }, "return `ABC` >= `abc`;");
    try testReturnValue(.{ .bool = false }, "return `ABC` >= `abc`;");
}

test "Compiler: comparison list" {
    try testReturnValue(.{ .bool = true }, "return [] == [];");
    try testReturnValue(.{ .bool = true }, "return [1] == [1];");
    try testReturnValue(.{ .bool = false }, "return [1] == [1,``];");
    try testReturnValue(.{ .bool = false }, "return [] == null;");
}

test "Compiler: comparison map" {
    try testReturnValue(.{ .bool = true }, "return %{} == %{};");
    try testReturnValue(.{ .bool = true }, "return %{a:1} == %{a: 1};");
    try testReturnValue(.{ .bool = true }, "return %{a:1, 123: `a`} == %{123: `a`, a: 1};");
    try testReturnValue(.{ .bool = false }, "return %{a: 1} == %{a:1,b:2};");
    try testReturnValue(.{ .bool = false }, "return %{} == null;");
}

test "Compiler: increment/decrement" {
    try testReturnValue(.{ .i64 = 4 },
        \\ var i = 0;
        \\ i++;
        \\ i++;
        \\ i++;
        \\ i--;
        \\ i++;
        \\ return i++;
    );

    try testReturnValue(.{ .i64 = 6 },
        \\ var x = 2;
        \\ x += 4;
        \\ return x ;
    );

    try testReturnValue(.{ .i64 = 6 },
        \\ var x = 2;
        \\ x += 4;
        \\ return x ;
    );

    try testReturnValue(.{ .i64 = -2 },
        \\ var x = 2;
        \\ x -= 4;
        \\ return x ;
    );

    // -1, 1...10 have special treatement, so test a range around there
    inline for (0..20) |i| {
        const src_pos = std.fmt.comptimePrint("var x = 0;\nx += {d};return x;", .{i});
        try testReturnValue(.{ .i64 = i }, src_pos);

        const signed: i64 = @intCast(i);
        const src_neg = std.fmt.comptimePrint("var x = 0;\nx += {d};return x;", .{signed});
        try testReturnValue(.{ .i64 = signed }, src_neg);
    }

    try testError("Expected semicolon (';'), got ++ (PLUS_PLUS)", "return 100++;");
}

test "Compiler: variables" {
    try testReturnValue(.{ .string = "Leto" },
        \\ var name = `Leto`;
        \\ return name;
    );

    try testReturnValue(.{ .string = "LONG" }, "var " ++ "l" ** 127 ++ " = `LONG`; return " ++ "l" ** 127 ++ ";");

    try testReturnValue(.{ .string = "Leto" },
        \\ var name = `Leto`;
        \\ {
        \\    var name = "Ghanima" ;
        \\ }
        \\ return name;
    );

    try testReturnValue(.{ .string = "other" },
        \\ var name = `Leto`;
        \\ {
        \\    var x = "Ghanima" ;
        \\ }
        \\ var x = "other";
        \\ return x;
    );

    try testReturnValue(.{ .string = "Ghanima" },
        \\ var name = `Leto`;
        \\ {
        \\    var name = "Ghanima" ;
        \\    return name;
        \\ }
    );

    try testReturnValue(.{ .i64 = 4 },
        \\ var count = 3;
        \\ return count + 1;
    );

    try testError("Variable 'name' used before being initialized", "var name = name + 3;");
    try testError("Variable 'unknown' is unknown", "return unknown;");
    try testError("Expected assignment operator ('='), got string 'hello'", "var x `hello`");

    try testError("Variable 'c' already declare",
        \\ var c = 3;
        \\ var c = 3;
    );

    try testError("IdentifierTooLong", "var " ++ "a" ** 128 ++ " = null;");
}

test "Compiler: if" {
    try testReturnValue(.{ .i64 = 1234 },
        \\ if (true) {
        \\   return 1234;
        \\ }
        \\ return 4321;
    );

    try testReturnValue(.{ .i64 = 4321 },
        \\ if (false) {
        \\   return 1234;
        \\ }
        \\ return 4321;
    );

    try testReturnValue(.{ .i64 = 9 },
        \\ if (1 == 1) {
        \\   return 9;
        \\ } else {
        \\   return 10;
        \\ }
    );

    try testReturnValue(.{ .i64 = 10 },
        \\ if (1 != 1) {
        \\   return 9;
        \\ } else {
        \\   return 10;
        \\ }
    );

    try testReturnValue(.{ .i64 = 8 },
        \\ if (1 == 1) {
        \\   return 8;
        \\ } else if (2 == 2) {
        \\   return 9;
        \\ } else {
        \\   return 10;
        \\ }
    );

    try testReturnValue(.{ .i64 = 9 },
        \\ if (1 != 1) {
        \\   return 8;
        \\ } else if (2 == 2) {
        \\   return 9;
        \\ } else {
        \\   return 10;
        \\ }
    );

    try testReturnValue(.{ .i64 = 10 },
        \\ if (1 != 1) {
        \\   return 8;
        \\ } else if (2 != 2) {
        \\   return 9;
        \\ } else {
        \\   return 10;
        \\ }
    );
}

test "Compiler: logical operators" {
    try testReturnValue(.{ .bool = false }, "return 1 == 1 and 3 == 2;");
    try testReturnValue(.{ .bool = false }, "return 0 == 1 and 3 == 2;");
    try testReturnValue(.{ .bool = false }, "return 1 == 3 or 3 == 4;");
    try testReturnValue(.{ .bool = true }, "return 1 == 1 and 2 == 2;");
    try testReturnValue(.{ .bool = true }, "return 1 == 1 or 3 == 2;");
    try testReturnValue(.{ .bool = true }, "return 1 == 3 or 3 == 3;");
    try testReturnValue(.{ .bool = false }, "return 1 == 3 and (3 == 4 or 4 == 4);");
}

test "Compiler: while" {
    try testReturnValue(.{ .i64 = 10 },
        \\ var i = 0;
        \\ while (i < 10) {
        \\   i++;
        \\ }
        \\ return i;
    );

    try testReturnValue(.{ .i64 = 0 },
        \\ var i = 0;
        \\ while (false) {
        \\   i = i + 1;
        \\ }
        \\ return i;
    );
}

test "Compiler: for" {
    try testReturnValue(.{ .i64 = 10 },
        \\ var i = 0;
        \\ for (var x = 0; x < 10; x = x + 1) {
        \\   i = i + 1;
        \\ }
        \\ return i;
    );

    try testReturnValue(.{ .i64 = 2 },
        \\ var i = 10;
        \\ for (var x = 10; x > 2; x = x - 1) {
        \\   i = i - 1;
        \\ }
        \\ return i;
    );

    // test various incerment/decrement while we're here (++ and --)
    try testReturnValue(.{ .i64 = 10 },
        \\ var i = 0;
        \\ for (var x = 0; x < 10; x++) {
        \\   i++;
        \\ }
        \\ return i;
    );

    try testReturnValue(.{ .i64 = 2 },
        \\ var i = 10;
        \\ for (var x = 10; x > 2; x--) {
        \\   i--;
        \\ }
        \\ return i;
    );

    // test various incerment/decrement while we're here (+= and -=)
    try testReturnValue(.{ .i64 = 8 },
        \\ var i = 0;
        \\ for (var x = 0; x < 10; x += 3) {
        \\   i += 2;
        \\ }
        \\ return i;
    );

    try testReturnValue(.{ .i64 = 4 },
        \\ var i = 10;
        \\ for (var x = 10; x > 2; x -= 3) {
        \\   i -= 2;
        \\ }
        \\ return i;
    );
}

test "Compiler: empty scope" {
    try testReturnValue(.{ .null = {} }, "{} return null;"); // doesn't crash, yay!
}

test "Compiler: variable scopes" {
    try testReturnValue(.{ .i64 = 100 },
        \\ var i = 0;
        \\ var count = 0;
        \\ while (i < 10) {
        \\   var j = 0;
        \\   while (j < 10) {
        \\      count += 1;
        \\      j += 1;
        \\   }
        \\   i += 1;
        \\ }
        \\ return count;
    );
}

test "Compiler: list initialization" {
    {
        try testReturnValue(t.createListRef(&.{}), "return [];");
    }

    {
        var arr = [_]Value{
            .{ .bool = true },
            .{ .f64 = 1.992 },
            .{ .string = "over 9000!" },
        };
        try testReturnValue(t.createListRef(&arr), "return [true, 1.992, `over 9000!`];");
    }

    {
        var arr = [_]Value{
            .{ .null = {} },
            .{ .i64 = 1 },
            .{ .string = "hello" },
        };
        try testReturnValue(t.createListRef(&arr),
            \\ var n = null;
            \\ var other = "hello";
            \\ return [n, 1, other];
        );
    }
}

test "Compiler: list indexing" {
    try testReturnValue(.{ .i64 = 10 }, "return [10, 2002, 5][0];");
    try testReturnValue(.{ .i64 = 2002 }, "return [10, 2002, 5][1];");
    try testReturnValue(.{ .i64 = 5 }, "return [10, 2002, 5][2];");
    try testReturnValue(.{ .i64 = 5 }, "return [10, 2002, 5][-1];");
    try testReturnValue(.{ .i64 = 2002 }, "return [10, 2002, 5][-2];");
    try testReturnValue(.{ .i64 = 10 }, "return [10, 2002, 5][-3];");

    try testRuntimeError("Index out of range. Index: 0, Len: 0", "return [][0];");
    try testRuntimeError("Index out of range. Index: 1, Len: 0", "return [][1];");
    try testRuntimeError("Index out of range. Index: 1, Len: 1", "return [0][1];");
    try testRuntimeError("Index out of range. Index: -1, Len: 0", "return [][-1];");
    try testRuntimeError("Index out of range. Index: -3, Len: 2", "return [1,2][-3];");
}

test "Compiler: list assignment" {
    try testReturnValue(.{ .i64 = 10 },
        \\ var arr = [0];
        \\ arr[0] = 10;
        \\ return arr[0];
    );

    try testReturnValue(.{ .string = "a" },
        \\ var arr = [0, 1, 2];
        \\ arr[2] = "a";
        \\ return arr[2];
    );

    try testReturnValue(.{ .bool = true },
        \\ var arr = [0, 1, 2];
        \\ arr[-1] = true;
        \\ return arr[2];
    );

    try testReturnValue(.{ .string = "x" },
        \\ var arr = [0, 1, 2];
        \\ arr[-2] = "x";
        \\ return arr[1];
    );

    try testReturnValue(.{ .string = "a" },
        \\ var arr = [0, 1, 2];
        \\ arr[-3] = "a";
        \\ return arr[0];
    );

    try testReturnValue(.{ .i64 = 11 },
        \\ var arr = [0, 5, 6];
        \\ arr[1] = arr[1] + arr[2];
        \\ return arr[1];
    );

    try testReturnValue(.{ .i64 = 6 },
        \\ var arr = [0, 5, 2];
        \\ arr[1]++;
        \\ return arr[1];
    );

    try testReturnValue(.{ .f64 = 2.2 },
        \\ var arr = [0, 5, 3.2];
        \\ var idx = 2;
        \\ arr[idx]--;
        \\ return arr[idx];
    );

    try testReturnValue(.{ .i64 = 13 },
        \\ var arr = [0, 5, 2];
        \\ arr[1] += 8;
        \\ return arr[1];
    );

    try testReturnValue(.{ .f64 = -7.7 },
        \\ var arr = [0, 5, 3.2];
        \\ var idx = 2;
        \\ arr[idx] -= 10.9;
        \\ return arr[idx];
    );

    try testReturnValue(.{ .f64 = 16.3 },
        \\ var arr = [0, 5, 3.2];
        \\ var idx = 2;
        \\ arr[idx] -= -13.1;
        \\ return arr[idx];
    );

    try testReturnValue(.{ .i64 = 8 },
        \\ var arr = [0, 7, 2];
        \\ return arr[1]++;
    );

    // important to test that the inner array is properly released
    try testReturnValue(.{ .i64 = 2 },
        \\ var arr = [[1]];
        \\ arr[0] = 2;
        \\ return arr[0];
    );

    try testRuntimeError("Index out of range. Index: 0, Len: 0", "[][0] = 1;");
    try testRuntimeError("Index out of range. Index: -1, Len: 0", "[][-1] = 1;");
    try testRuntimeError("Index out of range. Index: 1, Len: 1", "[1][1] = 1;");
    try testRuntimeError("Index out of range. Index: -2, Len: 1", "[1][-2] = 1;");
}

test "Compiler: map initialization" {
    {
        try testReturnValue(t.createMapRef(&.{}, &.{}), "return %{};");
    }

    {
        const expected = t.createMapRef(
            &.{ "leto", "123", "a key" },
            &.{ .{ .bool = true }, .{ .string = "hello" }, .{ .f64 = -1.23 } },
        );

        try testReturnValue(expected,
            \\ return %{
            \\   leto: true,
            \\   123: "hello",
            \\   `a key`: -1.23
            \\ };
        );

        // with trailing comma
        try testReturnValue(expected,
            \\ return %{
            \\   leto: true,
            \\   123: "hello",
            \\   `a key`: -1.23,
            \\ };
        );
    }
}

test "Compiler: map indexing" {
    try testReturnValue(.{ .i64 = 1 }, "return %{a: 1}[`a`];");
    try testReturnValue(.{ .null = {} }, "return %{a: 1}[`b`];");
    try testReturnValue(.{ .null = {} }, "return %{a: 1}[123];");
    try testReturnValue(.{ .bool = true }, "return %{123: true}[123];");

    try testReturnValue(.{ .bool = true }, "return %{123: true}[123];");
    try testReturnValue(.{ .i64 = 2 },
        \\ var x = %{a: 2};
        \\ var key = "a";
        \\ return x[key];
    );
}

test "Compiler: map assignment" {
    try testReturnValue(.{ .i64 = 10 },
        \\ var map = %{0: 2};
        \\ map[0] = 10;
        \\ return map[0];
    );

    try testReturnValue(.{ .string = "3" },
        \\ var map = %{"a": 1, "b": 2};
        \\ map["a"] = "3";
        \\ return map["a"];
    );

    try testReturnValue(.{ .i64 = 4 },
        \\ var map = %{"a": 1, "b": 2};
        \\ map["c"] = 4;
        \\ return map["c"];
    );

    try testReturnValue(.{ .i64 = 3 },
        \\ var map = %{"a": 1, "b": 2};
        \\ map["a"] = map["a"] + map["b"];
        \\ return map["a"];
    );

    try testReturnValue(.{ .i64 = -5 },
        \\ var map = %{1: 0, 2: -1, 3: -4};
        \\ map[3]--;
        \\ return map[3];
    );

    try testReturnValue(.{ .i64 = 13 },
        \\ var map = %{a: 1, `b`: 5, c: 2};
        \\ map["b"] += 8;
        \\ return map["b"];
    );

    try testReturnValue(.{ .i64 = 8 },
        \\ var map = %{"count": 7};
        \\ return map["count"]++;
    );

    // important to test that the inner array is properly released
    // with int key
    try testReturnValue(.{ .i64 = 5 },
        \\ var map = %{123: [2]};
        \\ map[123] = 5;
        \\ return map[123];
    );

    // important to test that the inner array is properly released
    // with string key
    try testReturnValue(.{ .i64 = 4 },
        \\ var map = %{"count": [2]};
        \\ map["count"] = 4;
        \\ return map["count"];
    );
}

test "Compiler: string indexing" {
    try testReturnValue(.{ .string = "a" }, "return `abc`[0];");
    try testReturnValue(.{ .string = "b" }, "return `abc`[1];");
    try testReturnValue(.{ .string = "c" }, "return `abc`[2];");
    try testReturnValue(.{ .string = "c" }, "return `abc`[-1];");
    try testReturnValue(.{ .string = "b" }, "return `abc`[-2];");
    try testReturnValue(.{ .string = "a" }, "return `abc`[-3];");

    try testRuntimeError("Index out of range. Index: 0, Len: 0", "return ``[0];");
    try testRuntimeError("Index out of range. Index: 1, Len: 0", "return ``[1];");
    try testRuntimeError("Index out of range. Index: 1, Len: 1", "return `a`[1];");
    try testRuntimeError("Index out of range. Index: -1, Len: 0", "return ``[-1];");
    try testRuntimeError("Index out of range. Index: -3, Len: 2", "return `ab`[-3];");
}

test "Compiler: invalid type indexing" {
    try testRuntimeError("Cannot index an integer", "return 0[0];");
    try testRuntimeError("Cannot index a float", "return 12.3[-1];");
    try testRuntimeError("Cannot index a boolean", "return true[0];");
    try testRuntimeError("Cannot index null", "return null[0];");

    try testRuntimeError("Invalid index or property type, got a boolean", "return [][true];");
    try testRuntimeError("Invalid index or property type, got null", "return [][null];");
    try testRuntimeError("Invalid index or property type, got a float", "return [][1.2];");
    try testRuntimeError("Cannot index a list with a string key", "return [][``];");
    try testRuntimeError("Invalid index or property type, got a list", "return [][[]];");
}

test "Compiler: orelse" {
    try testReturnValue(.{ .i64 = 4 }, "return 4 orelse 1;");
    try testReturnValue(.{ .i64 = 2 }, "return null orelse 2;");
    try testReturnValue(.{ .i64 = 3 }, "return null orelse 2+1;");
    try testReturnValue(.{ .string = "hi" }, "return null orelse null orelse null orelse `hi`;");
    try testReturnValue(.{ .i64 = 1 }, "return 1 orelse null orelse null orelse `hi`;");
}

test "Compiler: string dedupe" {
    try testReturnValueWithApp(struct {
        pub const ZtlConfig = struct {
            pub const deduplicate_string_literals = true;
        };
    }, .{}, .{ .string = "hello" },
        \\ var x = "hello";
        \\ var y = "hello";
        \\ return x;
    );

    try testReturnValueWithApp(struct {
        pub const ZtlConfig = struct {
            pub const ztl_deduplicate_string_literals = false;
        };
    }, .{}, .{ .string = "hello" },
        \\ var x = "hello";
        \\ var y = "hello";
        \\ return x;
    );
}

test "Compiler: break while" {
    try testReturnValue(.{ .i64 = 4 },
        \\ var i = 0;
        \\ while (i < 10) {
        \\   if (i == 4) break;
        \\   i += 1;
        \\ }
        \\ return i;
    );

    // Makes sure the stack is properly restored even on break
    try testReturnValue(.{ .i64 = 2 },
        \\ var i = 0;
        \\ while (i < 10) {
        \\   var noise = 3;
        \\   if (i == 4) break;
        \\   i += 1;
        \\ }
        \\ var y = 2;
        \\ return y;
    );

    try testReturnValue(.{ .i64 = 25 },
        \\ var i = 0;
        \\ var j = 0;
        \\ var x = 0;
        \\ while (i < 20) {
        \\   while (j < 10) {
        \\     if (j == 5) break;
        \\     j += 1;
        \\     x += 1;
        \\   }
        \\   i += 1;
        \\ }
        \\ return i + x;
    );

    try testReturnValue(.{ .i64 = 5 },
        \\ var i = 0;
        \\ var j = 0;
        \\ var x = 0;
        \\ while (i < 20) {
        \\   while ( j < 10) {
        \\     if (j == 5) break 2;
        \\     j += 1;
        \\     x += 1;
        \\   }
        \\   i += 1;
        \\ }
        \\ return i + x;
    );
}

test "Compiler: break for" {
    try testReturnValue(.{ .i64 = 4 },
        \\ var i = 0;
        \\ for (; i < 10; i++) {
        \\   if (i == 4) break;
        \\   i += 1;
        \\ }
        \\ return i;
    );

    try testReturnValue(.{ .i64 = 25 },
        \\ var i = 0;
        \\ var j = 0;
        \\ var x = 0;
        \\ for (;i < 20; i++) {
        \\   for (;j < 10; j++) {
        \\     if (j == 5) break;
        \\     x += 1;
        \\   }
        \\   i += 1;
        \\ }
        \\ return i + x;
    );

    try testReturnValue(.{ .i64 = 5 },
        \\ var i = 0;
        \\ var j = 0;
        \\ var x = 0;
        \\ for (;i < 20; i++) {
        \\   for (;j < 10; j++) {
        \\     if (j == 5) break 2;
        \\     x += 1;
        \\   }
        \\ }
        \\ return i + x;
    );
}

test "Compiler: break foreach" {
    try testReturnValue(.{ .i64 = 10 },
        \\ var count = 0;
        \\ var arr = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        \\ foreach (arr) |i| {
        \\   if (i == 5) break;
        \\   count += i;
        \\ }
        \\ return count;
    );

    try testReturnValue(.{ .i64 = 4010 },
        \\ var c1 = 0;
        \\ var c2 = 0;
        \\ foreach ([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) |i| {
        \\   foreach ([10, 20, 30, 40, 50, 60, 70, 80, 90, 100]) |j| {
        \\     if (j == 50) break;
        \\     c2 += 100;
        \\   }
        \\   c1 += 1;
        \\ }
        \\ return c1 + c2;
    );

    try testReturnValue(.{ .i64 = 414 },
        \\ var c1 = 0;
        \\ var c2 = 0;
        \\ foreach ([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], %{a: 1, b: 3}) |i, kv| {
        \\   foreach ([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], [1,2,3,4,5,6]) |j, k| {
        \\     if (j == 50) break 2;
        \\     c2 += 100 + kv.value + k;
        \\   }
        \\   c1 += 1;
        \\ }
        \\ return c1 + c2;
    );
}

test "Compiler: continue while" {
    try testReturnValue(.{ .i64 = 5 },
        \\ var i = 0;
        \\ var count = 0;
        \\ while (i < 10) {
        \\   i += 1;
        \\   if (i % 2 == 0) continue;
        \\   count += 1;
        \\ }
        \\ return count;
    );

    try testReturnValue(.{ .i64 = 70 },
        \\ var i = 0;
        \\ var x = 0;
        \\ while (i < 20) {
        \\   var j = 0;
        \\   while (j < 10) {
        \\     j += 1;
        \\     if (i >= 5) continue;
        \\     x += 1;
        \\   }
        \\   i += 1;
        \\ }
        \\ return i + x;
    );

    try testReturnValue(.{ .i64 = 42 },
        \\ var i = 0;
        \\ var x = 0;
        \\ while (i < 20) {
        \\   var j = 0;
        \\   x += 1;
        \\   while (j < 10) {
        \\     j += 1;
        \\     i += 1;
        \\     if (i > 2) continue 2;
        \\     x += 2;
        \\   }
        \\   i += 1;
        \\ }
        \\ return i + x;
    );
}

test "Compiler: continue for" {
    try testReturnValue(.{ .i64 = 15 },
        \\ var count = 0;
        \\ for (var i = 0; i < 10; i++) {
        \\   if (i % 2 == 0) {
        \\      count += 2;
        \\      continue;
        \\   }
        \\   count += 1;
        \\ }
        \\ return count;
    );

    try testReturnValue(.{ .i64 = 81 },
        \\ var count = 0;
        \\ for (var i = 0; i < 6; i++) {
        \\   for (var j = 0; j < 5; j++) {
        \\     if (i % 2 == 0) {
        \\        count += 2;
        \\        continue;
        \\     }
        \\     count += 3;
        \\   }
        \\   count += 1;
        \\ }
        \\ return count;
    );

    try testReturnValue(.{ .i64 = 54 },
        \\ var count = 0;
        \\ for (var i = 0; i < 6; i++) {
        \\   for (var j = 0; j < 5; j++) {
        \\     if (i % 2 == 0) {
        \\        count += 2;
        \\        continue 2;
        \\     }
        \\     count += 3;
        \\   }
        \\   count += 1;
        \\ }
        \\ return count;
    );
}

test "Compiler: continue foreach" {
    try testReturnValue(.{ .i64 = 50 },
        \\ var count = 0;
        \\ var arr = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        \\ foreach (arr) |i| {
        \\   if (i == 5) continue;
        \\   count += i;
        \\ }
        \\ return count;
    );

    try testReturnValue(.{ .i64 = 6012 },
        \\ var c1 = 2;
        \\ var c2 = 0;
        \\ foreach ([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) |i| {
        \\   foreach ([10, 20, 30, 40, 50, 60, 70]) |j| {
        \\     if (j == 50) continue;
        \\     c2 += 100;
        \\   }
        \\   c1 += 1;
        \\ }
        \\ return c1 + c2;
    );

    try testReturnValue(.{ .i64 = 1264 },
        \\ var c1 = 2;
        \\ var c2 = 0;
        \\ foreach ([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], %{a: 1, b: 3, c: 4}) |i, kv| {
        \\   foreach ([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], [1,2,3,4,5,6]) |j, k| {
        \\     if (j == 50) continue 2;
        \\     c2 += 100 + kv.value + k;
        \\   }
        \\   c1 += 10000;
        \\ }
        \\ return c1 + c2;
    );
}

test "Compiler: break invalid" {
    try testError("'break' cannot be used outside of loop", "break;");

    try testError("'break' cannot be used outside of loop",
        \\ for (var i = 0; i < 2; i++) {
        \\   add(i, i);
        \\ }
        \\
        \\ fn add(a, b) {
        \\   break;
        \\ }
    );

    try testError("'break 2' is invalid (current loop nesting: 1)",
        \\ for (var i = 0; i < 2; i++) {
        \\   break 2;
        \\ }
    );

    try testError("'break 2' is invalid (current loop nesting: 1)",
        \\ while (true) {
        \\   break 2;
        \\ }
    );
}

test "Compiler: continue invalid" {
    try testError("'continue' cannot be used outside of loop", "continue;");

    try testError("'continue' cannot be used outside of loop",
        \\ for (var i = 0; i < 2; i++) {
        \\   add(i, i);
        \\ }
        \\
        \\ fn add(a, b) {
        \\   continue;
        \\ }
    );

    try testError("'continue 2' is invalid (current loop nesting: 1)",
        \\ for (var i = 0; i < 2; i++) {
        \\   continue 2;
        \\ }
    );

    try testError("'continue 2' is invalid (current loop nesting: 1)",
        \\ while (true) {
        \\   continue 2;
        \\ }
    );
}

test "Compiler: ternary" {
    try testReturnValue(.{ .i64 = 1 }, "return true ? 1 : 10;");
    try testReturnValue(.{ .i64 = 10 }, "return false ? 1 : 10;");

    try testReturnValue(.{ .i64 = 3 },
        \\ var x = 2;
        \\ x += (x % 2 == 0) ? 1 : 2;
        \\ return x;
    );

    try testReturnValue(.{ .i64 = 5 },
        \\ var x = 3;
        \\ x += (x % 2 == 0) ? 1 : 2;
        \\ return x;
    );
}

test "Compiler: list references" {
    try testReturnValue(.{ .i64 = 9 },
        \\ var total = [1];
        \\ {
        \\   var ref = total;
        \\   ref[0] = 9;
        \\ }
        \\ return total[0];
    );
}

test "Compiler: foreach" {
    try testReturnValue(.{ .i64 = 5 },
        \\ var total = 5;
        \\ foreach([]) |item| {
        \\   total += item;
        \\ }
        \\ return total;
    );

    try testReturnValue(.{ .i64 = 15 },
        \\ var total = 1;
        \\ {
        \\   var arr = [2, 4, 8];
        \\   foreach(arr) |item| {
        \\    total += item;
        \\   }
        \\ }
        \\ return total;
    );

    try testReturnValue(.{ .i64 = 2 },
        \\ var total = 2;
        \\ {
        \\   foreach(%{}) |kv| {
        \\     total += kv.key + kv.value;
        \\   }
        \\ }
        \\ return total;
    );

    try testReturnValue(.{ .i64 = 627 },
        \\ var total = 1;
        \\ {
        \\   var map = %{10: 12, 300: 304};
        \\   foreach(map) |kv| {
        \\    total += kv.key + kv.value;
        \\   }
        \\ }
        \\ return total;
    );

    try testReturnValue(.{ .i64 = 3627 },
        \\ var total = 1;
        \\ {
        \\   var map = %{10: 12, 300: 304};
        \\   var arr = [1000, 2000];
        \\   foreach(map, arr) |kv, item| {
        \\    total += kv.key + kv.value + item;
        \\   }
        \\ }
        \\ return total;
    );

    // breaks on first short result
    try testReturnValue(.{ .i64 = 1023 },
        \\ var total = 1;
        \\ {
        \\   var map = %{10: 12, 300: 304};
        \\   var arr = [1000];
        \\   foreach(map, arr) |kv, item| {
        \\    total += kv.key + kv.value + item;
        \\   }
        \\ }
        \\ return total;
    );

    // breaks on first short result
    try testReturnValue(.{ .i64 = 1024 },
        \\ var total = 1;
        \\ {
        \\   var map = %{10: 13};
        \\   var arr = [1000, 2000];
        \\   foreach(map, arr) |kv, item| {
        \\    total += kv.key + kv.value + item;
        \\   }
        \\ }
        \\ return total;
    );
}

test "Compiler: stack overflow" {
    try testRuntimeError("Maximum call depth (255) reached",
        \\ fn overflow() {
        \\   overflow();
        \\ }
        \\ overflow();
    );
}

test "Compiler: ztl functions" {
    try testError("IdentifierTooLong", "fn " ++ "x" ** 128 ++ "(){}");

    try testError("Unreachable code detected",
        \\ fn a() {
        \\  return "a";
        \\  return "b";
        \\ }
    );

    try testReturnValue(.{ .i64 = 25 },
        \\ return value(3);
        \\
        \\ fn value(start) {
        \\   return start + 22;
        \\ }
    );

    // implicit return
    try testReturnValue(.{ .null = {} },
        \\ return value();
        \\
        \\ fn value() {
        \\ }
    );

    try testReturnValue(.{ .i64 = 26 },
        \\ var start = 4;
        \\ var noise = 99;
        \\ return value(start);
        \\
        \\ fn value(start) {
        \\   var noise = 100;
        \\   return start + 22;
        \\ }
    );

    try testReturnValue(.{ .i64 = 4 },
        \\ var x = 4;
        \\ var y = 6;
        \\ return sum(x, y);
        \\
        \\ fn sum(a, b) {
        \\    if (b == 0) {
        \\       return 5;
        \\    }
        \\    return a;
        \\ }
    );

    try testReturnValue(.{ .i64 = 10 },
        \\ fn first() {
        \\   var a = 1;
        \\   var c = second();
        \\   var d = 2;
        \\   return a + c + d;
        \\ }
        \\
        \\ fn second() {
        \\   var y = 3;
        \\   var z = 4;
        \\   return y + z;
        \\ }
        \\
        \\ return first();
    );

    try testReturnValue(.{ .i64 = 134 },
        \\ fn sum(a, b, count) {
        \\    if (count == 0) {
        \\       return magic(a) + b;
        \\    }
        \\    return sum(a + b, b, count - 1);
        \\ }
        \\
        \\ var x = 4;
        \\ var y = 6;
        \\ return sum(x, y, 10);
        \\
        \\
        \\ fn magic(a) {
        \\    if (a % 2 == 0) {
        \\      return a * 2;
        \\    }
        \\    return a;
        \\ }
    );
}

test "Compiler: function custom" {
    const App = struct {
        id: i64,

        pub const ZtlFunctions = struct {
            pub const add = 2;
            pub const double = 1;
        };

        pub fn call(self: *@This(), vm: *ztl.VM(*@This()), function: ztl.Functions(@This()), values: []Value) !Value {
            _ = vm;
            switch (function) {
                .add => return .{ .i64 = values[0].i64 + values[1].i64 },
                .double => return .{ .i64 = values[0].i64 * 2 + self.id },
            }
        }
    };

    var app = App{ .id = 200 };
    try testReturnValueWithApp(*App, &app, .{ .i64 = 1204 }, "return add(1000, double(2));");

    try testErrorWithApp(*App, &app, "Function 'add' reserved by custom application function", "fn add(){}");
    try testErrorWithApp(*App, &app, "Function 'add' expects 2 parameters, but called with 0", "return add());");
    try testErrorWithApp(*App, &app, "Function 'double' expects 1 parameter, but called with 2", "return double(2, 4));");
}

test "Compiler: function error" {
    try testError("Function 'flow' is unknown", "return flow();");
    try testError("Function name cannot begin with '@'", "fn @print(){}");

    try testError("Function 'x' expects 0 parameters, but called with 1",
        \\ fn x() {}
        \\ x(23);
    );

    try testError("Function 'x' expects 1 parameter, but called with 3",
        \\ x(1,2,3);
        \\ fn x(a) {}
    );
}

test "Compiler: properties" {
    try testReturnValue(.{ .i64 = 0 }, "return [].len;");
    try testReturnValue(.{ .i64 = 3 }, "return [1,10,100].len;");
    try testReturnValue(.{ .i64 = 0 }, "return %{}.len;");
    try testReturnValue(.{ .i64 = 1 }, "return %{a: 2}.len;");
}

test "Compiler: method errors" {
    try testError("xx' is not a valid method", "return [].xx()");
}

test "Compiler: method last" {
    try testError("Function 'last' expects 0 parameters, but called with 1", "return [].last(1)");

    try testReturnValue(.{ .null = {} }, "return [].last();");
    try testReturnValue(.{ .i64 = 20 }, "return [1,20].last();");
}

test "Compiler: method first" {
    try testError("Function 'first' expects 0 parameters, but called with 2", "return [].first(`a`, true)");

    try testReturnValue(.{ .null = {} }, "return [].first();");
    try testReturnValue(.{ .i64 = 99 }, "return [99,2].first();");
}

test "Compiler: method pop" {
    try testError("Function 'pop' expects 0 parameters, but called with 1", "return [].pop(null)");

    try testReturnValue(.{ .null = {} }, "return [].pop();");
    try testReturnValue(.{ .i64 = 132 },
        \\ var arr = [10, 20, 100];
        \\ var last = arr.pop();
        \\ return arr.len + arr[0] + arr[1] + last;
    );
}

test "Compiler: method remove" {
    try testError("Function 'remove' expects 1 parameter, but called with 0", "return [].remove()");
    try testError("Function 'remove' expects 1 parameter, but called with 2", "return %{}.remove(true, false)");

    try testReturnValue(.{ .bool = false }, "return [].remove(`a`);");
    try testReturnValue(.{ .bool = true }, "return [[]].remove([]);");
    try testReturnValue(.{ .i64 = 1312 },
        \\ var arr = [10, 20, 300];
        \\ var removed = arr.remove(20) ? 1000 : 0;
        \\ return arr.len + arr[0] + arr[1] + removed;
    );

    try testReturnValue(.{ .null = {} }, "return %{}.remove(`a`);");
    try testReturnValue(.{ .null = {} }, "return %{}.remove(3);");
    try testReturnValue(.{ .i64 = 301 },
        \\ var map = %{a: 100, b: 200};
        \\ var removed = map.remove("b");
        \\ return map.len + map[`a`] + removed;
    );
    try testReturnValue(.{ .i64 = 301 },
        \\ var map = %{1: 100, 20: 200};
        \\ var removed = map.remove(20);
        \\ return map.len + map[1] + removed;
    );
}

test "Compiler: method removeAt" {
    try testError("Function 'removeAt' expects 1 parameter, but called with 0", "return [].removeAt()");
    try testRuntimeError("Index out of range. Index: 0, Len: 0", "return [].removeAt(0);");

    try testReturnValue(.{ .i64 = 1057 },
        \\ var arr = [5, 25, 50];
        \\ var removed = arr.removeAt(1) == 25 ? 1000 : 0;
        \\ return arr.len + arr[0] + arr[1] + removed;
    );

    try testReturnValue(.{ .i64 = 2057 },
        \\ var arr = [5, 25, 50];
        \\ var removed = arr.removeAt(-2) == 25 ? 2000 : 0;
        \\ return arr.len + arr[0] + arr[1] + removed;
    );
}

test "Compiler: method append" {
    try testError("Function 'append' expects 1 parameter, but called with 0", "return [].append()");

    try testReturnValue(.{ .i64 = 4 },
        \\ var arr = [];
        \\ arr.append(3);
        \\ return arr.len + arr[0];
    );

    try testReturnValue(.{ .i64 = 15 },
        \\ var arr = [];
        \\ arr.append(3);
        \\ arr.append(10);
        \\ return arr.len + arr[0] + arr[1];
    );

    {
        var arr1 = [_]Value{
            .{ .i64 = 99 },
        };
        var arr2 = [_]Value{t.createListRef(&arr1)};
        try testReturnValue(t.createListRef(&arr2),
            \\ var arr = [];
            \\ {
            \\    var inner = [99];
            \\    arr.append(inner);
            \\ }
            \\ return arr;
        );
    }
}

test "Compiler: method contains" {
    try testError("Function 'contains' expects 1 parameter, but called with 0", "return [].contains();");
    try testRuntimeError("Map key must be an integer or string, got a boolean", "return %{}.contains(true);");

    try testReturnValue(.{ .bool = false }, "return [].contains(true);");
    try testReturnValue(.{ .bool = false }, "return [].contains(32);");
    try testReturnValue(.{ .bool = false }, "return [1,2,3].contains(4);");
    try testReturnValue(.{ .bool = true }, "return [1,2,3].contains(3);");
    try testReturnValue(.{ .bool = true }, "return [`aa`, `BB`].contains(`aa`);");
    try testReturnValue(.{ .bool = true }, "return [`aa`, `BB`].contains(`BB`);");
    try testReturnValue(.{ .bool = false }, "return [`aa`, `BB`].contains(`AA`);");

    try testReturnValue(.{ .bool = false }, "return %{}.contains(123);");
    try testReturnValue(.{ .bool = false }, "return %{111: true}.contains(123);");
    try testReturnValue(.{ .bool = true }, "return %{123: 1.2}.contains(123);");
    try testReturnValue(.{ .bool = false }, "return %{abc: 1, def: 2}.contains(123);");
    try testReturnValue(.{ .bool = true }, "return %{abc: 1, def: 2}.contains(`abc`);");
    try testReturnValue(.{ .bool = true }, "return %{abc: 1, def: 2}.contains(`def`);");
    try testReturnValue(.{ .bool = false }, "return %{abc: 1, def: 2}.contains(`ABC`);");
}

test "Compiler: method indexOf" {
    try testError("Function 'indexOf' expects 1 parameter, but called with 0", "return [].indexOf()");
    try testRuntimeError("Unknown method 'indexOf' for a map", "return %{}.indexOf(1);");

    try testReturnValue(.{ .null = {} }, "return [].indexOf(true);");
    try testReturnValue(.{ .null = {} }, "return [].indexOf(32);");
    try testReturnValue(.{ .null = {} }, "return [1,2,3].indexOf(4);");
    try testReturnValue(.{ .i64 = 2 }, "return [1,2,3].indexOf(3);");
    try testReturnValue(.{ .i64 = 0 }, "return [`aa`, `BB`].indexOf(`aa`);");
    try testReturnValue(.{ .i64 = 1 }, "return [`aa`, `BB`].indexOf(`BB`);");
    try testReturnValue(.{ .null = {} }, "return [`aa`, `BB`].indexOf(`AA`);");
}

test "Compiler: method sort" {
    try testError("Function 'sort' expects 0 parameters, but called with 2", "return [].sort(true, false)");
    try testRuntimeError("Unknown method 'sort' for a boolean", "return true.sort();");

    try testReturnValue(.{ .i64 = 5431 },
        \\ var arr = [4, 1, 3, 5];
        \\ arr.sort();
        \\ return arr[0] + (10 * arr[1]) + (100 * arr[2]) + (1000 * arr[3]);
    );

    try testReturnValue(.{ .f64 = 5431.2 },
        \\ var arr = [4, 1, 3.02, 5];
        \\ arr.sort();
        \\ return arr[0] + (10 * arr[1]) + (100 * arr[2]) + (1000 * arr[3]);
    );

    {
        var arr = [_]Value{
            .{ .string = "AZ" },
            .{ .string = "a" },
            .{ .string = "ab" },
        };
        try testReturnValue(t.createListRef(&arr), "return [`ab`, `a`, `AZ`].sort();");
    }
}

test "Compiler: method concat" {
    try testError("Function 'concat' expects 1 parameter, but called with 2", "return [].concat(true, false)");

    {
        var arr = [_]Value{
            .{ .i64 = 1 },
        };
        try testReturnValue(t.createListRef(&arr), "return [].concat(1);");
    }

    {
        var arr = [_]Value{
            .{ .i64 = 0 },
            .{ .i64 = 2 },
            .{ .i64 = 1 },
        };
        try testReturnValue(t.createListRef(&arr), "return [0,2].concat(1);");
    }

    {
        var arr = [_]Value{
            .{ .i64 = 0 },
            .{ .i64 = 2 },
        };
        try testReturnValue(t.createListRef(&arr), "return [].concat([0, 2]);");
    }

    {
        var arr = [_]Value{
            .{ .i64 = 1 },
            .{ .i64 = 3 },
            .{ .i64 = 0 },
            .{ .i64 = 2 },
        };
        try testReturnValue(t.createListRef(&arr), "return [1, 3].concat([0, 2]);");
    }

    {
        var arr = [_]Value{
            .{ .i64 = 1 },
            .{ .i64 = 3 },
            .{ .i64 = 0 },
            .{ .i64 = 2 },
        };
        try testReturnValue(t.createListRef(&arr), "return [1, 3].concat([0, 2]);");
    }

    {
        var arr = [_]Value{
            .{ .i64 = 1 },
            .{ .i64 = 3 },
            .{ .i64 = 0 },
            .{ .i64 = 2 },
        };
        try testReturnValue(t.createListRef(&arr),
            \\ var arr = [1, 3];
            \\ arr.concat([0, 2]);
            \\ return arr;
        );
    }

    {
        var arr = [_]Value{
            .{ .i64 = 1 },
            .{ .i64 = 3 },
            .{ .i64 = 2 },
            .{ .i64 = 0 },
        };
        try testReturnValue(t.createListRef(&arr),
            \\ var arr = [1, 3];
            \\ var other = [2, 0];
            \\ arr.concat(other);
            \\ return arr;
        );
    }

    {
        var arr1 = [_]Value{
            .{ .i64 = 1 },
            .{ .i64 = 2 },
        };
        var arr2 = [_]Value{t.createListRef(&arr1)};
        try testReturnValue(t.createListRef(&arr2),
            \\ var arr = [];
            \\ {
            \\   var other = [[1, 2]];
            \\   arr.concat(other);
            \\ }
            \\ return arr;
        );
    }
}

test "Compiler: method toString" {
    try testError("Function 'toString' expects 0 parameters, but called with 2", "return [].toString('', 0)");
    try testReturnValue(.{ .string = "abc" }, "return 'abc'.toString(); ");
    try testReturnValue(.{ .string = "123aabz" }, "return '123aabz'.toString().toString(); ");
    try testReturnValue(.{ .string = "3" }, "return 3.toString(); ");
    try testReturnValue(.{ .string = "false" }, "return false.toString(); ");
    try testReturnValue(.{ .string = "[1, 2, 3]" }, "return [1,2,3].toString(); ");
}

test "Compiler: partial" {
    const App = struct {
        pub const ZtlConfig = struct {
            pub const debug = ztl.DebugMode.full;
            pub const reference_counting = ztl.ReferenceCounting.strict;
        };

        pub fn partial(self: @This(), _: Allocator, template_key: []const u8, include_key: []const u8) !?PartialResult {
            _ = self;
            _ = template_key;

            if (std.mem.eql(u8, include_key, "fail")) {
                return error.SomeError;
            }

            if (std.mem.eql(u8, include_key, "404")) {
                return null;
            }

            if (std.mem.eql(u8, include_key, "incl_dbl")) {
                return .{ .src = "<% fn dbl(a) { return a * 2; } %>" };
            }

            if (std.mem.eql(u8, include_key, "recursive_1")) {
                return .{ .src = "<% @include('recursive_2') %>" };
            }

            if (std.mem.eql(u8, include_key, "recursive_2")) {
                return .{ .src = "<% @include('recursive_1') %>" };
            }

            return null;
        }
    };

    try testErrorWithApp(App, .{}, "PartialUnknown - Unknown partial: 'unknown'",
        \\ @include("unknown");
    );

    try testErrorWithApp(App, .{}, "PartialLoadError - Failed to load partial: 'fail'. Load Error: error.SomeError",
        \\ @include("fail");
    );

    try testErrorWithApp(App, .{}, "PartialUnknown - Unknown partial: '404'",
        \\ @include("404");
    );

    try testErrorWithApp(App, .{}, "BuiltinNotAnExpression - Builtin function '@include' does not produce a value",
        \\ return @include("incl_1");
    );

    try testErrorWithApp(App, .{}, "IncludeLoopDetected",
        \\ @include("recursive_1");
    );

    try testReturnValueWithApp(App, .{}, .{ .i64 = 12350 },
        \\ @include("incl_dbl");
        \\ return dbl(6175);
    );
}

fn testReturnValue(expected: Value, comptime src: []const u8) !void {
    try testReturnValueWithApp(struct {
        pub const ZtlConfig = struct {
            pub const debug = ztl.DebugMode.full;
            pub const reference_counting = ztl.ReferenceCounting.strict;
        };
    }, .{}, expected, src);

    try testReturnValueWithApp(struct {
        pub const ZtlConfig = struct {
            pub const max_locals = 256;
            pub const reference_counting = ztl.ReferenceCounting.strict;
        };
    }, .{}, expected, src);

    try testReturnValueWithApp(struct {
        pub const ZtlConfig = struct {
            pub const max_locals = 300;
            pub const reference_counting = ztl.ReferenceCounting.strict;
        };
    }, .{}, expected, src);
}

fn testReturnValueWithApp(comptime App: type, app: App, expected: Value, comptime src: []const u8) !void {
    const allocator = t.arena.allocator();

    const byte_code = blk: {
        var error_report = ztl.CompileErrorReport{};
        var c = try Compiler(App).init(allocator, app, .{ .error_report = &error_report });
        c.compile("<% " ++ src ++ "%>") catch |err| {
            std.debug.print("Compilation error: {any}\n{f}\n", .{ err, error_report });
            return err;
        };
        break :blk try c.writer.toBytes(allocator);
    };

    // disassemble(App, allocator, byte_code, std.io.getStdErr().writer()) catch unreachable;

    var vm = ztl.VM(App).init(allocator, app);

    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    const value = vm.run(byte_code, &aw.writer) catch |err| {
        std.debug.print("{any}", .{err});
        if (vm.err) |e| {
            std.debug.print("{any} {s}\n", .{ err, e });
        }
        var stderr_lock = std.debug.lockStderr(&.{});
        defer std.debug.unlockStderr();

        const stderr = stderr_lock.terminal().writer;
        disassemble(App, allocator, byte_code, stderr) catch unreachable;
        return err;
    };

    const is_equal = expected.equal(value) catch false;
    if (is_equal == false) {
        std.debug.print("{any} != {any}\n", .{ expected, value });
        return error.NotEqual;
    }
    vm.release(value);
    try checkVMForLeaks(&vm);
}

fn testError(expected: []const u8, comptime src: []const u8) !void {
    return testErrorWithApp(void, {}, expected, src);
}

fn testErrorWithApp(comptime App: type, app: App, expected: []const u8, comptime src: []const u8) !void {
    var error_report = ztl.CompileErrorReport{};
    var c = Compiler(App).init(t.arena.allocator(), app, .{ .error_report = &error_report }) catch unreachable;

    c.compile("<% " ++ src ++ " %>") catch {
        var aw: std.Io.Writer.Allocating = .init(t.allocator);
        defer aw.deinit();

        try aw.writer.print("{f}", .{error_report});
        if (std.mem.indexOf(u8, aw.written(), expected) == null) {
            std.debug.print("Wrong error\nexpected: '{s}'\nactual:   '{s}'\n", .{ expected, aw.written() });
            return error.WrongError;
        }
        return;
    };

    // const byte_code = try c.writer.toBytes(t.allocator);
    // defer t.allocator.free(byte_code);
    // disassemble(App, t.allocator, byte_code, std.io.getStdErr().writer()) catch unreachable;

    return error.NoError;
}

fn testRuntimeError(expected: []const u8, comptime src: []const u8) !void {
    var error_report = ztl.CompileErrorReport{};
    var c = try Compiler(void).init(t.arena.allocator(), {}, .{ .error_report = &error_report });
    c.compile("<% " ++ src ++ " %>") catch |err| {
        std.debug.print("Compilation error: {any}\n{f}\n", .{ err, error_report });
        return err;
    };

    const byte_code = try c.writer.toBytes(t.allocator);
    defer t.allocator.free(byte_code);
    // disassemble({}, t.allocator, byte_code, std.io.getStdErr().writer()) catch unreachable;

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var vm = ztl.VM(void).init(arena.allocator(), {});
    try checkVMForLeaks(&vm);

    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    _ = vm.run(byte_code, &aw.writer) catch {
        if (std.mem.indexOf(u8, vm.err.?, expected) == null) {
            std.debug.print("Wrong error, expected: {s} but got:\n{s}\n", .{ expected, vm.err.? });
            return error.WrongError;
        }
        return;
    };
    return error.NoError;
}

fn checkVMForLeaks(vm: anytype) !void {
    if (vm._ref_pool.count == 0) {
        return;
    }
    std.debug.print("ref pool leak: {d}\n", .{vm._ref_pool.count});
    return error.MemoryLeak;
}
