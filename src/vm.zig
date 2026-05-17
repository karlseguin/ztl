const std = @import("std");
const builtin = @import("builtin");

const Value = @import("value.zig").Value;
const KeyValue = @import("value.zig").KeyValue;

const config = @import("config.zig");
const OpCode = @import("byte_code.zig").OpCode;
const VERSION = @import("byte_code.zig").VERSION;

const Allocator = std.mem.Allocator;

const Stack = std.ArrayList(Value);

pub const RefPool = if (builtin.is_test) DebugRefPool else std.heap.MemoryPool(Value.Ref);

pub fn VM(comptime App: type) type {
    const MAX_CALL_FRAMES = config.extract(App, "max_call_frames");
    const REFENCE_COUNTING = config.extract(App, "reference_counting");
    return struct {
        app: App,

        _allocator: Allocator,
        _ref_pool: RefPool,

        _stack: Stack = .empty,
        _globals: Stack = .empty,

        _frames: [MAX_CALL_FRAMES]Frame = undefined,

        err: ?[]const u8 = null,

        const LocalIndex = config.LocalType(App);
        const SL = @sizeOf(LocalIndex);

        const Self = @This();

        // we expect allocator tp be an arena
        pub fn init(allocator: Allocator, app: App) Self {
            return .{
                .app = app,
                ._allocator = allocator,
                ._ref_pool = RefPool.init(allocator),
            };
        }

        // See template.zig's hack around globals to see why we're doing this
        pub fn prepareForGlobals(self: *Self, count: usize) !void {
            return self._globals.appendNTimes(self._allocator, .{.null = {}}, count);
        }

        pub fn injectGlobal(self: *Self, value: Value, i: usize) void {
            self._globals.items[i] = value;
        }

        pub fn run(self: *Self, byte_code: []const u8, writer: anytype) !Value {
            const version = byte_code[0];
            if (version != VERSION) {
                return error.IncompatibleVersion;
            }

            var ip = byte_code.ptr;
            const code_end = 9 + @as(u32, @bitCast(ip[1..5].*));

            if (code_end == 9) {
                return .{ .null = {} };
            }

            const code = byte_code[9..code_end];
            const data = byte_code[code_end..];

            // goto to the main script
            ip += 9 + @as(u32, @bitCast(ip[5..9].*));

            const ref_pool = &self._ref_pool;
            const allocator = self._allocator;

            errdefer if (comptime builtin.is_test) {
                // we can skip doing this in non-test since our pool_ref
                // is an arena which will all get cleaned up when pool_ref.deinit()
                // is called. But, during tests, since we do our own reference
                // tracking, we need this cleanup during error cases (only during
                // error cases, because during non-error cases, this should all
                // get cleaned up naturally)
                for (self._stack.items) |value| {
                    self.release(value);
                }
            };

            var frames = &self._frames;
            frames[0] = .{
                .ip = ip,
                .frame_pointer = 0,
            };
            var frame_count: usize = 0;

            var stack = &self._stack;
            var globals = &self._globals;
            var frame_pointer: usize = 0;


            while (true) {
                const op_code: OpCode = @enumFromInt(ip[0]);
                ip += 1;
                switch (op_code) {
                    .POP => {
                        const count = ip[0];
                        ip += 1;
                        self.releaseCount(stack, count);
                    },
                    .PUSH => {
                        const value = stack.getLast();
                        self.acquire(value);
                        try stack.append(allocator, value);
                    },
                    .OUTPUT => {
                        var value = stack.pop().?;
                        try value.write(writer, false);
                        self.release(value);
                    },
                    .OUTPUT_ESCAPE => {
                        var value = stack.pop().?;
                        try value.write(writer, true);
                        self.release(value);
                    },
                    .CONSTANT_I64 => {
                        const value = @as(i64, @bitCast(ip[0..8].*));
                        try stack.append(allocator, .{ .i64 = value });
                        ip += 8;
                    },
                    .CONSTANT_F64 => {
                        const value = @as(f64, @bitCast(ip[0..8].*));
                        try stack.append(allocator, .{ .f64 = value });
                        ip += 8;
                    },
                    .CONSTANT_BOOL => {
                        try stack.append(allocator, .{ .bool = ip[0] == 1 });
                        ip += 1;
                    },
                    .CONSTANT_STRING => {
                        const data_start = @as(u32, @bitCast(ip[0..4].*));
                        ip += 4;

                        const string_start = data_start + 4;
                        const string_end = @as(u32, @bitCast(data[data_start..string_start][0..4].*));
                        try stack.append(allocator, .{ .string = data[string_start..string_end] });
                    },
                    .CONSTANT_NULL => {
                        try stack.append(allocator, .{ .null = {} });
                    },
                    .GET_GLOBAL => {
                        const idx = if (comptime SL == 1) ip[0] else @as(u16, @bitCast(ip[0..2].*));
                        const value = globals.items[idx];
                        self.acquire(value);
                        // GET_GLOBAL pushes the global onto the stack
                        try stack.append(allocator, value);
                        ip += SL;
                    },
                    .SET_GLOBAL => {
                        const idx = if (comptime SL == 1) ip[0] else @as(u16, @bitCast(ip[0..2].*));
                        const current = &globals.items[idx];
                        self.release(current.*);
                        // SET_GLOBAL takes the value off the stack
                        current.* = stack.getLast();
                        self.acquire(current.*);
                        ip += SL;
                    },
                    .INCR_GLOBAL => {
                        const incr: i64 = if (ip[0] == 0) -1 else ip[0];
                        ip += 1;

                        const idx = if (comptime SL == 1) ip[0] else @as(u16, @bitCast(ip[0..2].*));
                        ip += SL;

                        const v = try self.add(globals.items[idx], .{ .i64 = incr });
                        try stack.append(allocator, v);
                        globals.items[idx] = v;
                    },
                    .GET_LOCAL => {
                        const idx = if (comptime SL == 1) ip[0] else @as(u16, @bitCast(ip[0..2].*));
                        const value = stack.items[frame_pointer + idx];
                        self.acquire(value);
                        try stack.append(allocator, value);
                        ip += SL;
                    },
                    .SET_LOCAL => {
                        const idx = if (comptime SL == 1) ip[0] else @as(u16, @bitCast(ip[0..2].*));
                        const current = &stack.items[frame_pointer + idx];
                        self.release(current.*);
                        current.* = stack.getLast();
                        self.acquire(current.*);
                        ip += SL;
                    },
                    .INCR_LOCAL => {
                        const incr: i64 = if (ip[0] == 0) -1 else ip[0];
                        ip += 1;

                        const idx = if (comptime SL == 1) ip[0] else @as(u16, @bitCast(ip[0..2].*));
                        ip += SL;

                        const adjusted_idx = frame_pointer + idx;
                        const v = try self.add(stack.items[adjusted_idx], .{ .i64 = incr });
                        try stack.append(allocator, v);
                        stack.items[adjusted_idx] = v;
                    },
                    .ADD => try self.arithmetic(stack, &add),
                    .SUBTRACT => try self.arithmetic(stack, &subtract),
                    .MULTIPLY => try self.arithmetic(stack, &multiply),
                    .DIVIDE => try self.arithmetic(stack, &divide),
                    .MODULUS => try self.arithmetic(stack, &modulus),
                    .NEGATE => {
                        var v = &stack.items[stack.items.len - 1];
                        switch (v.*) {
                            .i64 => |n| v.i64 = -n,
                            .f64 => |n| v.f64 = -n,
                            else => {
                                try self.setErrorFmt("Cannot negate non-numeric value: -{f}", .{v.*});
                                return error.TypeError;
                            },
                        }
                    },
                    .NOT => {
                        var v = &stack.items[stack.items.len - 1];
                        switch (v.*) {
                            .bool => |b| v.bool = !b,
                            else => {
                                try self.setErrorFmt("Cannot inverse non-boolean value: !{f}", .{v.*});
                                return error.TypeError;
                            },
                        }
                    },
                    .EQUAL => try self.comparison(stack, &equal),
                    .GREATER => try self.comparison(stack, &greater),
                    .LESSER => try self.comparison(stack, &lesser),
                    .FOREACH => {
                        const value_count = ip[0];
                        ip += 1;

                        // * 2 because we're going to be holding both the iterator and the value being iterated in
                        // + 1 for the true/false we inject after every FOREACH_ITERATE
                        try stack.ensureUnusedCapacity(allocator, (2 * value_count) + 1);

                        var items = stack.items;

                        const len = items.len;
                        const iterator_start = len - value_count;
                        for (items[iterator_start..len]) |*value| {
                            value.* = try self.toIterator(ref_pool, value.*);
                        }

                        // The first thing our FOREACH_ITERATE is going to do is
                        // pop off the values. On the first iteration, this makes
                        // no sense, but on subsequent iteration, we need to remove
                        // the previous iteration values.
                        // We could do this more cleanly by having the compiler
                        // issue a POP for each variable. But this is faster.
                        for (0..value_count) |_| {
                            stack.appendAssumeCapacity(.{ .null = {} });
                        }

                        // Above, we store the iterator in the stack where the value
                        // being iterated was. This keeps our stack neat, and aligns
                        // with the indexes our compiler generates, but it means that
                        // when we pop off the scope of the foreach, we'll only be
                        // popping off the iterators, and not the values that they replaced.
                        // For this reasons, our iterators have a reference to their underlying
                        // Value.REf, and when they are popped off, they also derefence the
                        // underlying value.s
                    },
                    .FOREACH_ITERATE => {
                        const value_count = ip[0];
                        ip += 1;

                        var items = stack.items;
                        const len = items.len;

                        const iterator_start = items.len - value_count;
                        ITERATE: for (items[iterator_start..len]) |it| {
                            const value = (try iterateNext(ref_pool, it.ref)) orelse {
                                stack.appendAssumeCapacity(.{ .bool = false });
                                break :ITERATE;
                            };
                            stack.appendAssumeCapacity(value);
                        } else {
                            stack.appendAssumeCapacity(.{ .bool = true });
                        }
                    },
                    .JUMP => {
                        // really??
                        const relative: i16 = @bitCast(ip[0..2].*);
                        std.debug.assert(@abs(relative) <= code.len);
                        if (relative >= 0) {
                            ip += @intCast(relative);
                        } else {
                            ip = ip - @abs(relative);
                        }
                    },
                    .JUMP_IF_FALSE, .JUMP_IF_FALSE_POP => {
                        if (stack.items[stack.items.len - 1].isTrue()) {
                            // just skip the jump address
                            ip += 2;
                        } else {
                            const relative: i16 = @bitCast(ip[0..2].*);
                            std.debug.assert(@abs(relative) <= code.len);

                            // really??
                            if (relative >= 0) {
                                ip += @intCast(relative);
                            } else {
                                ip = ip - @abs(relative);
                            }
                        }
                        if (op_code == .JUMP_IF_FALSE_POP) {
                            // pop the condition result (true/false) off the stack
                            self.release(stack.pop().?);
                        }
                    },
                    .INITIALIZE => {
                        const initialize_type: OpCode.Initialize = @enumFromInt(ip[0]);
                        ip += 1;
                        switch (initialize_type) {
                            .ARRAY => {
                                const value_count: u32 = @bitCast(ip[0..4].*);
                                ip += 4;

                                var ref = try ref_pool.create();
                                ref.* = .{ .value = .{ .list = .empty } };
                                var list = &ref.value.list;

                                if (value_count == 0) {
                                    try stack.append(allocator, .{ .ref = ref });
                                } else {
                                    std.debug.assert(stack.items.len >= value_count);
                                    try list.ensureTotalCapacity(allocator, value_count);

                                    var items = stack.items;
                                    for (items[items.len - value_count ..]) |v| {
                                        list.appendAssumeCapacity(v);
                                    }
                                    stack.items.len = items.len - value_count;
                                    // we popped at least 1 value off the stack, there
                                    // has to be space for our array
                                    stack.appendAssumeCapacity(.{ .ref = ref });
                                }
                            },
                            .MAP => {
                                const entry_count: u32 = @bitCast(ip[0..4].*);
                                ip += 4;

                                var ref = try ref_pool.create();
                                ref.* = .{ .value = .{ .map = .{} } };
                                var map = &ref.value.map;

                                if (entry_count == 0) {
                                    try stack.append(allocator, .{ .ref = ref });
                                } else {
                                    // * 2 since every entry is made up of a key and a value
                                    std.debug.assert(stack.items.len >= entry_count * 2);

                                    try map.ensureTotalCapacity(allocator, entry_count);

                                    const items = stack.items;
                                    const first_index = items.len - entry_count * 2;

                                    var i = first_index;
                                    while (i < items.len) {
                                        const key: KeyValue = switch (items[i]) {
                                            .i64 => |v| .{ .i64 = v },
                                            .string => |v| .{ .string = v },
                                            else => return error.InvalidKeyType,
                                        };
                                        map.putAssumeCapacity(key, items[i + 1]);
                                        i += 2;
                                    }
                                    stack.items.len = first_index;
                                    // we popped at least 2 values off the stack, there
                                    // has to be space for our map
                                    stack.appendAssumeCapacity(.{ .ref = ref });
                                }
                            },
                        }
                    },
                    .INDEX_GET => {
                        var values = stack.items;

                        const l = values.len;
                        std.debug.assert(l >= 2);

                        const last_value_index = l - 1;

                        const target = values[l - 2];

                        // replace the array/map with whatever we got
                        const result = try self.getIndexed(ref_pool, target, values[last_value_index]);
                        self.acquire(result);
                        self.release(target);
                        values[l - 2] = result;
                        stack.items.len = last_value_index;
                    },
                    .INDEX_SET => {
                        const values = stack.items;
                        const l = values.len;
                        std.debug.assert(l >= 3);

                        const target = values[l - 3];
                        const index = values[l - 2];
                        const value = values[l - 1];
                        // replace the array with whatever we got
                        try self.setIndexed(allocator, target, index, value);
                        stack.items.len = l - 2;
                    },
                    .PROPERTY_GET => {
                        const property: Property = @enumFromInt(@as(u16, @bitCast(ip[0..2].*)));
                        ip += 2;
                        const last = &stack.items[stack.items.len - 1];
                        const target = last.*;
                        last.* = try self.getProperty(target, property);
                        self.release(target);
                    },
                    .METHOD => {
                        const arity = ip[0];
                        ip += 1;

                        const method: Method = @enumFromInt(@as(u16, @bitCast(ip[0..2].*)));
                        ip += 2;

                        var values = stack.items;

                        const l = values.len;
                        // +1 for the target itself
                        std.debug.assert(l >= arity + 1);

                        const args_start = l - arity;
                        const target_index = args_start - 1;

                        const slot = &values[target_index];
                        const target = slot.*;
                        const value = try self.callMethod(allocator, target, method, values[args_start..]);
                        self.acquire(value);
                        slot.* = value;
                        self.release(target);
                        self.releaseCount(stack, arity);
                    },
                    .INCR_REF => {
                        const values = stack.items;
                        const l = values.len;
                        std.debug.assert(l >= 3);

                        const target = values[l - 3];
                        const index = values[l - 2];
                        const incr = values[l - 1];
                        values[l - 3] = try self.incrementIndexed(target, index, incr);
                        self.release(target);
                        stack.items.len = l - 2;
                    },
                    .CALL => {
                        const data_start = @as(u32, @bitCast(ip[0..4].*));
                        ip += 4;

                        const meta = data[data_start .. data_start + 5];

                        const arity = meta[0];
                        const code_pos = @as(u32, @bitCast(meta[1..5][0..4].*));

                        // Capture the state of our current frame. This is what
                        // we'll return to.
                        frames[frame_count].ip = ip;

                        // jump to the function code
                        ip = code[code_pos..].ptr;

                        // adjust our frame pointer
                        frame_pointer = stack.items.len - arity;

                        // Push a new frame. This is the functiont that we're
                        // going to be executing.
                        frame_count += 1;

                        if (frame_count == frames.len) {
                            try self.setErrorFmt("Maximum call depth ({d}) reached", .{frames.len});
                            return error.StackOverflow;
                        }

                        frames[frame_count] = .{
                            .ip = ip,
                            .frame_pointer = frame_pointer,
                        };
                    },
                    .CALL_ZIG => {
                        if (std.meta.hasMethod(App, "call") == false) {
                            self.setError(@typeName(App) ++ "has no 'call' method");
                            return error.UsageError;
                        }
                        const arity = ip[0];
                        ip += 1;

                        const function_id = @as(u16, @bitCast(ip[0..2].*));
                        ip += 2;

                        const result = try self.app.call(self, @enumFromInt(function_id), stack.items[stack.items.len - arity ..]);
                        self.releaseCount(stack, arity);
                        try stack.append(allocator, result);
                    },
                    .PRINT => {
                        const arity = ip[0];
                        ip += 1;

                        if (arity > 0) {
                            var items = stack.items;
                            std.debug.assert(items.len >= arity);
                            const start_index = items.len - arity;

                            {
                                var stderr_lock = std.debug.lockStderr(&.{});
                                defer std.debug.unlockStderr();

                                const stderr = stderr_lock.terminal().writer;
                                try items[start_index].write(stderr, false);
                                for (items[start_index + 1 ..]) |value| {
                                    try stderr.writeAll(" ");
                                    try value.write(stderr, false);
                                }
                                try stderr.writeAll("\n");
                            }
                            self.releaseCount(stack, arity);
                        }
                    },
                    .RETURN => {
                        const value: Value = blk: {
                            if (stack.items.len == 0) {
                                break :blk .{ .null = {} };
                            }

                            const v = stack.pop().?;
                            self.releaseCount(stack, stack.items.len);
                            break :blk v;
                        };

                        if (frame_count == 0) {
                            return value;
                        }
                        stack.items.len = frames[frame_count].frame_pointer;

                        frame_count -= 1;
                        const frame = frames[frame_count];
                        ip = frame.ip;
                        frame_pointer = frame.frame_pointer;
                        try stack.append(allocator, value);
                    },
                    .DEBUG => {
                        // debug information always contains a 2 byte length
                        // prefix (including the lenght prefix itself) to make
                        // it quick for the VM to skip.
                        ip += @as(u16, @bitCast(ip[0..2].*));
                    },
                }
            }
        }

        const ArithmeticError = error{
            TypeError,
            OutOfMemory,
        };

        const AddError = ArithmeticError || error{OutOfMemory};

        fn arithmetic(self: *Self, stack: *Stack, operation: *const fn (self: *Self, left: Value, right: Value) ArithmeticError!Value) !void {
            var values = stack.items;
            std.debug.assert(values.len >= 2);
            const right_index = values.len - 1;

            const left_index = right_index - 1;
            values[left_index] = try operation(self, values[left_index], values[right_index]);
            // TODO: release if we can do arithmetics on any ref values
            stack.items.len = right_index;
        }

        fn add(self: *Self, left: Value, right: Value) AddError!Value {
            switch (left) {
                .i64 => |l| switch (right) {
                    .i64 => |r| return .{ .i64 = l + r },
                    .f64 => |r| return .{ .f64 = @as(f64, @floatFromInt(l)) + r },
                    else => {},
                },
                .f64 => |l| switch (right) {
                    .f64 => |r| return .{ .f64 = l + r },
                    .i64 => |r| return .{ .f64 = l + @as(f64, @floatFromInt(r)) },
                    else => {},
                },
                .string => |l| {
                    var buffer: Value.Buffer = .empty;
                    try buffer.appendSlice(self._allocator, l);
                    {
                        var aw: std.Io.Writer.Allocating = .fromArrayList(self._allocator, &buffer);
                        defer buffer = aw.toArrayList();
                        right.write(&aw.writer, false) catch |err| switch (err) {
                            error.WriteFailed => return error.OutOfMemory, // See ArrayList.print
                        };
                    }

                    const buffer_ref = try self.createRef();
                    buffer_ref.* = .{ .count = 1, .value = .{ .buffer = buffer } };
                    return .{ .ref = buffer_ref };
                },
                else => {
                    const allocator = self._allocator;
                    if (left == .ref and left.ref.value == .buffer) {
                        {
                            var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &left.ref.value.buffer);
                            defer left.ref.value.buffer = aw.toArrayList();
                            right.write(&aw.writer, false) catch |err| switch (err) {
                                error.WriteFailed => return error.OutOfMemory, // See ArrayList.print
                            };
                        }
                        return left;
                    }
                    switch (right) {
                        .string => |r| {
                            var buffer: Value.Buffer = .empty;
                            {
                                var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
                                defer buffer = aw.toArrayList();
                                left.write(&aw.writer, false) catch |err| switch (err) {
                                    error.WriteFailed => return error.OutOfMemory, // See ArrayList.print
                                };
                            }
                            try buffer.appendSlice(allocator, r);

                            const buffer_ref = try self.createRef();
                            buffer_ref.* = .{ .count = 1, .value = .{ .buffer = buffer } };
                            return .{ .ref = buffer_ref };
                        },
                        .ref => |ref| switch (ref.value) {
                            .buffer => |r| {
                                var buffer: Value.Buffer = .empty;
                                {
                                    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
                                    defer buffer = aw.toArrayList();
                                    left.write(&aw.writer, false) catch |err| switch (err) {
                                        error.WriteFailed => return error.OutOfMemory, // See ArrayList.print
                                    };
                                }
                                try buffer.appendSlice(allocator, r.items);
                                self.releaseRef(ref);

                                const buffer_ref = try self.createRef();
                                buffer_ref.* = .{ .count = 1, .value = .{ .buffer = buffer } };
                                return .{ .ref = buffer_ref };
                            },
                            else => {},
                        },
                        else => {},
                    }
                },
            }
            try self.setErrorFmt("Cannot add non-numeric value: {f} + {f}", .{ left, right });
            return error.TypeError;
        }

        fn subtract(self: *Self, left: Value, right: Value) ArithmeticError!Value {
            switch (left) {
                .i64 => |l| switch (right) {
                    .i64 => |r| return .{ .i64 = l - r },
                    .f64 => |r| return .{ .f64 = @as(f64, @floatFromInt(l)) - r },
                    else => {},
                },
                .f64 => |l| switch (right) {
                    .f64 => |r| return .{ .f64 = l - r },
                    .i64 => |r| return .{ .f64 = l - @as(f64, @floatFromInt(r)) },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot subtract non-numeric value: {f} - {f}", .{ left, right });
            return error.TypeError;
        }

        fn multiply(self: *Self, left: Value, right: Value) ArithmeticError!Value {
            switch (left) {
                .i64 => |l| switch (right) {
                    .i64 => |r| return .{ .i64 = l * r },
                    .f64 => |r| return .{ .f64 = @as(f64, @floatFromInt(l)) * r },
                    else => {},
                },
                .f64 => |l| switch (right) {
                    .f64 => |r| return .{ .f64 = l * r },
                    .i64 => |r| return .{ .f64 = l * @as(f64, @floatFromInt(r)) },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot multiply non-numeric value: {f} - {f}", .{ left, right });
            return error.TypeError;
        }

        fn divide(self: *Self, left: Value, right: Value) ArithmeticError!Value {
            switch (left) {
                .i64 => |l| switch (right) {
                    .i64 => |r| return .{ .i64 = @divTrunc(l, r) },
                    .f64 => |r| return .{ .f64 = @as(f64, @floatFromInt(l)) / r },
                    else => {},
                },
                .f64 => |l| switch (right) {
                    .f64 => |r| return .{ .f64 = l / r },
                    .i64 => |r| return .{ .f64 = l / @as(f64, @floatFromInt(r)) },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot divide non-numeric value: {f} - {f}", .{ left, right });
            return error.TypeError;
        }

        fn modulus(self: *Self, left: Value, right: Value) ArithmeticError!Value {
            switch (left) {
                .i64 => |l| switch (right) {
                    .i64 => |r| return .{ .i64 = @mod(l, r) },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot take remainder of non-integer value: {f} - {f}", .{ left, right });
            return error.TypeError;
        }

        const ComparisonError = error{
            TypeError,
            OutOfMemory,
        };
        fn comparison(self: *Self, stack: *Stack, operation: *const fn (self: *Self, left: Value, right: Value) ComparisonError!bool) !void {
            var values = stack.items;

            const right_index = values.len - 1;
            std.debug.assert(right_index >= 1);

            const left_index = right_index - 1;

            const left = values[left_index];
            const right = values[right_index];
            const result = try operation(self, left, right);
            values[left_index] = .{ .bool = result };

            self.release(left);
            self.release(right);

            stack.items.len = right_index;
        }

        fn equal(self: *Self, left: Value, right: Value) ComparisonError!bool {
            return left.equal(right) catch {
                try self.setErrorFmt("Incompatible type comparison: {f} == {f} ({s}, {s})", .{ left, right, left.friendlyName(), right.friendlyName() });
                return error.TypeError;
            };
        }

        fn greater(self: *Self, left: Value, right: Value) ComparisonError!bool {
            switch (left) {
                .f64 => |l| switch (right) {
                    .f64 => |r| return l > r,
                    .i64 => |r| return l > @as(f64, @floatFromInt(r)),
                    else => {},
                },
                .i64 => |l| switch (right) {
                    .i64 => |r| return l > r,
                    .f64 => |r| return @as(f64, @floatFromInt(l)) > r,
                    else => {},
                },
                .string => |l| switch (right) {
                    .string => |r| return std.mem.order(u8, l, r) == .gt,
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Incompatible type comparison: {f} > {f} ({s}, {s})", .{ left, right, left.friendlyName(), right.friendlyName() });
            return error.TypeError;
        }

        fn lesser(self: *Self, left: Value, right: Value) ComparisonError!bool {
            switch (left) {
                .f64 => |l| switch (right) {
                    .f64 => |r| return l < r,
                    .i64 => |r| return l < @as(f64, @floatFromInt(r)),
                    else => {},
                },
                .i64 => |l| switch (right) {
                    .i64 => |r| return l < r,
                    .f64 => |r| return @as(f64, @floatFromInt(l)) < r,
                    else => {},
                },
                .string => |l| switch (right) {
                    .string => |r| return std.mem.order(u8, l, r) == .lt,
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Incompatible type comparison: {f} < {f} ({s}, {s})", .{ left, right, left.friendlyName(), right.friendlyName() });
            return error.TypeError;
        }

        fn getIndexed(self: *Self, ref_pool: *RefPool, target: Value, index: Value) !Value {
            switch (index) {
                .i64 => |n| return self.getNumericIndex(ref_pool, target, n),
                .string => |n| return self.getStringIndex(target, n),
                else => {},
            }
            try self.setErrorFmt("Invalid index or property type, got {s}", .{index.friendlyArticleName()});
            return error.TypeError;
        }

        fn getNumericIndex(self: *Self, ref_pool: *RefPool, target: Value, index: i64) !Value {
            _ = ref_pool;
            switch (target) {
                .string => |str| {
                    const actual_index = try self.resolveScalarIndex(str.len, index);
                    return .{ .string = str[actual_index .. actual_index + 1] };
                },
                .ref => |ref| switch (ref.value) {
                    .list => |list| return list.items[try self.resolveScalarIndex(list.items.len, index)],
                    .map => |map| return map.get(.{ .i64 = index }) orelse .{ .null = {} },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot index {s}", .{target.friendlyArticleName()});
            return error.TypeError;
        }

        fn getStringIndex(self: *Self, target: Value, index: []const u8) !Value {
            switch (target) {
                .ref => |ref| switch (ref.value) {
                    .map => |map| return map.get(.{ .string = index }) orelse .{ .null = {} },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot index {s} with a string key", .{target.friendlyArticleName()});
            return error.TypeError;
        }

        fn setIndexed(self: *Self, allocator: Allocator, target: Value, index: Value, value: Value) !void {
            switch (index) {
                .i64 => |n| return self.setNumericIndex(allocator, target, n, value),
                .string => |n| return self.setStringIndex(allocator, target, n, value),
                else => {},
            }
            try self.setErrorFmt("Invalid index or property type, got {s}", .{index.friendlyArticleName()});
            return error.TypeError;
        }

        fn setNumericIndex(self: *Self, allocator: Allocator, target: Value, index: i64, value: Value) !void {
            switch (target) {
                .ref => |ref| switch (ref.value) {
                    .list => |*list| {
                        const len = list.items.len;
                        const actual_index = try self.resolveScalarIndex(len, index);
                        const slot = &list.items[actual_index];
                        self.release(slot.*);
                        slot.* = value;
                        return;
                    },
                    .map => |*map| return self.setMapIndex(allocator, map, .{ .i64 = index }, value),
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot index {s}", .{target.friendlyArticleName()});
            return error.TypeError;
        }

        fn setStringIndex(self: *Self, allocator: Allocator, target: Value, index: []const u8, value: Value) !void {
            switch (target) {
                .ref => |ref| switch (ref.value) {
                    .map => |*map| return self.setMapIndex(allocator, map, .{ .string = index }, value),
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot index {s} with a string key", .{target.friendlyArticleName()});
            return error.TypeError;
        }

        fn setMapIndex(self: *Self, allocator: Allocator, map: *Value.Map, key: KeyValue, value: Value) !void {
            const gop = try map.getOrPut(allocator, key);
            if (gop.found_existing) {
                self.release(gop.value_ptr.*);
            }
            gop.value_ptr.* = value;
        }

        fn incrementIndexed(self: *Self, target: Value, index: Value, incr: Value) !Value {
            switch (index) {
                .i64 => |n| return self.incrementNumericIndexed(target, n, incr),
                .string => |n| return self.incrementStringIndexed(target, n, incr),
                else => {},
            }
            try self.setErrorFmt("Invalid index or property type, got {s}", .{index.friendlyArticleName()});
            return error.TypeError;
        }

        fn incrementNumericIndexed(self: *Self, target: Value, index: i64, incr: Value) !Value {
            switch (target) {
                .ref => |ref| switch (ref.value) {
                    .list => |*list| {
                        const len = list.items.len;
                        const actual_index = try self.resolveScalarIndex(len, index);
                        const value = list.items[actual_index];
                        const result = try self.add(value, incr);
                        list.items[actual_index] = result;
                        return result;
                    },
                    .map => |*map| {
                        const value = map.getPtr(.{ .i64 = index }) orelse {
                            try self.setErrorFmt("Map does not contain key '{d}'", .{index});
                            return error.MissingKey;
                        };
                        value.* = try self.add(value.*, incr);
                        return value.*;
                    },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot index {s}", .{target.friendlyArticleName()});
            return error.TypeError;
        }

        fn incrementStringIndexed(self: *Self, target: Value, index: []const u8, incr: Value) !Value {
            switch (target) {
                .ref => |ref| switch (ref.value) {
                    .map => |*map| {
                        const value = map.getPtr(.{ .string = index }) orelse {
                            try self.setErrorFmt("Map does not contain key '{s}'", .{index});
                            return error.MissingKey;
                        };
                        value.* = try self.add(value.*, incr);
                        return value.*;
                    },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot index {s} with a string key", .{target.friendlyArticleName()});
            return error.TypeError;
        }

        fn resolveScalarIndex(self: *Self, len: usize, index: i64) !usize {
            if (index >= 0) {
                if (index >= len) {
                    try self.setErrorFmt("Index out of range. Index: {d}, Len: {d}", .{ index, len });
                    return error.OutOfRange;
                }
                return @intCast(index);
            }

            // index is negative
            const abs_index = @as(i64, @intCast(len)) + index;
            if (abs_index < 0) {
                try self.setErrorFmt("Index out of range. Index: {d}, Len: {d}", .{ index, len });
                return error.OutOfRange;
            }
            return @intCast(abs_index);
        }

        fn getProperty(self: *Self, target: Value, prop: Property) !Value {
            switch (target) {
                .ref => |ref| switch (ref.value) {
                    .list => |list| switch (prop) {
                        .LEN => return .{ .i64 = @intCast(list.items.len) },
                        else => {},
                    },
                    .map => |map| switch (prop) {
                        .LEN => return .{ .i64 = @intCast(map.count()) },
                        else => {},
                    },
                    .map_entry => |kv| switch (prop) {
                        .KEY => return kv.key_ptr.toValue(),
                        .VALUE => return kv.value_ptr.*,
                        else => {},
                    },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Unknown property '{s}' for {s}", .{ prop.name(), target.friendlyArticleName() });
            return error.TypeError;
        }

        fn callMethod(self: *Self, allocator: Allocator, target: Value, method: Method, args: []Value) !Value {
            if (method == .TO_STRING) {
                if (target == .string) {
                    return target;
                }
                if (target == .ref and target.ref.value == .buffer) {
                    return target;
                }
                var buffer: Value.Buffer = .empty;
                {
                    var aw: std.Io.Writer.Allocating = .fromArrayList(self._allocator, &buffer);
                    defer buffer = aw.toArrayList();
                    target.write(&aw.writer, false) catch |err| switch (err) {
                        error.WriteFailed => return error.OutOfMemory, // See ArrayList.print
                    };
                }

                const buffer_ref = try self.createRef();
                buffer_ref.* = .{ .count = 0, .value = .{ .buffer = buffer } };
                return .{ .ref = buffer_ref };
            }

            switch (target) {
                .ref => |ref| switch (ref.value) {
                    .list => |*list| switch (method) {
                        .POP => return list.pop() orelse .{ .null = {} },
                        .LAST => return list.getLastOrNull() orelse .{ .null = {} },
                        .FIRST => {
                            if (list.items.len == 0) {
                                return .{ .null = {} };
                            }
                            return list.items[0];
                        },
                        .APPEND => {
                            const value = args[0];
                            self.acquire(value);
                            try list.append(allocator, value);
                            return target;
                        },
                        .REMOVE => {
                            const index = listIndexOf(list, args[0]) orelse return .{ .bool = false };
                            self.release(list.orderedRemove(index));
                            return .{ .bool = true };
                        },
                        .REMOVE_AT => {
                            const value = args[0];
                            if (value != .i64) {
                                try self.setErrorFmt("list.removeAt index must be an integer, got {s}", .{value.friendlyArticleName()});
                                return error.TypeError;
                            }
                            const index = try self.resolveScalarIndex(list.items.len, value.i64);
                            return list.orderedRemove(@intCast(index));
                        },
                        .CONTAINS => return .{ .bool = listIndexOf(list, args[0]) != null },
                        .INDEX_OF => {
                            const index = listIndexOf(list, args[0]) orelse return .{ .null = {} };
                            return .{ .i64 = @intCast(index) };
                        },
                        .SORT => {
                            std.mem.sort(Value, list.items, {}, struct {
                                fn lessThan(_: void, lhs: Value, rhs: Value) bool {
                                    return lhs.order(rhs) == .lt;
                                }
                            }.lessThan);
                            return target;
                        },
                        .CONCAT => {
                            const value = args[0];
                            switch (value) {
                                .ref => |oref| switch (oref.value) {
                                    .list => |o| {
                                        try list.ensureUnusedCapacity(allocator, o.items.len);
                                        for (o.items) |v| {
                                            self.acquire(v);
                                            list.appendAssumeCapacity(v);
                                        }
                                    },
                                    else => {
                                        self.acquire(value);
                                        try list.append(allocator, value);
                                    },
                                },
                                else => try list.append(allocator, value),
                            }
                            return target;
                        },
                        .TO_STRING => unreachable,
                    },
                    .map => |*map| switch (method) {
                        .REMOVE => {
                            const key = try self.valueToMapKey(args[0]);
                            if (map.fetchSwapRemove(key)) |kv| {
                                return kv.value;
                            }
                            return .{ .null = {} };
                        },
                        .CONTAINS => {
                            const key = try self.valueToMapKey(args[0]);
                            return .{ .bool = map.contains(key) };
                        },
                        .TO_STRING => unreachable,
                        else => {},
                    },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Unknown method '{s}' for {s}", .{ method.name(), target.friendlyArticleName() });
            return error.TypeError;
        }

        fn toIterator(self: *Self, ref_pool: *RefPool, value: Value) !Value {
            switch (value) {
                .ref => |ref| switch (ref.value) {
                    .list => |*list| {
                        const new_ref = try ref_pool.create();
                        new_ref.* = .{ .value = .{ .list_iterator = .{ .index = 0, .list = list, .ref = ref } } };
                        return .{ .ref = new_ref };
                    },
                    .map => |map| {
                        const new_ref = try ref_pool.create();
                        new_ref.* = .{ .value = .{ .map_iterator = .{ .inner = map.iterator(), .ref = ref } } };
                        return .{ .ref = new_ref };
                    },
                    else => {},
                },
                else => {},
            }
            try self.setErrorFmt("Cannot iterate over {s}", .{value.friendlyArticleName()});
            return error.TypeError;
        }

        fn iterateNext(ref_pool: *RefPool, ref: *Value.Ref) !?Value {
            switch (ref.value) {
                .list_iterator => |*it| {
                    const index = it.index;
                    const items = it.list.items;
                    if (index == items.len) {
                        return null;
                    }
                    it.index = index + 1;
                    return items[index];
                },
                .map_iterator => |*it| {
                    const entry = it.inner.next() orelse return null;
                    const new_ref = try ref_pool.create();
                    new_ref.* = .{ .value = .{ .map_entry = entry } };
                    return .{ .ref = new_ref };
                },
                else => unreachable,
            }
        }

        fn setErrorFmt(self: *Self, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
            self.err = try std.fmt.allocPrint(self._allocator, fmt, args);
        }

        fn setError(self: *Self, desc: []const u8) void {
            self.err = desc;
        }

        pub fn createRef(self: *Self) !*Value.Ref {
            return self._ref_pool.create();
        }

        pub fn acquire(_: *const Self, value: Value) void {
            if (comptime REFENCE_COUNTING == .none) {
                return;
            }

            switch (value) {
                .ref => |ref| ref.count += 1,
                else => {},
            }
        }

        pub fn release(self: *Self, value: Value) void {
            if (comptime REFENCE_COUNTING == .none) {
                return;
            }

            if (value != .ref) {
                return;
            }
            self.releaseRef(value.ref);
        }

        fn releaseCount(self: *Self, stack: *Stack, n: usize) void {

            const items = stack.items;
            const current_len = items.len;
            std.debug.assert(current_len >= n);
            const release_start = current_len - n;

            if (comptime REFENCE_COUNTING != .none) {
                for (items[release_start..]) |value| {
                    self.release(value);
                }
            }

            stack.items.len = release_start;
        }

        fn releaseRef(self: *Self, ref: *Value.Ref) void {
            if (comptime REFENCE_COUNTING == .none) {
                return;
            }

            const count = ref.count;
            if (count > 1) {
                ref.count = count - 1;
                return;
            }

            switch (ref.value) {
                .map_iterator => |it| self.releaseRef(it.ref),
                .list_iterator => |it| self.releaseRef(it.ref),
                .list => |*list| {
                    if (comptime REFENCE_COUNTING == .strict) {
                        for (list.items) |value| {
                            self.release(value);
                        }

                    }
                    list.deinit(self._allocator);
                },
                .map => |*map| {
                    if (comptime REFENCE_COUNTING == .strict) {
                        for (map.values()) |value| {
                            self.release(value);
                        }
                    }
                    map.deinit(self._allocator);
                },
                .buffer => |*buf| buf.deinit(self._allocator),
                else => {},
            }
            self._ref_pool.destroy(ref);
        }

        pub fn createValue(self: *Self, zig: anytype) !Value {
            const T = @TypeOf(zig);
            switch (@typeInfo(T)) {
                .null => return .{ .null = {} },
                .int => |int| {
                    if (int.signedness == .signed) {
                        switch (int.bits) {
                            1...64 => return .{ .i64 = zig },
                            else => {},
                        }
                    } else {
                        switch (int.bits) {
                            1...63 => return .{ .i64 = zig },
                            else => {},
                        }
                    }
                    if (zig < std.math.minInt(i64) or zig > std.math.maxInt(i64)) {
                        return error.UnsupportedType;
                    }
                    return .{ .i64 = @intCast(zig) };
                },
                .float => |float| {
                    switch (float.bits) {
                        1...64 => return .{ .f64 = zig },
                        else => return .{ .f64 = @floatCast(zig) },
                    }
                },
                .bool => return .{ .bool = zig },
                .comptime_int => return .{ .i64 = zig },
                .comptime_float => return .{ .f64 = zig },
                .pointer => |ptr| switch (ptr.size) {
                    .one => switch (@typeInfo(ptr.child)) {
                        .array => {
                            const Slice = []const std.meta.Elem(ptr.child);
                            return self.createValue(@as(Slice, zig));
                        },
                        else => return self.createValue(zig.*),
                    }
                    .many, .slice => {
                        if (ptr.size == .many and ptr.sentinel_ptr == null) {
                            return error.UnsupportedType;
                        }
                        const slice = if (ptr.size == .many) std.mem.span(zig) else zig;
                        const child = ptr.child;
                        if (child == u8) {
                            return .{ .string = zig };
                        }

                        var list: Value.List = .empty;
                        try list.ensureTotalCapacity(self._allocator, slice.len);
                        for (slice) |v| {
                            list.appendAssumeCapacity(try self.createValue(v));
                        }
                        const ref = try self.createRef();
                        ref.* = .{ .count = 1, .value = .{ .list = list } };
                        return .{ .ref = ref };
                    },
                    else => return error.UnsupportedType,
                },
                .array => |arr| {
                    if (arr.child == u8) {
                        return .{ .string = &zig };
                    }
                    return self.createValue(&zig);
                },
                .optional => |opt| {
                    if (zig) |v| {
                        return self.createValue(@as(opt.child, v));
                    }
                    return .{ .null = {} };
                },
                .@"union" => {
                    if (T == Value) {
                        return zig;
                    }
                    return error.UnsupportedType;
                },
                .@"struct" => |s| {
                    const allocator = self._allocator;
                    var map: Value.Map = .{};
                    try map.ensureTotalCapacity(allocator, s.fields.len);
                    inline for (s.fields) |field| {
                        map.putAssumeCapacity(.{ .string = field.name }, try self.createValue(@field(zig, field.name)));
                    }
                    const ref = try self.createRef();
                    ref.* = .{ .value = .{ .map = map } };
                    return .{ .ref = ref };
                },
                else => return error.UnsupportedType,
            }
        }

        fn valueToMapKey(self: *Self, value: Value) !KeyValue {
            switch (value) {
                .i64 => |v| return .{ .i64 = v },
                .string => |v| return .{ .string = v },
                else => {
                    try self.setErrorFmt("Map key must be an integer or string, got {s}", .{value.friendlyArticleName()});
                    return error.TypeError;
                },
            }
        }
    };
}

pub const Property = enum(u16) {
    LEN = 1,
    KEY = 2,
    VALUE = 3,

    pub fn name(self: Property) []const u8 {
        return switch (self) {
            .LEN => "len",
            .KEY => "key",
            .VALUE => "value",
        };
    }
};

pub const Method = enum(u16) {
    POP = 1,
    LAST = 2,
    FIRST = 3,
    APPEND = 4,
    REMOVE = 5,
    REMOVE_AT = 6,
    CONTAINS = 7,
    INDEX_OF = 8,
    SORT = 9,
    CONCAT = 10,
    TO_STRING = 11,

    pub fn name(self: Method) []const u8 {
        return switch (self) {
            .POP => "pop",
            .LAST => "last",
            .FIRST => "first",
            .APPEND => "append",
            .REMOVE => "remove",
            .REMOVE_AT => "removeAt",
            .CONTAINS => "contains",
            .INDEX_OF => "indexOf",
            .SORT => "sort",
            .CONCAT => "concat",
            .TO_STRING => "toString",
        };
    }
};

const Frame = struct {
    ip: [*]const u8,
    frame_pointer: usize = undefined,
};

const DebugRefPool = struct {
    count: usize,
    pool: std.heap.MemoryPool(Value.Ref),
    allocator: Allocator,

    fn init(allocator: Allocator) DebugRefPool {
        return .{
            .count = 0,
            .pool = .empty,
            .allocator = allocator,
        };
    }
    fn deinit(self: *DebugRefPool) void {
        self.pool.deinit(self.allocator);
    }

    pub fn create(self: *DebugRefPool) !*Value.Ref {
        self.count += 1;
        return self.pool.create(self.allocator);
    }

    pub fn destroy(self: *DebugRefPool, ref: *Value.Ref) void {
        self.count -= 1;
        self.pool.destroy(ref);
    }
};

fn listIndexOf(list: *const Value.List, needle: Value) ?usize {
    for (list.items, 0..) |item, i| {
        if (item.equal(needle) catch false) {
            return i;
        }
    }
    return null;
}
