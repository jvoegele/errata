# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `Errata.to_map/2` takes an `:only` or `:except` projection, so one error can be serialized two
  ways for its two audiences (#63).

  ```elixir
  Errata.to_map(error)                                        # the full record, for a reporter
  Errata.to_map(error, except: [:env])                        # for a response body
  Errata.to_map(error, only: [:code, :message, :retryable])   # narrower still
  ```

  `to_map/1` has always been a single serialization serving two consumers with opposite
  requirements: an error reporter, which wants everything, and an HTTP response body, which should
  carry as little as possible. It always included `:env` — which names the module, function, line,
  and source file where the error was created — and the boundaries guide's fallback controller led
  a reader straight into handing that to a client.

  The projection **reaches aggregate members and a wrapped Errata cause**, so `except: [:env]`
  removes every `:env` in the structure rather than only the outermost one; leaving members' `:env`
  in place would be a trap of exactly the kind the option exists to remove. A cause that is a plain
  exception rather than an Errata error is left alone, since it has no `:env` to drop and an
  `:only` projection would mangle it. Keys are validated against the set `to_map/1` can produce, so
  `except: [:envv]` raises rather than quietly selecting nothing.

  The encoder protocols are unchanged and still emit the full map. `Jason.Encoder` takes no
  options, and the reporting projection is the right default for what the protocols exist for —
  but that means encoding an error struct directly at a client-facing boundary still emits `:env`.
  `guides/boundaries.md` now says so under a warning admonition, and shows selecting fields
  explicitly instead.

- `Errata.root_error/1`, the deepest **Errata error** in a cause chain.

  A cause chain is Errata errors all the way down, ending in at most one foreign value — a bare
  atom, an `{:error, reason}` tuple, a standard exception. `cause/1` only accepts Errata errors, so
  a foreign value can only ever be at the bottom. And that bottom value is frequently the least
  useful thing in the chain: `:econnrefused` has no message, no context, no code and no
  classification, while the error wrapping it has all four.

  ```elixir
  error = Errata.wrap(RetriesExhausted, :econnrefused, reason: :timeout)

  Errata.root_cause(error)                    #=> :econnrefused
  Errata.root_error(error) |> Errata.code()   #=> "RETRIES_EXHAUSTED"
  ```

  The two differ **exactly** when the chain bottoms out in a foreign value, and are the same value
  otherwise. Which to reach for follows from that: `root_cause/1` diagnoses *what failed*, and is
  what a developer wants in a log; `root_error/1` is the deepest thing that still carries Errata's
  structure, and is what you hand to a view, a reporter, or a retry decision. `root_error/1` always
  returns an Errata error, so a caller never has to check what it got, where `root_cause/1` may
  return either and leaves that to the caller.

  They are not two views of the same fact. `wrap/2` keeps the cause in `:cause` and copies nothing
  out of it — a wrapped error's `:reason` and `:context` are untouched by what it wraps — so the two
  answers can be entirely different sentences, and neither is recoverable from the other's fields.

  This came out of the boundary recipe added below. Written against `root_cause/1`, the recipe's
  consumer module needed a three-clause `case` — with a clause-order trap, since an Errata error is
  *also* an exception — and an `inspect/1` fallback that would have shown a person the string
  `":timeout"`. Written against `root_error/1` it is a pipeline with no branching:

  ```elixir
  def user_message(value) do
    value |> Errata.to_error() |> Errata.root_error() |> Errata.display_message()
  end
  ```

  It is also more correct. The old version surfaced `Exception.message/1` from a foreign root
  cause: `"connection refused"` reads fine in a log, but on a screen it is text nobody wrote for a
  user, where the wrapping error's `display_message/1` is text somebody did.

- An application-wide fallback for types that declare no `:default_message` (#64):

  ```elixir
  config :errata, default_display_message: "an unexpected error occurred"
  ```

  `:default_message` is optional and the README presents the bare one-line definition as the normal
  starting point, so a type rendering as `nil` through `display_message/1`, `to_map/1`, and the JSON
  encoding is easy to reach — and `"error": null` in a response body is worse than a generic string.
  The library's own design guide worked around it with a `|| "invalid request"` at the point of
  use, which is the right advice but is one line every application repeats at every boundary.

  Defaults to `nil`, so nothing changes until an application opts in. It applies only where the type
  declares nothing and the caller passed no `:message` — a declared `:default_message` and a
  per-error `:message` both win — and it is read at runtime, mirroring `config :errata, redact:`,
  which is the closest existing analogue: a global floor that individual types refine. Because
  `to_map/1` dispatches through the generated `display_message/1`, the fallback reaches the encoded
  map too, which is precisely the consumer with no other source for a message. The developer
  message (`Exception.message/1`) is unaffected.

### Changed
- **`Errata.root_cause/1` now returns the error itself when the error has no cause**, instead of
  `nil` (#72). An error's chain includes the error, so the function is total: there is always a
  deepest thing in the chain, and it is the error when nothing is underneath it.

  ```elixir
  error = OrderNotFound.new(reason: :not_found)

  Errata.root_cause(error) == error   # was: nil
  Errata.cause(error)                 #=> nil, unchanged
  ```

  The `nil` was doing a job `cause/1` already does, and doing it in place of its own. Three things
  inside the library pointed the same way:

  - **`format_chain/1` already includes the error itself** — it renders an uncaused error as a
    one-element chain. `root_cause/1` was the one function that modelled the chain as causes-only.
  - **`errors/1` already returns a total answer** (`[]` for a non-aggregate) precisely so that
    "calling code never has to branch on whether it has an aggregate", which is how the guide
    describes it. `root_cause/1` returning `nil` was the same decision made the other way.
  - **`root_cause/1` could not be implemented without the workaround it asked users to write.** Its
    recursive clause read `root_cause(value) || value`, because the recursive call returned `nil`
    for an uncaused inner error. That `||` is now gone; the recursion is total.

  A dogfooding application hand-wrote its own `root_cause/1` rather than using this one, and the
  version it wrote returns the error itself — which is the behaviour the name leads people to
  expect.

  **Upgrading.** Code written the way the docs describe it — `Errata.root_cause(error) || error` —
  keeps working unchanged, since `error || error` is `error`; the `|| error` can now be deleted.
  What breaks, and breaks *quietly*, is code using the `nil` to detect the absence of a cause:

  ```elixir
  # Now always truthy — this branch is dead.
  if Errata.root_cause(error), do: ..., else: ...

  # The nil clause is now unreachable.
  case Errata.root_cause(error) do
    nil -> ...
    cause -> ...
  end
  ```

  Grep for `root_cause` near `if`, `case` or `nil`. In every such place the replacement is
  `Errata.cause/1`, which answers that question directly and is unchanged.

- The source path in a serialized error is now relative to the project root rather than absolute
  (#63). `to_map(error).env.file` reads `lib/my_app/orders.ex` instead of naming the directory
  layout of the machine that compiled the code — which in a release built on a developer machine
  can include a username. The `Errata.Env` struct still holds the absolute path it was compiled
  with; only what crosses the wire changes.

  The root is captured when the error *type* is defined, which is during the using application's
  compile, because it cannot be recovered at runtime — a release's working directory is the release
  root, not the build tree. One consequence: if an application constructs an error type belonging to
  a *library* directly, the roots differ and the path is emitted unchanged, as before. Errors a
  library creates for itself, which is the ordinary case, are relative.

### Fixed
- Unknown or misspelled `use` options are now a compile-time `ArgumentError` instead of being
  silently ignored (#62).

  ```elixir
  defmodule Typo do
    use Errata.DomainError, htp_status: 404
  end
  #=> ** (ArgumentError) invalid option(s) for Typo: [:htp_status].
  #=>    Valid options are [:default_reason, :default_message, :reasons, :http_status, :code,
  #=>    :severity, :retryable, :redact, :aggregate].
  ```

  Previously `define/3` validated the *values* of `:reasons` and `:aggregate` and never looked at
  the key set, so `htp_status: 404` produced a type with the default `422` and `defualt_message:`
  produced `message: nil` — both plausible enough that nothing downstream looks broken. This is the
  same defect class as #3, which was fixed for `new/1` and `create/1` params but not at the `use`
  site, which is the worse of the two: a param typo is caught the first time that line runs, while
  a `use` option is written once and the misconfiguration is permanent.

  It raises rather than warns, for consistency with the `new/1` param check and with
  `:reasons`/`:aggregate` validation, and because the entire value of the check is that it cannot
  be scrolled past. Strictly this is a breaking change for code passing a stray key, but such code
  is by definition already not doing what its author intended.

  Two related tightenings fall out of the same allowlist:

  - `:kind` is now rejected by `use Errata.DomainError` and `use Errata.InfrastructureError`, which
    set the kind themselves and previously ignored it. The message points at `use Errata.Error`.
  - An invalid `:kind` *value* (`use Errata.Error, kind: :bogus`) raises `ArgumentError` naming the
    three valid kinds, rather than a bare FunctionClauseError from the code generator.

### Documentation
- A new guide, `guides/testing.md` (#69). There was no guidance on testing an application that
  uses Errata, and what existed was scattered — one line in a README tip box, one convention
  visible only by reading this repository's own test files. Three of the five things it covers
  produce failures that read as library bugs at first glance.

  Its core advice is to **assert through the accessors**. That was measured rather than assumed:
  on an identical wrong-reason assertion, `assert Errata.reason(error) == :x` produces a two-line
  diff naming the field, where nulling `:env` produces ~16 lines, a whole-struct pattern match
  ~30, and plain `==` ~40. Pattern matching is explicitly *not* recommended despite asserting
  correctly, because ExUnit expands the entire right-hand term on a failed match and the `:env`
  stacktrace swamps the output.

  Also covers where fixture types must be defined and why; the seam at which redaction has to be
  asserted (`error.context` still holds the plaintext — checking it first is how redaction looks
  broken); the two things `:redact` structurally cannot protect, with a `refute_leaks/2` recipe;
  the `:telemetry_test` idiom, which needs no new dependency; that `capture_log/1` needs
  `metadata: :all` before the metadata `log/2` exists for appears; and that `assert_raise` matches
  the *developer* message rather than the display message.

  Every example is pinned by `test/errata/testing_guide_test.exs`, following `design_guide_test.exs`
  — the guide's examples are ExUnit assertions rather than `iex>` sessions, so they cannot be
  doctests.

- An "unwrapping a wrapped error" recipe in `guides/wrapping-errors.md` (#72). A dogfooding
  application hand-wrote a six-line `root_cause/1` loop and shipped it without noticing
  `Errata.root_cause/1` exists — and what it wrote differs from the built-in in the two ways that
  would have stopped it dropping into the call site anyway.

  `root_cause/1` returns `nil` when there is no cause, which is the truthful answer to the question
  it asks but rarely the one a call site wants, so `Errata.root_cause(error) || error` is the form
  to reach for — an idiom that appeared nowhere in the docs. And it raises on a non-Errata value,
  like every accessor, so a consumer holding whatever a `with` chain returned has to normalize
  first; `to_error/2` and `root_cause/1` compose, and the guides never paired them.

  `root_cause/1` was mentioned twice before, both times as the tail of a sentence about something
  else, and never under a heading a reader would scan for when the question is "this error's
  message is useless, how do I get to the real one".

  The recipe ends with a consumer-side module that only *reads* errors, which is also the natural
  place to show that the guards are `defguard`s: a module needs `require Errata` even to call them
  fully qualified, and every other guide example picks that up invisibly via `use Errata`.

- A worked end-to-end boundary example in `guides/boundaries.md` (#68). The guides showed the
  Phoenix fallback controller three times and never the view it renders through, so every adopter
  independently decided what an error looks like on the wire — the decision the `:env` exposure
  above makes easy to get wrong.

  The `to_map/2` projection turns the view into a single call, and two properties of it do the
  work: the projection recurses into aggregate members, so each renders by the same rule including
  its own `code`; and `:errors` is absent for a non-aggregate, so one clause covers both shapes.
  That gives the validation-response case a worked example for the first time — it is what
  aggregates were built for, and nothing showed one crossing an HTTP boundary.

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

