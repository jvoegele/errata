# Reporting errors

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

