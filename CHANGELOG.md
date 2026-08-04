# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Aggregate errors (#36), for the "several things went wrong at once" shape that validation
  produces. A type declared `aggregate: true` gains an `:errors` field holding member errors:

  ```elixir
  defmodule MyApp.Orders.ValidationFailed do
    use Errata.DomainError, aggregate: true
  end

  ValidationFailed.new(errors: [email_error, age_error])
  ```

  The alternative was modelling it as one error with a list of maps in `:context`, which throws
  away everything the library is for — each sub-failure loses its type, code, HTTP status,
  severity, and retryability and becomes inert data. An aggregate keeps them as errors: members
  serialize through `to_map/1` and the JSON encoders with their own types and codes, and with
  their own redaction rules applied.

  The aggregate is itself an ordinary Errata error, so `is_error/1`, raising, `{:error, _}`
  tuples, and boundary code all keep working. `Errata.errors/1` reaches the members and returns
  `[]` for an ordinary error, so callers never branch on whether they hold an aggregate;
  `Errata.aggregate?/1` asks about the type.

  The design work was the merge rules, and the three deliberately differ:

  - **`severity/1` — the most severe member.** Severities are totally ordered, so the maximum is
    unambiguous, and it is what a log level should be.
  - **`retryable?/1` — retryable only if every member is.** Retrying helps only if all of it
    could succeed next time; one permanent failure makes the retry pointless.
  - **`http_status/1` — the members' status if they agree, otherwise the aggregate's own.**
    There is no meaningful maximum over status codes, so picking a "highest" would be arbitrary;
    unanimity is the only member-derived answer that is never wrong.

  An empty aggregate falls back to its own declared values, and each rule stays overridable per
  type. Members must themselves be Errata errors — a bare map cannot answer those three
  questions, so anything else raises `ArgumentError` at construction. See `Errata.Aggregate`.

