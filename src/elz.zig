const std = @import("std");

const lib = @import("lib.zig");

pub const VM = lib.VM;
pub const Compiler = lib.Compiler;
pub const disassemble = lib.ByteCode.disassemble;

const t = @import("t.zig");

test "elz: arithmetic" {
    try t.expectEqual(9, testSimple("return 1 + 8;").i64);
    try t.expectEqual(-1, testSimple("return 10 - 11;").i64);
    try t.expectEqual(14, testSimple("return 2 * 7;").i64);
    try t.expectEqual(2, testSimple("return 18 / 9;").i64);

    try t.expectEqual(17, testSimple("return 2 + 5 * 3;").i64);
    try t.expectEqual(21, testSimple("return (2 + 5) * 3;").i64);
    try t.expectEqual(13, testSimple("return 2 * 5 + 3;").i64);

    try t.expectEqual(4.5, testSimple("return 1.2 + 3.3;").f64);
    try t.expectEqual(5.3, testSimple("return 2 + 3.3;").f64);
    try t.expectEqual(5.3, testSimple("return 3.3 + 2;").f64);
    try t.expectEqual(1.0, testSimple("return 1.1 - 0.1;").f64);
    try t.expectEqual(-1.2999999999999998, testSimple("return 2 - 3.3;").f64);
    try t.expectEqual(1.2999999999999998, testSimple("return 3.3 - 2;").f64);
    try t.expectEqual(3.9599999999999995, testSimple("return 1.2 * 3.3;").f64);
    try t.expectEqual(20.4, testSimple("return 5.1 * 4;").f64);
    try t.expectEqual(20.4, testSimple("return 4 * 5.1;").f64);
    try t.expectEqual(0.36363636363636365, testSimple("return 1.2 / 3.3;").f64);
    try t.expectEqual(1.275, testSimple("return 5.1 / 4;").f64);
    try t.expectEqual(0.7843137254901962, testSimple("return 4 / 5.1;").f64);
}

test "elz: not" {
    try t.expectEqual(true, testSimple("return !false;").bool);
    try t.expectEqual(false, testSimple("return !true;").bool);
}

test "elz: comparison int" {
    try t.expectEqual(true, testSimple("return 1 == 1;").bool);
    try t.expectEqual(false, testSimple("return 1 == 2;").bool);
    try t.expectEqual(false, testSimple("return 1 != 1;").bool);
    try t.expectEqual(true, testSimple("return 1 != 2;").bool);

    try t.expectEqual(false, testSimple("return 1 > 1;").bool);
    try t.expectEqual(false, testSimple("return 1 > 2;").bool);
    try t.expectEqual(true, testSimple("return 2 > 1;").bool);

    try t.expectEqual(true, testSimple("return 1 >= 1;").bool);
    try t.expectEqual(false, testSimple("return 1 >= 2;").bool);
    try t.expectEqual(true, testSimple("return 2 >= 1;").bool);

    try t.expectEqual(false, testSimple("return 1 < 1;").bool);
    try t.expectEqual(true, testSimple("return 1 < 2;").bool);
    try t.expectEqual(false, testSimple("return 2 < 1;").bool);

    try t.expectEqual(true, testSimple("return 1 <= 1;").bool);
    try t.expectEqual(true, testSimple("return 1 <= 2;").bool);
    try t.expectEqual(false, testSimple("return 2 <= 1;").bool);
}

test "elz: comparison float" {
    try t.expectEqual(true, testSimple("return 1.13 == 1.13;").bool);
    try t.expectEqual(false, testSimple("return 1.13 == 2.08;").bool);
    try t.expectEqual(false, testSimple("return 1.13 != 1.13;").bool);
    try t.expectEqual(true, testSimple("return 1.13 != 2.08;").bool);

    try t.expectEqual(false, testSimple("return 1.13 > 1.13;").bool);
    try t.expectEqual(false, testSimple("return 1.13 > 2.08;").bool);
    try t.expectEqual(true, testSimple("return 2.08 > 1.13;").bool);

    try t.expectEqual(true, testSimple("return 1.13 >= 1.13;").bool);
    try t.expectEqual(false, testSimple("return 1.13 >= 2.08;").bool);
    try t.expectEqual(true, testSimple("return 2.08 >= 1.13;").bool);

    try t.expectEqual(false, testSimple("return 1.13 < 1.13;").bool);
    try t.expectEqual(true, testSimple("return 1.13 < 2.08;").bool);
    try t.expectEqual(false, testSimple("return 2.08 < 1.13;").bool);

    try t.expectEqual(true, testSimple("return 1.13 <= 1.13;").bool);
    try t.expectEqual(true, testSimple("return 1.13 <= 2.08;").bool);
    try t.expectEqual(false, testSimple("return 2.08 <= 1.13;").bool);
}

