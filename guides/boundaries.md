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
code, and the framework glue stays in your application. The view this renders
through is shown in full under
[a worked boundary](#a-worked-boundary-end-to-end), along with the response
bodies it produces.

## Errors that aren't Errata errors

The clause above handles the errors your application defined. A real system also
receives errors it did not define: `{:error, :timeout}` from a client library, an
`Ecto.Changeset`, a `DBConnection.ConnectionError`. Those do not satisfy
`Errata.is_error/1`, and the accessors raise on them rather than guessing —
`Errata.http_status(:timeout)` is a programming error, not a `500`.

`Errata.to_error/2` converts any value into an Errata error, so the boundary has
one shape to handle:

```elixir
iex> error = Errata.to_error(:timeout)
iex> Errata.http_status(error)
500
iex> Errata.root_cause(error)
:timeout
```

A value Errata knows nothing about becomes an `Errata.UnknownError` — a `500`
that is not retryable — keeping the original as its cause, so nothing is
discarded on the way through. Errata errors are returned unchanged, which makes
the call safe to apply to something that may already be one.

### Wrapping versus normalizing

[`Errata.wrap/3`](wrapping-errors.md) also turns an arbitrary value into an
Errata error, so the two overlap. The difference is whether you know what the
failure means.

Wrapping is an act of interpretation, and belongs where a failure is caught: you
name the error type because in that place you know what a dropped connection
means for the operation in hand. It always adds a layer, since each layer's
interpretation is worth keeping.

Normalizing belongs where an error leaves the system and anything at all can
arrive. There is no type to name, and an error that already is one is returned
untouched. That last part is why reaching for `wrap/3` at a boundary is a bug
rather than a style choice — even wrapping in the very type `to_error/2` would
have chosen:

```elixir
iex> require Errata
iex> error = MyApp.Orders.OrderNotFound.new(reason: :not_found)
iex> Errata.http_status(error)
422
iex> Errata.to_error(error) |> Errata.http_status()
422
iex> Errata.wrap(Errata.UnknownError, error) |> Errata.http_status()
500
iex> Errata.wrap(Errata.UnknownError, error) |> Errata.display_message()
"an unexpected error occurred"
```

A `404` becomes a `500`, and the message the user was meant to read is replaced
by a generic one.

|                            | `wrap/3`                        | `to_error/2`                    |
| -------------------------- | ------------------------------- | ------------------------------- |
| do you know what it means? | yes — you name the type          | no — it is whatever arrived     |
| where                      | where the failure is caught      | where the error leaves          |
| given an Errata error      | adds a layer                     | returns it unchanged            |
| form                       | macro; records the call site     | function; capturable; no `:env` |

They compose rather than compete: an error wrapped on its way up keeps its full
chain of causes, and normalizing at the edge leaves that chain intact.

### Handling `{:error, reason}` tuples

Tuples are not unwrapped, since a value that legitimately _is_ a two-tuple can't
be told apart from one that means "error". Match at the call site instead:

```elixir
case Repo.transaction(fun) do
  {:ok, result} -> {:ok, result}
  {:error, reason} -> {:error, Errata.to_error(reason)}
end
```

### Classifying the types you recognize

A `500` is the right answer for a genuinely unknown value and the wrong answer
for a changeset, which is a `422`, or a connection timeout, which is a retryable
`503`. `Errata.to_error/2` classifies nothing on its own — it is the base case
beneath the types your application recognizes:

```elixir
defmodule MyApp.Errors do
  def to_error(%Ecto.Changeset{} = changeset) do
    MyApp.ValidationFailed.new(
      reason: :invalid,
      context: %{errors: MyApp.Changeset.error_map(changeset)},
      cause: changeset
    )
  end

  def to_error(%MyApp.Http.Timeout{url: url} = timeout),
    do: MyApp.Http.RequestFailed.new(reason: :timeout, context: %{url: url}, cause: timeout)

  # everything else falls through to the library default
  def to_error(other), do: Errata.to_error(other)
end
```

Each recognized type gets the classification of the error type it converts to,
and anything you have not gotten to yet still arrives as something the boundary
can render, log and count:

```elixir
iex> error = MyApp.Errors.to_error(%MyApp.Http.Timeout{url: "https://example.com"})
iex> Errata.http_status(error)
503
iex> Errata.retryable?(error)
true
iex> MyApp.Errors.to_error(:something_unforeseen) |> Errata.http_status()
500
```

Plain function clauses rather than anything Errata-specific: one function to read
to see how a system classifies its errors, and two boundaries can classify the
same value differently when they need to — an admin API and a public API rarely
want to say the same thing about a changeset.

The fallback controller then loses its hand-written clauses, including the guard:

```elixir
def call(conn, {:error, error}) do
  error = MyApp.Errors.to_error(error)

  conn
  |> put_status(Errata.http_status(error))
  |> put_view(MyApp.ErrorView)
  |> render("error.json", error: error)
end
```

### Normalize at the boundary, not before it

`Errata.http_status(:timeout)` raises, and that is worth keeping: inside your
domain code it means an error escaped unclassified, which is a bug you want to
hear about. Normalizing turns that noise into a quiet `500`, so call
`to_error/2` where an error is on its way out of the system — a controller, a
job runner, a message consumer — rather than in the middle of the code that
produced it.

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
classification your own retry logic — or a library such as
[`ExternalService`](https://hexdocs.pm/external_service), which handles retries
with backoff, rate limiting and circuit breakers, and which already uses Errata
for its own errors — can branch on without knowing the error's specific type:

```elixir
case do_work() do
  {:error, error} when Errata.is_error(error) ->
    if Errata.retryable?(error), do: retry(), else: {:error, error}

  result ->
    result
end
```

## Carrying the classification across the wire

Everything above works wherever the error struct is in hand. Once an error is
serialized — an API response, a job payload, a message on a queue — the receiving
side has a plain map, and the module that knows how to classify it may live in
another service, or in a program that isn't written in Elixir at all.

So `Errata.to_map/1`, and therefore the JSON encoding, carries the classification
along with the error:

```elixir
iex> alias MyApp.Http.RequestFailed
iex> map = Errata.to_map(RequestFailed.new(reason: :timeout))
iex> {map.kind, map.http_status, map.severity, map.retryable}
{:infrastructure, 503, :error, true}
```

These four keys are computed through the same overridable functions as the
accessors, so a type that derives its status or retryability from `:reason` is
serialized with the value it actually computed, not a default:

```elixir
iex> defmodule MyApp.Upstream.CallFailed do
...>   use Errata.InfrastructureError
...>   def http_status(%{reason: :timeout}), do: 504
...>   def http_status(_error), do: 503
...> end
iex> Errata.to_map(MyApp.Upstream.CallFailed.new(reason: :timeout)).http_status
504
```

In JSON the atoms arrive as strings while `http_status` stays an integer and
`retryable` a boolean, so a consumer can branch on them without parsing
anything:

```json
{
  "error_type": "MyApp.Http.RequestFailed",
  "code": null,
  "reason": "timeout",
  "message": "the request to an upstream service failed",
  "kind": "infrastructure",
  "http_status": 503,
  "severity": "error",
  "retryable": true
}
```

A wrapped `cause` and the members of an aggregate serialize through the same
`to_map/1`, so each carries its own classification rather than inheriting the
outer error's — a `422` validation failure wrapping a `503` upstream error
reports both.

Two things worth being clear about:

  * **Match on `code`, not `error_type`.** The classification tells a consumer
    what to *do*; it does not identify the error. `error_type` is a module name
    and moves when you move the module — see
    [stable external error codes](#stable-external-error-codes) above.
  * **A consumer needs nothing from Errata to use this.** The four keys are
    plain JSON values, which is the point: the far side can be another language,
    or a service that has never heard of this library. If the receiving side
    *is* an Elixir application that has the error type compiled, it can go
    further — see [rebuilding an error](#rebuilding-an-error-from-its-encoded-form)
    below.

`Errata.log/2` and `Errata.report/2` attach the same classification as metadata,
so a telemetry handler can route and tag on exactly what a boundary branches on
— see [Reporting errors](observability.md).

### Two audiences, two projections

`to_map/1` is the **full record**. It is aimed at an error reporter, which wants
everything it can get — including `:env`, the module, function, and source line
where the error was created.

That is the wrong map to hand a client. A response body should carry what the
caller can act on and nothing else, and in particular should not describe your
source layout. Pass `:only` or `:except` to say which audience you are serving:

```elixir
iex> alias MyApp.Http.RequestFailed
iex> map = Errata.to_map(RequestFailed.new(reason: :timeout), only: [:code, :message, :retryable])
iex> Map.keys(map) |> Enum.sort()
[:code, :message, :retryable]
```

```elixir
iex> alias MyApp.Http.RequestFailed
iex> map = Errata.to_map(RequestFailed.new(reason: :timeout), except: [:env])
iex> Map.has_key?(map, :env)
false
```

The projection reaches aggregate members and a wrapped Errata cause too, so
`except: [:env]` removes every `:env` in the structure rather than only the
outermost one. Keys are validated, so a misspelled one raises rather than
quietly selecting nothing.

> #### The encoder protocols emit the full map {: .warning}
>
> `Jason.encode!/1` and `JSON.encode!/1` on an error struct produce `to_map/1` —
> the full record, `:env` included. So **`render("error.json", error: error)`
> handing the struct straight to an encoder puts your source paths in the response
> body.** At a client-facing boundary, select the fields and encode the resulting
> map rather than the error.

The source path that `to_map/1` does emit is relative to the project root of the
application that defined the error type, so it reads `lib/my_app/orders.ex:29`
rather than naming the directory layout of the machine that built the release.

## A worked boundary, end to end

The pieces above appear separately throughout this guide. Here they are together,
which is the only place all of the decisions have to be made at once. Errata stays
free of any web-framework dependency, so the glue below is application code — but
it is the same glue in every application, so here it is.

### The view

```elixir
defmodule MyAppWeb.ErrorJSON do
  @client_fields [:code, :message, :retryable, :errors]

  def render("error.json", %{error: error}) do
    Errata.to_map(error, only: @client_fields)
  end
end
```

That is the whole view. A single-error response:

```elixir
iex> alias MyApp.Orders.OrderNotFound
iex> Errata.to_map(OrderNotFound.new(reason: :not_found), only: [:code, :message, :retryable, :errors])
%{code: "ORDER_NOT_FOUND", message: "the requested order does not exist", retryable: false}
```

and a validation response, from the same call with no branching:

```elixir
iex> alias MyApp.Orders.{ValidationFailed, EmailInvalid, PostcodeRequired}
iex> invalid = ValidationFailed.new(errors: [EmailInvalid.new(), PostcodeRequired.new()])
iex> Errata.to_map(invalid, only: [:code, :message, :retryable, :errors])
%{
  code: "VALIDATION_FAILED",
  message: "the order could not be validated",
  retryable: false,
  errors: [
    %{code: "EMAIL_INVALID", message: "email is not a valid address", retryable: false},
    %{code: "POSTCODE_REQUIRED", message: "postcode is required", retryable: false}
  ]
}
```

Two properties are doing the work. The projection **recurses into members**, so
each one is rendered by the same rule as the top-level error — including its own
`code`, which is what a client matches on. And `:errors` is simply **absent** for
a type that is not an aggregate, so the single clause covers both shapes without
asking which one it has.

### The controller

```elixir
defmodule MyAppWeb.FallbackController do
  use Phoenix.Controller

  def call(conn, {:error, value}) do
    error = MyApp.Errors.to_error(value)

    Errata.log(error)

    conn
    |> put_status(Errata.http_status(error))
    |> put_view(MyAppWeb.ErrorJSON)
    |> render("error.json", error: error)
  end
end
```

`MyApp.Errors.to_error/1` is the funnel from
[classifying the types you recognize](#classifying-the-types-you-recognize) — it
turns an `Ecto.Changeset`, a `{:error, :timeout}`, or anything else the boundary
meets into an Errata error, so everything below it can assume one. `Errata.log/2`
with no level logs at the error's own `severity/1`, so a `:warning`-severity
domain error does not page anyone; see [Reporting errors](observability.md) for
the telemetry side.

The status comes from `Errata.http_status/1`, and an aggregate answers it for the
whole collection — the members' status when they agree, its own when they do not.

### Why the fields are selected rather than handed over

The shorter implementation of this view is `Errata.to_map(error)`. Here is what
that hands a client:

```elixir
iex> alias MyApp.Orders.OrderNotFound
iex> OrderNotFound.new(reason: :not_found) |> Errata.to_map() |> Map.keys() |> Enum.sort()
[:cause, :code, :context, :env, :error_type, :http_status, :kind, :message, :reason, :retryable, :severity]
```

`:env` is your module, function, and source line. `:context` is whatever the error
site put there. `error_type` is a module name, which moves when you move the
module — the reason [stable external codes](#stable-external-error-codes) exist.

Naming the fields also means **adding a field to an error cannot silently widen
your public API.** The list is the contract you are offering clients, so it is
worth writing down somewhere, and the view is the natural place.

## Rebuilding an error from its encoded form

Everything above works from the encoded map alone. When the receiving side is an
Elixir application that already has the error type compiled — a service you
deploy alongside this one, a job runner, a consumer of your own queue — it can
turn the map back into an error with `Errata.from_map/3`, and get pattern
matching and the guards back with it:

```elixir
iex> alias MyApp.Orders.OrderNotFound
iex> encoded = OrderNotFound.new(reason: :not_found) |> Jason.encode!() |> Jason.decode!()
iex> {:ok, error} = Errata.from_map(OrderNotFound, encoded)
iex> match?(%OrderNotFound{}, error)
true
iex> Errata.http_status(error)
422
```

The type is an argument rather than something read from the encoded
`error_type`. Resolving a module from a name off the wire would mean trusting
that name *and* keeping a registry of every error type — the central registry
the structural `is_error/1` guard exists to avoid. Passing the type keeps the
decision at the call site, where you already know what you asked for.

Use `from_map!/3` when a malformed payload means something is broken rather than
something a caller sent wrong; it returns the error directly and raises
otherwise.

### What a decoded error is, and is not

It is a faithful **classification**, not a faithful reconstruction:

  * `:kind`, `http_status/1`, `severity/1` and `retryable?/1` are recomputed from
    the type *here*, and the encoded values are ignored. The receiver's own
    definitions win, so a decoded error behaves identically to a locally-created
    one even when the sender is running an older version of the type.
  * `:env` is always `nil` — it described a location in the sending process.
  * `:cause` is kept as the decoded value rather than rebuilt into an error,
    since that would need its module too.
  * Context redacted on the way out stays redacted. The original values were
    never on the wire.

Two limits worth knowing before you reach for it. **Aggregate types are
refused** — each member carries its type only as a name, so rebuilding them
needs exactly the registry above; decode members individually and rebuild the
aggregate with `new/1`. And **context keys come back as strings** by default,
since context is arbitrary data and converting it is where an atom-exhaustion
risk would live; pass `keys: :existing_atoms` to convert the ones that already
exist.

A type that declares `:reasons` decodes its reason by matching against that
declared set, so nothing from the wire ever reaches `String.to_existing_atom/1`.
That makes `:reasons` worth declaring on any type you expect to cross a
boundary:

```elixir
iex> defmodule MyApp.Orders.PaymentRejected do
...>   use Errata.DomainError, reasons: [:declined, :expired]
...> end
iex> Errata.from_map(MyApp.Orders.PaymentRejected, %{"reason" => "timeout"})
{:error, {:unknown_reason, "timeout"}}
```

`:timeout` is a perfectly ordinary atom in any running system; it is refused
here because it is not one of *this type's* reasons.

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

### One error, two surfaces

`display_message/1` is the **surface-independent** phrasing: the words that hold
wherever the error can be shown. That is worth deciding deliberately, because one
error type usually surfaces in more than one place.

Take an authentication failure from a third-party API. On a background transfer
report, the connection has gone stale and the useful message is "reconnect to
continue". The same error comes back from the *connect form*, where credentials
are being entered for the first time — there is nothing to reconnect to, and the
user is looking at the three fields they just typed. The right message there is
about the fields.

Neither phrasing is wrong; they answer different questions, and only the call site
knows which one is being asked. So put the phrasing that holds everywhere in the
type, and match on `Errata.reason/1` where a surface needs different words:

```elixir
def error_text(error) do
  case Errata.reason(error) do
    :unauthorized -> "Check your username and password and try again."
    _ -> Errata.display_message(error)
  end
end
```

Kept the other way round, every error type would have to know the set of places it
can be rendered — a set that grows with the application, and that the error site
has no way to see.

The developer message is unaffected either way: `Exception.message/1` keeps
combining `:message` and `:reason` for logs and raised output, whatever
`display_message/1` does. See
[rendering an error for users](#rendering-an-error-for-users) above.

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

