# Errata

[![CI](https://github.com/jvoegele/errata/actions/workflows/ci.yml/badge.svg)](https://github.com/jvoegele/errata/actions/workflows/ci.yml)

<!-- README START -->

Errata is an Elixir library for **structured, named error handling**.

In Elixir it is common to signal failure either by returning an error tuple
(`{:error, reason}`) or by raising an exception. Errata embraces both styles,
but replaces ad-hoc reasons and loosely structured exceptions with _named,
structured error types_ that share a consistent shape and carry full contextual
detail about what went wrong and where.

Each Errata error is an `Exception` struct with a well-defined set of fields:

  * `message` — a human-readable description of the error
  * `reason` — an atom that classifies the error, useful for pattern matching
  * `context` — a map of arbitrary metadata captured at the site of the error
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
  * **Classify errors** as domain, infrastructure, or general, and branch on
    that classification at system boundaries with the `Errata` guards.
  * **Serialize errors automatically** — every error type implements the
    `String.Chars` and `Jason.Encoder` protocols.

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

## Defining custom error types

Most errors in an application are either domain errors or infrastructure errors,
so Errata provides a dedicated module for each. Prefer these two when defining
custom error types: they make the classification explicit and let domain and
infrastructure errors be identified throughout the system.

```elixir
defmodule MyApp.SomeContext.MyDomainError do
  # A business-rule violation or other error within the problem domain.
  use Errata.DomainError
end

defmodule MyApp.SomeContext.MyInfrastructureError do
  # A network timeout, database failure, or other infrastructure-level error.
  use Errata.InfrastructureError
end
```

For the occasional error that fits neither category — such as an error
originating in library code — use the base `Errata.Error` module, which creates
an error of kind `:general`:

```elixir
defmodule MyApp.SomeContext.MyError do
  # An error that is neither a domain nor an infrastructure error.
  use Errata.Error
end
```

Each `use` accepts a few options:

  * `:default_message` — the `:message` to use when none is given
  * `:default_reason` — the `:reason` to use when none is given

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

There are two ways to create an error. `new/1` builds an error from the given
params but leaves the `:env` field `nil`:

```elixir
iex> alias MyApp.SomeContext.MyError
iex> MyError.new(reason: :invalid_data, context: %{foo: "bar"})
%MyError{reason: :invalid_data, context: %{foo: "bar"}, env: nil}
```

`create/1` additionally captures the current `__ENV__` and stacktrace into the
`:env` field. Because it is a macro, the error module must be `require`d first:

```elixir
iex> require MyApp.SomeContext.MyError, as: MyError
iex> error = MyError.create(reason: :invalid_data, context: %{foo: "bar"})
iex> error.reason == :invalid_data
true
iex> error.context == %{foo: "bar"}
true
iex> match?(%Errata.Env{stacktrace: stacktrace} when is_list(stacktrace), error.env)
true
```

> #### Prefer `create/1` to capture context {: .tip}
>
> Because `new/1` leaves the `:env` field `nil`, it discards the module,
> function, file, line, and stacktrace of the error's origin — often the most
> useful information when debugging or reporting an error. Prefer `create/1`
> (or `Errata.create/2`, below) unless you have a specific reason not to capture
> this context.

The `create/1` macro must be `require`d for each error module. As an
alternative, the `Errata.create/2` macro creates an error of _any_ type without
a separate `require` for each one — convenient when a module works with several
error types. Since you typically already `require Errata` to use the custom
guards, you can simply `alias` your error modules and call `Errata.create/2`:

```elixir
iex> require Errata
iex> alias MyApp.SomeContext.MyError
iex> error = Errata.create(MyError, reason: :invalid_data)
iex> error.reason
:invalid_data
iex> match?(%Errata.Env{}, error.env)
true
```

However the error is created, wrap it in a tuple when returning it from a
function:

```elixir
{:error, MyError.new(reason: :invalid_data)}
{:error, MyError.create(reason: :invalid_data)}
```

## Raising errors as exceptions

Because Errata errors are ordinary Elixir exceptions, the same type can also be
raised with `raise/2`, passing params as the second argument:

```elixir
raise MyApp.SomeContext.MyDomainError, reason: :invalid_data, context: %{foo: "bar"}
```

## Handling errors

Errata errors are standard Elixir exceptions, so they can be rescued like any
other exception, and `Kernel.is_exception/1` returns `true` for them. In
addition, Errata provides guards for recognizing and classifying its errors:

- `Errata.is_error/1` — true for any Errata error
- `Errata.is_domain_error/1` — true for domain errors
- `Errata.is_infrastructure_error/1` — true for infrastructure errors

To use these guards, `import` or `require` the `Errata` module. The kind-based
guards are especially useful at system boundaries — for example, translating
domain errors into client errors (`4xx`) and infrastructure errors into server
errors (`5xx`) with alerting — while domain logic generally matches on the
specific error type.

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
defmodule MyApp.SomeContext do
  # require the Errata module to use the custom guards
  require Errata

  def handle_errata_error_as_exception do
    try do
      function_that_raises_errata_error!()
    rescue
      e in [MyApp.SomeContext.MyDomainError] ->
        # Errata errors can be rescued by their specific type
        handle_my_domain_error(e)

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

  def handle_errata_error_as_value do
    case function_that_returns_errata_error_as_value() do
      {:ok, result} ->
        handle_ok_result(result)

      {:error, %MyApp.SomeContext.MyDomainError{} = error} ->
        # Errata errors can be pattern matched by their specific type
        handle_my_domain_error(error)

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
iex> alias MyApp.SomeContext.{MyDomainError, MyError}
iex> try do
...>   raise MyError, reason: :boom
...> rescue
...>   e in [MyDomainError] ->
...>     {:specific, e.reason}
...>
...>   e ->
...>     if Errata.is_error(e), do: {:errata, e.reason}, else: {:other, e}
...> end
{:errata, :boom}
```

And second, matching on an error returned as a value, where the guards _can_ be
used directly in a `when` clause:

```elixir
iex> require Errata
iex> alias MyApp.SomeContext.MyError
iex> case {:error, MyError.new(reason: :invalid_data)} do
...>   {:error, e} when Errata.is_error(e) -> {:errata, e.reason}
...>   {:error, other} -> {:other, other}
...> end
{:errata, :invalid_data}
```

### Rendering an error for users

`Exception.message/1` (and the `String.Chars` implementation) return a
_developer-oriented_ message that combines the `:message` and `:reason` (for
example, `"the requested order does not exist: :not_found"`) — useful in logs
and raised-exception output. When rendering an error for an end user, use
`Errata.display_message/1` instead, which returns just the human-readable
`:message`.

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
`UnknownSku.create(reason: :unknown_sku)`) adds no information and can be
omitted.

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
    {:errata, "~> 0.8.1"}
  ]
end
```

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/errata/index.html).