test "elz: comparison int - float" {
    try t.expectEqual(true, testSimple("return 1 == 1.0;").bool);
    try t.expectEqual(false, testSimple("return 1 == 1.1;").bool);
    try t.expectEqual(false, testSimple("return 1 != 1.0;").bool);
    try t.expectEqual(true, testSimple("return 1 != 1.1;").bool);

    try t.expectEqual(false, testSimple("return 1 > 1.0;").bool);
    try t.expectEqual(false, testSimple("return 1 > 2.0;").bool);
    try t.expectEqual(true, testSimple("return 2 > 1.9;").bool);

    try t.expectEqual(true, testSimple("return 1 >= 1.0;").bool);
    try t.expectEqual(false, testSimple("return 1 >= 2.0;").bool);
    try t.expectEqual(true, testSimple("return 2 >= 1.98;").bool);

    try t.expectEqual(false, testSimple("return 1 < 1.0;").bool);
    try t.expectEqual(true, testSimple("return 1 < 1.01;").bool);
    try t.expectEqual(false, testSimple("return 2 < 1.99;").bool);

    try t.expectEqual(true, testSimple("return 1 <= 1.0;").bool);
    try t.expectEqual(true, testSimple("return 1 <= 1.01;").bool);
    try t.expectEqual(false, testSimple("return 2 <= 1.99;").bool);
}

test "elz: comparison float - int" {
    try t.expectEqual(true, testSimple("return 1.0 == 1;").bool);
    try t.expectEqual(false, testSimple("return 1.1 == 1;").bool);
    try t.expectEqual(false, testSimple("return 1.0 != 1;").bool);
    try t.expectEqual(true, testSimple("return 1.1 != 1;").bool);

    try t.expectEqual(false, testSimple("return 1.0 > 1;").bool);
    try t.expectEqual(false, testSimple("return 1.9 > 2;").bool);
    try t.expectEqual(true, testSimple("return 2.1 > 2;").bool);

    try t.expectEqual(true, testSimple("return 1.0 >= 1;").bool);
    try t.expectEqual(false, testSimple("return 1.9 >= 2;").bool);
    try t.expectEqual(true, testSimple("return 2.1 >= 2;").bool);

    try t.expectEqual(false, testSimple("return 1.0 < 1;").bool);
    try t.expectEqual(true, testSimple("return 0.99 < 1;").bool);
    try t.expectEqual(false, testSimple("return 2.1 < 2;").bool);

    try t.expectEqual(true, testSimple("return 1.0 <= 1;").bool);
    try t.expectEqual(true, testSimple("return 3.99 <= 4;").bool);
    try t.expectEqual(false, testSimple("return 10.1 <= 10;").bool);
}

test "elz: comparison bool" {
    try t.expectEqual(true, testSimple("return true == true;").bool);
    try t.expectEqual(true, testSimple("return false == false;").bool);
    try t.expectEqual(false, testSimple("return true == false;").bool);
    try t.expectEqual(false, testSimple("return false == true;").bool);

    try t.expectEqual(false, testSimple("return true != true;").bool);
    try t.expectEqual(false, testSimple("return false != false;").bool);
    try t.expectEqual(true, testSimple("return true != false;").bool);
    try t.expectEqual(true, testSimple("return false != true;").bool);
}

