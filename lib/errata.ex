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
          required(:__struct__) => module(),
          required(:__exception__) => true,
          required(:__errata_error__) => true,
          required(:kind) => Errata.error_kind(),
          required(:message) => String.t() | nil,
          required(:reason) => atom() | nil,
          required(:context) => map() | nil,
          required(:cause) => Errata.Cause.t() | nil,
          required(:env) => Errata.Env.t() | nil,
          # Present only on aggregate types (`use Errata.Error, aggregate: true`).
          # Optional rather than required so an ordinary error still matches, and
          # declared at all so code that matches on it is not unreachable.
          optional(:errors) => [error()]
        }

  @typedoc """
  Type to represent Errata domain errors.
  """
  @type domain_error :: %{
          required(:__struct__) => module(),
          required(:__exception__) => true,
          required(:__errata_error__) => true,
          required(:kind) => :domain,
          required(:message) => String.t() | nil,
          required(:reason) => atom() | nil,
          required(:context) => map() | nil,
          required(:cause) => Errata.Cause.t() | nil,
          required(:env) => Errata.Env.t() | nil,
          # Present only on aggregate types (`use Errata.Error, aggregate: true`).
          # Optional rather than required so an ordinary error still matches, and
          # declared at all so code that matches on it is not unreachable.
          optional(:errors) => [error()]
        }

  @typedoc """
  Type to represent Errata infrastructure errors.
  """
  @type infrastructure_error :: %{
          required(:__struct__) => module(),
          required(:__exception__) => true,
          required(:__errata_error__) => true,
          required(:kind) => :infrastructure,
          required(:message) => String.t() | nil,
          required(:reason) => atom() | nil,
          required(:context) => map() | nil,
          required(:cause) => Errata.Cause.t() | nil,
          required(:env) => Errata.Env.t() | nil,
          # Present only on aggregate types (`use Errata.Error, aggregate: true`).
          # Optional rather than required so an ordinary error still matches, and
          # declared at all so code that matches on it is not unreachable.
          optional(:errors) => [error()]
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

  Wrapping is for when you know what a failure means — that is why it takes the
  error type as an argument, and why it always adds a layer even around an error
  that is already an Errata error. Where an error is on its way _out_ of the
  system and anything at all can arrive, use `to_error/2` instead: it has no type
  to name and leaves an already-classified error alone, where wrapping would
  replace that error's status and user-facing message with the wrapper's.
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
  Converts any value into an Errata error.

  Errata errors are returned unchanged, which makes this safe to apply to a
  value that may already have been normalized:

      iex> alias MyApp.Orders.OrderNotFound
      iex> error = OrderNotFound.new(reason: :not_found)
      iex> Errata.to_error(error) == error
      true

  Anything else is wrapped in an `Errata.UnknownError`, keeping the original as
  the cause. An atom also becomes the `:reason`:

      iex> error = Errata.to_error(:timeout)
      iex> error.__struct__
      Errata.UnknownError
      iex> Errata.reason(error)
      :timeout
      iex> Errata.cause(error)
      :timeout

  ## When to use this rather than `wrap/3`

  Both turn an arbitrary value into an Errata error. The difference is whether
  you know what the failure means.

  `wrap/3` is an act of interpretation, used where a failure is caught: you name
  the error type because in that place you know what a dropped connection means
  for the operation in hand, and it always adds a layer because each layer's
  interpretation is worth keeping. `to_error/2` is used where an error leaves the
  system and anything at all can arrive — there is no type to name, and an error
  that already is one comes back untouched.

  That last part is the reason to keep them apart. Wrapping at a boundary
  replaces an already-correct classification with the wrapper's:

      iex> require Errata
      iex> error = MyApp.Orders.OrderNotFound.new(reason: :not_found)
      iex> Errata.to_error(error) |> Errata.http_status()
      422
      iex> Errata.wrap(Errata.UnknownError, error) |> Errata.http_status()
      500

  It is also a plain function rather than a macro, so it can be captured and
  passed around (`&Errata.to_error/1`). The tradeoff is that it does not populate
  the `:env` field: normalization usually happens in a generic boundary function,
  where the call site is the boundary itself rather than anywhere informative
  about the failure.

  ## Classifying the types you know

  A `500` is the right answer for a genuinely unknown value and the wrong answer
  for an `Ecto.Changeset`, which is a `422`, or a connection timeout, which is a
  retryable `503`. This function classifies nothing on its own; it is the base
  case beneath the types your application recognizes:

      defmodule MyApp.Errors do
        def to_error(%Ecto.Changeset{} = changeset),
          do: MyApp.ValidationFailed.new(reason: :invalid, cause: changeset)

        def to_error(other), do: Errata.to_error(other)
      end

  Keeping the recognized types in ordinary function clauses means a boundary
  reads one function to see how errors are classified, and that the classification
  can differ between boundaries where it needs to. See
  [Errors at a boundary](guides/boundaries.md) for the full pattern.

  ## Options

    * `:fallback` - the error type to wrap unrecognized values in; defaults to
      `Errata.UnknownError`. Useful when an application has a catch-all type of
      its own.
    * `:kind` and `:stacktrace` - describe the wrapped cause, as in `wrap/3`.

  Any remaining options are passed as error params (`:reason`, `:message`,
  `:context`), which is how a caller supplies a reason that the value itself
  does not carry:

      iex> error = Errata.to_error("connection reset", reason: :disconnected)
      iex> Errata.reason(error)
      :disconnected

  ## Handling `{:error, reason}` tuples

  Tuples are not unwrapped: `to_error({:error, :timeout})` normalizes the
  two-tuple itself, since a value that legitimately _is_ a two-tuple is
  indistinguishable from one that means "error". Match the tuple at the call
  site instead:

      case do_something() do
        {:ok, result} -> result
        {:error, reason} -> {:error, Errata.to_error(reason)}
      end

  Raises `ArgumentError` if `:fallback` is not an Errata error type.
  """
  @spec to_error(term(), keyword()) :: error()
  def to_error(value, opts \\ [])

  def to_error(error, _opts) when is_error(error), do: error

  def to_error(value, opts) do
    {fallback, opts} = Keyword.pop(opts, :fallback, Errata.UnknownError)

    Errata.Errors.normalize(fallback, value, opts)
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

  The map contains `:error_type`, `:code`, `:reason`, `:message` (the
  `display_message/1` rendering), `:cause`, `:env`, `:context`, and — for an
  aggregate type — `:errors`.

  It also carries the error's classification, so that code holding only the
  serialized form can decide what to do with it:

      iex> alias MyApp.Orders.OrderNotFound
      iex> map = Errata.to_map(OrderNotFound.new(reason: :not_found))
      iex> {map.kind, map.http_status, map.severity, map.retryable}
      {:domain, 422, :error, false}

  These four are computed through the same overridable functions as `kind/1`,
  `http_status/1`, `severity/1` and `retryable?/1`, so an override is reflected
  here too. See
  [Errors at a boundary](guides/boundaries.md#carrying-the-classification-across-the-wire).

  Most consumers of this map need nothing else — the classification is enough to
  route, log and retry. An Elixir application that has the error type compiled
  can turn the map back into an error with `from_map/3`.

  Raises an `ArgumentError` if `error` is not an Errata error.

  ## Projecting the map

  `to_map/1` is the full record, aimed at an error reporter that wants everything.
  A response body crossing a boundary to a client wants much less — in particular
  it should not carry `:env`, which names a source file and line. Pass `:only` or
  `:except` (not both) to select:

      Errata.to_map(error, except: [:env])
      Errata.to_map(error, only: [:code, :message, :retryable])

  The projection reaches aggregate members and a wrapped Errata cause as well, so
  `except: [:env]` removes every `:env` in the structure rather than only the
  outermost one. A cause that is a plain exception rather than an Errata error is
  left alone.

  Keys are validated: a misspelled one raises rather than silently selecting
  nothing. See
  [Errors at a boundary](guides/boundaries.md) for which projection belongs on
  the wire and which belongs in your reporter.
  """
  @spec to_map(error(), keyword()) :: map()
  def to_map(error, opts \\ [])

  def to_map(error, opts) when is_error(error) do
    error
    |> Errata.Errors.to_map()
    |> Errata.Errors.project(opts)
  end

  def to_map(other, _opts) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Rebuilds an error of the given type from its encoded form.

  This is the counterpart to `to_map/1`, for the receiving end of a boundary: a
  service that consumes an error another service serialized, a job runner
  reading a payload, a consumer taking a message off a queue. It accepts the map
  produced by `to_map/1` directly, or the result of decoding that map's JSON
  (string keys are handled as well as atom keys).

      iex> alias MyApp.Orders.OrderNotFound
      iex> encoded = Errata.to_map(OrderNotFound.new(reason: :not_found))
      iex> {:ok, error} = Errata.from_map(OrderNotFound, encoded)
      iex> Errata.reason(error)
      :not_found
      iex> Errata.is_domain_error(error)
      true

  The error type is an argument rather than something read from the encoded
  `error_type` key. That key holds a module name, which is an implementation
  detail Errata deliberately does not treat as an identifier — resolving it
  would mean both trusting a name from the wire and keeping a registry of every
  error type, which is exactly what the structural `is_error/1` guard avoids.

  ## What comes back, and what does not

  A decoded error is a faithful **classification**, not a faithful
  reconstruction:

    * `:reason`, `:message` and `:context` are restored.
    * `:kind`, `http_status/1`, `severity/1` and `retryable?/1` are recomputed
      from the type in *this* application, and the encoded values are ignored.
      The receiver's own definitions win, so an error decodes consistently with
      every locally-created error of the same type even if the sender is running
      an older version.
    * `:env` is always `nil`. It describes a location in the sending process,
      which would be actively misleading attached to an error here.
    * `:cause` is kept as the plain decoded value rather than being rebuilt into
      an error, since doing so would need its module too. `Errata.cause/1`
      returns it; `format_chain/1` still shows it.
    * Context that was redacted on the way out stays redacted — the original
      values are not on the wire, and nothing here pretends otherwise.

  ## Options

    * `:keys` — what the keys of the decoded `:context` map should be. Defaults
      to `:strings`, which is the shape context arrives in from JSON. Pass
      `:existing_atoms` to convert keys that already exist as atoms, which makes
      a context built locally round-trip to the same shape:

          iex> alias MyApp.Orders.OrderNotFound
          iex> encoded = Errata.to_map(OrderNotFound.new(context: %{order_id: 42}))
          iex> {:ok, error} = Errata.from_map(OrderNotFound, encoded, keys: :existing_atoms)
          iex> Errata.context(error)
          %{order_id: 42}

      Conversion is best-effort and recursive: a key with no existing atom is
      left as a string rather than being created, so decoding untrusted input
      cannot exhaust the atom table. The default is `:strings` because `:context`
      holds arbitrary data, and that is where the risk would otherwise live.

      Both modes rewrite the keys, so the decoded shape depends only on this
      option — not on whether you passed JSON-decoded data or a map straight
      from `to_map/1`.

  ## Errors

  Returns `{:error, reason}` rather than raising, since malformed input is an
  expected condition where this is called. Passing something that is not an
  Errata error type is a programming error and still raises `ArgumentError`.

      iex> alias MyApp.Orders.OrderNotFound
      iex> Errata.from_map(OrderNotFound, %{"reason" => "no_such_reason_exists"})
      {:error, {:unknown_reason, "no_such_reason_exists"}}

  A type that declares `:reasons` is decoded by matching against that declared
  set, so no atom is created from external input at all. See `from_map!/3` for
  the raising variant.
  """
  @doc since: "1.7.0"
  @spec from_map(module(), term(), keyword()) :: {:ok, error()} | {:error, term()}
  def from_map(error_type, map, opts \\ []) do
    Errata.Errors.from_map(error_type, map, opts)
  end

  @doc """
  Same as `from_map/3`, but returns the error directly and raises on failure.

      iex> alias MyApp.Orders.OrderNotFound
      iex> encoded = Errata.to_map(OrderNotFound.new(reason: :not_found))
      iex> Errata.from_map!(OrderNotFound, encoded) |> Errata.reason()
      :not_found

  Reach for this when the encoded form comes from somewhere you control — your
  own job queue, a service you deploy alongside this one — and a malformed
  payload means something is broken rather than something a caller sent wrong.
  Use `from_map/3` when the input is foreign and a bad payload is one of the
  outcomes you expect to handle.

  Raises `ArgumentError` on anything `from_map/3` would return `{:error, _}` for.
  """
  @doc since: "1.7.0"
  @spec from_map!(module(), term(), keyword()) :: error()
  def from_map!(error_type, map, opts \\ []) do
    case Errata.Errors.from_map(error_type, map, opts) do
      {:ok, error} ->
        error

      {:error, reason} ->
        raise ArgumentError, Errata.Errors.format_decode_error(error_type, reason)
    end
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

  This delegates to the error module's generated `display_message/1` function,
  which returns the `:message` field unless the type overrides it. Override it to
  compute a user-facing message from the error's `:reason` or `:context`; the
  override applies here and in `to_map/1` (and therefore the JSON encoding).

      iex> alias MyApp.Orders.PaymentDeclined
      iex> error = PaymentDeclined.new(reason: :insufficient_funds)
      iex> Errata.display_message(error)
      "the payment was declined"
      iex> Exception.message(error)
      "the payment was declined: :insufficient_funds"

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec display_message(error()) :: String.t() | nil
  def display_message(error) when is_error(error),
    do: error.__struct__.display_message(error)

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
  Walks the cause chain of `error` and returns the deepest thing in it.

  An error's chain always includes the error itself, so this always returns
  something: for an error with no cause, the deepest thing in the chain *is* that
  error. Use `cause/1` to ask whether an error has a cause at all.

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

  An error with no cause is its own root:

      iex> alias MyApp.Orders.OrderNotFound
      iex> error = OrderNotFound.new(reason: :not_found)
      iex> Errata.root_cause(error) == error
      true

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec root_cause(error()) :: term()
  def root_cause(error) when is_error(error) do
    case cause(error) do
      nil -> error
      value -> if is_error(value), do: root_cause(value), else: value
    end
  end

  def root_cause(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns the deepest Errata error in `error`'s cause chain.

  A cause chain is Errata errors all the way down, optionally ending in one
  foreign value — a bare atom, an `{:error, reason}` tuple, a standard exception.
  `root_cause/1` returns that bottom value whatever it is; this returns the
  deepest thing in the chain that is still an *Errata* error, and so still carries
  a `code`, a `context`, a classification and a `display_message/1`.

  The two differ exactly when the chain bottoms out in a foreign value:

      iex> alias MyApp.Http.RetriesExhausted
      iex> require Errata
      iex> error = Errata.wrap(RetriesExhausted, :econnrefused)
      iex> Errata.root_cause(error)
      :econnrefused
      iex> Errata.root_error(error) == error
      true

  When the chain ends in an Errata error, they are the same value.

  Reach for `root_cause/1` to diagnose *what failed* — `:econnrefused` is the
  answer a developer wants in a log. Reach for this to render, report or classify,
  where a bare atom has nothing on it to use:

      iex> alias MyApp.Http.RetriesExhausted
      iex> require Errata
      iex> Errata.wrap(RetriesExhausted, :econnrefused) |> Errata.root_error() |> Errata.code()
      "RETRIES_EXHAUSTED"

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec root_error(error()) :: error()
  def root_error(error) when is_error(error) do
    case cause(error) do
      deeper when is_error(deeper) -> root_error(deeper)
      _foreign_value_or_nil -> error
    end
  end

  def root_error(other) do
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
  Returns `error`'s `:reason`, or `nil` if it has none.

      iex> alias MyApp.Orders.OrderNotFound
      iex> Errata.reason(OrderNotFound.new(reason: :not_found))
      :not_found

      iex> alias MyApp.Orders.OrderNotFound
      iex> Errata.reason(OrderNotFound.new())
      nil

  Equivalent to reading `error.reason`, and preferable at a boundary that handles
  errors generically: a variable bound by a bare `rescue e ->` has no type the
  compiler can narrow, so `e.reason` there draws an "unknown key" warning — for
  any exception, not just an Errata one. Going through the accessor is a plain
  function call and warns for nothing.

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec reason(error()) :: atom() | nil
  def reason(error) when is_error(error), do: error.reason

  def reason(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns `error`'s `:context`, or `%{}` if it has none.

  Returns an empty map rather than `nil` for an error created without context, so
  calling code can treat the result as a map unconditionally.

      iex> alias MyApp.Orders.OrderNotFound
      iex> Errata.context(OrderNotFound.new(context: %{order_id: 42}))
      %{order_id: 42}

      iex> alias MyApp.Orders.OrderNotFound
      iex> Errata.context(OrderNotFound.new())
      %{}

  This is the error's **unredacted** context — the values as captured. Redaction
  applies to what Errata serializes and emits (see `Errata.Redaction`); an error
  in your own hands keeps the real values for debugging, and this accessor
  reflects that.

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec context(error()) :: map()
  def context(error) when is_error(error), do: error.context || %{}

  def context(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns `error`'s kind: `:domain`, `:infrastructure`, or `:general`.

      iex> alias MyApp.Orders.OrderNotFound
      iex> Errata.kind(OrderNotFound.new())
      :domain

  For branching on the kind, the `is_domain_error/1` and
  `is_infrastructure_error/1` guards are usually the better tool, since they work
  in a guard clause. This is for the cases that want the value itself — logging
  it, or tagging a metric.

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec kind(error()) :: error_kind()
  def kind(error) when is_error(error), do: error.kind

  def kind(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
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
  classification that _your_ retry logic, or a library such as
  [`ExternalService`](https://hexdocs.pm/external_service) (which already uses
  Errata for its own errors), can branch on without knowing the error's specific
  type:

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
  Returns the member errors of an aggregate, or `[]` for an ordinary error.

  Returning `[]` rather than raising for a non-aggregate means calling code can
  treat every error uniformly — an ordinary error is simply an error with no
  members — instead of branching on `aggregate?/1` first:

      for member <- Errata.errors(error) do
        Logger.warning(Exception.message(member))
      end

  See `Errata.Aggregate` for how aggregates merge severity, retryability, and
  HTTP status across their members.

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec errors(error()) :: [error()]
  def errors(%{errors: errors} = error) when is_error(error) and is_list(errors), do: errors
  def errors(error) when is_error(error), do: []

  def errors(other) do
    raise ArgumentError, "expected an Errata error, got: #{inspect(other)}"
  end

  @doc """
  Returns `true` if `error` is an aggregate — a type declared with
  `aggregate: true`, which can hold member errors.

  Note this is about the *type*, not the contents: an aggregate with no members
  is still an aggregate.

  Raises an `ArgumentError` if `error` is not an Errata error.
  """
  @spec aggregate?(error()) :: boolean()
  def aggregate?(error) when is_error(error), do: Errata.Errors.aggregate_type?(error)

  def aggregate?(other) do
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
    * `:http_status` — the error's HTTP status (see `http_status/1`)
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
      `:error_type`, `:code`, `:severity`, `:retryable`, `:http_status`, and
      `:context` as top-level keys (simple values suitable for use as metric
      tags)

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
      error: redacted_error(error, context),
      kind: error.kind,
      reason: error.reason,
      error_type: error.__struct__,
      code: code(error),
      severity: severity(error),
      retryable: retryable?(error),
      http_status: http_status(error),
      context: context,
      cause: Errata.Errors.cause_map(error.cause),
      caused_by: caused_by_metadata(error)
    }
  end

  # An aggregate's members carry contexts of their own, each with its own
  # redaction rules. Redacting only the container's context would leave every
  # member's raw context reachable through `metadata.error.errors` — the same
  # hole the struct-level redaction above exists to close, one level down.
  defp redacted_error(%{errors: errors} = error, context) when is_list(errors) do
    members = Enum.map(errors, &redacted_error(&1, Errata.Errors.redacted_context(&1)))
    %{error | context: context, errors: members}
  end

  defp redacted_error(error, context), do: %{error | context: context}

  defp log_metadata(error) do
    [
      error_type: error.__struct__,
      kind: error.kind,
      reason: error.reason,
      code: code(error),
      severity: severity(error),
      retryable: retryable?(error),
      http_status: http_status(error),
      context: Errata.Errors.redacted_context(error),
      cause: Errata.Errors.cause_map(error.cause),
      caused_by: caused_by_metadata(error),
      env: env_metadata(error.env)
    ]
  end

  # The cause reaches metadata twice on purpose, for two kinds of consumer. The
  # `cause` map is the same shape `to_map/1` emits, so a JSON log formatter or a
  # telemetry handler gets the whole chain with each level's own classification
  # and redaction. `caused_by` is a single greppable line for a console reader or
  # a log field, rendered the way `format_chain/1` renders that element but
  # without its stacktrace.
  #
  # Named `caused_by` rather than `root_cause` deliberately: this is `nil` for an
  # error with no cause, where `Errata.root_cause/1` returns the error itself. A
  # key that contradicted the function of the same name would be worse than a
  # slightly different word.
  defp caused_by_metadata(%{cause: nil}), do: nil

  defp caused_by_metadata(error) do
    case root_cause(error) do
      ^error -> nil
      value -> format_cause_value(value)
    end
  end

  # `Exception.format_banner/2` renders a plain term as "** (ErlangError) Erlang
  # error: :econnrefused", which buries the useful part. Inspect those instead.
  defp format_cause_value(value) when is_exception(value),
    do: Exception.format_banner(:error, value)

  defp format_cause_value(value), do: inspect(value)

  defp env_metadata(%Errata.Env{module: module, function: function, file: file, line: line}) do
    %{module: module, function: function, file: file, line: line}
  end

  defp env_metadata(_), do: %{}

  defp maybe_log(_error, level) when level in [false, nil], do: :ok
  defp maybe_log(error, true), do: log(error, severity(error))
  defp maybe_log(error, level) when is_atom(level), do: log(error, level)
end
