//! A small regular-expression subset, sufficient for the
//! pluralization rules: literals, character classes, groups and
//! alternation, optional elements, word boundaries, `^`/`$` anchors,
//! and case-insensitive ASCII matching. Captures up to nine groups.

const std = @import("std");

pub const Error = error{InvalidPattern} || std.mem.Allocator.Error;

const Class = struct {
    negated: bool,
    /// Inclusive code point ranges; an empty list with `negated`
    /// matches everything.
    ranges: []const [2]u21,

    fn matches(self: Class, c: u21) bool {
        const lower: u21 = if (c < 0x80) std.ascii.toLower(@intCast(c)) else c;
        var in = false;
        for (self.ranges) |r| {
            if (lower >= r[0] and lower <= r[1]) {
                in = true;
                break;
            }
        }
        return in != self.negated;
    }
};

const Inst = union(enum) {
    char: struct { c: u8, next: *const Inst },
    class: struct { cl: Class, next: *const Inst },
    boundary: struct { next: *const Inst },
    start: struct { next: *const Inst },
    end: struct { next: *const Inst },
    /// Alternation: try `a` first, then `b` (leftmost preference).
    split: struct { a: *const Inst, b: *const Inst },
    /// Record the start (kind = .begin) or end (.finish) of a capture.
    save: struct { slot: usize, begin: bool, next: *const Inst },
    done,
};

/// A compiled pattern. All memory lives in the allocator given to
/// [`compile`].
pub const Pattern = struct {
    program: *const Inst,
    group_count: usize,

    /// A match: its extent and the captured groups (empty when a group
    /// did not participate).
    pub const Match = struct {
        start: usize,
        end: usize,
        groups: [10]?[]const u8,
    };

    /// Find the leftmost match in `word` (ASCII case-insensitive).
    pub fn find(self: Pattern, word: []const u8) ?Match {
        var start: usize = 0;
        while (start <= word.len) : (start += 1) {
            var caps: [20]?usize = @splat(null);
            caps[0] = start;
            if (run(self.program, word, start, &caps)) {
                var groups: [10]?[]const u8 = @splat(null);
                groups[0] = word[start..caps[1].?];
                var i: usize = 1;
                while (i <= self.group_count) : (i += 1) {
                    if (caps[2 * i] != null and caps[2 * i + 1] != null) {
                        groups[i] = word[caps[2 * i].?..caps[2 * i + 1].?];
                    }
                }
                return .{
                    .start = start,
                    .end = caps[1].?,
                    .groups = groups,
                };
            }
        }
        return null;
    }
};

fn run(pc: *const Inst, word: []const u8, pos: usize, caps: *[20]?usize) bool {
    switch (pc.*) {
        .done => {
            if (caps[1] == null) caps[1] = pos;
            return true;
        },
        .char => |i| {
            if (pos < word.len and eqlIgnoreCase(word[pos], i.c)) {
                return run(i.next, word, pos + 1, caps);
            }
            return false;
        },
        .class => |i| {
            if (pos >= word.len) return false;
            var cp: u21 = word[pos];
            var len: usize = 1;
            if (word[pos] >= 0x80) {
                len = std.unicode.utf8ByteSequenceLength(word[pos]) catch return false;
                if (pos + len > word.len) return false;
                cp = std.unicode.utf8Decode(word[pos .. pos + len]) catch return false;
            }
            if (i.cl.matches(cp)) {
                return run(i.next, word, pos + len, caps);
            }
            return false;
        },
        .boundary => |i| {
            const before = pos > 0 and isWordChar(word[pos - 1]);
            const after = pos < word.len and isWordChar(word[pos]);
            if (before != after) return run(i.next, word, pos, caps);
            return false;
        },
        .start => |i| {
            if (pos == 0) return run(i.next, word, pos, caps);
            return false;
        },
        .end => |i| {
            if (pos == word.len) return run(i.next, word, pos, caps);
            return false;
        },
        .save => |i| {
            const slot = i.slot;
            const old = caps[slot];
            const value: usize = if (i.begin) pos else pos;
            caps[slot] = value;
            if (run(i.next, word, pos, caps)) return true;
            caps[slot] = old;
            return false;
        },
        .split => |i| {
            const snapshot = caps.*;
            if (run(i.a, word, pos, caps)) return true;
            caps.* = snapshot;
            return run(i.b, word, pos, caps);
        },
    }
}

