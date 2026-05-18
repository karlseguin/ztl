const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Compile = struct {
    pos: u32 = 0,
    src: []const u8 = "",
    err: ?anyerror = null,
    message: []const u8 = "",
    include_key: ?[]const u8 = null,

    pub fn format(self: *const Compile, writer: *std.Io.Writer) !void {
        if (self.err) |se| {
            try writer.writeAll(@errorName(se));
            try writer.writeAll(" - ");
        }
        if (self.message.len > 0) {
            try writer.writeAll(self.message);
            try writer.writeAll(" - ");
        }

        try writer.print("line {d}:\n", .{self.lineNumber()});

        try writer.writeAll(self.contextBefore(2));
        try writer.writeAll(self.line());
        try writer.writeByte('\n');

        const c = self.column();
        try writer.splatBytesAll("-", c);
        try writer.writeAll("^");
        try writer.writeAll(self.contextAfter(1));

        if (self.include_key) |ik| {
            try writer.writeAll("\nIn @include file: '");
            try writer.writeAll(ik);
            try writer.writeByte('\'');
        }
    }

    pub fn line(self: *const Compile) []const u8 {
        const src = self.src;
        const line_start = self.lineStart();
        const line_end = self.lineEnd();
        return src[line_start..line_end];
    }

    pub fn lineStart(self: *const Compile) usize {
        if (std.mem.lastIndexOfScalar(u8, self.src[0..self.pos], '\n')) |n| {
            return n + 1;
        }
        return 0;
    }

    pub fn lineEnd(self: *const Compile) usize {
        return std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n') orelse self.src.len;
    }

    pub fn lineNumber(self: *const Compile) usize {
        return std.mem.count(u8, self.src[0..self.pos], "\n") + 1;
    }

    pub fn column(self: *const Compile) usize {
        return self.pos - self.lineStart();
    }

    pub fn contextBefore(self: *const Compile, line_count: usize) []const u8 {
        const end = self.lineStart();

        if (end == 0) {
            return "";
        }

        var pos = end;
        var i: usize = 0;
        const src = self.src;

        while (i <= line_count) : (i += 1) {
            pos = std.mem.lastIndexOfScalar(u8, src[0..pos], '\n') orelse return src[0..end];
        }
        return src[pos + 1 .. end];
    }

    pub fn contextAfter(self: *const Compile, line_count: usize) []const u8 {
        const start = self.lineEnd();

        const src = self.src;

        if (start == src.len) {
            return "";
        }

        var pos = start;
        var i: usize = 0;
        while (i <= line_count) : (i += 1) {
            pos = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse return src[start..];
            pos += 1;
        }
        return src[start .. pos - 1];
    }
};

pub const Render = struct {
    err: ?anyerror = null,
    message: []const u8 = "",
    allocator: ?Allocator = null,

    pub fn deinit(self: Render) void {
        if (self.allocator) |a| {
            a.free(self.message);
        }
    }

    pub fn format(self: *const Render, writer: *std.Io.Writer) !void {
        if (self.err) |se| {
            try writer.writeAll(@errorName(se));
            try writer.writeAll(" - ");
        }

        if (self.message.len > 0) {
            try writer.writeAll(self.message);
        }
    }
};
