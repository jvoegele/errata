defmodule Errata do
  # Pull in the moduledocs from the demarcated section of the README file
  @external_resource Path.expand("./README.md")
  @moduledoc File.read!(Path.expand("./README.md"))
             |> String.split("<!-- README START -->")
             |> Enum.at(1)
             |> String.split("<!-- README END -->")
             |> List.first()

  require Logger

  @typedoc """
  Type to represent the various kinds of Errata errors.
  """
  @type error_kind :: :domain | :infrastructure | :general | nil

  @typedoc """
  Type to represent any kind of Errata error.

  Errata errors are `Exception` structs that have additional fields to contain extra contextual
  information, such as an error reason or details about the context in which the error occurred.
  """
  @type error :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error__: true,
          kind: Errata.error_kind(),
          message: String.t() | nil,
          reason: atom() | nil,
          context: map() | nil,
          cause: Errata.Cause.t() | nil,
          env: Errata.Env.t() | nil
        }

  @typedoc """
  Type to represent Errata domain errors.
  """
  @type domain_error :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error__: true,
          kind: :domain,
          message: String.t() | nil,
          reason: atom() | nil,
          context: map() | nil,
          cause: Errata.Cause.t() | nil,
          env: Errata.Env.t() | nil
        }

  @typedoc """
  Type to represent Errata infrastructure errors.
  """
  @type infrastructure_error :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error__: true,
          kind: :infrastructure,
          message: String.t() | nil,
          reason: atom() | nil,
          context: map() | nil,
          cause: Errata.Cause.t() | nil,
          env: Errata.Env.t() | nil
        }

  @doc """
  Returns `true` if `term` is any Errata error type; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_error(term)
           when is_struct(term) and
                  is_exception(term) and
                  is_map_key(term, :__errata_error__) and
                  :erlang.map_get(:__errata_error__, term) == true and
                  is_map_key(term, :kind) and
                  :erlang.map_get(:kind, term) in [
                    :domain,
                    :infrastructure,
                    :general
                  ] and
                  is_map_key(term, :message) and
                  is_map_key(term, :reason) and
                  is_map_key(term, :context) and
                  is_map_key(term, :cause) and
                  is_map_key(term, :env)

  @doc """
  Returns `true` if `term` is an Errata domain error type; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_domain_error(term)
           when is_error(term) and
                  :erlang.map_get(:kind, term) == :domain

  @doc """
  Returns `true` if `term` is an Errata infrastructure error type; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_infrastructure_error(term)
           when is_error(term) and
                  :erlang.map_get(:kind, term) == :infrastructure

  @doc """
  Brings Errata's guards into scope and requires the module.

  `use Errata` is the simplest way to set up a module that handles or creates
  Errata errors. It is exactly equivalent to importing just the three guards:

      import Errata, only: [is_error: 1, is_domain_error: 1, is_infrastructure_error: 1]

  This makes `is_error/1`, `is_domain_error/1`, and `is_infrastructure_error/1`
  available **unqualified** — including in `when` clauses and function heads — and,
  because `import` implies `require`, also makes the `create/2` and `wrap/3`
  macros callable in their qualified form (`Errata.create/2`, `Errata.wrap/3`).

      defmodule MyApp.Orders.Boundary do
        use Errata

        def handle({:error, e}) when is_error(e), do: handle_errata_error(e)
        def handle({:error, e}), do: handle_other_error(e)
      end

  Only the guards are imported. The rest of the `Errata` API stays qualified
  (`Errata.to_map/1`, `Errata.put_context/3`, `Errata.report/2`, and so on),
  which keeps generically named functions out of your module's namespace and
  reads clearly at a boundary.

  > #### Not the same as `use Errata.Error` {: .info}
  >
  > `use Errata` is for modules that _work with_ errors. To _define_ a new error
  > type, `use Errata.Error` (or `Errata.DomainError` / `Errata.InfrastructureError`)
  > instead.
  """
  defmacro __using__(_opts) do
    quote do
      import Errata, only: [is_error: 1, is_domain_error: 1, is_infrastructure_error: 1]
    end
  end

  @doc """
  Creates an error of the given `error_module`, capturing the current `__ENV__`
  and stacktrace into the `:env` field.

  This is a convenience equivalent to the per-module `c:Errata.Error.create/1`
  macro, but it lives on the `Errata` module. Because you typically already
  `require Errata` (to use the guards above), you can `alias` your error modules
  and call `Errata.create/2` for any of them without a separate `require` for
  each error type:

      defmodule MyApp.Orders do
        require Errata
        alias MyApp.Orders.{OrderNotFound, PaymentDeclined}

        def fetch_order(id) do
          {:error, Errata.create(OrderNotFound, reason: :not_found, context: %{order_id: id})}
        end
      end

  Compare to the per-module macro, which requires a `require` for every error
  type used in the module:

      require MyApp.Orders.OrderNotFound, as: OrderNotFound
      require MyApp.Orders.PaymentDeclined, as: PaymentDeclined
  """
  defmacro create(error_module, params \\ Macro.escape(%{})) do
    quote do
      {:current_stacktrace, [_process_info_call | stacktrace]} =
        Process.info(self(), :current_stacktrace)

      Errata.Errors.create(unquote(error_module), unquote(params), __ENV__, stacktrace)
    end
  end

  @doc """
  Wraps `cause` in a new error of the given `error_module`, capturing the current
  `__ENV__` and stacktrace into the `:env` field.

  This is a convenience equivalent to the per-module `c:Errata.Error.wrap/2`
  macro, but it lives on the `Errata` module. As with `create/2`, you typically
  already `require Errata` (for the guards above), so you can `alias` your error
  modules and call `Errata.wrap/3` for any of them without a separate `require`
  for each error type:

      defmodule MyApp.Orders do
        require Errata
        alias MyApp.Orders.OrderNotFound

        def fetch_order(id) do
          try do
            external_lookup!(id)
          rescue
            e ->
              {:error,
               Errata.wrap(OrderNotFound, e, stacktrace: __STACKTRACE__, reason: :lookup_failed)}
          end
        end
      end

  The original error, exception, or value is stored as the new error's `:cause`;
  retrieve it with `Errata.cause/1` (or follow the chain with
  `Errata.root_cause/1`). The `opts` are the same as for the per-module
  `c:Errata.Error.wrap/2` macro: the standard error params (`:reason`,
  `:message`, `:context`) plus `:stacktrace` and `:kind`, which describe the
  wrapped cause.
  """
  defmacro wrap(error_module, cause, opts \\ []) do
    quote do
      {:current_stacktrace, [_process_info_call | stacktrace]} =
        Process.info(self(), :current_stacktrace)

      Errata.Errors.wrap(
        unquote(error_module),
        unquote(cause),
        unquote(opts),
        __ENV__,
        stacktrace
      )
    end
  end

  @doc """
  Converts any Errata error to a plain, JSON-encodable map.

  This is the generic counterpart to the per-type `c:Errata.Error.to_map/1`
  callback: it works on _any_ value for which `is_error/1` returns `true`,
  without needing to know the error's specific module. This is convenient at
  system boundaries (such as a Phoenix fallback controller) where errors of
  many different types are handled uniformly.

      iex> alias MyApp.Orders.OrderNotFound
      iex> error = OrderNotFound.new(reason: :not_found, context: %{order_id: 42})
      iex> map = Errata.to_map(error)
      iex> map.error_type
      "MyApp.Orders.OrderNotFound"
      iex> map.reason
      :not_found
      iex> map.context
      %{order_id: 42}

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec to_map(error()) :: map()
  def to_map(error) when is_error(error), do: Errata.Errors.to_map(error)

  def to_map(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns the human-readable _display message_ for an error: the value of its
  `:message` field, or `nil` if none was set.

  This is distinct from `Exception.message/1` (and the `String.Chars`
  implementation), which return a _developer-oriented_ message that also
  includes the `:reason` — useful in logs and raised-exception output, but not
  intended for end users. Use `display_message/1` when rendering an error for a
  user (for example, the body of a `4xx` HTTP response), supplying your own
  fallback for the `nil` case.

      iex> alias MyApp.Orders.PaymentDeclined
      iex> error = PaymentDeclined.new(reason: :insufficient_funds)
      iex> Errata.display_message(error)
      "the payment was declined"
      iex> Exception.message(error)
      "the payment was declined: :insufficient_funds"

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec display_message(error()) :: String.t() | nil
  def display_message(error) when is_error(error), do: error.message

  def display_message(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns a copy of `error` with `value` stored under `key` in its `:context` map.

  Context is normally set once, at the site where an error is created. But a
  structured error often travels up through several layers before reaching a
  boundary, and intermediate layers frequently know context that the creation
  site did not (the `user_id` known here, the `request_id` known there). Use
  `put_context/3` (or `merge_context/2`) to _enrich_ an error's context as it
  propagates, without rebuilding the struct by hand.

  If the error has no context yet (`nil`), it is initialized to a map. An
  existing value under `key` is overwritten.

      iex> alias MyApp.Orders.OrderNotFound
      iex> error = OrderNotFound.new(reason: :not_found, context: %{order_id: 42})
      iex> Errata.put_context(error, :user_id, 7).context
      %{order_id: 42, user_id: 7}

  A typical use is enriching an error as it propagates through a `with` chain:

      with {:error, err} <- fetch_order(id) do
        {:error, Errata.put_context(err, :user_id, current_user_id)}
      end

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec put_context(error(), term(), term()) :: error()
  def put_context(error, key, value) when is_error(error) do
    %{error | context: Map.put(error.context || %{}, key, value)}
  end

  def put_context(other, _key, _value) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns a copy of `error` with the key/value pairs from `context` merged into
  its `:context` map.

  Like `put_context/3`, but merges an entire map at once. On key collisions, the
  values in the given `context` win (last-write-wins). If the error has no
  context yet (`nil`), it is initialized from `context`.

      iex> alias MyApp.Orders.OrderNotFound
      iex> error = OrderNotFound.new(reason: :not_found, context: %{order_id: 42})
      iex> Errata.merge_context(error, %{user_id: 7, order_id: 99}).context
      %{order_id: 99, user_id: 7}

  Raises an `ArgumentError` if `error` is not an Errata error, or if `context` is
  not a map.
  """
  @spec merge_context(error(), map()) :: error()
  def merge_context(error, context) when is_error(error) and is_map(context) do
    %{error | context: Map.merge(error.context || %{}, context)}
  end

  def merge_context(error, context) when is_error(error) do
    raise ArgumentError, "expected a map of context to merge, got: #{inspect(context)}"
  end

  def merge_context(other, _context) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns the immediate cause wrapped by `error`, or `nil` if it has none.

  The cause is the original error, exception, or value that was wrapped when the
  error was created (typically via the generated `c:Errata.Error.wrap/2` macro,
  or by passing a `:cause` to `c:Errata.Error.new/1` or `c:Errata.Error.create/1`).
  This returns the bare wrapped value; the captured stacktrace (if any) is held
  in the error's `:cause` field as an `Errata.Cause` struct.

      iex> alias MyApp.Orders.OrderNotFound
      iex> require OrderNotFound
      iex> original = %RuntimeError{message: "boom"}
      iex> error = OrderNotFound.wrap(original, reason: :lookup_failed)
      iex> Errata.cause(error)
      %RuntimeError{message: "boom"}

      iex> alias MyApp.Orders.OrderNotFound
      iex> Errata.cause(OrderNotFound.new(reason: :not_found))
      nil

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec cause(error()) :: term() | nil
  def cause(error) when is_error(error) do
    case error.cause do
      %Errata.Cause{value: value} -> value
      nil -> nil
    end
  end

  def cause(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Walks the cause chain of `error` and returns the deepest (root) cause, or `nil`
  if `error` has no cause.

  When a wrapped cause is itself an Errata error carrying its own cause, the
  chain is followed to the bottom.

      iex> alias MyApp.Orders.{OrderNotFound, PaymentDeclined}
      iex> require OrderNotFound
      iex> require PaymentDeclined
      iex> root = %RuntimeError{message: "db down"}
      iex> inner = OrderNotFound.wrap(root, reason: :lookup_failed)
      iex> outer = PaymentDeclined.wrap(inner, reason: :declined)
      iex> Errata.root_cause(outer)
      %RuntimeError{message: "db down"}

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec root_cause(error()) :: term() | nil
  def root_cause(error) when is_error(error) do
    case cause(error) do
      nil -> nil
      value -> if is_error(value), do: root_cause(value) || value, else: value
    end
  end

  def root_cause(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Renders `error` and its full cause chain as a multi-line string for logging.

  The head is the error's own developer-oriented message (as returned by
  `Exception.message/1`), followed by a `Caused by:` line for each wrapped cause.
  Wrapped Errata errors recurse into their own chain; other wrapped values are
  rendered via `Exception.format/3`, including the captured stacktrace when one
  is present.

  Unlike `Exception.message/1`, which is kept clean and reports only the error's
  own message, this includes the entire chain — use it where you want the
  underlying context surfaced, such as a log entry.

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec format_chain(error()) :: String.t()
  def format_chain(error) when is_error(error) do
    head = "#{inspect(error.__struct__)}: #{Exception.message(error)}"

    case error.cause do
      nil -> head
      %Errata.Cause{} = cause -> head <> "\nCaused by: " <> format_cause(cause)
    end
  end

  def format_chain(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  defp format_cause(%Errata.Cause{value: value}) when is_error(value), do: format_chain(value)

  defp format_cause(%Errata.Cause{kind: kind, value: value, stacktrace: stacktrace}) do
    Exception.format(kind, value, stacktrace || [])
  end

  @doc """
  Returns the HTTP status code associated with `error`.

  This delegates to the error module's generated `http_status/1` function, which
  defaults off the error's kind — `:domain` errors map to `422`, `:infrastructure`
  errors to `503`, and `:general` errors to `500`. A specific status can be set
  per type with the `:http_status` option to `use Errata.Error` (and friends), or
  by overriding `http_status/1` to compute a status from the error's `:reason` or
  `:context`.

  This lets a boundary — such as a Phoenix fallback controller — map any Errata
  error to a response status without knowing its specific type:

      def call(conn, {:error, error}) when Errata.is_error(error) do
        conn
        |> put_status(Errata.http_status(error))
        |> put_view(MyApp.ErrorView)
        |> render("error.json", error: error)
      end

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec http_status(error()) :: non_neg_integer()
  def http_status(error) when is_error(error) do
    error.__struct__.http_status(error)
  end

  def http_status(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns the stable external code for `error`, or `nil` if it has none.

  An error's type identity is its Elixir module, which is an implementation
  detail: renaming or moving the module changes the only identifier that
  `to_map/1` exposes (`error_type`). That makes it a poor contract for external
  consumers — API clients, i18n catalogs, support tooling — who need an
  identifier that survives refactoring.

  A code is that identifier. It is opt-in, and independent of the module name:

      defmodule MyApp.Orders.OrderNotFound do
        use Errata.DomainError, code: "ORDER_NOT_FOUND"
      end

  The code appears in `to_map/1` (and therefore in the JSON encoding) under the
  `code` key, and in the metadata emitted by `log/2` and `report/2`. Types that
  do not declare one return `nil`, so a boundary that requires a code should
  supply its own fallback:

      Errata.code(error) || "UNKNOWN"

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec code(error()) :: String.t() | nil
  def code(error) when is_error(error) do
    error.__struct__.code(error)
  end

  def code(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns the severity of `error`, as a `t:Logger.level/0`.

  This delegates to the error module's generated `severity/1` function, which is
  `:error` for every error type unless it says otherwise. Set a severity per type
  with the `:severity` option to `use Errata.Error` (and friends), or override
  `severity/1` to compute one from the error's `:reason` or `:context`.

  Severity is the level at which `log/2` logs an error when no level is given
  explicitly, and is included in the metadata of both `log/2` and `report/2`, so
  a telemetry handler can route or alert on it:

      defmodule MyApp.Orders.RateLimited do
        use Errata.DomainError, severity: :warning
      end

  Unless a type opts in, the severity is `:error`:

      iex> alias MyApp.Orders.OrderNotFound
      iex> Errata.severity(OrderNotFound.new())
      :error

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec severity(error()) :: Logger.level()
  def severity(error) when is_error(error) do
    error.__struct__.severity(error)
  end

  def severity(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns `true` if `error` is considered retryable.

  This delegates to the error module's generated `retryable?/1` function, whose
  default is derived from the error's kind: `:infrastructure` errors are
  retryable (timeouts and connection blips are usually transient), while
  `:domain` and `:general` errors are not. Set it per type with the `:retryable`
  option to `use Errata.Error` (and friends), or override `retryable?/1` to
  decide from the error's `:reason` or `:context`.

  Errata deliberately provides no retry mechanism of its own — this is a
  classification that _your_ retry logic (or a library such as `:retry`) can
  branch on without knowing the error's specific type:

      case do_work() do
        {:error, error} when Errata.is_error(error) ->
          if Errata.retryable?(error), do: retry(), else: {:error, error}

        result ->
          result
      end

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec retryable?(error()) :: boolean()
  def retryable?(error) when is_error(error) do
    error.__struct__.retryable?(error)
  end

  def retryable?(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Logs `error` at the given `level` with its structured fields attached as Logger
  metadata.

  When no `level` is given, the error's own `severity/1` is used (which is
  `:error` unless the error type sets a `:severity`).

  The log _message_ is the developer-oriented `Exception.message/1` (combining
  `:message` and `:reason`). The error's `:reason`, `:kind`, `:context`, and
  origin `:env` are attached as **Logger metadata** rather than being flattened
  into the message string, so they remain queryable structured fields in
  backends that support them. The following metadata keys are set:

    * `:error_type` — the error's module
    * `:kind` — the error's kind (`:domain` / `:infrastructure` / `:general`)
    * `:reason` — the error's reason
    * `:code` — the error's stable external code, or `nil` (see `code/1`)
    * `:severity` — the error's severity (see `severity/1`)
    * `:retryable` — whether the error is retryable (see `retryable?/1`)
    * `:context` — the error's context map
    * `:env` — a map of the origin `module`, `function`, `file`, and `line`

  Returns `:ok`. Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec log(error(), Logger.level() | nil) :: :ok
  def log(error, level \\ nil)

  def log(error, level) when is_error(error) do
    Logger.log(level || severity(error), fn -> Exception.message(error) end, log_metadata(error))
  end

  def log(other, _level) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Emits a `:telemetry` event for `error`, and optionally logs it.

  This is the seam for error _reporting_: rather than integrating with any
  particular external service, Errata emits a telemetry event that your
  application handles — attaching a handler that forwards to Sentry, a metrics
  backend, or wherever errors should go. The vendor integration stays in your
  application; Errata stays out of it.

  The event is `[:errata, :error]`, with:

    * measurements `%{system_time: integer(), count: 1}` — `:count` is always `1`,
      so `Telemetry.Metrics.counter/2` works out of the box
    * metadata containing the full `:error` struct plus `:kind`, `:reason`,
      `:error_type`, `:code`, `:severity`, `:retryable`, and `:context` as
      top-level keys (simple values suitable for use as metric tags)

  Options:

    * `:metadata` — a map or keyword list of extra metadata merged into the event.
      The standard keys above are protected: on a key collision, the standard
      value wins.
    * `:measurements` — extra measurements merged into the event, with the
      standard measurements likewise protected.
    * `:log` — also log the error via `log/2`. `false` (the default) emits
      telemetry only; `true` logs at the error's own `severity/1`; an atom level
      (e.g. `:warning`) logs at that level.

  Returns `:ok`. Raises an `ArgumentError` if `error` is not an Errata error.

      :telemetry.attach("myapp-errata", [:errata, :error], &MyApp.ErrorReporter.handle/4, nil)

      Errata.report(error, metadata: %{request_id: request_id}, log: :warning)
  """
  @spec report(error(), keyword()) :: :ok
  def report(error, opts \\ [])

  def report(error, opts) when is_error(error) and is_list(opts) do
    measurements =
      opts
      |> Keyword.get(:measurements, [])
      |> Map.new()
      |> Map.merge(%{system_time: System.system_time(), count: 1})

    metadata =
      opts
      |> Keyword.get(:metadata, [])
      |> Map.new()
      |> Map.merge(standard_metadata(error))

    :telemetry.execute([:errata, :error], measurements, metadata)

    maybe_log(error, Keyword.get(opts, :log, false))

    :ok
  end

  def report(other, _opts) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  # The `:error` struct is carried with its context redacted too, not just the
  # separate `:context` key. Leaving the raw struct in metadata would make
  # redaction pointless in the case it exists for: a handler that forwards the
  # error to Sentry reaches `metadata.error` and ships the unredacted context.
  # The struct is otherwise untouched — same type, same reason, still
  # pattern-matchable and re-raisable. The unredacted context remains available
  # on the error you hold locally.
  defp standard_metadata(error) do
    context = Errata.Errors.redacted_context(error)

    %{
      error: %{error | context: context},
      kind: error.kind,
      reason: error.reason,
      error_type: error.__struct__,
      code: code(error),
      severity: severity(error),
      retryable: retryable?(error),
      context: context
    }
  end

  defp log_metadata(error) do
    [
      error_type: error.__struct__,
      kind: error.kind,
      reason: error.reason,
      code: code(error),
      severity: severity(error),
      retryable: retryable?(error),
      context: Errata.Errors.redacted_context(error),
      env: env_metadata(error.env)
    ]
  end

  defp env_metadata(%Errata.Env{module: module, function: function, file: file, line: line}) do
    %{module: module, function: function, file: file, line: line}
  end

  defp env_metadata(_), do: %{}

  defp maybe_log(_error, level) when level in [false, nil], do: :ok
  defp maybe_log(error, true), do: log(error, severity(error))
  defp maybe_log(error, level) when is_atom(level), do: log(error, level)
end
