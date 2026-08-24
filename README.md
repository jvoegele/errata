# Errata

[![CI](https://github.com/jvoegele/errata/actions/workflows/ci.yml/badge.svg)](https://github.com/jvoegele/errata/actions/workflows/ci.yml)

<!-- README START -->

Errata is an Elixir library for **structured, named error handling**.

In Elixir it is common to signal failure either by returning an error tuple
(`{:error, reason}`) or by raising an exception. Errata embraces both styles,
but replaces ad-hoc reasons and loosely structured exceptions with _named,
structured error types_ that share a consistent shape and carry full contextual
detail about what went wrong and where.

Taken together, an application's Errata types form a kind of _errata sheet_ for
the system: a deliberate, named catalogue of the ways it can fail.

Each Errata error is an `Exception` struct with a well-defined set of fields:

  * `message` — a human-readable description of the error
  * `reason` — an atom that classifies the error, useful for pattern matching
  * `context` — a map of arbitrary metadata captured at the site of the error
  * `cause` — the original error wrapped by this one, when it was created from a
    lower-level failure (see `Errata.Cause` and `Errata.cause/1`)
  * `env` — the module, function, file, line, and stacktrace where the error
    was created (see `Errata.Env`)

Because the full context is embedded in the struct, it travels with the error
whether the error is raised or returned as a value, and can be logged, reported,
or rendered to JSON at the boundaries of the system without losing the
information needed to interpret it.

With Errata you can:

  * **Define custom error types** in one line with `use Errata.DomainError`,
    `use Errata.InfrastructureError`, or `use Errata.Error`.
  * **Use an error as a value or an exception** — the same type can be returned
    in an `{:error, error}` tuple or raised with `raise/2`.
  * **Capture rich context** — an error reason, arbitrary metadata, and the
    exact point of origin (module, function, file, line, and stacktrace).
  * **Wrap lower-level errors** — catch an exception or error value and wrap it
    as the `:cause` of a structured Errata error, without losing the original.
  * **Classify errors** as domain, infrastructure, or general, and branch on
    that classification at system boundaries with the `Errata` guards.
  * **Serialize errors automatically** — every error type implements the
    `String.Chars` protocol and, depending on what's available, the built-in
    `JSON.Encoder` (Elixir 1.18+) and/or `Jason.Encoder` protocols.
  * **Report errors at a boundary** — log an error with its fields as structured
    metadata, or emit a telemetry event for your own handler to forward to
    Sentry, a metrics backend, or wherever errors should go.

## Quick start

```elixir
# Define a domain error. Errata generates the exception struct, the
# `Errata.Error` behaviour, and the String.Chars and Jason.Encoder protocols.
defmodule MyApp.Orders.OrderNotFound do
  use Errata.DomainError,
    default_message: "the requested order does not exist"
end

defmodule MyApp.Orders do
  require Errata

  # Return the error as a value, capturing the reason, some context, and the
  # point of origin (via `Errata.create/2`).
  def fetch_order(id) do
    with :error <- lookup(id) do
      {:error, Errata.create(MyApp.Orders.OrderNotFound, reason: :not_found, context: %{order_id: id})}
    end
  end

  # ...or raise the very same type as an exception.
  def fetch_order!(id) do
    case fetch_order(id) do
      {:ok, order} -> order
      {:error, error} -> raise error
    end
  end
end
```

An Errata error carries its full context with it, and can be rendered to a
string or to JSON for logging and error reporting:

```elixir
error = MyApp.Orders.OrderNotFound.new(reason: :not_found, context: %{order_id: 42})

to_string(error)
#=> "the requested order does not exist: :not_found"

Jason.encode!(error)
#=> ~s({"error_type":"MyApp.Orders.OrderNotFound","reason":"not_found", ...})
```

## The three kinds of errors

Every Errata error has a _kind_, fixed when the type is defined:

- **Domain errors** — business-rule violations and other failures within the
  problem domain. Define them with `Errata.DomainError`.
- **Infrastructure errors** — network timeouts, database failures, and other
  failures outside the problem domain. Define them with
  `Errata.InfrastructureError`.
- **General errors** — anything that fits neither, or where the distinction does
  not matter. Define them with the base `Errata.Error`.

An error's **kind** decides how a boundary treats it; its **type** decides how
your domain logic behaves. For how to choose between them, what each kind
defaults to, and how to opt out of the taxonomy entirely, see the
[design notes](guides/design.md).

## Defining custom error types

Most errors in an application are either domain errors or infrastructure errors,
so Errata provides a dedicated module for each. Prefer these two when defining
custom error types: they make the classification explicit and let domain and
infrastructure errors be identified throughout the system.

```elixir
defmodule MyApp.Orders.PaymentDeclined do
  # A business-rule violation or other error within the problem domain.
  use Errata.DomainError
end

defmodule MyApp.Orders.PaymentGatewayTimeout do
  # A network timeout, database failure, or other infrastructure-level error.
  use Errata.InfrastructureError
end
```

For the occasional error that fits neither category — such as an error
originating in library code — use the base `Errata.Error` module, which creates
an error of kind `:general`:

```elixir
defmodule MyApp.UnexpectedError do
  # An error that is neither a domain nor an infrastructure error.
  use Errata.Error
end
```

Every option is optional. The two you are likely to reach for first:

  * `:default_message` — the `:message` to use when none is given
  * `:default_reason` — the `:reason` to use when none is given

The rest are classifications consumed at a boundary — `:http_status`, `:code`,
`:severity`, `:retryable` — plus `:reasons` (declare the valid reasons for the
type), `:redact` (keep sensitive context out of logs and JSON), and `:aggregate`
(a type that holds several errors at once). See
[Errors at a boundary](guides/boundaries.md),
[Reporting errors](guides/observability.md), and
[Wrapping and composing errors](guides/wrapping-errors.md), or
`Errata.Error` for the full reference.

Whichever module you use, the resulting error type is an exception struct that
conforms to the `t:Errata.error/0` type, implements the `Errata.Error`
behaviour, and provides `String.Chars` and `Jason.Encoder` implementations so
that it can be rendered as a string or encoded as JSON automatically.

> #### Define error types in compiled code {: .warning}
>
> Because those protocol implementations are consolidated when your project
> compiles, an error type defined *after* consolidation gets none of them.
> Defining one in a `.exs` script, an `iex` session, or inside a test module body
> produces three "protocol has already been consolidated" warnings at compile
> time and then, much later and somewhere else entirely:
>
> ```
> ** (Protocol.UndefinedError) protocol String.Chars not implemented for %Bare{...}
> ```
>
> Protocol implementations are consolidated when your project compiles, so a type
> defined after that point gets none of the three. Only the protocol paths are
> affected — `Errata.to_map/1` and the accessors work on such a type regardless —
> which is why this can go unnoticed until something calls `to_string/1`.
>
> Define error types in `lib/`. In tests, either define fixture types at the **top
> level of the test file**, above the test module, or set
> `consolidate_protocols: Mix.env() != :test` in `mix.exs` — the first is local and
> needs no project change, the second is one line and removes the trap for the
> whole suite. This project does both. See
> [Testing with Errata](guides/testing.md) for this and the other things worth
> knowing before writing the first test.

## Creating errors as return values

Returning an error as a value — preferably wrapped in an `{:error, error}`
tuple — lets you create the error with full context at the site where it occurs,
while leaving the _handling_ of the error to callers further up the stack. The
error can then be logged or reported at a system boundary without losing any of
its context.

There are three ways to create an error. They differ in how much setup they need
and in whether they record where the error came from.

**`Errata.create/2` is the one to reach for by default.** It captures the current
`__ENV__` and stacktrace into the `:env` field, and because it takes the error
type as an argument, a single `use Errata` covers every error type the module
creates — there is no per-type `require`:

```elixir
iex> require Errata
iex> alias MyApp.Orders.OrderNotFound
iex> error = Errata.create(OrderNotFound, reason: :not_found, context: %{order_id: 42})
iex> error.reason
:not_found
iex> match?(%Errata.Env{}, error.env)
true
```

In a real module, write `use Errata` rather than `require Errata` — it does the
same `require` and brings the [guards](guides/handling-errors.md) into scope at the same
time:

```elixir
defmodule MyApp.Orders do
  use Errata

  alias MyApp.Orders.OrderNotFound
  alias MyApp.Orders.PaymentDeclined

  def find(id) do
    {:error, Errata.create(OrderNotFound, reason: :not_found, context: %{order_id: id})}
  end

  def pay(_order) do
    {:error, Errata.create(PaymentDeclined, reason: :insufficient_funds)}
  end
end
```

**`create/1` on the error module** does exactly the same thing, and reads a
little more directly when a module works mostly with one error type. It is a
macro on the error module, so that module must be `require`d:

```elixir
iex> require MyApp.Orders.OrderNotFound, as: OrderNotFound
iex> error = OrderNotFound.create(reason: :not_found, context: %{order_id: 42})
iex> error.reason == :not_found
true
iex> error.context == %{order_id: 42}
true
iex> match?(%Errata.Env{stacktrace: stacktrace} when is_list(stacktrace), error.env)
true
```

**`new/1` is a plain function** that builds the error without environment info:

```elixir
iex> alias MyApp.Orders.OrderNotFound
iex> OrderNotFound.new(reason: :not_found, context: %{order_id: 42})
%OrderNotFound{reason: :not_found, context: %{order_id: 42}, env: nil}
```

> #### Which should I use? {: .tip}
>
> Use `Errata.create/2` — or `create/1` if you have `require`d the error module —
> unless you have a reason not to. The module, function, file, line, and
> stacktrace of an error's origin are often the most useful things you have when
> debugging, and capturing them costs on the order of a microsecond, which is
> negligible next to almost any operation that can fail. Both are macros, which
> is what lets them see the call site at all.
>
> `new/1` is for the cases a macro cannot serve. It can be called dynamically —
> `apply(OrderNotFound, :new, [params])` — where a macro raises
> `UndefinedFunctionError`, and it can be captured as `&OrderNotFound.new/1` and
> passed around, where capturing a macro would freeze the environment of the
> capture site into every error it builds. It is also handy in tests and
> fixtures, where `env: nil` keeps error structs easy to compare.

However the error is created, wrap it in a tuple when returning it from a
function:

```elixir
{:error, Errata.create(OrderNotFound, reason: :not_found)}
{:error, OrderNotFound.create(reason: :not_found)}
{:error, OrderNotFound.new(reason: :not_found)}
```

## Raising errors as exceptions

Because Errata errors are ordinary Elixir exceptions, the same type can also be
raised with `raise/2`, passing params as the second argument:

```elixir
raise MyApp.Orders.OrderNotFound, reason: :not_found, context: %{order_id: 42}
```

## Guides

The sections above are the whole of what most applications need. The guides
cover the rest, and follow the life of an error — handled, composed as it
travels, converted where it leaves, reported:

  * **[Handling errors](guides/handling-errors.md)** — the guards, `use Errata`,
    and matching on errors as values versus rescuing them as exceptions.
  * **[Wrapping and composing errors](guides/wrapping-errors.md)** — wrapping a
    lower-level failure as a `:cause`, enriching context as an error propagates,
    and aggregate errors that carry several errors at once.
  * **[Errors at a boundary](guides/boundaries.md)** — HTTP status codes, stable
    external codes, severity and retryability, normalizing errors your
    application did not define (and when that differs from wrapping), carrying
    an error's classification across the wire and rebuilding it on the far side,
    and rendering an error for a user.
  * **[Reporting errors](guides/observability.md)** — `Errata.log/2`,
    `Errata.report/2`, the telemetry contract, and redacting sensitive context.
  * **[Testing with Errata](guides/testing.md)** — where fixture types must be
    defined, asserting on errors readably, proving redaction works, and the
    telemetry and log seams.
  * **[Design notes](guides/design.md)** — choosing a kind, choosing between an
    error type and a reason, and why Errata works the way it does.

<!-- README END -->

## Installation

Add `errata` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:errata, "~> 1.8"}
  ]
end
```

### JSON encoding

Errata encodes errors to JSON through whichever backend is available, so you
generally don't need to configure anything:

  * On **Elixir 1.18 and later**, error types implement the built-in
    `JSON.Encoder` protocol, so `JSON.encode!(error)` works with no extra
    dependencies.
  * If [`jason`](https://hex.pm/packages/jason) is present, error types also
    implement `Jason.Encoder`, so `Jason.encode!(error)` works as before. Jason
    is an *optional* dependency — add it explicitly if you want it (for example
    to use Jason on Elixir versions earlier than 1.18, or alongside the built-in
    encoder):

    ```elixir
    {:jason, "~> 1.4"}
    ```

Both backends produce the same JSON shape. If neither is available (Elixir
older than 1.18 without Jason), errors can still be converted to a plain map
with `Errata.to_map/1`, which you can encode however you like.

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/errata/index.html).
