defmodule Errata do
  # Pull in the moduledocs from the demarcated section of the README file
  @external_resource Path.expand("./README.md")
  @moduledoc File.read!(Path.expand("./README.md"))
             |> String.split("<!-- README START -->")
             |> Enum.at(1)
             |> String.split("<!-- README END -->")
             |> List.first()

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
          env: Errata.Env.t()
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
end
