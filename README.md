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

Every Errata error has a _kind_, which places it into one of three
classifications:

- _Domain errors_ represent error conditions within a problem domain or bounded
  context. These are business-process violations or other errors in the problem
  domain, and so should be part of the
  [Ubiquitous Language](https://martinfowler.com/bliki/UbiquitousLanguage.html)
  of the domain. Define them with `Errata.DomainError`.
- _Infrastructure errors_ represent errors that occur at an infrastructure level
  but are not part of the problem domain, such as network timeouts, database
  connection failures, or filesystem errors. Define them with
  `Errata.InfrastructureError`.
- _General errors_ are errors that fit neither category, such as errors that
  emanate from library code, or any error for which the distinction does not
  matter. Define them with the base `Errata.Error`.

An error's kind is primarily a concern at the _boundaries_ of the system rather
than within domain logic. Code at the edges of the application (such as a
Phoenix fallback controller) can branch on an error's kind using the
[custom guards](#handling-errors) — translating domain errors into `4xx`
responses that are safe to show users, and infrastructure errors into `5xx`
responses that are logged with alerting and hidden from users. Within your
domain logic, by contrast, you generally dispatch on the specific error _type_.
In short: an error's **kind** decides how the boundary treats it, while its
**type** decides how your domain logic behaves.

For how to choose a kind, what each one defaults to, and how to opt out of the
taxonomy entirely, see the [design notes](guides/design.md).

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

Each `use` accepts a few options:

  * `:default_message` — the `:message` to use when none is given
  * `:default_reason` — the `:reason` to use when none is given
  * `:reasons` — an optional list of atoms enumerating the valid reasons for the
    type (see [Choosing between an error type and a reason](#choosing-between-an-error-type-and-a-reason))
  * `:code` — a stable external code for the type, independent of the module name
    (see [Stable external error codes](#stable-external-error-codes))
  * `:http_status`, `:severity`, `:retryable` — classifications consumed at
    boundaries (see [Mapping errors to HTTP status codes](#mapping-errors-to-http-status-codes)
    and [Classifying errors: severity and retryability](#classifying-errors-severity-and-retryability))

Whichever module you use, the resulting error type is an exception struct that
conforms to the `t:Errata.error/0` type, implements the `Errata.Error`
behaviour, and provides `String.Chars` and `Jason.Encoder` implementations so
that it can be rendered as a string or encoded as JSON automatically.

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
same `require` and brings the [guards](#handling-errors) into scope at the same
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

## Wrapping errors

When a lower-level subsystem or external library fails, you often want to
translate that failure into a structured Errata error of your own — without
discarding the original. The generated `wrap/2` macro does exactly this: it
creates an error (capturing the current `__ENV__`, like `create/1`) and stores
the original error, exception, or value as its `:cause`.

The typical use is inside a `rescue` clause, passing `__STACKTRACE__` so the
original error's point of failure is preserved alongside it:

```elixir
iex> require MyApp.Orders.OrderNotFound, as: OrderNotFound
iex> error =
...>   try do
...>     raise "the database connection dropped"
...>   rescue
...>     e -> OrderNotFound.wrap(e, stacktrace: __STACKTRACE__, reason: :lookup_failed)
...>   end
iex> error.reason
:lookup_failed
iex> Errata.cause(error)
%RuntimeError{message: "the database connection dropped"}
```

Like `create/1`, the `wrap/2` macro must be `require`d for each error module. The
`Errata.wrap/3` macro is the convenient alternative — it wraps a cause in an error
of _any_ type without a separate `require` for each one. Since you typically
already `require Errata`, you can `alias` your error modules and call it directly:

```elixir
iex> require Errata
iex> alias MyApp.Orders.OrderNotFound
iex> error = Errata.wrap(OrderNotFound, %RuntimeError{message: "boom"}, reason: :lookup_failed)
iex> error.reason
:lookup_failed
iex> Errata.cause(error)
%RuntimeError{message: "boom"}
```

The cause can be any term — another Errata error, a standard exception, or a
plain value such as the `reason` from an `{:error, reason}` tuple. Retrieve the
immediate cause with `Errata.cause/1`, or follow a chain of wrapped errors to
the bottom with `Errata.root_cause/1`. The cause is also included when the error
is serialized with `to_map/1` or encoded as JSON.

For logging, `Errata.format_chain/1` renders an error together with its full
chain of causes:

```
MyApp.Orders.OrderNotFound: the requested order does not exist: :lookup_failed
Caused by: ** (RuntimeError) the database connection dropped
    (stdlib 5.2) ...
```

## Enriching context as an error propagates

An error's `context` is usually captured where the error is created, but a
structured error often travels up through several layers before it reaches a
boundary — and those intermediate layers frequently know context that the
creation site did not: the `user_id` known in one place, the `request_id` known
in another. `Errata.put_context/3` and `Errata.merge_context/2` let you _enrich_
an error's context as it propagates, without rebuilding the struct by hand.

This pairs naturally with returning errors as values through a `with` chain:
each layer attaches what it knows and lets the error continue on its way.

```elixir
iex> alias MyApp.Orders.OrderNotFound
iex> OrderNotFound.new(reason: :not_found, context: %{order_id: 42})
...> |> Errata.put_context(:user_id, 7)
...> |> Errata.merge_context(%{order_id: 99})
...> |> Errata.context()
%{order_id: 99, user_id: 7}
```

`put_context/3` sets a single key; `merge_context/2` merges a whole map, with the
given values winning on any key collision. Either one initializes the `context`
map if the error did not have one yet.

## Handling errors

Errata errors are standard Elixir exceptions, so they can be rescued like any
other exception, and `Kernel.is_exception/1` returns `true` for them. In
addition, Errata provides guards for recognizing and classifying its errors:

- `Errata.is_error/1` — true for any Errata error
- `Errata.is_domain_error/1` — true for domain errors
- `Errata.is_infrastructure_error/1` — true for infrastructure errors

Because the guards are macros, the `Errata` module must be `require`d or
`import`ed to use them. The simplest way is `use Errata`, which imports the three
guards — so you can write them unqualified in `when` clauses and function heads —
and, because `import` implies `require`, also makes the `Errata.create/2` and
`Errata.wrap/3` macros callable:

```elixir
defmodule MyApp.Orders.Boundary do
  use Errata

  def handle({:error, e}) when is_error(e), do: handle_errata_error(e)
  def handle({:error, e}), do: handle_other_error(e)
end
```

`use Errata` brings only the guards into scope; the rest of the API stays
qualified (`Errata.to_map/1`, `Errata.put_context/3`, and so on), which reads
well at a boundary and avoids pulling generically named functions into your
namespace. (Don't confuse it with `use Errata.Error` and friends, which _define_
a new error type.) If you'd rather not `use` the module, the equivalent explicit
form imports just the guards — which, again, also requires the module:

```elixir
import Errata, only: [is_error: 1, is_domain_error: 1, is_infrastructure_error: 1]
```

The kind-based guards are especially useful at system boundaries — for example,
translating domain errors into client errors (`4xx`) and infrastructure errors
into server errors (`5xx`) with alerting — while domain logic generally matches
on the specific error type.

The following example handles Errata errors both as raised exceptions and as
error values returned from functions:

> #### `rescue` clauses and the custom guards {: .info}
>
> Elixir's `rescue` clauses only accept a bare variable or the
> `var in [ExceptionModule]` form; they do **not** accept arbitrary `when`
> guards. To use the `Errata.is_error/1` family when rescuing, rescue the
> exception into a variable and then dispatch on it (for example with `cond/1`),
> as shown below. The guards _can_ be used directly in the `when` clause of a
> `case`, `with`, or function head when handling errors returned as values.

```elixir
defmodule MyApp.Orders.Boundary do
  # require the Errata module to use the custom guards
  require Errata

  def handle_order_lookup_as_exception(id) do
    try do
      MyApp.Orders.fetch_order!(id)
    rescue
      e in [MyApp.Orders.OrderNotFound] ->
        # Errata errors can be rescued by their specific type
        handle_order_not_found(e)

      e ->
        # `rescue` clauses cannot use `when` guards, so rescue the exception
        # and then dispatch on it using the custom guards defined in the
        # Errata module
        cond do
          Errata.is_error(e) -> handle_errata_error(e)
          # Regular exceptions may be handled separately if desired
          true -> handle_other_error(e)
        end
    end
  end

  def handle_order_lookup_as_value(id) do
    case MyApp.Orders.fetch_order(id) do
      {:ok, order} ->
        handle_order(order)

      {:error, %MyApp.Orders.OrderNotFound{} = error} ->
        # Errata errors can be pattern matched by their specific type
        handle_order_not_found(error)

      {:error, error} when Errata.is_error(error) ->
        # Or they can be identified using one of the custom guards defined in
        # the Errata module (`when` guards are allowed in `case` clauses)
        handle_errata_error(error)

      {:error, reason} ->
        # Other errors may be handled separately if desired
        handle_other_error(reason)
    end
  end
end
```

The patterns above, distilled into runnable examples — first, rescuing an
exception and dispatching on it with the custom guards:

```elixir
iex> require Errata
iex> alias MyApp.Orders.{OrderNotFound, PaymentDeclined}
iex> try do
...>   raise OrderNotFound, reason: :not_found
...> rescue
...>   e in [PaymentDeclined] ->
...>     {:specific, e.reason}
...>
...>   e ->
...>     # `Errata.reason/1` rather than `e.reason`: a variable bound by a bare
...>     # `rescue e ->` has no type the compiler can narrow (see the note below).
...>     if Errata.is_error(e), do: {:errata, Errata.reason(e)}, else: {:other, e}
...> end
{:errata, :not_found}
```

And second, matching on an error returned as a value, where the guards _can_ be
used directly in a `when` clause:

```elixir
iex> require Errata
iex> alias MyApp.Orders.OrderNotFound
iex> case {:error, OrderNotFound.new(reason: :not_found)} do
...>   {:error, e} when Errata.is_error(e) -> {:errata, e.reason}
...>   {:error, other} -> {:other, other}
...> end
{:errata, :not_found}
```

> #### Reading fields inside a bare `rescue` {: .info}
>
> A variable bound by a bare `rescue e ->` has no type the compiler can narrow —
> it is "some exception, fields unknown" — so reading a field directly with
> `e.reason` draws an `unknown key .reason` warning. This is ordinary Elixir
> behaviour rather than anything about Errata: `e.message` on a plain
> `RuntimeError` warns in exactly the same position.
>
> Use an accessor instead. `Errata.reason/1`, `Errata.context/1`,
> `Errata.kind/1`, `Errata.code/1`, `Errata.severity/1`, `Errata.http_status/1`,
> `Errata.retryable?/1`, and `Errata.cause/1` are plain function calls, so they
> warn for nothing and read better than field access besides. Or match the
> specific type — `e in [PaymentDeclined] -> e.reason` — when you know it.
>
> Field access after a *structural guard* (`{:error, e} when Errata.is_error(e)`)
> is warning-free — verified on every Elixir this library supports, 1.15 through
> 1.20. Earlier versions of this guide suggested `Map.fetch!/2` for that case;
> that workaround is not needed.

### Mapping errors to HTTP status codes

At an HTTP boundary you often want to translate an error into a response status.
Every Errata error has a generated `http_status/1` function whose default is
derived from the error's kind — `:domain` errors map to `422`, `:infrastructure`
errors to `503`, and `:general` errors to `500`. Set a specific status per type
with the `:http_status` option, or override `http_status/1` to compute one from
the error's `reason` or `context`:

```elixir
defmodule MyApp.Orders.OrderNotFound do
  use Errata.DomainError, http_status: 404
end
```

`Errata.http_status/1` returns the status for _any_ Errata error without needing
to know its specific type, which is convenient in a Phoenix fallback controller:

```elixir
def call(conn, {:error, error}) when Errata.is_error(error) do
  conn
  |> put_status(Errata.http_status(error))
  |> put_view(MyApp.ErrorView)
  |> render("error.json", error: error)
end
```

This keeps Errata free of any web-framework dependency: it hands you the status
code, and the framework glue stays in your application.

### Stable external error codes

The only type identity `to_map/1` exposes is the module name
(`"MyApp.Orders.OrderNotFound"`), which is an implementation detail: rename or
move the module and the identifier your API clients match on changes with it.
For consumers outside your codebase — API clients, i18n catalogs, support
tooling — give the type a **stable external code** instead:

```elixir
defmodule MyApp.Orders.OrderNotFound do
  use Errata.DomainError, code: "ORDER_NOT_FOUND"
end
```

The code appears in `to_map/1` (and so in the JSON encoding) under the `code`
key, and in the metadata emitted by `Errata.log/2` and `Errata.report/2`.
`Errata.code/1` returns it for any Errata error.

Codes are entirely opt-in and there is no default — a type that doesn't declare
one returns `nil`, and Errata deliberately does not derive a code from the module
name, since that would reintroduce the very coupling the code exists to avoid. A
boundary that needs a code for every error should supply its own fallback:

```elixir
Errata.code(error) || "UNKNOWN"
```

Like the other generated functions, `code/1` is overridable, so a single error
type can carry different codes per reason:

```elixir
defmodule MyApp.Auth.TokenInvalid do
  use Errata.DomainError, reasons: [:expired, :revoked]

  def code(%{reason: :expired}), do: "TOKEN_EXPIRED"
  def code(%{reason: :revoked}), do: "TOKEN_REVOKED"
  def code(_error), do: "TOKEN_INVALID"
end
```

### Classifying errors: severity and retryability

Two further classifications are available on every error type, both following the
same pattern as `http_status/1` — a `use` option, an overridable per-module
function, and a top-level accessor that works on any Errata error.

**Severity** (`Errata.severity/1`) is a `Logger` level describing how much the
error matters. It defaults to `:error` for every type, so nothing is reclassified
behind your back; set `:severity` on the types that deserve a quieter (or
louder) treatment:

```elixir
defmodule MyApp.Orders.RateLimited do
  use Errata.DomainError, severity: :warning
end
```

Severity is the level `Errata.log/2` uses when you don't pass one explicitly, and
it is included in the metadata of both `Errata.log/2` and `Errata.report/2`, so a
telemetry handler can route or alert on it.

**Retryability** (`Errata.retryable?/1`) records whether the failure is likely to
be transient. Its default is derived from the error's kind — `:infrastructure`
errors are retryable (timeouts and connection blips usually are), `:domain` and
`:general` errors are not — and it can be set per type or computed per error:

```elixir
defmodule MyApp.Orders.PaymentGatewayError do
  use Errata.InfrastructureError

  # a rejected request will be rejected again; a timeout may not be
  def retryable?(%{reason: :invalid_request}), do: false
  def retryable?(_error), do: true
end
```

Errata deliberately ships no retry mechanism of its own. `retryable?/1` is a
classification your own retry logic (or a library such as
[`retry`](https://hexdocs.pm/retry)) can branch on without knowing the error's
specific type:

```elixir
case do_work() do
  {:error, error} when Errata.is_error(error) ->
    if Errata.retryable?(error), do: retry(), else: {:error, error}

  result ->
    result
end
```

### Rendering an error for users

`Exception.message/1` (and the `String.Chars` implementation) return a
_developer-oriented_ message that combines the `:message` and `:reason` (for
example, `"the requested order does not exist: :not_found"`) — useful in logs
and raised-exception output. When rendering an error for an end user, use
`Errata.display_message/1` instead, which returns just the human-readable
`:message`.

### Dynamic messages

A static `:default_message` cannot name the thing that went wrong — it can say
"the item is out of stock" but not _which_ item. Rather than building the string
by hand at every call site, override the generated `display_message/1` to compute
it from the error's `:reason` or `:context`, once, where the type is defined:

```elixir
defmodule MyApp.Orders.ItemOutOfStock do
  use Errata.DomainError, default_message: "the item is out of stock"

  def display_message(%{context: %{sku: sku, available: available}}),
    do: "only #{available} of #{sku} left in stock"

  def display_message(error), do: error.message
end
```

`Errata.display_message/1` and `Errata.to_map/1` both dispatch through it, so the
computed message reaches the JSON encoding and anything else rendering the error
for a user. Keep a final clause returning `error.message` so the type still has a
sensible message when the context it wants is absent:

```elixir
iex> alias MyApp.Orders.ItemOutOfStock
iex> error = ItemOutOfStock.new(reason: :insufficient_stock, context: %{sku: "ABC-1", available: 2})
iex> Errata.display_message(error)
"only 2 of ABC-1 left in stock"
iex> Errata.to_map(error).message
"only 2 of ABC-1 left in stock"
iex> Errata.display_message(ItemOutOfStock.new(reason: :insufficient_stock))
"the item is out of stock"
```

This is a plain function rather than a template syntax, so it is just pattern
matching: one clause per shape of context, with the compiler checking it and no
separate interpolation language to learn.

The developer message is deliberately unaffected by the override above:

```elixir
iex> alias MyApp.Orders.ItemOutOfStock
iex> error = ItemOutOfStock.new(reason: :insufficient_stock, context: %{sku: "ABC-1", available: 2})
iex> Exception.message(error)
"the item is out of stock: :insufficient_stock"
```

Logs and raised-exception output keep the stable, greppable message while the
specifics stay queryable in the metadata that `Errata.log/2` attaches. If you do
want the computed detail in the developer message too, override `message/1` as
well — that one applies to `Exception.message/1`, `to_string/1`, and `raise`.

## Reporting errors

Because an Errata error carries its full context, it is straightforward to get
it into your observability stack at a boundary. Errata provides two thin,
composable functions for this, and — deliberately — no integration with any
particular external service.

`Errata.log/2` logs an error's developer message, attaching its `reason`, `kind`,
`code`, `severity`, `retryable`, `context`, and origin `env` as **Logger metadata**
rather than flattening them into the message string, so they stay queryable in
structured logging backends. With no level given it logs at the error's own severity, which
is `:error` unless the type sets one:

```elixir
Errata.log(error)            # logs at the error's severity
Errata.log(error, :warning)  # at a chosen level
```

`Errata.report/2` emits a [`:telemetry`](https://hexdocs.pm/telemetry) event for
the error (and, optionally, logs it). This is the seam for external reporting:
rather than Errata depending on Sentry (or any other service), your application
attaches a telemetry handler that forwards the error wherever it needs to go.
The vendor integration lives in your application; Errata stays out of it.

```elixir
Errata.report(error)
Errata.report(error, metadata: %{request_id: request_id}, log: :warning)
```

The event is `[:errata, :error]`, with measurements `%{system_time: _, count: 1}`
(so [`Telemetry.Metrics`](https://hexdocs.pm/telemetry_metrics) counters work out
of the box) and metadata carrying the full `:error` struct plus `:kind`,
`:reason`, `:error_type`, `:code`, `:severity`, `:retryable`, and `:context` as
top-level keys — simple values that work directly as metric tags. A handler in
your application wires it up:

```elixir
:telemetry.attach("myapp-errata", [:errata, :error], &MyApp.ErrorReporter.handle/4, nil)

def handle([:errata, :error], _measurements, metadata, _config) do
  Sentry.capture_message(Exception.message(metadata.error),
    extra: Errata.to_map(metadata.error),
    tags: %{error_type: inspect(metadata.error_type), reason: metadata.reason}
  )
end
```

### Redacting sensitive context

Everything above ships an error's `:context` outward — into your logs, your
telemetry handlers, and your JSON responses. That is the point of capturing it,
and it is also how a password ends up in your log aggregator, because the
natural thing to write is:

```elixir
context: %{params: params}    # password, token, card number
context: %{headers: headers}  # Authorization bearer token
```

Declare the sensitive keys with `:redact` and Errata replaces their values with
`"[REDACTED]"` everywhere it serializes the context:

```elixir
defmodule MyApp.Auth.LoginFailed do
  use Errata.DomainError, redact: [:password, :token]
end
```

Redaction is **recursive** and matches atom and binary keys alike, so declaring
`:password` also covers the `"password"` buried inside that captured params map:

```elixir
error =
  MyApp.Auth.LoginFailed.new(
    context: %{params: %{"email" => "kim@example.com", "password" => "hunter2"}}
  )

Errata.to_map(error).context
#=> %{params: %{"email" => "kim@example.com", "password" => "[REDACTED]"}}
```

It applies at the **serialization seam**, not at creation, so the error struct
you are holding still has the real values for local debugging — only the copies
Errata emits are redacted. That includes the `:error` struct in telemetry
metadata, so the `Sentry.capture_message(..., extra: Errata.to_map(metadata.error))`
handler above cannot leak what you asked to be redacted.

For a floor of protection across every error type, set the keys globally:

```elixir
config :errata, redact: [:password, :token, :secret, :authorization, :api_key]
```

The global default is `[]` — nothing is redacted until you ask, so adding Errata
to an existing app never silently changes what it logs. Declared and global keys
compose. When a key list is not enough, override `redact_context/1`; see
`Errata.Redaction`.

## Aggregate errors

Validation produces the shape a single error struct cannot model: a request fails
and there are five reasons, all of which the caller needs. Putting them in
`:context` as a list of maps throws away everything Errata is for — each
sub-failure loses its type, code, HTTP status, severity, and retryability, and
becomes inert data.

Declare a type as an aggregate and it holds errors instead:

```elixir
defmodule MyApp.Orders.ValidationFailed do
  use Errata.DomainError, aggregate: true, default_message: "validation failed"
end

ValidationFailed.new(errors: [email_error, age_error])
```

The aggregate is an ordinary Errata error — `Errata.is_error/1` holds, it raises
and returns in `{:error, _}` tuples, and it serializes through `to_map/1` and the
JSON encoders like anything else. Its members serialize with it, each keeping its
own type, code, and redaction rules:

```elixir
Errata.to_map(error).errors
#=> [%{error_type: "MyApp.Orders.EmailInvalid", code: "EMAIL_INVALID", ...},
#=>  %{error_type: "MyApp.Orders.AgeInvalid",   code: "AGE_INVALID",   ...}]
```

Reach the members with `Errata.errors/1`, which returns `[]` for an ordinary
error so calling code never has to branch on whether it has an aggregate.

### How the merge rules work

An aggregate has to answer `severity/1`, `retryable?/1`, and `http_status/1` for
a collection. The three merge **differently**, because the right answer differs:

| | rule | why |
|---|---|---|
| `severity/1` | the most severe member | severities are totally ordered, so the maximum is unambiguous — and if any member is `:error`, the aggregate is at least `:error` |
| `retryable?/1` | retryable only if **every** member is | retrying helps only if all of it could succeed next time; one permanent failure makes the retry pointless |
| `http_status/1` | the members' status if they agree, else the aggregate's own | there is no meaningful maximum over status codes, so a "highest" would be arbitrary |

An aggregate with no members falls back to its own declared values. Each rule is
overridable per type, so a type that wants different behaviour just defines the
function. See `Errata.Aggregate` for the full reasoning.

### Members must be Errata errors

Anything else raises `ArgumentError` when the aggregate is built. That is
deliberate: the merge rules are defined in terms of `severity/1`, `retryable?/1`,
and `http_status/1`, which a bare map or a foreign exception cannot answer. Wrap
a foreign error in an Errata type first — that is what `Errata.wrap/3` is for.

## Choosing between an error type and a reason

Errata errors carry both a _type_ (the module) and an optional `:reason` atom,
and it is not always obvious which to reach for. As a rule of thumb:

- Use a **distinct error type** for each condition that callers may want to
  handle differently or that has its own meaning in the domain. The type is the
  primary identity of an error and the thing you pattern match on.
- Use the **`:reason`** field to _sub-classify_ within a single error type — to
  distinguish variations of the same error that share handling but differ in
  cause.

For example, a single `PaymentDeclined` domain error can use `:reason` to record
why the payment was declined, rather than defining a separate type for each
cause:

```elixir
PaymentDeclined.create(reason: :insufficient_funds)
PaymentDeclined.create(reason: :fraud_suspected)
```

Conversely, a `:reason` that merely restates the type name (such as
`OrderNotFound.create(reason: :order_not_found)`) adds no information and can be
omitted.

When a type's reasons form a known, closed set, you can **declare them** with the
`:reasons` option. Errata then rejects any reason outside the set (a `nil`,
unspecified reason is always allowed) and generates a `reason/0` type enumerating
them, so the valid reasons are part of the type's documented contract:

```elixir
defmodule MyApp.Orders.PaymentDeclined do
  use Errata.DomainError,
    reasons: [:insufficient_funds, :fraud_suspected, :card_expired]
end

PaymentDeclined.new(reason: :insufficient_funds)   # ok
PaymentDeclined.new(reason: :mistyped)             # ** (ArgumentError) invalid reason :mistyped ...
```

This turns the guidance above from a convention into something the compiler-adjacent
tooling and your tests can enforce. If you also set `:default_reason`, it must be one
of the declared `:reasons`.

## Why Errata?

It is common in Elixir and Erlang to signal failure with an error tuple of the
form `{:error, reason}`. All too often, though, the `reason` is a bare atom or
(worse) a string that carries no context: it may read clearly enough in the
surrounding code, but as a log message or error report — far from where the
error arose — it lacks the detail needed to interpret what actually happened.

Raising exceptions is a less common but still widespread alternative. Exceptions
do carry some context, including a stacktrace, but they lack a common, uniform
structure to build logging and error handling around.

Errata gives all errors a uniform structure and lets them be created with full
contextual detail, including arbitrary metadata. That context is embedded in the
error struct, so it propagates with the error whether the error is raised or
returned as a value, and the error is JSON-encodable so it can be reported to an
external service such as Sentry.

This pays off, in particular, in `with` expressions. When each step returns
`{:ok, result}` or `{:error, reason}` and the `reason` lacks context, the `with`
is forced to add an `else` clause to log or report every possible error
meaningfully. When each error is instead a structured type carrying its own
context, the `with` can omit the `else` clause entirely and let the error
propagate to a boundary — such as a Phoenix controller — where it is logged or
reported without any loss of the context needed to interpret it.

Chris Keathley discusses this point in depth in his blog post
[Good and Bad Elixir](https://keathley.io/blog/good-and-bad-elixir.html), under
"Avoid `else` in `with` blocks".

<!-- README END -->

## Installation

Add `errata` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:errata, "~> 1.4"}
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
