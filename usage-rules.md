# Errata usage rules

Structured, named error handling. An Errata error is an ordinary `Exception` struct that can be
**returned as a value or raised**, carrying a `message`, a `reason` atom, a `context` map, a
`cause` (the error it wrapped), and an `env` (module, function, file, line, stacktrace).

Taken together, an application's error types are a named catalogue of the ways it can fail.

## Setup

```elixir
# mix.exs
{:errata, "~> 1.8"}
```

JSON encoding needs no configuration: on Elixir 1.18+ every error type implements the built-in
`JSON.Encoder`; if `jason` is present it implements `Jason.Encoder` too. Both emit the same shape.

In any module that creates or classifies errors:

```elixir
use Errata     # not `require` — this requires AND imports the three guards
```

## Rule 0: define error types in compiled code

**This is the trap that costs the most time, because it fails far from its cause.**

`use Errata.DomainError` and friends generate `String.Chars` and JSON protocol implementations,
and protocols are **consolidated when your project compiles**. A type defined after that point
gets none of them. Defining one in a `.exs` script, an `iex` session, or *inside a test module
body* produces three "protocol has already been consolidated" warnings at compile time, and then,
much later and somewhere else:

```
** (Protocol.UndefinedError) protocol String.Chars not implemented for %Bare{...}
```

Only the protocol paths break — `Errata.to_map/1` and the accessors work regardless — which is why
it can go unnoticed until something calls `to_string/1`.

Define error types in `lib/`. In tests, define fixture types at the **top level of the test file,
above the test module**, or set `consolidate_protocols: Mix.env() != :test` in `mix.exs`.

## Defining a type

Pick a kind. The kind decides how a **boundary** treats the error; the type decides how your
**domain logic** behaves.

```elixir
defmodule MyApp.Orders.PaymentDeclined do
  use Errata.DomainError,          # a business-rule violation, inside the problem domain
    default_message: "the payment was declined",
    reasons: [:insufficient_funds, :card_expired]
end

defmodule MyApp.Orders.GatewayTimeout do
  use Errata.InfrastructureError   # network, database — outside the problem domain
end

defmodule MyApp.UnexpectedError do
  use Errata.Error                 # kind :general — fits neither
end
```

Prefer `DomainError` and `InfrastructureError` over the base `Errata.Error`: the classification is
what lets a boundary route errors without knowing every type.

Every option is optional:

| Option | Purpose |
| --- | --- |
| `:default_message` / `:default_reason` | used when none is given |
| `:reasons` | declare the valid reasons — compile-time validated, and the basis of atom safety in `from_map/3` |
| `:http_status`, `:code`, `:severity`, `:retryable` | classifications consumed at a boundary |
| `:redact` | keep sensitive context out of logs and JSON |
| `:aggregate` | a type that carries several errors at once |

Declaring `:reasons` is worth doing by default. It catches typos at compile time, generates a
`reason/0` type, and is what makes decoding an error from the wire safe — a declared set turns
decoding into a lookup, so nothing from outside is ever atomised.

## Creating errors

Three ways, differing in setup and in whether they record where the error came from.

```elixir
# Default. Captures __ENV__ and the stacktrace into :env. One `use Errata` covers every type.
{:error, Errata.create(OrderNotFound, reason: :not_found, context: %{order_id: id})}

# Same thing, reads better when a module works mostly with one type. Needs `require OrderNotFound`.
{:error, OrderNotFound.create(reason: :not_found)}

# A plain function. No :env captured.
{:error, OrderNotFound.new(reason: :not_found)}
```

**Reach for `Errata.create/2` unless you have a reason not to.** The origin of an error is often
the most useful thing you have when debugging, and capturing it costs ~0.7 µs — negligible next to
anything that can fail.

`new/1` exists for the cases a macro cannot serve, and those are the only reasons to prefer it:

  * dynamic dispatch — `apply(OrderNotFound, :new, [params])`; a macro raises `UndefinedFunctionError`
  * capture — `&OrderNotFound.new/1`; capturing a macro freezes the capture site's env into every
    error it builds
  * tests and fixtures, where `env: nil` keeps structs easy to compare

`create` must be a macro, and cannot be reimplemented as a function that derives the call site
from the stacktrace: **tail-call optimisation drops the caller's frame**, so `e = Err.new(...); e`
would silently report the caller's caller.

Raising uses the same type:

```elixir
raise MyApp.Orders.OrderNotFound, reason: :not_found, context: %{order_id: 42}
```

## Wrapping: the cause chain

Wrap a lower-level failure rather than discarding it:

```elixir
rescue
  e -> {:error, Errata.wrap(MyApp.Orders.GatewayTimeout, e, stacktrace: __STACKTRACE__)}
```

A cause chain is Errata errors all the way down, optionally ending in **one foreign value** — a
bare atom, an `{:error, reason}` tuple, a standard exception. That shape decides which accessor
you want:

```elixir
Errata.root_error(error)                       # deepest ERRATA error — has code, context, classification
Errata.root_error(error) |> Errata.cause()     # the foreign original, or nil
Errata.format_chain(error)                     # the whole chain, stacktraces included, for a log
```

