# Contributing

Thanks for your interest in swift-changeset.

## Getting set up

```bash
git clone https://github.com/Swift-Flight/swift-changeset
cd swift-changeset
swift build
swift test
```

No services, containers, or environment variables are required — the whole
suite is in-process and runs in well under a second.

## Before opening a pull request

```bash
swift build -Xswiftc -warnings-as-errors
swift test
SWIFT_CHANGESET_BUILD_DOCS=1 swift package generate-documentation \
    --target Changesets --warnings-as-errors
```

CI runs exactly these three, on Linux and macOS, against Swift 6.0 and 6.2.

## What we look for

**Tests assert behavior, not shape.** A test that only checks a value round
-trips through a dictionary is not telling us anything. Test what would break.

**Documentation carries examples.** Every public symbol gets a doc comment,
and anything non-obvious gets a runnable example in it. The DocC guides in
`Sources/Changesets/Changesets.docc/` are part of the library, not an
afterthought.

**Zero dependencies stay zero.** The only dependency in `Package.swift` is
swift-docc-plugin, gated behind `SWIFT_CHANGESET_BUILD_DOCS` so consumers never
resolve it. Please keep it that way.

## Scope

This library is deliberately thin. It does not cast types, build queries, talk
to a database, or run migrations. Proposals that push it toward being an ORM
are likely to be declined — but nested changesets and optimistic locking are
both known gaps and would be welcome.
