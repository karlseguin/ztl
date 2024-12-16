const std = @import("std");
const zt = @import("zt.zig");

const VM = zt.VM;
const Value = zt.Value;
const Error = zt.Error;
const Compiler = zt.Compiler;

const config = @import("config.zig");
const Token = @import("scanner.zig").Token;
const Scanner = @import("scanner.zig").Scanner;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

// There's a long comment at the end of this file which tries to explain
// what's going on.

pub fn Template(comptime App: type) type {
    return struct {
        err: ?Error,
        arena: ArenaAllocator,
        globals: [][]const u8,
        byte_code: []const u8,

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{
                .err = null,
                .globals = &.{},
                .byte_code = "",
                .arena = ArenaAllocator.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        pub fn compile(self: *Self, src: []const u8) !void {
            var build_arena = ArenaAllocator.init(self.arena.child_allocator);
            defer build_arena.deinit();

            const build_allocator = build_arena.allocator();

            const zt_src = try self._translateToZt(build_allocator, src);

            const template_arena = self.arena.allocator();

            {
            // at this point, the template -> zt translation will be invalid if
                // any globals (@variable) were used. If we try to compile, we'll
                // get an error about undefined variables.
                // We need to extract any globals from the zt source code, and then
                // manipulate the bytecode to have it think those locals are valid
                // (which, when we run the bytecode, the VM will inject)
                const temp_globals = try self.extractGlobals(build_allocator, zt_src);

                // copy our globals arraylist (which was generated in our
                // tempoary build_arena and might be wasting space, and references
                // the source) into a properly sized slice owned by the template's
                // permanent arena and also owning the identifier name;
                self.globals = try template_arena.alloc([]const u8, temp_globals.count());
                var i: usize = 0;
                var it = temp_globals.keyIterator();
                while (it.next()) |key_ptr| {
                    self.globals[i] = try template_arena.dupe(u8, key_ptr.*);
                    i += 1;
                }
                sortVariableNames(self.globals);
            }

            // OK, this is one of the crazier parts. Ideally, we'd take our zt
            // source code, and add declarations for our globals. So, a simple
            // template like:
            //    <%= @name %>

            // would have an zt like:;
            //    $ @name;
            //
            // And now we'd want to do:
            //
            //    var @name = null;  // PREPEND THIS
            //    $ @name;
            //
            // But prepending is expensive. So our compiler has a special
            // definedLocal function which will simulate having those declaration
            // (it'll write the appropriate byte code and alter its own variable
            // stack).

            var compiler = try Compiler(App).init(build_allocator);
            compiler.compile(zt_src, .{.force_locals = self.globals}) catch |err| {
                if (compiler.err) |ce| {
                    self.err = .{
                        .position = ce.position,
                        .desc = try template_arena.dupe(u8, ce.desc),
                    };
                } else {
                    self.err = .{
                        .position = .{},
                        .desc = @errorName(err),
                    };
                }
                return err;
            };

            self.byte_code = try compiler.byteCode(template_arena);
        }

        pub fn translateToZt(self: *Self, src: []const u8) !ZtSource {
            var arena = ArenaAllocator.init(self.arena.child_allocator);
            const zt_src = try self._translateToZt(arena.allocator(), src);

            return .{
                .src = zt_src,
                .arena = arena,
            };
        }

        pub fn run(self: *Self, allocator: Allocator, writer: anytype, args: anytype) !void {
            var vm = VM(App).init(allocator);
            defer vm.deinit();

            return self.runOn(writer, &vm, args);
        }

        pub fn runOn(self: *Self, writer: anytype, vm: *VM(App), args: anytype) !void {
            const T = @TypeOf(args);
            const allocator = vm._arena.allocator();

            switch (@typeInfo(T)) {
                .@"struct" => |s| {
                    const field_names = comptime blk: {
                        var field_names: [s.fields.len][]const u8 = undefined;
                        for (s.fields, 0..) |f, i| {
                            field_names[i] = f.name;
                        }
                        sortVariableNames(&field_names);
                        break :blk field_names;
                    };
                    inline for(field_names) |name| {
                        const value = Value.from(allocator, @field(args, name)) catch {
                            self.err = .{
                                .position = null,
                                .desc = "Unsupported argument type: " ++ @typeName(@TypeOf(@field(args, name))),
                            };
                            return error.InvalidArgument;
                        };
                        try vm.injectLocal(value);
                    }
                },
                else => @compileError("args must be a struct, got: " ++ @typeName(T)),
            }

            _ = try vm.run(self.byte_code, writer);
        }

        pub fn disassemble(self: *const Self, writer: anytype) !void {
            return zt.disassemble(App, self.byte_code, writer);
        }

        // allocator is an arena
        fn _translateToZt(self: *Self, allocator: Allocator, src: []const u8) ![]const u8 {
            if (src.len == 0) {
                return "return ``;";
            }

            var buf = std.ArrayList(u8).init(allocator);
            // we'll need at least this much space
            try buf.ensureTotalCapacity(src.len + 64);

            var start: usize = 0;
            const end = src.len - 1;
            var scanner = Scanner.init(allocator, "");

            // If the first character is '%', it isn't a tag. Doing this check here
            // means we don't have to check if `i == 0` inside our loop.
            var pos: usize = if (src[0] == '%') 1 else 0;

            var trim_left = false;

            while (true) {
                const idx = std.mem.indexOfScalarPos(u8, src, pos, '%') orelse end;
                if (idx == end) {
                    var literal = src[start..];
                    if (trim_left) {
                       literal = std.mem.trimLeft(u8, literal, &std.ascii.whitespace);
                    }
                    try appendOut(&buf, literal);
                    break;
                }

                if (src[idx - 1] != '<') {
                    pos = idx + 1;
                    continue;
                }

                var next = src[idx + 1];
                if (next == '%') {
                    // <%%  => '<%'
                    try appendOut(&buf, src[start..idx]);
                    pos = idx + 1;
                    start = pos;
                    continue;
                }

                // A literal. We can't append this to buf just yet, since the
                // following template tag might ask us to strip white spaces.
                var literal = src[start .. idx - 1];
                // skip the %
                pos = idx + 1;

                if (next == '-' and pos != end) {
                    pos += 1;
                    next = src[pos];
                    literal = std.mem.trimRight(u8, literal, &std.ascii.whitespace);
                }

                if (trim_left) {
                    literal = std.mem.trimLeft(u8, literal, &std.ascii.whitespace);
                }
                try appendOut(&buf, literal);

                // find the position of the closing tag, %>
                const code_end, const end_tag_len, trim_left = try self.findCodeEnd(&scanner, src, pos);

                if (next == '=') {
                    pos += 1; // skip the =
                    const ELZ_SET_EXP = "\n$";
                    const expression = src[pos..code_end];
                    try buf.ensureUnusedCapacity(ELZ_SET_EXP.len + expression.len + 2);
                    buf.appendSliceAssumeCapacity(ELZ_SET_EXP);
                    buf.appendSliceAssumeCapacity(expression);
                    buf.appendSliceAssumeCapacity(";");
                } else {
                    try buf.append('\n');
                    try buf.appendSlice(std.mem.trim(u8, src[pos..code_end], &std.ascii.whitespace));
                }

                pos = code_end + end_tag_len; // skip the closing %> or -%>
                start = pos;
            }
            try buf.appendSlice("\nreturn;");
            return buf.items;
        }

        fn findCodeEnd(self: *Self, scanner: *Scanner, src: []const u8, pos: usize) !struct{usize, usize, bool} {
            scanner.reset(src[pos..]);
            while (self.scanNext(scanner)) |token| switch (token.value) {
                .PERCENT => {
                    switch ((try self.scanNext(scanner)).value) {
                        .GREATER, => return .{pos + token.position.pos, 2, false},
                        else => {},
                    }
                },
                 .MINUS => if (scanner.peek(&.{.PERCENT, .GREATER})) {
                    return .{pos + token.position.pos, 3, true};
                },
                .EOF => {
                    self.err = .{
                        .position = .{},
                        .desc = "Missing expected end tag, '%>'",
                    };
                    return error.ScanError;
                },
                else => {},
            } else |err| {
                return err;
            }
            unreachable;
        }

        // allocator is an arena
        fn extractGlobals(self: *Self, allocator: Allocator, src: []const u8) !std.StringHashMapUnmanaged(void) {
            var scanner = Scanner.init(allocator, src);
            // a map because we need to de-dupe
            var globals: std.StringHashMapUnmanaged(void) = .{};

            while (self.scanNext(&scanner)) |token| switch (token.value) {
                .IDENTIFIER => |name| {
                    if (name[0] == '@') {
                       _ = try globals.getOrPut(allocator, name);
                    }
                },
                .EOF => return globals,
                else => {},
            } else |err| {
                return err;
            }
            unreachable;
        }

        fn scanNext(self: *Self, scanner: *Scanner) !Token {
            return scanner.next() catch |err| {
                if (scanner.err) |se| {
                    self.err = .{.position = .{}, .desc = try self.arena.allocator().dupe(u8, se)};
                } else {
                    self.err = .{.position = .{}, .desc = @errorName(err)};
                }
                return err;
            };
        }
    };
}

const ZtSource = struct {
    src: []const u8,
    arena: ArenaAllocator,

    pub fn deinit(self: *const ZtSource) void {
        self.arena.deinit();
    }
};

fn appendOut(buf: *std.ArrayList(u8), content: []const u8) !void {
    if (content.len == 0) {
        return;
    }

    try buf.ensureUnusedCapacity(4 + content.len);
    buf.appendSliceAssumeCapacity("$`");
    buf.appendSliceAssumeCapacity(content);
    buf.appendSliceAssumeCapacity("`;");
}

fn sortVariableNames(values: [][]const u8) void {
    std.mem.sort([]const u8, values, {}, struct {
        fn sort(_: void, lhs: []const u8, rhs: []const u8) bool {
             return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.sort);
}

const t = @import("t.zig");
test "Template: simple" {
    try testTemplate("Simple", "Simple", .{});
}

test "Template: edge cases" {
    try testTemplate("hello %", "hello %", .{});
    try testTemplate("hello % ", "hello % ", .{});
    try testTemplate("hello %%", "hello %%", .{});
    try testTemplate("hello <%", "hello <%%", .{});
    try testTemplate("hello <%=", "hello <%%=", .{});
    try testTemplate("hello <% world", "hello <%% world", .{});
    try testTemplate("%", "%", .{});
    try testTemplate("%>a", "%>a", .{});
    try testTemplate("%-Hi", "%-Hi", .{});
    try testTemplate("<%-", "<%%-", .{});
}

test "Template: output literals" {
    try testTemplate("123", "<%= 123 %>", .{});
    try testTemplate("-1.23492", "<%= -1.23492 %>", .{});
    try testTemplate("null", "<%= null %>", .{});
    try testTemplate("", "<%= null orelse `` %>", .{});
    try testTemplate("true", "<%= true %>", .{});
    try testTemplate("false", "<%= false %>", .{});
    try testTemplate("[1, 2, true]", "<%= [1 ,2,  true] %>", .{});
}

test "Template: output variable" {
    try testTemplate("Leto", "<%= @name %>", .{.name = "Leto"});
    try testTemplate("7", "<%= @x + 1 %>", .{.x = 6});
}

test "Template: space stripping" {
    try testTemplate("  Leto   ", "  <%= @name %>   ", .{.name = "Leto"});
    try testTemplate("Leto   ", "  <%-= @name %>   ", .{.name = "Leto"});
    try testTemplate("  Leto", "  <%= @name -%>  ", .{.name = "Leto"});
    try testTemplate("Leto", "  <%-= @name -%>  ", .{.name = "Leto"});
}

test "Template: local and global" {
    try testTemplate("12", \\
        \\ <%- var x = 2; -%>
        \\ <%-= x + @count -%>
    , .{.count = 10});
}

test "Template: for loop" {
    try testTemplate(
        \\<h2>Products</h2>
        \\  product: 10
        \\  product: 22
        \\  product: 33
    ,
        \\<h2>Products</h2>
        \\<%- for (var i = 0; i < @products.len; i++) { %>
        \\  product: <%= @products[i] -%>
        \\<%- } %>
    , .{.products = [_]i64{10, 22, 33}});
}

test "Template: errors in template" {
    try testTemplateError("Missing expected end tag, '%>'", "<%=");
}

fn testTemplate(expected: []const u8, template: []const u8, args: anytype) !void {
    var tmpl = Template(void).init(t.allocator);
    defer tmpl.deinit();
    tmpl.compile(template) catch |err| {
        if (tmpl.translateToZt(template)) |zts| {
            defer zts.deinit();
            std.debug.print("==zt source:==\n{s}\n", .{zts.src});
        } else |_| {}

        std.debug.print("Compile template error:\n{s}\n", .{tmpl.err.?.desc});
        return err;
    };
    // try tmpl.disassemble(std.io.getStdErr().writer());

    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();
    tmpl.run(t.allocator, buf.writer(), args) catch |err| {
        const zts = tmpl.translateToZt(template) catch unreachable;
        defer zts.deinit();
        std.debug.print("==zt source:==\n{s}\n", .{zts.src});

        std.debug.print("==disassemble==\n", .{});
        try tmpl.disassemble(std.io.getStdErr().writer());
        return err;
    };
    try t.expectString(expected, buf.items);
}

fn testTemplateError(expected: []const u8, template: []const u8) !void {
    var tmpl = Template(void).init(t.allocator);
    defer tmpl.deinit();
    tmpl.compile(template) catch {
        try t.expectString(expected, tmpl.err.?.desc);
        return;
    };
    return error.NoError;
}

// Surprisingly [to me] this is the dirtiest part of the codebase. Our goal is
// to take a template, say:
//
//    <h2>Products</h2>
//    <% for (var i = 0; i < @products.len; i++) { %>
//      <%= @products[i].name %>
//    <% } %>
//
// And to turn it into zt code that can be compiled and the run. At first glance,
// we want to create something like:
//
//    var html = "";
//    html += '<h2>Products</h2>';
//    for (var i = 0; i < @products.len; i++) {
//        html += @products[i].name;
//    }
//    return html;
//
// But we have 3 challenges.
//
// 1 - It's possible for string literals within the zt code to conflict with the
// template syntax. For example, this simple template is problematic:
//
//     <%= "hello %> world" %>
//
// We need to be zt-aware when we parse the template. You could say the template
// is a superset of zt. indexOf("%>") isn't going to work. Whenever we enter
// a code block (whether it's an output block or not), we need to use the zt
// scanner to find the correct terminating tag.
//
// 2 - The above zt isn't valid: @products is undefined. We could add global
// variables to zt, but that would be implemented through a hashmap which would
// be relatively slow compared to a local variable. So, we want to generate
// code where @products is a local variable:
//
//    var @products = null; // ADDED
//    var html = "";
//    html += '<h2>Products</h2>';
//
// As a pre-compilation step, we need to scan the source and extract all globals.
// (And then we'll do some shenanigans in the VM to load these pseudo-globals
// into the VM's stack before running - that behavior is documented in the vm).
//
// 3 - While we're going to translate the template to valid zt, we'd like errors
// to be somewhat meaningful from the point of view of the template. So we need
// to inject debug information into the zt source, and both the scanner and
// compiler need to be aware of these.