- Redaction of sensitive values in error context (#35). Errata encourages capturing
  arbitrary metadata in `:context` and then ships it outward — `to_map/1` and the JSON
  encoding, `Errata.log/2` as Logger metadata, `Errata.report/2` as telemetry metadata.
  There was no way to keep a value out of that path, so `context: %{params: params}`
  put a password in the log aggregator. Unlike the other items on the list this was a
  safety gap rather than a missing feature: the default behavior was the unsafe one and
  nothing in the docs said so.
  - A `:redact` option declares a type's sensitive keys:

    ```elixir
    use Errata.DomainError, redact: [:password, :token]
    ```

  - Redaction is **recursive** and matches atom and binary keys alike. This is the
    point rather than a bonus: the common leak is not `%{password: pw}` but a params
    map captured wholesale, where the sensitive key is nested and has a string key.
  - It applies at the **serialization seam**, not at creation, so the struct you hold
    keeps the real values for local debugging. Only what Errata emits is redacted.
  - `config :errata, redact: [...]` sets a global floor for every error type. The
    default is `[]` — nothing changes shape until an application opts in.
  - The generated `redact_context/1` is overridable for rules a key list cannot
    express, and every serialization seam dispatches through it, so an override
    applies to all of them rather than the one its author was looking at.
  - `Errata.Redaction` is public, so custom overrides can reuse the recursive walk.

### Changed
- The `error/0`, `domain_error/0`, and `infrastructure_error/0` types now carry an
  `optional(:errors)` key, so that code matching on an aggregate's members type-checks. This is
  additive: an ordinary error still matches, and no existing spec becomes invalid.
- `Errata.report/2` telemetry metadata now carries the `:error` struct with its context
  redacted, not just the separate `:context` key (#35). Leaving the raw struct there
  would have made redaction pointless in the case it exists for — a handler forwarding
  `metadata.error` to an external service would ship the unredacted context. The struct
  is otherwise untouched: same type, same reason, still pattern-matchable and
  re-raisable. This only affects error types that declare `:redact` keys or applications
  that set the global config; with neither, metadata is unchanged.

## [1.4.0] - 2026-07-31

### Added
- Stable external error codes. An error type can declare a `:code` (such as
  `"ORDER_NOT_FOUND"`) that is independent of its Elixir module name, giving
  external consumers — API clients, i18n catalogs, support tooling — an
  identifier that survives renaming or moving the module. Retrieve it with
  `Errata.code/1` or the generated per-module `code/1`, which is overridable so a
  type can derive a code from the error's `:reason` or `:context`. Codes are
  opt-in with no default: a type that does not declare one returns `nil`, since
  deriving a code from the module name would reintroduce the coupling the option
  exists to break. (#22)
- Severity and retryability classification on error types. (#24)
  - `Errata.severity/1` returns an error's severity as a `Logger` level, set per
    type with the `:severity` option. It defaults to `:error` for every kind, so
    nothing is reclassified unless a type opts in.
  - `Errata.retryable?/1` returns whether an error is likely transient, set per
    type with the `:retryable` option and defaulting off the error's kind:
    `:infrastructure` errors are retryable, `:domain` and `:general` errors are
    not. Errata provides no retry mechanism of its own — this is a classification
    for your own retry logic to branch on.
  - Both are generated as overridable per-module functions (`severity/1` and
    `retryable?/1`), following the same pattern as `http_status/1`, so a type can
    compute either from the error's `:reason` or `:context`. Neither adds a field
    to the error struct or to the `to_map/1` / JSON shape.

### Changed
- `Errata.to_map/1` (and therefore the JSON encoding) now includes a `code` key,
  which is `null` for error types that do not declare a `:code`. This is additive
  to the serialized shape — the key is always present, consistent with the
  existing `message`, `cause`, and `env` keys, which are likewise emitted when
  empty. Consumers that ignore unknown keys are unaffected. (#22)
- `Errata.log/2` now logs at the error's `severity/1` when no level is given, and
  `Errata.report/2` with `log: true` does the same. Since severity is `:error`
  unless a type sets one, this is backward compatible for existing error types.
  (#24)
- `:code`, `:severity`, and `:retryable` are now included in the metadata emitted
  by `Errata.log/2` (as Logger metadata) and `Errata.report/2` (as top-level
  `[:errata, :error]` telemetry metadata), so handlers can route or alert on them.
  (#22, #24)

### Fixed
- The `t:Errata.error/0` type declared `env: Errata.Env.t()`, but an error created
  with `new/1` has no environment. It is now `Errata.Env.t() | nil`, matching
  `t:Errata.domain_error/0` and `t:Errata.infrastructure_error/0` and the actual
  behavior.

## [1.3.0] - 2026-06-04

### Added
- `use Errata` — a convenience macro for modules that handle or create Errata
  errors. It imports the three guards (`is_error/1`, `is_domain_error/1`,
  `is_infrastructure_error/1`) so they can be used unqualified in `when` clauses
  and function heads, and (because `import` implies `require`) makes the
  `Errata.create/2` and `Errata.wrap/3` macros callable. Only the guards are
  imported; the rest of the API stays qualified. This is distinct from
  `use Errata.Error`, which defines a new error type.

## [1.2.0] - 2026-06-04

### Added
- `Errata.wrap/2` and `Errata.wrap/3` macros, which wrap a cause in an error of
  any type while capturing the current `__ENV__` and stacktrace — the convenience
  counterpart to the per-module `wrap/2` macro, mirroring `Errata.create/2`. This
  lets a module wrap causes for several error types without a separate `require`
  for each one.

## [1.1.0] - 2026-06-03

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

### Upgrading
- If your project calls `Jason` directly but relied on Errata to pull it in
  transitively, add `{:jason, "~> 1.4"}` to your own dependencies, since Errata
  no longer forces it into your dependency tree. On Elixir 1.18+ you can instead
  use the built-in `JSON` module and drop the Jason dependency entirely.

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

