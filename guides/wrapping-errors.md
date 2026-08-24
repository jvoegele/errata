# Wrapping and composing errors

An error rarely travels alone. It may wrap a lower-level failure as its cause,
pick up context from each layer it passes through, or stand for a whole set of
errors at once. This guide covers all three.

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

Wrapping is for when you know what a failure means, which is why it takes the
error type as an argument and always adds a layer. Where an error is on its way
_out_ of the system and anything at all can arrive, there is no type to name and
rewrapping would discard a classification that is already correct; reach for
`Errata.to_error/2` there instead. See
[Wrapping versus normalizing](boundaries.md#wrapping-versus-normalizing).

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

## Unwrapping a wrapped error

Wrapping is worth doing because the outer error names *what your code was trying
to do*. That is exactly why the outer message is often the least useful thing to
show someone:

```elixir
iex> require Errata
iex> alias MyApp.Http.RetriesExhausted
iex> error = Errata.wrap(RetriesExhausted, %RuntimeError{message: "connection refused"})
iex> Errata.display_message(error)
"the request could not be completed after 3 attempts"
```

"After 3 attempts" describes the retry handler's reaction. `"connection refused"`
is the thing that actually went wrong.

**A cause chain is a chain of Errata errors, the deepest of which may carry a
foreign original** — the exception or value your code actually caught. Two
functions follow from that, and between them they cover every question:

```elixir
iex> require Errata
iex> alias MyApp.Http.RetriesExhausted
iex> error = Errata.wrap(RetriesExhausted, %RuntimeError{message: "connection refused"})
iex> Errata.root_error(error) |> Errata.display_message()
"the request could not be completed after 3 attempts"
iex> Errata.root_error(error) |> Errata.cause()
%RuntimeError{message: "connection refused"}
```

`Errata.root_error/1` walks to the deepest **error**, however many layers down it
is, and always returns one — an error with no cause is its own root. So what
comes back always has a `code`, a `context`, a classification and a
`display_message/1`, and there is no fallback to write at the call site.

`Errata.cause/1` on that error gives the foreign original, or `nil` when the chain
is Errata errors the whole way:

```elixir
iex> alias MyApp.Orders.OrderNotFound
iex> OrderNotFound.new(reason: :not_found) |> Errata.root_error() |> Errata.cause()
nil
```

For a log, reach for neither: `Errata.format_chain/1` renders every level with the
original stacktrace, which no accessor exposes.

> #### `root_cause/1` is deprecated {: .warning}
>
> It returns an Errata error or a foreign value depending on how the chain ends,
> so a caller has to work out which it got. `Errata.root_cause(error)` is
> equivalent to `Errata.cause(Errata.root_error(error)) || Errata.root_error(error)`;
> in practice you want one of the two halves, not the union.

Every accessor **raises on a value that is not an Errata error**. A consumer
handling whatever a `with` chain returned does not necessarily have one, so
normalize first — `to_error/2` composes with all of them:

```elixir
iex> Errata.to_error(:timeout) |> Errata.root_error() |> Errata.code()
nil
```

### Why the foreign original is kept separate

`Errata.cause/1` only accepts Errata errors, so a foreign value can only ever sit
at the *bottom* of a chain, never in the middle. That bottom value is often the
least useful thing there: `:econnrefused` has no message, no context, no code and
no classification, while the error wrapping it has all four.

They are also not two views of the same fact. `wrap/2` keeps the cause in
`:cause` and copies nothing out of it, so a wrapped error's `:reason` and
`:context` are untouched by what it wraps:

```elixir
iex> require Errata
iex> alias MyApp.Http.RetriesExhausted
iex> error = Errata.wrap(RetriesExhausted, :econnrefused)
iex> {Errata.reason(error), Errata.context(error)}
{nil, %{}}
```

So the two ends of a chain answer different questions, and which you want depends
on who is reading:

  * **Rendering, reporting, classifying** — `root_error/1`. It is the deepest
    thing that still carries Errata's structure, so it is what you hand to a
    view, a reporter, or a retry decision.
  * **Diagnosing** — `Errata.cause/1` on the root error, for the original your
    code caught, or `format_chain/1` for the whole picture with stacktraces.

### A consumer that only reads errors

Putting those together — a module that renders errors for people, without
creating any:

```elixir
defmodule MyAppWeb.ErrorHelpers do
  def user_message(value) do
    value
    |> Errata.to_error()
    |> Errata.root_error()
    |> Errata.display_message()
  end
end
```

`to_error/2` guarantees an Errata error going in, `root_error/1` guarantees one
coming out, so there is no clause to get wrong and no term to fall back on:

```elixir
iex> MyAppWeb.ErrorHelpers.user_message(:timeout)
"an unexpected error occurred"
```

```elixir
iex> require Errata
iex> alias MyApp.Http.RetriesExhausted
iex> MyAppWeb.ErrorHelpers.user_message(Errata.wrap(RetriesExhausted, :econnrefused))
"the request could not be completed after 3 attempts"
```

Note that this deliberately does *not* reach for `Exception.message/1` on a
foreign root cause. A `%RuntimeError{message: "connection refused"}` reads fine
in a log, but on a screen it is text nobody wrote for a user — the wrapping
error's `display_message/1` is the one somebody did.

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

