# Reporting errors

Because an Errata error carries its full context, it is straightforward to get
it into your observability stack at a boundary. Errata provides two thin,
composable functions for this, and — deliberately — no integration with any
particular external service.

`Errata.log/2` logs an error's developer message, attaching its `reason`, `kind`,
`code`, `severity`, `retryable`, `http_status`, `context`, and origin `env` as **Logger metadata**
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
`:reason`, `:error_type`, `:code`, `:severity`, `:retryable`, `:http_status`,
and `:context` as top-level keys — simple values that work directly as metric
tags. A handler in your application wires it up:

```elixir
:telemetry.attach("myapp-errata", [:errata, :error], &MyApp.ErrorReporter.handle/4, nil)

def handle([:errata, :error], _measurements, metadata, _config) do
  Sentry.capture_message(Exception.message(metadata.error),
    extra: Errata.to_map(metadata.error),
    tags: %{error_type: inspect(metadata.error_type), reason: metadata.reason}
  )
end
```

## What a handler sees of the cause chain

An error that wraps a lower-level failure has two facts worth reporting, and the
outer one is usually the less useful: `Exception.message/1` on the error above
says what your code was *trying* to do, not what went wrong. So the cause travels
in metadata, in two shapes for two kinds of consumer:

  * **`cause`** — the same nested map `Errata.to_map/1` emits, so a structured
    log formatter or a telemetry handler gets every level of the chain with its
    own `code`, `context` and classification. Redaction applies at each level.
  * **`caused_by`** — one greppable line naming the deepest failure, for a console
    reader or a single log field.

```elixir
error = Errata.wrap(RetriesExhausted, %RuntimeError{message: "connection refused"})

# in a Logger backend or a telemetry handler:
metadata.caused_by   #=> "** (RuntimeError) connection refused"
metadata.cause       #=> %{error_type: "RuntimeError", message: "connection refused"}
```

Both are `nil` for an error with no cause. Note that `caused_by` is *not* named
`root_cause`: `Errata.root_cause/1` returns the error itself when there is no
cause, and a metadata key that contradicted the function of the same name would
be worse than a slightly different word.

Neither key requires the handler to know what kind of thing the cause is — a
foreign exception, an `{:error, reason}` tuple and a nested Errata error are all
rendered for you.

### Reaching for the whole chain

A telemetry handler also receives the error struct itself under `:error`, so it
can render the full chain including stacktraces, which no metadata key carries:

```elixir
def handle_event([:errata, :error], _measurements, %{error: error}, _config) do
  Logger.error(Errata.format_chain(error))
end
```

`Errata.format_chain/1` is the right call for a log line about a wrapped failure:
it shows each level and the original stacktrace, where `Errata.log/2` logs the
outer error's message with the chain in metadata.

The one place a handler still has to look at *types* is a reporter that wants an
exception rather than a map — `Sentry.capture_exception/2`, say. Which one you
want is an application decision, so pick it explicitly:

```elixir
case Errata.root_cause(error) do
  %{__exception__: true} = exception -> Sentry.capture_exception(exception, extra: Errata.to_map(error))
  _plain_term -> Sentry.capture_message(Exception.message(error), extra: Errata.to_map(error))
end
```

## Redacting sensitive context

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

## Testing what you have wired up

`:telemetry_test` ships with the telemetry dependency Errata already requires, so
asserting on the `[:errata, :error]` event needs nothing extra, and `capture_log/1`
needs `metadata: :all` before the metadata that `log/2` exists for shows up. Both
idioms are in [Testing with Errata](testing.md), along with the seam at which
redaction has to be asserted.
