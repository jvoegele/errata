# Getting started

This guide takes you from an empty `mix.exs` to your first named error type —
returned as a value, raised as an exception, and handled at a boundary — in a
few minutes. It assumes no prior knowledge of Errata.

For the complete API reference, see the `Errata` module.

## Installation

Add `errata` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:errata, "~> 1.9"}
  ]
end
```

Then run `mix deps.get`. Errata's only required dependency is `:telemetry`, and
it starts no processes — there is nothing to add to your supervision tree.

JSON encoding needs no configuration. On Elixir 1.18 and later every error type
implements the built-in `JSON.Encoder`; if `jason` is in your dependencies it
implements `Jason.Encoder` as well. Both emit the same shape.

## The big idea

Elixir gives you two ways to signal failure, and most applications use both. A
function returns `{:error, reason}`, or it raises. Errata does not ask you to
pick one — it asks what the failure *is*.

The usual alternatives lose that. `{:error, :not_found}` is an atom that could
have come from anywhere and carries nothing but itself; by the time it reaches a
boundary, the order id, the module, and the line that produced it are gone. A
bare `raise "order not found"` is worse — now it is a string.

An Errata error is a named type. It is an ordinary `Exception` struct, so it can
be returned in a tuple *or* raised, and it carries its context with it either
way:

  * `message` — a human-readable description
  * `reason` — an atom that classifies it, for pattern matching
  * `context` — a map of whatever metadata matters at the point of failure
  * `cause` — the lower-level error this one wrapped, if any
  * `env` — the module, function, file, line, and stacktrace where it was created

Taken together, your application's error types become a catalogue of the ways it
can fail — an *errata sheet* for the system.

## Define your first error type

Pick a kind. Errata has three, and the choice is about how a **boundary** should
treat the error, not about how your domain logic branches on it:

```elixir
defmodule MyApp.Orders.OrderNotFound do
  use Errata.DomainError,
    default_message: "the requested order does not exist"
end
```

`Errata.DomainError` is for business-rule violations and other failures inside
the problem domain. `Errata.InfrastructureError` is for timeouts, database
failures, and the like. `Errata.Error` is the base, for anything that fits
neither. Prefer the first two: they make the classification explicit, and the
`Errata` guards can then act on it anywhere in the system.

That one line generates the exception struct, the `Errata.Error` behaviour, and
the `String.Chars` and JSON protocol implementations.

> #### Define error types in `lib/` {: .warning}
>
> This is the trap that costs the most time, because it fails far from its
> cause. Protocol implementations are consolidated when your project compiles,
> so an error type defined *after* that point — in a `.exs` script, an `iex`
> session, or inside a test module body — gets none of them. You get three
> "protocol has already been consolidated" warnings at compile time, and then,
> much later and somewhere else entirely, a `Protocol.UndefinedError` from
> something as innocent as `to_string/1`.
>
> Define error types in `lib/`. In tests, define fixture types at the **top
> level of the test file**, above the test module, or set
> `consolidate_protocols: Mix.env() != :test` in `mix.exs`. See
> [Testing with Errata](testing.md).

## Return it as a value

Add `use Errata` to the module that creates errors. It requires `Errata` (the
creation macros need it) and imports the three guards at the same time:

```elixir
defmodule MyApp.Orders do
  use Errata

  alias MyApp.Orders.OrderNotFound

  def fetch_order(id) do
    with :error <- lookup(id) do
      {:error, Errata.create(OrderNotFound, reason: :not_found, context: %{order_id: id})}
    end
  end
end
```

`Errata.create/2` is the one to reach for by default. It is a macro, which is
what lets it capture `__ENV__` and the stacktrace into the error's `:env` field,
and because it takes the type as an argument, a single `use Errata` covers every
error type the module creates.

Two variants exist for when that does not fit. `OrderNotFound.create/1` does the
same thing and reads better when a module works mostly with one type, but being
a macro on the error module, that module must be `require`d. `OrderNotFound.new/1`
is a plain function that skips the `:env` capture — use it where a macro cannot
go, such as `apply/3` or a captured `&OrderNotFound.new/1`, and in test fixtures
where `env: nil` keeps structs easy to compare.

## Or raise it

The same type, unchanged:

```elixir
raise MyApp.Orders.OrderNotFound, reason: :not_found, context: %{order_id: 42}
```

This is the point of the design. You do not define one type for the value path
and another for the exception path — you define the error once and decide at each
call site how to signal it.

## Handle it

`use Errata` brought three guards into scope, so you can branch on whether
something is an Errata error at all, and on its kind:

```elixir
def handle({:ok, order}), do: order
def handle({:error, e}) when is_domain_error(e), do: render_user_message(e)
def handle({:error, e}) when is_infrastructure_error(e), do: retry_later(e)
def handle({:error, e}) when is_error(e), do: report(e)
def handle({:error, other}), do: report_unknown(other)
```

Guard first. The accessors raise on a value that is not an Errata error, so a
pipeline that assumes every `{:error, _}` holds one will fail on the first
foreign error it meets. `Errata.to_error/2` is the other way round: it converts
whatever it is handed into an Errata error, letting you normalise once and treat
everything uniformly after that.

## Get it out of the system

At a boundary, an error becomes a log line, a telemetry event, an HTTP response,
or JSON — and it still has everything it started with:

```elixir
to_string(error)
#=> "the requested order does not exist: :not_found"

Errata.to_map(error)
#=> %{error_type: "MyApp.Orders.OrderNotFound", reason: :not_found, ...}

Errata.log(error)
Errata.report(error)
```

Error types can also declare `:http_status`, `:code`, `:severity`, and
`:retryable`, so the boundary can act on the type rather than on a `case` that
has to know every error in the application. `:redact` keeps sensitive context out
of logs and JSON.

## Where to go next

  * **[Handling errors](handling-errors.md)** — the guards, `use Errata`, and
    matching errors as values versus rescuing them as exceptions.
  * **[Wrapping and composing errors](wrapping-errors.md)** — wrapping a
    lower-level failure as a `:cause`, enriching context as an error travels,
    and aggregates that carry several errors at once.
  * **[Errors at a boundary](boundaries.md)** — HTTP status, stable external
    codes, severity and retryability, normalizing foreign errors, and rendering
    an error for a user.
  * **[Reporting errors](observability.md)** — `Errata.log/2`, `Errata.report/2`,
    the telemetry contract, and redaction.
  * **[Testing with Errata](testing.md)** — where fixture types must live,
    asserting on errors readably, and the telemetry and log seams.
  * **[Design notes](design.md)** — choosing a kind, choosing between a type and
    a reason, and why Errata works the way it does.
  * **[Errata and AI coding agents](ai-coding-agents.md)** — getting the rules
    this package ships in front of your agent.

---

**Next:** [Handling errors](handling-errors.md)
