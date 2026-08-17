# Handling errors

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

