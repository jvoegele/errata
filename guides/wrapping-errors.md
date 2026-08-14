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