fn eqlIgnoreCase(a: u8, b: u8) bool {
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Compile a pattern with the given flags. When `string_rule` is set,
/// the pattern is anchored at both ends (`^...$`), mirroring the
/// upstream package's treatment of string rules.
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, string_rule: bool) Error!Pattern {
    // A trailing `$` is enforced by the appended end anchor.
    var src = pattern;
    if (src.len > 0 and src[src.len - 1] == '$') src = src[0 .. src.len - 1];
    var c = Compiler{ .allocator = allocator, .s = src };
    var group_count: usize = 0;
    const body = try c.alternation(&group_count);

    var program: *const Inst = try c.inst(.{ .done = {} });
    program = try c.inst(.{ .end = .{ .next = program } });
    if (string_rule) {
        program = try c.seq(body, program);
        program = try c.inst(.{ .start = .{ .next = program } });
    } else {
        program = try c.seq(body, program);
    }

    return .{ .program = program, .group_count = group_count };
}

const Seq = []const Node;

/// Parse tree node, lowered to instructions in a second pass.
const Node = union(enum) {
    literal: u8,
    class: Class,
    boundary,
    start,
    optional: *const Node,
    group: struct { capture: ?usize, alts: []const Seq },
};

const Compiler = struct {
    allocator: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    inst_count: usize = 0,

    fn inst(self: *Compiler, x: Inst) Error!*const Inst {
        const p = try self.allocator.create(Inst);
        p.* = x;
        return p;
    }

    fn peek(self: *Compiler) ?u8 {
        if (self.i >= self.s.len) return null;
        return self.s[self.i];
    }

    /// Parse a top-level alternation into a single-node sequence.
    fn alternation(self: *Compiler, group_count: *usize) Error!Seq {
        var alts = std.ArrayList(Seq).empty;
        try alts.append(self.allocator, try self.sequence(group_count));
        while (self.peek() == '|') {
            self.i += 1;
            try alts.append(self.allocator, try self.sequence(group_count));
        }
        if (alts.items.len == 1) return alts.items[0];
        const group = Node{
            .group = .{ .capture = null, .alts = try alts.toOwnedSlice(self.allocator) },
        };
        const out = try self.allocator.alloc(Node, 1);
        out[0] = group;
        return out;
    }

    fn sequence(self: *Compiler, group_count: *usize) Error!Seq {
        var nodes = std.ArrayList(Node).empty;
        while (self.peek()) |c| {
            if (c == ')' or c == '|') break;
            try nodes.append(self.allocator, try self.atom(group_count));
        }
        return nodes.toOwnedSlice(self.allocator);
    }

    fn atom(self: *Compiler, group_count: *usize) Error!Node {
        const c = self.peek() orelse return error.InvalidPattern;
        var node: Node = undefined;

        switch (c) {
            '(' => {
                self.i += 1;
                var capture: ?usize = null;
                if (self.peek() == '?') {
                    self.i += 1;
                    if (self.peek() == ':') {
                        self.i += 1;
                    } else return error.InvalidPattern;
                } else {
                    group_count.* += 1;
                    capture = group_count.*;
                }
                var alts = std.ArrayList(Seq).empty;
                try alts.append(self.allocator, try self.sequence(group_count));
                while (self.peek() == '|') {
                    self.i += 1;
                    try alts.append(self.allocator, try self.sequence(group_count));
                }
                if (self.peek() != ')') return error.InvalidPattern;
                self.i += 1;
                node = .{ .group = .{ .capture = capture, .alts = try alts.toOwnedSlice(self.allocator) } };
            },
            '[' => {
                self.i += 1;
                node = .{ .class = try self.classBody() };
            },
            '\\' => {
                self.i += 1;
                const e = self.peek() orelse return error.InvalidPattern;
                self.i += 1;
                switch (e) {
                    'b' => node = .boundary,
                    'w' => node = .{ .class = .{ .negated = false, .ranges = &word_ranges } },
                    'W' => node = .{ .class = .{ .negated = true, .ranges = &word_ranges } },
                    else => node = .{ .literal = e },
                }
            },
            '^' => {
                self.i += 1;
                node = .start;
            },
            else => {
                self.i += 1;
                node = .{ .literal = c };
            },
        }

        if (self.peek() == '?') {
            self.i += 1;
            const wrapped = try self.allocator.create(Node);
            wrapped.* = node;
            node = .{ .optional = wrapped };
        }
        return node;
    }

    const ClassAtom = union(enum) { char: u21, word };

    fn classAtom(self: *Compiler) Error!ClassAtom {
        const c = self.peek() orelse return error.InvalidPattern;
        if (c != '\\') {
            self.i += 1;
            if (c < 0x80) return .{ .char = c };
            // Decode the multi-byte literal as a code point.
            const len = std.unicode.utf8ByteSequenceLength(c) catch return error.InvalidPattern;
            if (self.i - 1 + len > self.s.len) return error.InvalidPattern;
            const cp = std.unicode.utf8Decode(self.s[self.i - 1 .. self.i - 1 + len]) catch return error.InvalidPattern;
            self.i += len - 1;
            return .{ .char = cp };
        }
        self.i += 1;
        const e = self.peek() orelse return error.InvalidPattern;
        self.i += 1;
        return switch (e) {
            'w' => .word,
            'u' => blk: {
                // \uXXXX — the ranges used are ASCII.
                if (self.i + 4 > self.s.len) break :blk .{ .char = e };
                const hex = self.s[self.i .. self.i + 4];
                const value = std.fmt.parseInt(u16, hex, 16) catch break :blk .{ .char = e };
                self.i += 4;
                break :blk .{ .char = @intCast(@min(value, 0x7F)) };
            },
            else => .{ .char = e },
        };
    }

    fn classBody(self: *Compiler) Error!Class {
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.i += 1;
        }
        var ranges = std.ArrayList([2]u21).empty;
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.InvalidPattern;
            if (c == ']' and !first) {
                self.i += 1;
                break;
            }
            first = false;
            const lo = try self.classAtom();
            if (lo == .word) {
                try ranges.appendSlice(self.allocator, &word_ranges);
                continue;
            }
            if (self.peek() == '-' and self.i + 1 < self.s.len and self.s[self.i + 1] != ']') {
                self.i += 1;
                const hi = try self.classAtom();
                try ranges.append(self.allocator, .{ lo.char, hi.char });
            } else {
                try ranges.append(self.allocator, .{ lo.char, lo.char });
            }
        }
        return .{ .negated = negated, .ranges = try ranges.toOwnedSlice(self.allocator) };
    }

    /// Lower a parsed sequence to instructions chaining into `next`.
    fn seq(self: *Compiler, nodes: Seq, next: *const Inst) Error!*const Inst {
        var link = next;
        var i = nodes.len;
        while (i > 0) {
            i -= 1;
            link = try self.lower(nodes[i], link);
        }
        return link;
    }

    fn lower(self: *Compiler, node: Node, next: *const Inst) Error!*const Inst {
        switch (node) {
            .literal => |c| return self.inst(.{ .char = .{ .c = c, .next = next } }),
            .class => |cl| return self.inst(.{ .class = .{ .cl = cl, .next = next } }),
            .boundary => return self.inst(.{ .boundary = .{ .next = next } }),
            .start => return self.inst(.{ .start = .{ .next = next } }),
            .optional => |sub| {
                const in = try self.lower(sub.*, next);
                return self.inst(.{ .split = .{ .a = in, .b = next } });
            },
            .group => |g| {
                // Alternatives chain into a group-close save, then next.
                var alts = std.ArrayList(*const Inst).empty;
                const capture = g.capture;
                var tail = next;
                if (capture) |n| {
                    const slot = 2 * n + 1;
                    tail = try self.inst(.{ .save = .{ .slot = slot, .begin = false, .next = next } });
                }
                for (g.alts) |alt| {
                    try alts.append(self.allocator, try self.seq(alt, tail));
                }
                var chain = alts.items[alts.items.len - 1];
                var k = alts.items.len - 1;
                while (k > 0) {
                    k -= 1;
                    chain = try self.inst(.{ .split = .{ .a = alts.items[k], .b = chain } });
                }
                if (capture) |n| {
                    const slot = 2 * n;
                    return self.inst(.{ .save = .{ .slot = slot, .begin = true, .next = chain } });
                }
                return chain;
            },
        }
    }
};

