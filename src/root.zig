//! Pluralize and singularize English words.
//!
//! A behavior-faithful Zig port of the npm package
//! [`pluralize`](https://github.com/blakeembrey/pluralize) (v8.0.0).
//! The upstream test suite is ported in `tests.zig`.

const std = @import("std");
const pattern = @import("pattern.zig");

const Pattern = pattern.Pattern;

const Rule = struct {
    regex: Pattern,
    replacement: []const u8,
};

/// A rule book of irregulars, uncountables, and regex rules. Built
/// with [`init`] (which loads the upstream defaults) and mutable via
/// the `add*Rule` methods. All internal state lives in the allocator
/// given to `init`; free it with [`deinit`].
pub const Pluralize = struct {
    arena: std.heap.ArenaAllocator,
    irregular_singles: std.StringHashMapUnmanaged([]const u8),
    irregular_plurals: std.StringHashMapUnmanaged([]const u8),
    uncountables: std.StringHashMapUnmanaged(void),
    plural_rules: std.ArrayListUnmanaged(Rule),
    singular_rules: std.ArrayListUnmanaged(Rule),

    /// Create a `Pluralize` with the default upstream rules loaded.
    pub fn init(allocator: std.mem.Allocator) (std.mem.Allocator.Error || pattern.Error)!Pluralize {
        var self = Pluralize{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .irregular_singles = .empty,
            .irregular_plurals = .empty,
            .uncountables = .empty,
            .plural_rules = .empty,
            .singular_rules = .empty,
        };
        errdefer self.deinit();
        const a = self.arena.allocator();

        // Order matters: later additions are checked first.
        try self.addDefaultIrregulars();
        for (default_plural_rules) |r| {
            try self.addRule(&self.plural_rules, try pattern.compile(a, r[0], false), r[1]);
        }
        for (default_singular_rules) |r| {
            try self.addRule(&self.singular_rules, try pattern.compile(a, r[0], false), r[1]);
        }
        for (default_uncountables) |word| {
            try self.uncountables.put(a, try a.dupe(u8, word), {});
        }
        // Regex uncountables: identity rules on both sides.
        for (default_uncountable_regexes) |p| {
            const compiled = try pattern.compile(a, p, false);
            try self.addRule(&self.plural_rules, compiled, "$0");
            try self.addRule(&self.singular_rules, compiled, "$0");
        }
        return self;
    }

    pub fn deinit(self: *Pluralize) void {
        self.arena.deinit();
    }

    /// Pluralize a word (`"cat"` → `"cats"`). The result is allocated
    /// with `allocator`; the caller owns it.
    pub fn plural(self: *const Pluralize, allocator: std.mem.Allocator, word: []const u8) std.mem.Allocator.Error![]u8 {
        return self.replaceWord(allocator, word, &self.irregular_singles, &self.irregular_plurals, self.plural_rules.items);
    }

    /// Singularize a word (`"cats"` → `"cat"`). The result is allocated
    /// with `allocator`; the caller owns it.
    pub fn singular(self: *const Pluralize, allocator: std.mem.Allocator, word: []const u8) std.mem.Allocator.Error![]u8 {
        return self.replaceWord(allocator, word, &self.irregular_plurals, &self.irregular_singles, self.singular_rules.items);
    }

    /// Pluralize or singularize a word based on `count`; with
    /// `inclusive`, the count prefixes the word (`"3 ducks"`).
    pub fn count(
        self: *const Pluralize,
        allocator: std.mem.Allocator,
        word: []const u8,
        n: i64,
        inclusive: bool,
    ) std.mem.Allocator.Error![]u8 {
        const word_result = if (n == 1)
            try self.singular(allocator, word)
        else
            try self.plural(allocator, word);
        if (!inclusive) return word_result;
        defer allocator.free(word_result);
        return std.fmt.allocPrint(allocator, "{d} {s}", .{ n, word_result });
    }

    /// True when the word is already plural.
    pub fn isPlural(self: *const Pluralize, word: []const u8) bool {
        return self.checkWord(word, &self.irregular_singles, &self.irregular_plurals, self.plural_rules.items);
    }

    /// True when the word is already singular.
    pub fn isSingular(self: *const Pluralize, word: []const u8) bool {
        return self.checkWord(word, &self.irregular_plurals, &self.irregular_singles, self.singular_rules.items);
    }

    /// Add a pluralization rule. The pattern uses the subset grammar of
    /// [`pattern.compile`] (literals, classes, groups, `?`, `|`, `\b`);
    /// a `$` is implied.
    pub fn addPluralRule(self: *Pluralize, rule: []const u8, replacement: []const u8) !void {
        const a = self.arena.allocator();
        try self.addRule(&self.plural_rules, try pattern.compile(a, rule, false), try a.dupe(u8, replacement));
    }

    /// Add a singularization rule.
    pub fn addSingularRule(self: *Pluralize, rule: []const u8, replacement: []const u8) !void {
        const a = self.arena.allocator();
        try self.addRule(&self.singular_rules, try pattern.compile(a, rule, false), try a.dupe(u8, replacement));
    }

    /// Mark a word as uncountable (same in singular and plural).
    pub fn addUncountableRule(self: *Pluralize, word: []const u8) !void {
        const a = self.arena.allocator();
        try self.uncountables.put(a, try a.dupe(u8, word), {});
    }

    /// Register an irregular single/plural pair (both directions).
    pub fn addIrregularRule(self: *Pluralize, single: []const u8, plural_word: []const u8) !void {
        const a = self.arena.allocator();
        const s = try std.ascii.allocLowerString(a, single);
        const p = try std.ascii.allocLowerString(a, plural_word);
        try self.irregular_singles.put(a, s, p);
        try self.irregular_plurals.put(a, p, s);
    }

    fn addDefaultIrregulars(self: *Pluralize) std.mem.Allocator.Error!void {
        for (default_irregulars) |pair| {
            try self.addIrregularRule(pair[0], pair[1]);
        }
    }

    fn addRule(self: *Pluralize, rules: *std.ArrayListUnmanaged(Rule), compiled: Pattern, replacement: []const u8) std.mem.Allocator.Error!void {
        try rules.append(self.arena.allocator(), .{ .regex = compiled, .replacement = replacement });
    }

    fn replaceWord(
        self: *const Pluralize,
        allocator: std.mem.Allocator,
        word: []const u8,
        replace_map: *const std.StringHashMapUnmanaged([]const u8),
        keep_map: *const std.StringHashMapUnmanaged([]const u8),
        rules: []const Rule,
    ) std.mem.Allocator.Error![]u8 {
        const token = try std.ascii.allocLowerString(allocator, word);
        defer allocator.free(token);

        if (keep_map.get(token)) |kept| {
            return restoreCaseAlloc(allocator, word, kept);
        }
        if (replace_map.get(token)) |replacement| {
            return restoreCaseAlloc(allocator, word, replacement);
        }
        return self.sanitizeWordAlloc(allocator, token, word, rules);
    }

    fn sanitizeWordAlloc(
        self: *const Pluralize,
        allocator: std.mem.Allocator,
        token: []const u8,
        word: []const u8,
        rules: []const Rule,
    ) std.mem.Allocator.Error![]u8 {
        if (token.len == 0 or self.uncountables.contains(token)) {
            return allocator.dupe(u8, word);
        }

        // Rules are checked in reverse insertion order.
        var i = rules.len;
        while (i > 0) {
            i -= 1;
            if (rules[i].regex.find(word)) |m| {
                return replaceMatch(allocator, word, m, rules[i].replacement);
            }
        }
        return allocator.dupe(u8, word);
    }

    fn checkWord(
        self: *const Pluralize,
        word: []const u8,
        replace_map: *const std.StringHashMapUnmanaged([]const u8),
        keep_map: *const std.StringHashMapUnmanaged([]const u8),
        rules: []const Rule,
    ) bool {
        var buf: [256]u8 = undefined;
        var scratch: [256]u8 = undefined;
        if (word.len > buf.len) return false;
        const token = std.ascii.lowerString(&buf, word);

        if (keep_map.contains(token)) return true;
        if (replace_map.contains(token)) return false;

        if (token.len == 0 or self.uncountables.contains(token)) return true;

        var i = rules.len;
        while (i > 0) {
            i -= 1;
            if (rules[i].regex.find(token)) |m| {
                const replaced = replaceMatchInto(&scratch, token, m, rules[i].replacement);
                return std.mem.eql(u8, replaced, token);
            }
        }
        return true;
    }
};

