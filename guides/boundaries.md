# Errors at a boundary

A boundary — an HTTP handler, a job runner, a message consumer — has to turn an
error into a decision: what status to return, what to show the caller, how loudly
to log it, whether to try again. Errata answers each of those with a function
that works on any error type, so a boundary can be written once and keep working
as new error types are added.

## Mapping errors to HTTP status codes

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

## Stable external error codes

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

## Classifying errors: severity and retryability

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

## Rendering an error for users

`Exception.message/1` (and the `String.Chars` implementation) return a
_developer-oriented_ message that combines the `:message` and `:reason` (for
example, `"the requested order does not exist: :not_found"`) — useful in logs
and raised-exception output. When rendering an error for an end user, use
`Errata.display_message/1` instead, which returns just the human-readable
`:message`.

## Dynamic messages

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