test "elz: comparison null" {
    try t.expectEqual(true, testSimple("return null == null;").bool);
    try t.expectEqual(false, testSimple("return null != null;").bool);

    try t.expectEqual(false, testSimple("return 0 == null;").bool);
    try t.expectEqual(false, testSimple("return 0.0 == null;").bool);
    try t.expectEqual(false, testSimple("return 1 == null;").bool);
    try t.expectEqual(false, testSimple("return 1.1 == null;").bool);
    try t.expectEqual(false, testSimple("return `` == null;").bool);
    try t.expectEqual(false, testSimple("return `abc` == null;").bool);
    try t.expectEqual(false, testSimple("return true == null;").bool);
    try t.expectEqual(false, testSimple("return false == null;").bool);

    try t.expectEqual(true, testSimple("return 0 != null;").bool);
    try t.expectEqual(true, testSimple("return 0.0 != null;").bool);
    try t.expectEqual(true, testSimple("return 1 != null;").bool);
    try t.expectEqual(true, testSimple("return 1.1 != null;").bool);
    try t.expectEqual(true, testSimple("return `` != null;").bool);
    try t.expectEqual(true, testSimple("return `abc` != null;").bool);
    try t.expectEqual(true, testSimple("return true != null;").bool);
    try t.expectEqual(true, testSimple("return false != null;").bool);
}

test "elz: comparison string" {
    try t.expectEqual(true, testSimple("return `abc` == `abc`;").bool);
    try t.expectEqual(false, testSimple("return `abc` == `123`;").bool);
    try t.expectEqual(false, testSimple("return `abc` == `ABC`;").bool);

    try t.expectEqual(false, testSimple("return `abc` != `abc`;").bool);
    try t.expectEqual(true, testSimple("return `abc` != `123`;").bool);
    try t.expectEqual(true, testSimple("return `abc` != `ABC`;").bool);

    try t.expectEqual(false, testSimple("return `abc` < `abc`;").bool);
    try t.expectEqual(false, testSimple("return `abc` > `abc`;").bool);
    try t.expectEqual(true, testSimple("return `abc` <= `abc`;").bool);
    try t.expectEqual(true, testSimple("return `abc` >= `abc`;").bool);

    try t.expectEqual(false, testSimple("return `abc` < `ABC`;").bool);
    try t.expectEqual(false, testSimple("return `abc` <= `ABC`;").bool);
    try t.expectEqual(true, testSimple("return `ABC` <= `abc`;").bool);
    try t.expectEqual(true, testSimple("return `ABC` <= `abc`;").bool);

    try t.expectEqual(true, testSimple("return `abc` > `ABC`;").bool);
    try t.expectEqual(true, testSimple("return `abc` >= `ABC`;").bool);
    try t.expectEqual(false, testSimple("return `ABC` >= `abc`;").bool);
    try t.expectEqual(false, testSimple("return `ABC` >= `abc`;").bool);
}

test "elz: variables" {
    defer t.reset();

    try t.expectString("Leto", testSimple(
        \\ var name = `Leto`;
        \\ return name;
    ).string);

    try t.expectString("Leto", testSimple(
        \\ var name = `Leto`;
        \\ {
        \\    var name = "Ghanima" ;
        \\ }
        \\ return name;
    ).string);

    try t.expectString("Ghanima", testSimple(
        \\ var name = `Leto`;
        \\ {
        \\    var name = "Ghanima" ;
        \\    return name;
        \\ }
    ).string);
}

fn testSimple(src: []const u8) lib.Value {
    var c = Compiler.init(t.allocator) catch unreachable;
    defer c.deinit();

    c.compile(src) catch |err| {
        std.debug.print("==={any}===\n", .{err});
        if (c.err) |ce| {
            std.debug.print("{any} - {s}\n", .{ ce.err, ce.desc });
        }
        unreachable;
    };

    const byte_code = c.byteCode(t.allocator) catch unreachable;
    defer t.allocator.free(byte_code);
    // disassemble(byte_code, std.io.getStdOut().writer()) catch unreachable;

    var vm = VM.init(t.allocator);
    defer vm.deinit();

    const value = vm.run(byte_code) catch |err| {
        std.debug.print("{any}", .{err});
        if (vm.err) |e| {
            std.debug.print("{any} {s}", .{ e.err, e.desc });
        }
        unreachable;
    };

    // Values are tied to the VM, which this function will deinit
    // We need to dupe our strnig into our testing arena.
    return switch (value) {
        .string => |str| .{.string = t.arena.allocator().dupe(u8, str) catch unreachable},
        else => value,
    };
}