/// Apply a rule's replacement to a match, restoring the case pattern
/// of the original word (exact, all-lower, all-upper, or title case).
/// Replace the matched portion of `word` with the rule's replacement,
/// interpolating `$0`-`$9` and restoring the case pattern of the
/// matched text on the replacement.
fn replaceMatch(allocator: std.mem.Allocator, word: []const u8, m: Pattern.Match, replacement: []const u8) std.mem.Allocator.Error![]u8 {
    const raw = try interpolate(allocator, replacement, m);
    defer allocator.free(raw);

    const matched = word[m.start..m.end];
    var cased: []const u8 = undefined;
    var owned = false;
    if (matched.len == 0) {
        // Empty match: restore the case of the preceding character.
        if (m.start == 0) {
            cased = raw;
        } else {
            cased = try restoreCaseAlloc(allocator, word[m.start - 1 .. m.start], raw);
            owned = true;
        }
    } else {
        cased = try restoreCaseAlloc(allocator, matched, raw);
        owned = true;
    }
    defer if (owned) allocator.free(cased);

    return std.mem.concat(allocator, u8, &.{ word[0..m.start], cased, word[m.end..] });
}

/// `replaceMatch` into a fixed buffer (used by `checkWord`).
fn replaceMatchInto(buf: []u8, word: []const u8, m: Pattern.Match, replacement: []const u8) []const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const replaced = replaceMatch(fba.allocator(), word, m, replacement) catch return word;
    return replaced;
}