> **Do not hand-roll a recursive unwrap loop, and do not use `Errata.root_cause/1`** — it is
> deprecated precisely because it returns an Errata error *or* a foreign value depending on how the
> chain ends, so the caller has to work out which it got. Use `root_error/1` to render, report or
> classify; `cause/1` on it to diagnose what actually failed.

This is where a shared error library pays off: a `RetriesExhausted` from `external_service`
wrapping your own error, neither knowing about the other, still unwraps to "connection refused" —
which is the message a user can act on, where "could not be completed after 3 attempts" is not.

## Handling errors

The three guards are `defguard`s, so a module calling them **fully qualified still needs
`require Errata`**. `use Errata` does that for you and imports them unqualified:

```elixir
use Errata

case do_something() do
  {:error, e} when Errata.is_domain_error(e) -> render_to_user(e)
  {:error, e} when Errata.is_infrastructure_error(e) -> retry_later(e)
  {:error, e} when Errata.is_error(e) -> report(e)
  {:error, other} -> report_foreign(other)
end
```

### Every accessor raises on a non-Errata value

`reason/1`, `context/1`, `kind/1`, `code/1`, `severity/1`, `retryable?/1`, `http_status/1`,
`cause/1`, `root_error/1`, `display_message/1` — all of them raise `ArgumentError` when handed
something that is not an Errata error.

That matters because the boundary where you ask these questions is exactly the boundary where
other error shapes arrive. An Oban worker receiving `{:error, %Ecto.Changeset{}}` alongside your
own errors will **raise inside error handling** — the worst place for it, since it replaces a real
error with an unrelated one.

Two correct shapes:

```elixir
# Guard first
{:error, reason} when Errata.is_error(reason) ->
  if Errata.retryable?(reason), do: {:snooze, 60}, else: give_up(reason)

{:error, reason} ->
  give_up(reason)
```

```elixir
# Or normalise first, and treat everything uniformly
error = Errata.to_error(reason)
if Errata.retryable?(error), do: {:snooze, 60}, else: give_up(error)
```

### `display_message/1` returns `nil` when there is no message to show

Specifically, when the type declares no `:default_message` and none was given — verified on 1.8.0.
So call sites generally need a fallback: `Errata.display_message(e) || Exception.message(e)`.

Note also that `display_message/1` is written for one audience at a time. The same error may want
different phrasing in a background report and on the form the user is staring at — special-casing
at the call site is legitimate.

## At a boundary

`Errata.to_error/2` normalises any value into an Errata error, which is what makes a catch-all
handler possible. The recommended shape is your own `to_error/1` with ordinary clauses, so one
function shows how a boundary classifies errors:

```elixir
defmodule MyAppWeb.Errors do
  def to_error(%Ecto.Changeset{} = changeset),
    do: MyApp.ValidationFailed.new(reason: :invalid, cause: changeset)

  def to_error(other), do: Errata.to_error(other)
end
```

> **`{:error, reason}` tuples are not unwrapped.** `Errata.to_error({:error, :timeout})` normalises
> the *two-tuple itself*, because a value that legitimately is a two-tuple is indistinguishable
> from one meaning "error". Match the tuple at the call site:
> `{:error, reason} -> {:error, Errata.to_error(reason)}`.

Then route on classification rather than on type:

```elixir
conn |> put_status(Errata.http_status(error)) |> json(Errata.to_map(error))
```

`to_map/1` and both JSON encoders carry `kind`, `http_status`, `severity`, `retryable` and `code`,
so a consumer holding only the serialised error can still route on it. `Errata.from_map/3` rebuilds
one on the far side — the type is an argument, not read from the payload, and `:reasons` is what
keeps it safe.

## Reporting

```elixir
Errata.log(error)              # structured Logger metadata; level defaults to severity(error)
Errata.report(error)           # emits [:errata, :error] telemetry for your own handler
Errata.report(error, log: true)
```

Vendor-neutral — wire the telemetry event to Sentry or wherever errors should go. Use `:redact` on
types whose context can hold secrets; the library tells you to put arbitrary metadata in `context`
and then ships it to Logger, telemetry and JSON.

## Two things that will surprise you

**Structural guards are invisible to the Elixir type checker.** `is_error/1` matches on struct
shape, which does not refine a struct type, so `e.reason` after a bare `rescue` or guard warns on
1.18+. Use the accessors (`Errata.reason(e)`) or `Map.fetch!(e, :reason)`.

**Dialyzer's `:extra_return` flag is unusable in an Errata application.** Generated accessors are
specced to the behaviour's contract, not to one implementation — `code/1` is `String.t() | nil`
though a type declaring `code: "..."` only ever returns the string; `retryable?/1` is `boolean()`
though a domain error only ever returns `false`. The warning count grows with every error type
defined. Leave the flag off.

## Aggregates

For a type that carries several errors at once (validation, batch work), `use Errata.DomainError,
aggregate: true`. `Errata.errors/1` returns `[]` for an ordinary error rather than raising, so
calling code can treat every error uniformly instead of branching on `aggregate?/1` first:

```elixir
for member <- Errata.errors(error), do: Logger.warning(Exception.message(member))
```
