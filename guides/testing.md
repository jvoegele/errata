# Testing with Errata

An Errata error is a value, so testing one is mostly ordinary Elixir: build it,
call the code, assert on what comes back. What follows is the handful of places
where the obvious first attempt points somewhere other than the cause — where
fixture types can live, how to get a readable diff out of a failed assertion,
where redaction takes effect, and how to reach the telemetry and log seams.

Every example here is executed by `test/errata/testing_guide_test.exs`.

## Where to define fixture error types

An error type defined inside a test body fails, in a default `mix new` project:

```elixir
test "error type defined in a test body" do
  defmodule InBody do
    use Errata.DomainError, default_message: "boom"
  end

  to_string(InBody.new(reason: :x))
end
```

```
** (Protocol.UndefinedError) protocol String.Chars not implemented
   for %InBody{...} of type InBody (a struct)
```

`use Errata.Error` generates three protocol implementations — `String.Chars`,
plus `JSON.Encoder` and/or `Jason.Encoder` — and protocol implementations are
consolidated when your project compiles. A type defined after that point gets
none of them. The three "protocol has already been consolidated" warnings that
explain this are emitted at the `defmodule`, far from the `to_string/1` that
fails.

Two fixes, and they are different trade-offs:

  * **Define fixture types at the top level of the test file**, above the test
    module. Local, needs no project change. This is what Errata's own test suite
    does.
  * **Set `consolidate_protocols: Mix.env() != :test`** in `mix.exs`. One line,
    and it removes the trap for the whole suite. Errata does this too.

Only the protocol paths are affected. Everything else works on a type defined in
a test body, which is why this can go unnoticed for a while:

```elixir
error = InBody.new(reason: :x)

Errata.reason(error)           #=> :x
Errata.display_message(error)  #=> "boom"
Errata.to_map(error).code      #=> "IN_BODY"

to_string(error)               #=> ** (Protocol.UndefinedError)
```

## Asserting on errors

The obvious assertion fails, and fails unreadably:

```elixir
{:error, error} = Orders.place_order(%{id: 7})

assert error == OrderNotFound.new(reason: :not_found, context: %{order_id: 7})
```

The two structs differ only in `:env` — one was built with `Errata.create/2`,
which captures the environment, and the other with `new/1`, which does not. But
ExUnit prints both sides in full, and `Errata.Env` contains a stacktrace,
absolute file paths and `context_modules`, so the one field that actually differs
is buried in roughly forty lines of diff.

**Assert through the accessors.** This is the shortest path to a diff that names
the problem:

```elixir
assert %OrderNotFound{} = error
assert Errata.reason(error) == :not_found
assert Errata.context(error) == %{order_id: 7}
```

When the reason is wrong, that produces:

```
code:  assert Errata.reason(error) == :expired
left:  :not_found
right: :expired
```

Two lines, pointing at the field that differs. For comparison, on the same wrong
assertion:

| approach | failure diff |
| --- | --- |
| accessor assertions | 2 lines, names the differing field |
| `%{error \| env: nil} == expected` | ~16 lines, both sides readable |
| pattern match on the whole struct | ~30 lines, right side fully expanded |
| plain `==` | ~40 lines, both sides fully expanded |

Pattern matching on the whole struct is *not* a good workaround, despite
asserting correctly: ExUnit expands the entire right-hand term on a failed match,
so the diff is as unreadable as `==`.

When you genuinely want to compare everything, null out the volatile field:

```elixir
assert %{error | env: nil} == OrderNotFound.new(reason: :not_found, context: %{order_id: 7})
```

`new/1` is the constructor to prefer in tests for the same reason — it leaves
`:env` nil, so the structs it builds compare cleanly. See `c:Errata.Error.new/1`.

## Asserting that redaction works

This is the one worth getting right, because getting it wrong looks like a
security problem:

```elixir
error = LoginFailed.new(context: %{password: "hunter2", user: "jane"})

error.context                    #=> %{password: "hunter2", user: "jane"}
Errata.context(error)            #=> %{password: "hunter2", user: "jane"}
Errata.to_map(error).context     #=> %{password: "[REDACTED]", user: "jane"}
```

Redaction applies **where the error leaves the process**, not at creation: the
struct keeps the value, and `to_map/1` is what removes it. A test that reads
`error.context` therefore sees the plaintext password, which looks exactly like
proof that `:redact` is not working.

Assert at the seam instead:

```elixir
assert Errata.to_map(error).context == %{password: "[REDACTED]", user: "jane"}
```

### What `:redact` cannot protect

`:redact` covers the keys you remembered to declare. It cannot cover the two ways
secrets actually escape:

```elixir
# 1. the same secret under a key you did not declare
LoginFailed.new(context: %{params: %{"passwd" => "hunter2"}})

# 2. a secret interpolated into the message, which :redact never touches
LoginFailed.new(message: "login failed for hunter2")
```

Both pass through untouched. The property you want is not "the `:redact` option
is configured" but "**this value does not appear anywhere we emit**", which means
checking `to_map/1`, `Exception.message/1` and `display_message/1` together:

```elixir
defp refute_leaks(error, secret) do
  emitted = [
    inspect(Errata.to_map(error)),
    Exception.message(error),
    to_string(Errata.display_message(error))
  ]

  for output <- emitted do
    refute output =~ secret
  end
end
```

## Testing the telemetry seam

`Errata.report/2` is the integration point for external reporting, so an
application will have a handler worth testing. `:telemetry_test` ships with the
telemetry dependency Errata already requires, so this needs nothing extra:

```elixir
test "reporting an error emits the classification" do
  :telemetry_test.attach_event_handlers(self(), [[:errata, :error]])

  Errata.report(OrderNotFound.new(reason: :not_found))

  assert_received {[:errata, :error], _ref, measurements, metadata}
  assert metadata.code == "ORDER_NOT_FOUND"
  assert metadata.kind == :domain
  assert measurements.count == 1
end
```

## Logs

`capture_log/1` works normally with `Errata.log/2`. The *metadata* is the whole
point of `log/2`, though, and it is not in the captured string unless you ask for
it:

```elixir
log = capture_log([metadata: :all], fn -> Errata.log(error) end)

assert log =~ "code=ORDER_NOT_FOUND"
assert log =~ "severity=error"
```

## Which message `assert_raise` matches

`assert_raise` matches the **developer** message — `:message` and `:reason`
combined, the same string `Exception.message/1` returns:

```elixir
assert_raise OrderNotFound, "the requested order does not exist: :not_found", fn ->
  raise OrderNotFound, reason: :not_found
end
```

Not the display message. Given how carefully the two renderings are kept apart
elsewhere, this is easy to guess wrong — see
[rendering an error for users](boundaries.md#rendering-an-error-for-users).