fn interpolate(allocator: std.mem.Allocator, template: []const u8, m: Pattern.Match) std.mem.Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '$' and i + 1 < template.len and std.ascii.isDigit(template[i + 1])) {
            var j = i + 1;
            var n: usize = 0;
            while (j < template.len and std.ascii.isDigit(template[j])) : (j += 1) {
                n = n * 10 + (template[j] - '0');
            }
            if (n < m.groups.len) {
                if (m.groups[n]) |g| try out.appendSlice(allocator, g);
            }
            i = j;
        } else {
            try out.append(allocator, template[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Port of upstream's `restoreCase`, restricted to ASCII case.
fn restoreCaseAlloc(allocator: std.mem.Allocator, word: []const u8, token: []const u8) std.mem.Allocator.Error![]u8 {
    if (std.mem.eql(u8, word, token)) return allocator.dupe(u8, token);

    if (isAllLower(word)) {
        return std.ascii.allocLowerString(allocator, token);
    }
    if (isAllUpper(word)) {
        return std.ascii.allocUpperString(allocator, token);
    }
    if (word.len > 0 and std.ascii.isUpper(word[0])) {
        var out = try std.ascii.allocLowerString(allocator, token);
        if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
        return out;
    }
    return std.ascii.allocLowerString(allocator, token);
}

fn isAllLower(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isUpper(c)) return false;
    }
    return true;
}

fn isAllUpper(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isLower(c)) return false;
    }
    return true;
}