const word_ranges = [_][2]u21{ .{ '0', '9' }, .{ 'a', 'z' }, .{ '_', '_' } };

test "pattern basics" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const p1 = try compile(aa, "(ax|test)is$", false);
    const m1 = p1.find("testis").?;
    try std.testing.expectEqualStrings("test", m1.groups[1].?);

    const m2 = p1.find("axis").?;
    try std.testing.expectEqualStrings("ax", m2.groups[1].?);
    try std.testing.expect(p1.find("is") == null);

    const p2 = try compile(aa, "([^aeiouy]|qu)y$", false);
    const m3 = p2.find("baby").?;
    try std.testing.expectEqualStrings("b", m3.groups[1].?);

    // Case-insensitive.
    const p3 = try compile(aa, "thou", true);
    try std.testing.expect(p3.find("THOU") != null);
    try std.testing.expect(p3.find("thousand") == null);

    // Word boundary.
    const p4 = try compile(aa, "\\b((?:tit)?m|l)(?:ice|ouse)$", false);
    const m4 = p4.find("titmice").?;
    try std.testing.expectEqualStrings("titm", m4.groups[1].?);
    try std.testing.expect(p4.find("dice") == null);

    // Optional group.
    const p5 = try compile(aa, "(child)(?:ren)?$", false);
    const m5 = p5.find("children").?;
    try std.testing.expectEqualStrings("child", m5.groups[1].?);
}
