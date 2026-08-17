# Design notes

Conceptual material that is useful once you have defined a few error types, but
that nobody needs before their first one.

## Choosing a kind

Every Errata error has a `:kind` — `:domain`, `:infrastructure`, or `:general` —
fixed when you define the type. This section covers what the choice decides, how
to make it, and how to opt out of it entirely.

### What the kind decides

The kind supplies the default for two of the boundary classifications:

| kind | `http_status/1` | `retryable?/1` |
|---|---|---|
| `:domain` | `422` | `false` |
| `:infrastructure` | `503` | `true` |
| `:general` | `500` | `false` |

Both are defaults only, overridden per type with the `:http_status` and
`:retryable` options. Nothing else derives from the kind: `severity/1` defaults
to `:error` for every kind, and `code/1` has no default at all.

Treat the `retryable?/1` default as usually right and the `http_status/1` default
as a starting point. Domain errors in particular often want a more specific
status than `422`:

```elixir
defmodule MyApp.Orders.OrderNotFound do
  use Errata.DomainError, http_status: 404
end
```

The kind also backs two guards, `Errata.is_domain_error/1` and
`Errata.is_infrastructure_error/1`, which let a boundary branch on the kind in a
function head. This is the part that keeps paying off as an application grows:
a fallback controller written today handles domain error types added months
later, without being edited.

```elixir
defmodule MyAppWeb.FallbackController do
  use Phoenix.Controller
  import Errata

  # Safe to show the caller. `display_message/1` is `nil` for a type defined
  # without `:default_message`, so give it a fallback.
  def call(conn, {:error, error}) when is_domain_error(error) do
    conn
    |> put_status(Errata.http_status(error))
    |> json(%{error: Errata.display_message(error) || "invalid request"})
  end

  # Ours to fix — log it and stay vague.
  def call(conn, {:error, error}) when is_error(error) do
    Errata.log(error)

    conn
    |> put_status(Errata.http_status(error))
    |> json(%{error: "something went wrong"})
  end
end
```

### Making the choice

The most reliable question is not whose fault the error is, but **who acts on
it**:

- The **caller** can act on it by changing the request — `:domain`.
- An **operator** acts on it, or it resolves on its own if retried —
  `:infrastructure`.
- **Neither, or it does not matter** — `:general`.

That question resolves most of the cases that feel ambiguous when phrased as
"domain or infrastructure":

| situation | kind | because |
|---|---|---|
| input fails a validation rule | `:domain` | the caller fixes the input |
| an order is not found | `:domain` | the caller asks for a different order |
| the database connection drops | `:infrastructure` | an operator or a retry fixes it |
| a third-party API is unreachable | `:infrastructure` | same — see below |
| a malformed request body arrives | `:domain` | the caller sends valid JSON |
| a malformed *response* from an upstream service | `:infrastructure` | the caller can do nothing |
| an unexpected error from library code | `:general` | nobody planned for it |

Whatever convention you settle on, apply it consistently across an application.
The kind's defaults are silent — a misclassified infrastructure error returns
`422` for a database outage, and nothing warns you.

### External-service errors

A third-party API failing is `:infrastructure`. An application reaches an
external service through an adapter, and that adapter is infrastructure; from the
caller's point of view there is no useful difference between "our database is
down" and "their API is down." Both are already retryable by default, and a
specific status is one option away:

```elixir
defmodule MyApp.Payments.GatewayUnavailable do
  use Errata.InfrastructureError,
    default_message: "the payment gateway is unavailable",
    http_status: 502,
    code: "GATEWAY_UNAVAILABLE"
end
```

If you need to tell *your* outages from *someone else's* — for circuit breakers,
alerting, or deciding who gets paged — that distinction is about ownership rather
than layer, and it does not have to live in the kind. Define a guard over your
own types:

```elixir
defmodule MyApp.Errors do
  @external [MyApp.Payments.GatewayUnavailable, MyApp.Shipping.CarrierTimeout]

  defguard is_external_error(term)
           when is_struct(term) and :erlang.map_get(:__struct__, term) in @external
end
```

It is usable in function heads and `case` clauses exactly like
`is_infrastructure_error/1`, and it names the set explicitly rather than
inferring it:

```elixir
defmodule MyApp.Boundary do
  import MyApp.Errors

  def handle(error) when is_external_error(error), do: :open_circuit
  def handle(_error), do: :normal
end
```

The same technique works for any classification an application wants — by
subsystem, by team, by alerting policy — without the taxonomy having to
anticipate it.

### Ignoring the taxonomy

The taxonomy is a convenience, not a requirement. If the domain/infrastructure
split does not fit how you think about your errors, define every type with the
base `Errata.Error` and set the classifications you care about explicitly:

```elixir
defmodule MyApp.OrderNotFound do
  use Errata.Error,
    default_message: "the requested order does not exist",
    http_status: 404,
    retryable: false
end
```

Everything else in the library works unchanged: `Errata.is_error/1`,
`http_status/1`, `code/1`, `severity/1`, `retryable?/1`, `log/2`, `report/2`,
`wrap/2`, redaction, and aggregation are all defined over the classification
functions rather than over the kind. What you give up is the two kind guards, so
boundaries dispatch on something else instead — a status range, or a guard of
your own as shown above:

```elixir
def call(conn, {:error, error}) when is_error(error) do
  case Errata.http_status(error) do
    status when status < 500 -> render_client_error(conn, status, error)
    status -> render_server_error(conn, status, error)
  end
end
```

This is a supported way to use the library, not a workaround. Errors defined this
way have kind `:general`, interoperate with errors that do use the taxonomy, and
lose nothing else.

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