/// Upstream irregulars, in insertion order.
const default_irregulars = [_][2][]const u8{
    .{ "I", "we" },
    .{ "me", "us" },
    .{ "he", "they" },
    .{ "she", "they" },
    .{ "them", "them" },
    .{ "myself", "ourselves" },
    .{ "yourself", "yourselves" },
    .{ "itself", "themselves" },
    .{ "herself", "themselves" },
    .{ "himself", "themselves" },
    .{ "themself", "themselves" },
    .{ "is", "are" },
    .{ "was", "were" },
    .{ "has", "have" },
    .{ "this", "these" },
    .{ "that", "those" },
    .{ "my", "our" },
    .{ "its", "their" },
    .{ "his", "their" },
    .{ "her", "their" },
    .{ "echo", "echoes" },
    .{ "dingo", "dingoes" },
    .{ "volcano", "volcanoes" },
    .{ "tornado", "tornadoes" },
    .{ "torpedo", "torpedoes" },
    .{ "genus", "genera" },
    .{ "viscus", "viscera" },
    .{ "stigma", "stigmata" },
    .{ "stoma", "stomata" },
    .{ "dogma", "dogmata" },
    .{ "lemma", "lemmata" },
    .{ "schema", "schemata" },
    .{ "anathema", "anathemata" },
    .{ "ox", "oxen" },
    .{ "axe", "axes" },
    .{ "die", "dice" },
    .{ "yes", "yeses" },
    .{ "foot", "feet" },
    .{ "eave", "eaves" },
    .{ "goose", "geese" },
    .{ "tooth", "teeth" },
    .{ "quiz", "quizzes" },
    .{ "human", "humans" },
    .{ "proof", "proofs" },
    .{ "carve", "carves" },
    .{ "valve", "valves" },
    .{ "looey", "looies" },
    .{ "thief", "thieves" },
    .{ "groove", "grooves" },
    .{ "pickaxe", "pickaxes" },
    .{ "passerby", "passersby" },
    .{ "canvas", "canvases" },
};

/// Upstream pluralization rules, in insertion order.
const default_plural_rules = [_][2][]const u8{
    .{ "s?$", "s" },
    .{ "[^\\u0000-\\u007F]$", "$0" },
    .{ "([^aeiou]ese)$", "$1" },
    .{ "(ax|test)is$", "$1es" },
    .{ "(alias|[^aou]us|t[lm]as|gas|ris)$", "$1es" },
    .{ "(e[mn]u)s?$", "$1s" },
    .{ "([^l]ias|[aeiou]las|[ejzr]as|[iu]am)$", "$1" },
    .{ "(alumn|syllab|vir|radi|nucle|fung|cact|stimul|termin|bacill|foc|uter|loc|strat)(?:us|i)$", "$1i" },
    .{ "(alumn|alg|vertebr)(?:a|ae)$", "$1ae" },
    .{ "(seraph|cherub)(?:im)?$", "$1im" },
    .{ "(her|at|gr)o$", "$1oes" },
    .{ "(agend|addend|millenni|dat|extrem|bacteri|desiderat|strat|candelabr|errat|ov|symposi|curricul|automat|quor)(?:a|um)$", "$1a" },
    .{ "(apheli|hyperbat|periheli|asyndet|noumen|phenomen|criteri|organ|prolegomen|hedr|automat)(?:a|on)$", "$1a" },
    .{ "sis$", "ses" },
    .{ "(?:(kni|wi|li)fe|(ar|l|ea|eo|oa|hoo)f)$", "$1$2ves" },
    .{ "([^aeiouy]|qu)y$", "$1ies" },
    .{ "([^ch][ieo][ln])ey$", "$1ies" },
    .{ "(x|ch|ss|sh|zz)$", "$1es" },
    .{ "(matr|cod|mur|sil|vert|ind|append)(?:ix|ex)$", "$1ices" },
    .{ "\\b((?:tit)?m|l)(?:ice|ouse)$", "$1ice" },
    .{ "(pe)(?:rson|ople)$", "$1ople" },
    .{ "(child)(?:ren)?$", "$1ren" },
    .{ "eaux$", "$0" },
    .{ "m[ae]n$", "men" },
    .{ "thou", "you" },
};

