# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [1.7.0] - 2026-08-19

### Added
- `Errata.from_map/3` and `Errata.from_map!/3` (#48), the counterpart to `to_map/1`: an Elixir
  application that has an error type compiled can rebuild an error of that type from its encoded
  form, and get concrete-struct pattern matching and the guards back with it.

  ```elixir
  {:ok, error} = Errata.from_map(MyApp.Orders.OrderNotFound, decoded_json)
  match?(%MyApp.Orders.OrderNotFound{}, error)  #=> true
  ```

  Accepts the map from `to_map/1` directly or the result of decoding its JSON — string and atom
  keys both work. `from_map/3` returns `{:ok, error} | {:error, reason}`, since malformed input is
  an expected condition where this gets called; `from_map!/3` returns the error and raises, for
  payloads from somewhere you control. Passing a module that is not an Errata error type is a
  programming error and raises in both.

  **The type is an argument, not read from the encoded `error_type`.** Resolving a module from a
  name off the wire would mean trusting that name *and* keeping a registry of every error type —
  the central registry that Errata's structural `is_error/1` guard exists to avoid. This is the
  same reasoning that kept `to_error/2`'s fallback out of application config in 1.5.0.

  **Atom safety comes from `:reasons` rather than from `String.to_existing_atom/1`.** A type that
  declares its reasons is decoded by matching the incoming value against that declared set, so
  nothing from the wire reaches `to_existing_atom/1` at all — and a reason whose atom exists but is
  not declared for *this* type is refused, which the `to_existing_atom` approach would accept and
  then fail on at construction. Types without declared reasons fall back to `to_existing_atom/1`,
  which is why declaring `:reasons` is now worth doing on anything that crosses a boundary.

  A decoded error is a faithful *classification*, not a faithful reconstruction, and the docs say
  so plainly: `:kind`, `http_status/1`, `severity/1` and `retryable?/1` are recomputed from the type
  in the receiving application and the encoded values are ignored, so the receiver's own definitions
  win even when the sender runs an older version; `:env` is always `nil`, since it described a
  location in the sending process; `:cause` is kept as the decoded value rather than rebuilt; and
  context redacted on the way out stays redacted.

  Two deliberate limits. **Aggregate types are refused** rather than silently losing their members,
  because each member carries its type only as a name — decode members individually and rebuild
  with `new/1`. And **context keys come back as strings** by default, because `:context` holds
  arbitrary data and converting it is where an atom-exhaustion risk would live; `keys:
  :existing_atoms` converts the keys that already exist, recursively and best-effort, leaving
  unknown ones as strings.

  This completes #48, whose classification half shipped in 1.6.0.

### Changed
- `Errata.log/2` and `Errata.report/2` now include `:http_status` in their metadata, alongside the
  `:kind`, `:reason`, `:error_type`, `:code`, `:severity` and `:retryable` keys that were already
  there. A telemetry handler can now tag on the same classification a boundary branches on — a
  5xx-rate metric, for instance — without re-deriving the status from `:kind`.

  1.6.0 put all five classifications in `to_map/1` but left the metadata with four, and that
  asymmetry was documented as deliberate on the grounds that a log line and a telemetry event are
  not HTTP responses. That reasoning is still true as far as it goes, but it did not survive the
  comparison: `:retryable` is derived from `:kind` in exactly the same way and has always been in
  the metadata, so "derived, and only meaningful in some contexts" was never the line being drawn.
  What was left was an omission that had to be explained everywhere the key list appears, which
  costs more over time than a key some handlers ignore.

  Additive: metadata is a map (telemetry) and a keyword list (Logger), so existing handlers and
  formatters are unaffected unless they assert on the exact key set. Types that compute
  `http_status/1` from `:reason` or `:context` have that computed value in the metadata, since this
  dispatches through the same overridable function as `code/1`, `severity/1` and `retryable?/1`
  already do.

## [1.6.0] - 2026-08-19

### Added
- The error's classification now travels with it through `Errata.to_map/1`, and therefore through
  the `Jason.Encoder` / `JSON.Encoder` implementations (#48). The serialized form gains four keys:
  `kind`, `http_status`, `severity`, and `retryable`.

  Errata's premise is that a boundary can ask any error what status to return, how loudly to log it,
  and whether retrying is worth attempting. That held only while the error struct was in hand: the
  moment it was serialized — an API response, a job payload, a message on a queue — the answers were
  gone, because computing them requires the error's module. Of the five classifications, only `code`
  crossed the wire. A receiving service had to re-derive the rest from the module name, which the
  docs correctly tell people not to match on, since it is an implementation detail that moves when
  the module moves.

  ```json
  {
    "error_type": "MyApp.Http.RequestFailed",
    "reason": "timeout",
    "kind": "infrastructure",
    "http_status": 503,
    "severity": "error",
    "retryable": true
  }
  ```

  The four keys are computed through the same overridable functions as the accessors, so a type that
  derives its status or retryability from `:reason` serializes what it actually computed rather than
  a default. A wrapped `:cause` and the members of an aggregate serialize through the same
  `to_map/1`, so each carries its own classification instead of inheriting the outer error's.

  This is deliberately the *classification* half of #48 and not the deserialization half. Putting
  the answers on the wire serves a consumer that does not hold the error's module — another service,
  or a program not written in Elixir — and needs no atom-safety or module-resolution machinery to do
  it. A `from_map/2` that reconstructs the struct serves the opposite case, where the receiving VM
  already has the module compiled and could recompute the classification anyway; it remains open,
  now with the cheaper half no longer blocking on it.

  Additive under SemVer: map patterns are open, so existing matches on `to_map/1` still hold. Only
  an assertion of exact map equality would need updating.

## [1.5.0] - 2026-08-18

### Added
- `Errata.to_error/2` and `Errata.UnknownError` (#46), for the errors an application did *not*
  define: `{:error, :timeout}` from a client library, an `Ecto.Changeset`, a
  `DBConnection.ConnectionError`. Errata's boundary accessors are strict on purpose —
  `Errata.http_status(:timeout)` raises rather than guessing a `500` — so a fallback controller had
  one uniform clause and a hand-written one for everything else.

  `Errata.to_error/2` is total, and returns an Errata error unchanged so it is safe to apply to a
  value that may already be normalized:

  ```elixir
  Errata.to_error(:timeout)        # an Errata.UnknownError, reason: :timeout, cause: :timeout
  Errata.to_error(existing_error)  # existing_error, unchanged
  ```

  `Errata.UnknownError` is the default target, and the first concrete error type Errata itself
  ships. It is an ordinary `:general` error — a `500`, not retryable — with the original value kept
  as its `:cause`, so `root_cause/1` and `format_chain/1` still reach it. Pass
  `fallback: MyApp.UnexpectedError` to land in an application's own catch-all instead. There is
  deliberately no application config for this: a global setting would be the central registry that
  Errata's structural `is_error/1` guard exists to avoid, and it would mean a library calling
  `to_error/1` minted the *application's* error type.

  This classifies nothing on its own, and is not meant to. A `500` is right for a genuinely unknown
  value and wrong for a changeset (a `422`) or a connection timeout (a retryable `503`), so
  `to_error/1` is documented as the base case beneath an application's own dispatch function rather
  than as a replacement for one:

  ```elixir
  defmodule MyApp.Errors do
    def to_error(%Ecto.Changeset{} = changeset),
      do: MyApp.ValidationFailed.new(reason: :invalid, cause: changeset)

    def to_error(other), do: Errata.to_error(other)
  end
  ```

  An `Errata.Convertible` protocol was built for this and then cut before release. Every
  implementation would have been written by the same application that calls `to_error/1` — neither
  Ecto nor Finch is going to depend on Errata to write one, and a library that already uses Errata
  returns Errata errors — so the open-extension property that justifies a protocol never came into
  play, while its constraints (one implementation per type, globally, forever) did. Function clauses
  are the simpler tool when one party owns both sides, and they let two boundaries classify the same
  value differently. A protocol can be added later without breaking anything, which is the reason to
  wait rather than guess.

  `to_error/2` is a plain function rather than a macro, unlike `wrap/3`. That makes it capturable
  (`&Errata.to_error/1`) at the cost of leaving `:env` nil — which is the honest result anyway,
  since normalization happens in a generic boundary function whose location says nothing about where
  the failure came from.

  Two details worth knowing: an atom becomes the `:reason` as well as the cause, but only when the
  target type would accept it, since deriving a reason that a type's `:reasons` list rejects would
  turn the call that exists to stop unknown values escaping into a raise. And `{:error, reason}`
  tuples are *not* unwrapped, since a value that legitimately is a two-tuple cannot be told apart
  from one that means "error" — match the tuple at the call site instead.

- `Errata.reason/1`, `Errata.context/1`, and `Errata.kind/1` (#39), completing an accessor set that
  already had `code/1`, `severity/1`, `http_status/1`, `retryable?/1`, `cause/1`, and
  `display_message/1`. `context/1` returns `%{}` rather than `nil` for an error created without
  context, so calling code can treat the result as a map unconditionally, and it returns the
  *unredacted* context — redaction applies to what Errata serializes and emits, not to the error in
  your own hands.

  These are also the answer to the type-checker interaction the README documented. Measured on
  Elixir 1.20, the picture is narrower than the issue assumed: field access after a structural
  guard (`{:error, e} when Errata.is_error(e) -> e.reason`) is **warning-free**, and the one shape
  that still warns — a variable bound by a bare `rescue e ->` — warns for *any* exception, not just
  an Errata one (`e.message` on a plain `RuntimeError` warns identically). So this is ordinary
  Elixir behaviour rather than something Errata does to you, and the accessors are a plain function
  call that sidesteps it.

  The README's info box has been rewritten accordingly, and its `Map.fetch!/2` advice dropped — that
  workaround is not needed. Structural-guard field access is verified warning-free across the whole
  supported range, 1.15 through 1.20; the bare-`rescue` warning appears from 1.17, when the type
  checker landed. The compile-time behaviour is now pinned by tests, so a future Elixir that
  changes it will say so.

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

### Added
- Generated error types now have an overridable `display_message/1` function (#45), so a type can
  compute its user-facing message from its `:reason` or `:context` rather than being limited to a
  static `:default_message`:

      defmodule MyApp.Orders.OrderNotFound do
        use Errata.DomainError, default_message: "the requested order does not exist"

        def display_message(%{context: %{order_id: id}}), do: "order #{id} does not exist"
        def display_message(error), do: error.message
      end

  `Errata.display_message/1` and `Errata.to_map/1` (and therefore the JSON encoding) now dispatch
  through it, so an override reaches every place a user-facing message is read. This brings
  `display_message/1` in line with `http_status/1`, `code/1`, `severity/1`, and `retryable?/1`,
  which were already generated-overridable-and-delegated; it was the only one reading the struct
  field directly. The default returns the `:message` field unchanged, so behavior is unchanged for
  types that do not override it.

### Documentation
- The README is split into a short front page plus guides (#40). It was 955 lines, and everything
  added since 1.0 had landed in one linear page — the cumulative effect overstated what a reader
  has to learn to start. The front page now covers what Errata is, the quick start, defining error
  types, creating and raising them, and an index; four new guides under `guides/` cover the rest:

    * `guides/handling-errors.md` — the guards, `use Errata`, values vs. rescuing.
    * `guides/boundaries.md` — HTTP status, external codes, severity and retryability, and
      rendering an error for a user.
    * `guides/wrapping-errors.md` — `wrap/2` and cause chains, context enrichment, and aggregates.
    * `guides/observability.md` — `log/2`, `report/2`, the telemetry contract, and redaction.

  `guides/design.md` gains the "type vs. reason" and "Why Errata?" material alongside the `:kind`
  guidance it already held. Doctest coverage moved with the content rather than being lost: the 23
  README doctests are now 16 on the front page plus 7 in the guides, run by `doctest_file/1` in the
  new `test/guides_test.exs`.
- The shared doctest fixtures (`MyApp.Orders.*`) moved from the top of `test/errata_test.exs` into
  `test/support/my_app.ex`, so that any single test file needing them can be run on its own. This
  also makes `elixirc_paths(:test)`'s long-standing `test/support` entry point at a directory that
  exists.

- A "Dynamic messages" section in the README (#23) showing how to compute a user-facing message
  from an error's `:reason` or `:context` by overriding `display_message/1`, rather than building
  the string by hand at every call site. This is the answer to message templating: a plain function
  and pattern matching, with no template syntax to learn and no missing-key failure mode. The
  examples are doctests, including the one showing that the override deliberately does *not* change
  the developer message that `Exception.message/1` and logs use. The `:default_message` option docs
  now point at it.

### Fixed
- `to_string/1` (the `String.Chars` implementation) now respects an overridden `message/1` (#45).
  It called the internal message formatter directly, so a type that overrode `message/1` got its
  custom rendering from `Exception.message/1`, `raise`, and `Errata.log/2`, but silently got the
  default from `to_string/1` — despite the two being documented as the same developer-oriented
  message. `to_string/1` and `Exception.message/1` now always agree.

### Documentation
- `Errata.create/2` is now documented as the recommended way to create an error (#37). It captures
  the same `:env` as the per-module `create/1` macro, but because it takes the error type as an
  argument, a single `use Errata` covers every error type a module creates — the per-type `require`
  that `create/1` needs is never required. The README and the `Errata.Error` moduledoc now lead with
  it.
- `c:Errata.Error.create/1` documents the cost of capturing the environment: on the order of a
  microsecond per error, and flat with respect to stack depth, since the VM already caps the
  captured stacktrace at 8 frames. Explicitly *not* a reason to reach for `c:Errata.Error.new/1`.
- `c:Errata.Error.new/1` says what it is actually for, rather than reading as a trap: the cases a
  macro cannot serve — dynamic invocation via `apply/3`, capturing as `&SomeError.new/1` — plus
  tests and fixtures, where `env: nil` keeps error structs easy to compare.

- A new "Design notes" guide (`guides/design.md`, #38) covering the `:kind` taxonomy from the
  user's side: what each kind actually decides, how to choose one, where external-service errors
  belong, and how to opt out of the taxonomy entirely by defining every type with the base
  `Errata.Error`. Two points it makes plainly that the reference docs did not: `kind` supplies
  defaults for `http_status/1` and `retryable?/1` only — `severity/1` and `code/1` do not derive
  from it — and the `http_status/1` default is a starting point that domain errors often override,
  while the `retryable?/1` default is usually right. The guide's examples are pinned by
  `test/errata/design_guide_test.exs`, since they are module definitions rather than doctests.

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

