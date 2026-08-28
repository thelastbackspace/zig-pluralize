# Contributing

The bar is deliberately high; the process is short.

## Development

- Zig 0.16.0 (pinned in `build.zig.zon`)
- `zig build test` — every test must pass
- `zig fmt --check .` — formatting is enforced
- `zig build` — must compile clean

## Ground rules

- Documented behavior is pinned by the upstream test suite (see Credits in
  the README). A change that alters behavior needs a reference to upstream's
  behavior, plus tests.
- Port the upstream project's own test cases when adding coverage.
- No dependencies beyond the Zig standard library without prior discussion.
- Conventional commits (`feat:`, `fix:`, `docs:`, ...). PRs are
  squash-merged, so the PR title becomes the commit message.

PRs to `main` run the CI gate automatically; a green `test` check is
required to merge.