/// Upstream singularization rules, in insertion order.
const default_singular_rules = [_][2][]const u8{
    .{ "s$", "" },
    .{ "(ss)$", "$1" },
    .{ "(wi|kni|(?:after|half|high|low|mid|non|night|[^\\w]|^)li)ves$", "$1fe" },
    .{ "(ar|(?:wo|[ae])l|[eo][ao])ves$", "$1f" },
    .{ "ies$", "y" },
    .{ "(dg|ss|ois|lk|ok|wn|mb|th|ch|ec|oal|is|ck|ix|sser|ts|wb)ies$", "$1ie" },
    .{ "\\b(l|(?:neck|cross|hog|aun)?t|coll|faer|food|gen|goon|group|hipp|junk|vegg|(?:pork)?p|charl|calor|cut)ies$", "$1ie" },
    .{ "\\b(mon|smil)ies$", "$1ey" },
    .{ "\\b((?:tit)?m|l)ice$", "$1ouse" },
    .{ "(seraph|cherub)im$", "$1" },
    .{ "(x|ch|ss|sh|zz|tto|go|cho|alias|[^aou]us|t[lm]as|gas|(?:her|at|gr)o|[aeiou]ris)(?:es)?$", "$1" },
    .{ "(analy|diagno|parenthe|progno|synop|the|empha|cri|ne)(?:sis|ses)$", "$1sis" },
    .{ "(movie|twelve|abuse|e[mn]u)s$", "$1" },
    .{ "(test)(?:is|es)$", "$1is" },
    .{ "(alumn|syllab|vir|radi|nucle|fung|cact|stimul|termin|bacill|foc|uter|loc|strat)(?:us|i)$", "$1us" },
    .{ "(agend|addend|millenni|dat|extrem|bacteri|desiderat|strat|candelabr|errat|ov|symposi|curricul|quor)a$", "$1um" },
    .{ "(apheli|hyperbat|periheli|asyndet|noumen|phenomen|criteri|organ|prolegomen|hedr|automat)a$", "$1on" },
    .{ "(alumn|alg|vertebr)ae$", "$1a" },
    .{ "(cod|mur|sil|vert|ind)ices$", "$1ex" },
    .{ "(matr|append)ices$", "$1ix" },
    .{ "(pe)(rson|ople)$", "$1rson" },
    .{ "(child)ren$", "$1" },
    .{ "(eau)x?$", "$1" },
    .{ "men$", "man" },
};

const default_uncountables = [_][]const u8{
    "adulthood",    "advice",      "agenda",    "aid",         "aircraft",
    "alcohol",      "ammo",        "analytics", "anime",       "athletics",
    "audio",        "bison",       "blood",     "bream",       "buffalo",
    "butter",       "carp",        "cash",      "chassis",     "chess",
    "clothing",     "cod",         "commerce",  "cooperation", "corps",
    "debris",       "diabetes",    "digestion", "elk",         "energy",
    "equipment",    "excretion",   "expertise", "firmware",    "flounder",
    "fun",          "gallows",     "garbage",   "graffiti",    "hardware",
    "headquarters", "health",      "herpes",    "highjinks",   "homework",
    "housework",    "information", "jeans",     "justice",     "kudos",
    "labour",       "literature",  "machinery", "mackerel",    "mail",
    "media",        "mews",        "moose",     "music",       "mud",
    "manga",        "news",        "only",      "personnel",   "pike",
    "plankton",     "pliers",      "police",    "pollution",   "premises",
    "rain",         "research",    "rice",      "salmon",      "scissors",
    "series",       "sewage",      "shambles",  "shrimp",      "software",
    "staff",        "swine",       "tennis",    "traffic",     "transportation",
    "trout",        "tuna",        "wealth",    "welfare",     "whiting",
    "wildebeest",   "wildlife",    "you",
};

const default_uncountable_regexes = [_][]const u8{
    "pok[eé]mon$",
    "[^aeiou]ese$",
    "deer$",
    "fish$",
    "measles$",
    "o[iu]s$",
    "pox$",
    "sheep$",
};

test {
    _ = @import("pattern.zig");
    _ = @import("tests.zig");
}
