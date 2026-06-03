# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [1.1.0]

### Added
- Native JSON support: on Elixir 1.18 and later, every error type now implements
  the built-in `JSON.Encoder` protocol, so `JSON.encode!(error)` works with no
  third-party dependencies. The built-in and Jason backends produce the same JSON
  shape. (#30)

### Changed
- `jason` is now an *optional* dependency. Projects that have Jason continue to
  get a generated `Jason.Encoder` implementation exactly as before; projects on
  Elixir 1.18+ that don't use Jason can now drop it and rely on the built-in
  `JSON` encoder. This is backward compatible — anyone who depends on
  `Jason.encode!(error)` already has Jason in their own dependencies. (#30)

## [1.0.0] - 2026-06-03

First stable release. As of 1.0.0 the public API — the error struct shape, the
`Errata` guards and helper functions, the generated `Errata.Error` callbacks, and
the `to_map/1` / JSON and `[:errata, :error]` telemetry shapes — is covered by
[Semantic Versioning](http://semver.org/spec/v2.0.0.html).

### Added
- Context enrichment: `Errata.put_context/3` and `Errata.merge_context/2` add to
  an error's `:context` as it propagates, so intermediate layers can attach
  context the creation site did not have without rebuilding the struct. (#18)
- Declared reasons: error types can now enumerate their valid reasons with the
  `:reasons` option (`use Errata.DomainError, reasons: [...]`). Creating an error
  with a reason outside the declared set raises an `ArgumentError` (a `nil` reason
  is always allowed); a `:default_reason`, if given, must be one of the declared
  reasons; and a `reason/0` type enumerating them is generated for the docs. (#20)
- Error reporting: `Errata.log/2` logs an error at a given level with its
  `reason`, `kind`, `context`, and origin attached as structured Logger metadata;
  `Errata.report/2` emits a `[:errata, :error]` telemetry event (and optionally
  logs), providing a vendor-neutral seam for forwarding errors to Sentry, metrics,
  etc. via a telemetry handler in your application. Adds a `telemetry ~> 1.0`
  dependency. (#19)
- HTTP status mapping: each error type now has a generated, overridable
  `http_status/1` function (and a matching `Errata.http_status/1`) that defaults
  off the error's kind (`:domain` → `422`, `:infrastructure` → `503`, `:general`
  → `500`). Set a specific status with the `:http_status` option, or override the
  function to compute one from the error. No web-framework dependency is added. (#21)

## [0.10.0] - 2026-06-02

### Added
- Error wrapping (chaining): error types can now carry a `:cause` — the original
  error, exception, or value that led to them — without losing the context of
  the underlying failure.
  - A generated `wrap/1,2` macro on each error module wraps a caught error as the
    `:cause` of a new error, capturing the current `__ENV__` (like `create/1`)
    and, when given `stacktrace: __STACKTRACE__`, the original error's stacktrace.
  - `new/1`, `create/1`, and `raise/2` now also accept a `:cause` param.
  - The cause is stored as an `Errata.Cause` struct (`kind`/`value`/`stacktrace`).
  - `Errata.cause/1` returns the immediate cause; `Errata.root_cause/1` walks the
    chain to the deepest cause; `Errata.format_chain/1` renders the full
    `Caused by:` chain for logging.
  - `to_map/1` (and JSON) now include the cause, recursing into wrapped Errata
    errors and rendering standard exceptions by type and message.

## [0.9.0] - 2026-06-02

### Added
- `Errata.create/2` macro to create an error of any type while capturing the
  current env, without a separate `require` for each error module. (#4)
- `Errata.to_map/1` to convert any Errata error to a plain, JSON-encodable map
  without needing to know the error's specific module. (#5)
- `Errata.display_message/1` to retrieve the bare, human-readable `:message` of
  an error (without the `:reason` suffix that `Exception.message/1` appends),
  for rendering errors to end users. (#7)

### Changed
- **Breaking:** `new/1`, `create/1`, and `raise/2` now raise an `ArgumentError`
  when given unrecognized param keys instead of silently ignoring them. Only
  `:message`, `:reason`, and `:context` are accepted. Callers that previously
  relied on extra keys being dropped will need to remove them. (#3)

### Fixed
- Serialized error maps (`to_map/1`) and their JSON form no longer leak the
  `Elixir.` prefix on module names: `error_type` and `env.module` are now
  rendered as e.g. `"MyApp.Foo"` (as strings rather than raw atoms), and
  `env.file_line` no longer includes a trailing colon. (#6)

