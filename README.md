# pluralize

[![CI](https://github.com/thelastbackspace/zig-pluralize/actions/workflows/ci.yml/badge.svg)](https://github.com/thelastbackspace/zig-pluralize/actions/workflows/ci.yml)

Pluralize and singularize English words — irregulars, uncountables,
and case preservation included.

```zig
const pluralize = @import("pluralize");

var p = try pluralize.Pluralize.init(allocator);
defer p.deinit();

const a = try p.plural(allocator, "cat"); // "cats"
defer allocator.free(a);
const b = try p.plural(allocator, "person"); // "people"
defer allocator.free(b);
const c = try p.singular(allocator, "geese"); // "goose"
defer allocator.free(c);
const d = try p.count(allocator, "test", 3, true); // "3 tests"
defer allocator.free(d);

const cats = p.isPlural("cats"); // true
const goose = p.isSingular("goose"); // true
```

Words keep their case shape: `"Cat"` → `"Cats"`, `"CAT"` → `"CATS"`.

## Installation

Requires Zig 0.16.0.

```sh
zig fetch --save git+https://github.com/thelastbackspace/zig-pluralize#v1.0.0
```

Then in `build.zig`:

```zig
const pluralize = b.dependency("pluralize", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pluralize", pluralize.module("pluralize"));
```

## API

### `Pluralize`

A rule book holding irregular pairs, uncountables, and regex rules.
`init` loads the upstream defaults; the `add*` methods extend it. All
rule state lives in `Pluralize`'s own allocator; `deinit` frees it.

- `plural(allocator, word) ![]u8` / `singular(allocator, word) ![]u8` —
  convert one word; caller owns the result.
- `count(allocator, word, n, inclusive) ![]u8` — pick the form for a
  count, optionally prefixed (`"1 test"`, `"3 tests"`).
- `isPlural(word) bool` / `isSingular(word) bool`.

### Custom rules

- `addIrregularRule(single, plural)` — register a pair
  (`"canadia"`/`"canadensis"`).
- `addUncountableRule(word)` — same form both ways.
- `addPluralRule(pattern, replacement)` / `addSingularRule(...)` —
  pattern uses a small regex subset: literals, character classes,
  groups and alternation, `?`, `\b`, `^`; the end anchor is implied.
  Replacements interpolate `$0`–`$9`.

## Notes

- Matching is ASCII case-insensitive over Unicode code points.
- Case restoration (`restoreCase`) is ASCII-only: `"Cat"` → `"Cats"`
  works, but non-ASCII case shapes pass through in lowercase form.
- Patterns are compiled internally by a purpose-built engine
  (`src/pattern.zig`) covering exactly the constructs the rules use —
  no general regex dependency.

## Testing

```sh
zig build test
```

The suite ports upstream's test file: 657 singular/plural pairs,
checked through plural, singular, `isPlural`, `isSingular`, and count
conversion, plus case preservation and custom-rule tests.

## Contributing

PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The CI gate
(`zig fmt --check`, tests, build) must pass.

## Credits

Behavior, the rule tables, and the test suite follow the npm package
[`pluralize`](https://github.com/blakeembrey/pluralize) v8.0.0 (MIT,
© Blake Embrey); the implementation is original. Zig implementation
© 2026 thelastbackspace, MIT — see [LICENSE](LICENSE).
