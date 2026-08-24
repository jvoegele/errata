defmodule Errata.Errors do
  @moduledoc false

  # Import only the guard we use; a bare `import Errata` would also pull in
  # `Errata.to_map/1`, which conflicts with this module's local `to_map/1`.
  import Errata, only: [is_error: 1]

  # The only keys callers are allowed to set when creating an error. Internal
  # fields (`:kind`, `:env`, `:__errata_error__`) are managed by Errata itself.
  @allowed_param_keys [:message, :reason, :context, :cause]

  # The complete set of options accepted by `use Errata.Error` and its per-kind
  # variants, and the single source of truth for that surface. `define/3` rejects
  # any key not listed here, so a misspelled option is a compile error rather
  # than a permanently and invisibly misconfigured error type.
  #
  # `:kind` is deliberately absent: it is meaningful only via `use Errata.Error`,
  # which reads and strips it before calling `define/3`.
  @type_opts [
    :default_reason,
    :default_message,
    :reasons,
    :http_status,
    :code,
    :severity,
    :retryable,
    :redact,
    :aggregate
  ]

  # The closed set of error kinds. Closed deliberately: `Errata.is_error/1` and
  # its siblings are structural guards over these three, and a fourth would break
  # that. See issue #38 for the decision.
  @kinds [:general, :domain, :infrastructure]

  # Valid values for the `:severity` option, most to least severe. This is the
  # set of `t:Logger.level/0` values, listed here rather than read from
  # `Logger.levels/0`, which does not exist on all supported Elixir versions.
  # The deprecated `:warn` alias is intentionally excluded.
  @severity_levels [
    :emergency,
    :alert,
    :critical,
    :error,
    :warning,
    :notice,
    :info,
    :debug
  ]

  @doc false
  @spec create(module() | struct(), Errata.Error.params()) :: Errata.Error.t()
  def create(error_type, params) do
    error_type
    |> struct(validate_params!(params, error_type))
    |> normalize_cause()
    |> validate_reason!()
    |> validate_errors!()
  end

  @doc false
  @spec create(module() | struct(), Errata.Error.params(), Macro.Env.t(), Exception.stacktrace()) ::
          Errata.error()
  def create(error_type, params, %Macro.Env{} = env, stacktrace) do
    error =
      error_type
      |> struct(validate_params!(params, error_type))
      |> normalize_cause()
      |> validate_reason!()
      |> validate_errors!()

    %{error | env: Errata.Env.new(env, stacktrace)}
  end

  @doc false
  @spec wrap(module(), term(), Errata.Error.params(), Macro.Env.t(), Exception.stacktrace()) ::
          Errata.error()
  def wrap(error_type, cause, opts, %Macro.Env{} = env, stacktrace) do
    {cause_opts, params} = opts |> Enum.to_list() |> Keyword.split([:kind, :stacktrace])
    params = Keyword.put(params, :cause, Errata.Cause.new(cause, cause_opts))

    create(error_type, params, env, stacktrace)
  end

  @doc false
  @spec normalize(module(), term(), keyword()) :: Errata.error()
  def normalize(error_type, value, opts) do
    validate_fallback!(error_type)

    {cause_opts, params} = opts |> Enum.to_list() |> Keyword.split([:kind, :stacktrace])

    params
    |> Keyword.put(:cause, Errata.Cause.new(value, cause_opts))
    |> put_derived_reason(error_type, value)
    |> then(&create(error_type, &1))
  end

  # `Errata.to_error(:timeout)` producing `reason: :timeout` is the obviously
  # useful behaviour, but a fallback type that declares `:reasons` would reject
  # an undeclared atom — turning a call whose whole purpose is to stop unknown
  # values escaping into a raise. Derive a reason only when the type accepts it.
  defp put_derived_reason(params, error_type, value)
       when is_atom(value) and not is_nil(value) and not is_boolean(value) do
    if Keyword.has_key?(params, :reason) or not valid_reason?(error_type, value),
      do: params,
      else: Keyword.put(params, :reason, value)
  end

  defp put_derived_reason(params, _error_type, _value), do: params

  defp valid_reason?(error_type, reason) do
    case error_type.__errata_valid_reasons__() do
      nil -> true
      valid -> reason in valid
    end
  end

  # A misspelled or non-Errata `:fallback` would otherwise fail deep inside
  # `struct/2` with an UndefinedFunctionError for `__struct__/1`.
  defp validate_fallback!(error_type), do: validate_error_type!(error_type, ":fallback")

  defp errata_error_type?(error_type) do
    is_atom(error_type) and Code.ensure_loaded?(error_type) and
      function_exported?(error_type, :__errata_valid_reasons__, 0)
  end

  defp validate_error_type!(error_type, label) do
    if errata_error_type?(error_type) do
      :ok
    else
      raise ArgumentError,
            "#{label} must be an Errata error type (a module that uses Errata.Error, " <>
              "Errata.DomainError, or Errata.InfrastructureError), got: #{inspect(error_type)}"
    end
  end

  @doc false
  @spec from_map(module(), term(), keyword()) :: {:ok, Errata.error()} | {:error, term()}
  def from_map(error_type, map, opts) do
    # A bad module is a programming error and raises; bad *data* is the expected
    # condition at a boundary and comes back as `{:error, _}`.
    validate_error_type!(error_type, "the error type")

    cond do
      not is_map(map) ->
        {:error, {:invalid_map, map}}

      # An aggregate's members each carry their own `error_type` as a string, and
      # resolving those to modules is precisely the registry that taking the type
      # as an argument exists to avoid. Refuse rather than silently drop members.
      aggregate_type?(error_type) ->
        {:error, {:unsupported, :aggregate}}

      true ->
        decode(error_type, map, opts)
    end
  end

  defp decode(error_type, map, opts) do
    key_mode = Keyword.get(opts, :keys, :strings)

    with :ok <- validate_key_mode(key_mode),
         {:ok, reason} <- decode_reason(error_type, field(map, :reason)) do
      params =
        [
          message: field(map, :message),
          reason: reason,
          context: decode_context(field(map, :context), key_mode),
          cause: field(map, :cause)
        ]
        # Dropping nils lets the type's own defaults (`:default_message`,
        # `:default_reason`) apply, rather than pinning the field to nil.
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, create(error_type, params)}
    end
  end

  defp validate_key_mode(mode) when mode in [:strings, :existing_atoms], do: :ok
  defp validate_key_mode(mode), do: {:error, {:invalid_option, {:keys, mode}}}

  # The encoded form may have atom keys (straight from `to_map/1`) or string keys
  # (having been through JSON); accept either.
  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp decode_reason(_error_type, nil), do: {:ok, nil}

  defp decode_reason(error_type, value) when is_binary(value) or is_atom(value) do
    case error_type.__errata_valid_reasons__() do
      # A declared `:reasons` set makes this a lookup against known atoms, so no
      # atom is created from external input at all — the safest form of this.
      valid when is_list(valid) -> declared_reason(valid, value)
      nil -> existing_reason(value)
    end
  end

  defp decode_reason(_error_type, value), do: {:error, {:invalid_reason, value}}

  defp declared_reason(valid, value) do
    case Enum.find(valid, &(to_string(&1) == to_string(value))) do
      nil -> {:error, {:unknown_reason, value}}
      reason -> {:ok, reason}
    end
  end

  defp existing_reason(value) when is_atom(value), do: {:ok, value}

  defp existing_reason(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, {:unknown_reason, value}}
  end

  defp decode_context(nil, _key_mode), do: nil

  # Both modes rewrite keys rather than passing them through, so the decoded
  # shape depends only on the option — not on whether the caller happened to
  # hand us JSON-decoded string keys or a map straight from `to_map/1`.
  defp decode_context(context, key_mode) when is_map(context),
    do: convert_keys(context, key_mode)

  defp decode_context(context, _key_mode), do: context

  defp convert_keys(%_struct{} = value, _mode), do: value

  defp convert_keys(map, mode) when is_map(map) do
    Map.new(map, fn {key, value} -> {convert_key(key, mode), convert_keys(value, mode)} end)
  end

  defp convert_keys(list, mode) when is_list(list), do: Enum.map(list, &convert_keys(&1, mode))
  defp convert_keys(value, _mode), do: value

  defp convert_key(key, :strings) when is_binary(key), do: key
  defp convert_key(key, :strings), do: to_string(key)

  # Best-effort by design: a key that has no existing atom stays a string rather
  # than failing the decode or minting one, so decoding untrusted input cannot
  # exhaust the atom table.
  defp convert_key(key, :existing_atoms) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp convert_key(key, :existing_atoms), do: key

  @doc false
  @spec format_decode_error(module(), term()) :: String.t()
  def format_decode_error(error_type, reason) do
    "could not decode #{inspect(error_type)}: " <> decode_error_detail(reason)
  end

  defp decode_error_detail({:invalid_map, value}),
    do: "expected a map, got: #{inspect(value)}"

  defp decode_error_detail({:unsupported, :aggregate}),
    do:
      "aggregate error types cannot be decoded, because each member's type would " <>
        "have to be resolved from its name. Decode the members individually with " <>
        "their own types and rebuild the aggregate with new/1."

  defp decode_error_detail({:unknown_reason, value}),
    do:
      "#{inspect(value)} is not a known reason. Declare it in the type's :reasons " <>
        "option, or check that the sending and receiving versions agree."

  defp decode_error_detail({:invalid_reason, value}),
    do: "expected the reason to be a string or an atom, got: #{inspect(value)}"

  defp decode_error_detail({:invalid_option, {:keys, mode}}),
    do: "invalid :keys option #{inspect(mode)}, expected :strings or :existing_atoms"

  defp decode_error_detail(other), do: inspect(other)

  # The `:cause` param may be given as a raw value (e.g. via `new(cause: ...)`);
  # normalize it into an `Errata.Cause` struct. A `nil` cause means "no cause".
  defp normalize_cause(%{cause: nil} = error), do: error
  defp normalize_cause(%{cause: %Errata.Cause{}} = error), do: error
  defp normalize_cause(%{cause: value} = error), do: %{error | cause: Errata.Cause.new(value)}
  defp normalize_cause(error), do: error

  # Reject unknown/misspelled param keys instead of silently dropping them
  # (which `struct/2` would do). Returns the params unchanged when valid.
  #
  # `:errors` is allowed only for aggregate types. Accepting it everywhere would
  # silently drop the members on a type that has no `:errors` field, which is
  # exactly the typo this check exists to catch.
  defp validate_params!(params, error_type) do
    allowed =
      if aggregate_type?(error_type),
        do: [:errors | @allowed_param_keys],
        else: @allowed_param_keys

    invalid =
      params
      |> Enum.map(fn {key, _value} -> key end)
      |> Enum.reject(&(&1 in allowed))

    case invalid do
      [] ->
        params

      keys ->
        raise ArgumentError,
              "invalid param key(s) for an Errata error: #{inspect(keys)}. " <>
                "Allowed keys are #{inspect(allowed)}."
    end
  end

  # An aggregate's members are validated at construction rather than at
  # serialization, so a bad member is reported where it was introduced.
  defp validate_errors!(%mod{errors: errors} = error),
    do: %{error | errors: Errata.Aggregate.validate_members!(errors, mod)}

  defp validate_errors!(error), do: error

  @doc false
  @spec aggregate_type?(module() | struct()) :: boolean()
  def aggregate_type?(%mod{}), do: aggregate_type?(mod)

  def aggregate_type?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__errata_aggregate__, 0) and
      module.__errata_aggregate__()
  end

  # When an error type declares a closed set of `:reasons`, reject any non-nil
  # reason outside that set. A `nil` (unspecified) reason is always allowed, and
  # types that do not declare `:reasons` are unrestricted (their generated
  # accessor returns `nil`). Returns the error unchanged when valid.
  defp validate_reason!(%mod{reason: reason} = error) do
    case mod.__errata_valid_reasons__() do
      nil ->
        error

      _valid when is_nil(reason) ->
        error

      valid ->
        if reason in valid do
          error
        else
          raise ArgumentError,
                "invalid reason #{inspect(reason)} for #{inspect(mod)}. " <>
                  "Declared reasons are #{inspect(valid)}."
        end
    end
  end

  @doc false
  def to_map(%error_type{} = error) when is_error(error) do
    %{
      # `inspect/1` renders the module as "MyApp.Foo" instead of the raw atom
      # form "Elixir.MyApp.Foo" that would otherwise leak into JSON output.
      error_type: inspect(error_type),
      code: error_type.code(error),
      reason: error.reason,
      message: error_type.display_message(error),
      # The classification travels with the error so that a consumer on the far
      # side of the wire can act on it without holding the error's module — or
      # being written in Elixir. `kind` is a fixed field; the rest dispatch
      # through the overridable functions, so an override is honored here too.
      kind: error.kind,
      http_status: error_type.http_status(error),
      severity: error_type.severity(error),
      retryable: error_type.retryable?(error),
      cause: cause_map(error.cause),
      env: Errata.Env.to_map(error.env),
      context: context_map(error)
    }
    |> put_errors_map(error)
  end

  # Members serialize through the same `to_map/1`, so each keeps its own type,
  # code, and — importantly — its own redaction rules.
  defp put_errors_map(map, %{errors: errors}) when is_list(errors),
    do: Map.put(map, :errors, Enum.map(errors, &to_map/1))

  defp put_errors_map(map, _error), do: map

  # Render the wrapped cause for serialization. Errata errors recurse into their
  # full structured map; standard exceptions are rendered by type and message;
  # any other term is kept if JSON-encodable and otherwise `inspect`'d. The
  # cause's stacktrace is intentionally omitted, mirroring `Errata.Env.to_map/1`.
  defp cause_map(nil), do: nil
  defp cause_map(%Errata.Cause{value: value}), do: cause_value_map(value)

  defp cause_value_map(value) when is_error(value), do: to_map(value)

  defp cause_value_map(%mod{} = value) when is_exception(value),
    do: %{error_type: inspect(mod), message: Exception.message(value)}

  defp cause_value_map(value) do
    if Errata.JSON.encodable?(value), do: value, else: inspect(value)
  end

  @doc false
  @spec format_message(Errata.Error.t()) :: String.t()
  def format_message(error)

  def format_message(%{errors: errors} = error) when is_list(errors) do
    error
    |> Map.delete(:errors)
    |> base_message()
    |> Errata.Aggregate.format_message(errors)
  end

  def format_message(error), do: base_message(error)

  defp base_message(%{message: nil, reason: nil}), do: ""
  defp base_message(%{message: nil, reason: reason}) when is_atom(reason), do: inspect(reason)
  defp base_message(%{message: message, reason: nil}) when is_binary(message), do: message

  defp base_message(%{message: message, reason: reason})
       when is_binary(message) and is_atom(reason) do
    "#{message}: #{inspect(reason)}"
  end

  # Encode an error to JSON via the Jason backend. Only compiled when Jason is
  # available; the generated `Jason.Encoder` impl (and therefore this function)
  # is only emitted in that case, so the reference to `Jason.Encode` never
  # produces an "undefined module" warning on Jason-less builds.
  if Code.ensure_loaded?(Jason) do
    @doc false
    def to_json(error, opts) do
      error
      |> to_map()
      |> Jason.Encode.map(opts)
    end
  end

  @doc false
  def define(kind, module_name, opts \\ [])
      when kind in @kinds and is_atom(module_name) do
    validate_opts!(module_name, opts)

    reasons = Keyword.get(opts, :reasons)
    validate_reasons_opt!(module_name, reasons, Keyword.get(opts, :default_reason))
    validate_aggregate_opt!(module_name, opts)

    aggregate_def = define_aggregate_reflection(opts)
    attribute_defs = define_attributes(module_name)
    type_def = define_type(kind)
    reasons_def = define_reasons(reasons)
    http_status_def = define_http_status(kind, module_name, opts)
    code_def = define_code(module_name, opts)
    severity_def = define_severity(module_name, opts)
    retryable_def = define_retryable(kind, module_name, opts)
    redact_def = define_redact_context(module_name, opts)
    display_message_def = define_display_message()
    exception_def = define_exception(kind, opts)
    errata_error_impl = define_errata_error_callbacks()
    string_chars_impl = define_string_chars_impl(module_name)
    json_encoder_impls = define_json_encoder_impls(module_name)

    quote do
      unquote(aggregate_def)
      unquote(attribute_defs)
      unquote(type_def)
      unquote(reasons_def)
      unquote(http_status_def)
      unquote(code_def)
      unquote(severity_def)
      unquote(retryable_def)
      unquote(redact_def)
      unquote(display_message_def)
      unquote(exception_def)
      unquote(errata_error_impl)
      unquote(string_chars_impl)
      unquote(json_encoder_impls)
    end
  end

  # Generate the overridable `http_status/1` function. It defaults off the error's
  # kind (or the `:http_status` option) and is marked `defoverridable` so callers
  # can override it to compute a status from the error's `:reason` or `:context`.
  # It is intentionally a plain function rather than a behaviour callback, so that
  # user overrides do not trip Elixir's `@impl` consistency warnings.
  defp define_http_status(kind, module_name, opts) do
    status = http_status_value!(kind, module_name, opts)
    aggregate? = aggregate?(opts)

    doc = """
    Returns the HTTP status code associated with this error (`#{status}` by default).

    The default is derived from the error's kind, or set via the `:http_status`
    option. Override this function to compute a status from the error's `:reason`
    or `:context`. See also `Errata.http_status/1`.
    """

    quote do
      @doc unquote(doc)
      @spec http_status(Errata.error()) :: non_neg_integer()
      def http_status(error)

      if unquote(aggregate?) do
        def http_status(%{errors: errors}),
          do: Errata.Aggregate.http_status(errors, unquote(status))
      end

      def http_status(_error), do: unquote(status)

      defoverridable http_status: 1
    end
  end

  defp http_status_value!(kind, module_name, opts) do
    case Keyword.get(opts, :http_status) do
      nil ->
        default_http_status(kind)

      status when is_integer(status) and status in 100..599 ->
        status

      other ->
        raise ArgumentError,
              ":http_status for #{inspect(module_name)} must be an integer HTTP status code " <>
                "(100..599), got: #{inspect(other)}"
    end
  end

  defp default_http_status(:domain), do: 422
  defp default_http_status(:infrastructure), do: 503
  defp default_http_status(:general), do: 500

  # Generate the overridable `code/1` function. Unlike the other classifications,
  # there is no sensible default: a code is a contract with external consumers,
  # so it exists only where one was deliberately declared. Deriving it from the
  # module name would reintroduce exactly the coupling the option exists to break.
  defp define_code(module_name, opts) do
    code = code_value!(module_name, opts)

    doc =
      case code do
        nil ->
          """
          Returns the stable external code for this error, or `nil` if it has none.

          No code is set for this error type. Set one with the `:code` option, or
          override this function to derive a code from the error's `:reason` or
          `:context`. See also `Errata.code/1`.
          """

        code ->
          """
          Returns the stable external code for this error (`#{inspect(code)}`).

          The code is independent of this module's name, so it remains a valid
          contract with external consumers even if the module is renamed or moved.
          See also `Errata.code/1`.
          """
      end

    quote do
      @doc unquote(doc)
      @spec code(Errata.error()) :: String.t() | nil
      def code(error)
      def code(_error), do: unquote(code)

      defoverridable code: 1
    end
  end

  defp code_value!(module_name, opts) do
    case Keyword.get(opts, :code) do
      nil ->
        nil

      code when is_binary(code) and code != "" ->
        code

      other ->
        raise ArgumentError,
              ":code for #{inspect(module_name)} must be a non-empty string, got: #{inspect(other)}"
    end
  end

  # Generate the overridable `severity/1` function. Unlike `http_status/1`, the
  # default does not vary by kind: every error type is `:error` unless it says
  # otherwise, so that adding severity does not silently change the level at
  # which existing errors are logged.
  defp define_severity(module_name, opts) do
    severity = severity_value!(module_name, opts)
    aggregate? = aggregate?(opts)

    doc = """
    Returns the severity of this error (`#{inspect(severity)}` by default).

    The severity is a `t:Logger.level/0` and is the level at which `Errata.log/2`
    logs the error when no level is given explicitly. Set it with the `:severity`
    option, or override this function to compute a severity from the error's
    `:reason` or `:context`. See also `Errata.severity/1`.
    """

    quote do
      @doc unquote(doc)
      @spec severity(Errata.error()) :: Logger.level()
      def severity(error)

      if unquote(aggregate?) do
        def severity(%{errors: errors}), do: Errata.Aggregate.severity(errors, unquote(severity))
      end

      def severity(_error), do: unquote(severity)

      defoverridable severity: 1
    end
  end

  defp severity_value!(module_name, opts) do
    case Keyword.get(opts, :severity) do
      nil ->
        :error

      severity when severity in @severity_levels ->
        severity

      other ->
        raise ArgumentError,
              ":severity for #{inspect(module_name)} must be one of the Logger levels " <>
                "#{inspect(@severity_levels)}, got: #{inspect(other)}"
    end
  end

  # Generate the overridable `display_message/1` function. Like the classification
  # functions above it is a plain, overridable function that `Errata.display_message/1`
  # and `to_map/1` dispatch through, so a type can compute a user-facing message from
  # its `:reason` or `:context` and have that reach every place a display message is
  # read. The default returns the `:message` field unchanged.
  defp define_display_message do
    doc = """
    Returns the user-facing _display message_ for this error (the `:message` field by default).

    This is distinct from `Exception.message/1`, which also includes the error's `:reason` and is
    aimed at developers. Override this function to compute a message from the error's `:reason` or
    `:context`:

        def display_message(%{context: %{order_id: id}}), do: "order \#{id} does not exist"
        def display_message(error), do: error.message

    `Errata.display_message/1` and `Errata.to_map/1` both dispatch through this function, so an
    override applies to the JSON encoding and to anything rendering the error for a user. See also
    `Errata.display_message/1`.
    """

    quote do
      @doc unquote(doc)
      @spec display_message(Errata.error()) :: String.t() | nil
      def display_message(error)
      def display_message(%{message: message}), do: message

      defoverridable display_message: 1
    end
  end

  # Generate the overridable `redact_context/1` function. Like `http_status/1` and
  # friends it is a plain function rather than a behaviour callback, so overriding
  # it does not trip Elixir's `@impl` consistency warnings.
  defp define_redact_context(module_name, opts) do
    keys = redact_keys!(module_name, opts)

    declared =
      case keys do
        [] -> "no keys declared"
        keys -> "#{inspect(keys)} by default"
      end

    doc = """
    Returns this error's `:context` with sensitive values redacted (#{declared}).

    Called wherever Errata serializes the context — `to_map/1` and the JSON
    encoding, `Errata.log/2` metadata, and `Errata.report/2` telemetry metadata.
    The error struct itself is left alone, so the real values remain available
    locally for debugging.

    Declared keys are redacted recursively and match whether written as atoms or
    binaries. Set them with the `:redact` option, add a global floor with
    `config :errata, redact: [...]`, or override this function for full control.
    See `Errata.Redaction`.
    """

    quote do
      @doc unquote(doc)
      @spec redact_context(Errata.error()) :: map()
      def redact_context(error)

      def redact_context(%{context: context}) do
        Errata.Redaction.redact(
          context || %{},
          unquote(keys) ++ Errata.Redaction.global_keys()
        )
      end

      defoverridable redact_context: 1
    end
  end

  defp redact_keys!(module_name, opts) do
    case Keyword.get(opts, :redact, []) do
      keys when is_list(keys) ->
        Enum.each(keys, fn
          key when is_atom(key) or is_binary(key) ->
            :ok

          other ->
            raise ArgumentError,
                  ":redact for #{inspect(module_name)} must be a list of atoms or strings, " <>
                    "got a list containing: #{inspect(other)}"
        end)

        keys

      other ->
        raise ArgumentError,
              ":redact for #{inspect(module_name)} must be a list of atoms or strings, " <>
                "got: #{inspect(other)}"
    end
  end

  # Generate the overridable `retryable?/1` function. The default is derived from
  # the error's kind: infrastructure failures (timeouts, connection blips) are
  # usually transient, while domain errors are not.
  defp define_retryable(kind, module_name, opts) do
    retryable = retryable_value!(kind, module_name, opts)
    aggregate? = aggregate?(opts)

    doc = """
    Returns whether this error is considered retryable (`#{inspect(retryable)}` by default).

    The default is derived from the error's kind — `:infrastructure` errors are
    retryable, `:domain` and `:general` errors are not — or set via the
    `:retryable` option. Override this function to decide from the error's
    `:reason` or `:context`. See also `Errata.retryable?/1`.
    """

    quote do
      @doc unquote(doc)
      @spec retryable?(Errata.error()) :: boolean()
      def retryable?(error)

      if unquote(aggregate?) do
        def retryable?(%{errors: errors}),
          do: Errata.Aggregate.retryable?(errors, unquote(retryable))
      end

      def retryable?(_error), do: unquote(retryable)

      defoverridable retryable?: 1
    end
  end

  defp retryable_value!(kind, module_name, opts) do
    case Keyword.get(opts, :retryable) do
      nil ->
        default_retryable(kind)

      retryable when is_boolean(retryable) ->
        retryable

      other ->
        raise ArgumentError,
              ":retryable for #{inspect(module_name)} must be a boolean, got: #{inspect(other)}"
    end
  end

  defp default_retryable(:infrastructure), do: true
  defp default_retryable(_kind), do: false

  # Validate the `:reasons` option at the `use` site (compile time). When given,
  # it must be a non-empty list of atoms, and any `:default_reason` must be one
  # of the declared reasons.
  @doc false
  # Validates the user-supplied `:kind` value. Lives here with the other option
  # validators, but is called from `Errata.Error.__using__/1`, which is the only
  # entry point that lets a user choose the kind at all.
  def validate_kind_opt!(_module_name, kind) when kind in @kinds, do: :ok

  def validate_kind_opt!(module_name, kind) do
    raise ArgumentError,
          ":kind for #{inspect(module_name)} must be one of #{inspect(@kinds)}, " <>
            "got: #{inspect(kind)}"
  end

  defp validate_opts!(module_name, opts) do
    case Keyword.keys(opts) -- @type_opts do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "invalid option(s) for #{inspect(module_name)}: #{inspect(Enum.uniq(unknown))}. " <>
                "Valid options are #{inspect(@type_opts)}." <> kind_opt_hint(unknown)
    end
  end

  # `:kind` is a real option, just not on every entry point, so say which one it
  # belongs to rather than leaving the reader to infer it from its absence.
  defp kind_opt_hint(unknown) do
    if :kind in unknown do
      " The :kind option is only available via `use Errata.Error` — " <>
        "Errata.DomainError and Errata.InfrastructureError set the kind themselves."
    else
      ""
    end
  end

  defp validate_reasons_opt!(_module, nil, _default_reason), do: :ok

  defp validate_reasons_opt!(module, reasons, default_reason) do
    unless is_list(reasons) and reasons != [] and Enum.all?(reasons, &is_atom/1) do
      raise ArgumentError,
            ":reasons for #{inspect(module)} must be a non-empty list of atoms, " <>
              "got: #{inspect(reasons)}"
    end

    if not is_nil(default_reason) and default_reason not in reasons do
      raise ArgumentError,
            ":default_reason #{inspect(default_reason)} for #{inspect(module)} is not one of " <>
              "the declared :reasons #{inspect(reasons)}"
    end

    :ok
  end

  # Generate the per-module reasons accessor used by `validate_reason!/1`, plus a
  # `reason` type enumerating the declared reasons. Modules without declared
  # reasons return `nil` (unrestricted) and get no `reason` type.
  defp define_reasons(nil) do
    quote do
      @doc false
      def __errata_valid_reasons__, do: nil
    end
  end

  defp define_reasons(reasons) when is_list(reasons) do
    [first | rest] = reasons
    reason_type = Enum.reduce(rest, first, fn r, acc -> quote(do: unquote(acc) | unquote(r)) end)

    quote do
      @typedoc """
      The set of reasons declared as valid for this error type.
      """
      @type reason :: unquote(reason_type)

      @doc false
      def __errata_valid_reasons__, do: unquote(reasons)
    end
  end

  @doc false
  defp context_map(error) do
    # Redact first, so a sensitive value is replaced before the JSON-encodability
    # pass can `inspect/1` it into a string and smuggle it through.
    error
    |> redacted_context()
    |> Enum.reduce(Map.new(), fn {key, value}, acc ->
      # Make sure that all of the data in the `context` map is JSON-encodable
      if Errata.JSON.encodable?(value) do
        Map.put(acc, key, value)
      else
        Map.put(acc, key, inspect(value))
      end
    end)
  end

  @doc """
  Returns `error`'s context with sensitive values redacted, by dispatching to the
  error module's `redact_context/1`.

  Every seam that serializes context goes through here — `to_map/1` and the JSON
  encoding in this module, and `Errata.log/2` / `Errata.report/2` metadata — so
  that a custom `redact_context/1` override applies to all of them and not just
  the one the author happened to be looking at.

  Falls back to the raw context for a struct that satisfies `Errata.is_error/1`
  structurally but was not generated by `use Errata.Error` and so has no
  `redact_context/1`.
  """
  @spec redacted_context(Errata.error()) :: map()
  def redacted_context(%error_type{context: context} = error) do
    if Code.ensure_loaded?(error_type) and function_exported?(error_type, :redact_context, 1) do
      error_type.redact_context(error)
    else
      context || %{}
    end
  end

  def redacted_context(_error), do: %{}

  # `:aggregate` opts plumbing. Reflected as `__errata_aggregate__/0` so the
  # runtime helpers can ask a type whether it aggregates without the caller
  # having to say so.
  defp aggregate?(opts), do: Keyword.get(opts, :aggregate, false) == true

  defp validate_aggregate_opt!(module_name, opts) do
    case Keyword.get(opts, :aggregate, false) do
      value when is_boolean(value) ->
        :ok

      other ->
        raise ArgumentError,
              ":aggregate for #{inspect(module_name)} must be true or false, got: #{inspect(other)}"
    end
  end

  defp define_aggregate_reflection(opts) do
    aggregate? = aggregate?(opts)

    quote do
      @doc false
      def __errata_aggregate__, do: unquote(aggregate?)
    end
  end

  defp define_attributes(module_name) do
    quote do
      @__errata_error_module__ unquote(module_name)
      @behaviour Errata.Error
    end
  end

  defp define_type(:general) do
    quote do
      @type t :: Errata.error()
    end
  end

  defp define_type(:domain) do
    quote do
      @type t :: Errata.domain_error()
    end
  end

  defp define_type(:infrastructure) do
    quote do
      @type t :: Errata.infrastructure_error()
    end
  end

  defp define_exception(kind, opts) do
    default_message = Keyword.get(opts, :default_message)
    default_reason = Keyword.get(opts, :default_reason)

    # The `:errors` field exists only on aggregate types. Adding it everywhere
    # would put an always-empty list on every error struct and make `is_error/1`
    # ambiguous about what an aggregate is.
    aggregate_fields = if aggregate?(opts), do: [errors: []], else: []

    quote do
      defexception [
                     __errata_error__: true,
                     kind: unquote(kind),
                     message: unquote(default_message),
                     reason: unquote(default_reason),
                     context: nil,
                     cause: nil,
                     env: nil
                   ] ++ unquote(aggregate_fields)

      @impl Exception
      def exception(params) do
        Errata.Errors.create(@__errata_error_module__, params)
      end

      @impl Exception
      def message(%{} = errata_error) do
        Errata.Errors.format_message(errata_error)
      end

      defoverridable Exception
    end
  end

  defp define_errata_error_callbacks do
    quote do
      @impl Errata.Error
      def new(params \\ %{}), do: Errata.Errors.create(@__errata_error_module__, params)

      @impl Errata.Error
      defmacro create do
        __module__ = @__errata_error_module__

        quote do
          {:current_stacktrace, [_process_info_call | stacktrace]} =
            Process.info(self(), :current_stacktrace)

          Errata.Errors.create(unquote(__module__), %{}, __ENV__, stacktrace)
        end
      end

      @impl Errata.Error
      defmacro create(params) do
        __module__ = @__errata_error_module__

        quote do
          {:current_stacktrace, [_process_info_call | stacktrace]} =
            Process.info(self(), :current_stacktrace)

          Errata.Errors.create(unquote(__module__), unquote(params), __ENV__, stacktrace)
        end
      end

      @impl Errata.Error
      defmacro wrap(cause) do
        __module__ = @__errata_error_module__

        quote do
          {:current_stacktrace, [_process_info_call | stacktrace]} =
            Process.info(self(), :current_stacktrace)

          Errata.Errors.wrap(unquote(__module__), unquote(cause), [], __ENV__, stacktrace)
        end
      end

      @impl Errata.Error
      defmacro wrap(cause, opts) do
        __module__ = @__errata_error_module__

        quote do
          {:current_stacktrace, [_process_info_call | stacktrace]} =
            Process.info(self(), :current_stacktrace)

          Errata.Errors.wrap(
            unquote(__module__),
            unquote(cause),
            unquote(opts),
            __ENV__,
            stacktrace
          )
        end
      end

      @impl Errata.Error
      def to_map(errata_error), do: Errata.Errors.to_map(errata_error)
    end
  end

  # `to_string/1` and `Exception.message/1` are documented as the same
  # developer-oriented rendering, so this dispatches through the error module's
  # `message/1` rather than calling `format_message/1` directly. Calling it
  # directly meant an overridden `message/1` applied to `Exception.message/1` and
  # `raise` but not to `to_string/1`, which silently diverged.
  defp define_string_chars_impl(error_module) do
    quote do
      defimpl String.Chars, for: unquote(error_module) do
        def to_string(errata_error), do: unquote(error_module).message(errata_error)
      end
    end
  end

  # Emit a JSON encoder protocol impl for each backend that is available at
  # compile time. On Elixir 1.18+ this includes the built-in `JSON.Encoder`; on
  # any build where Jason is present (it is an optional dependency) it includes
  # `Jason.Encoder`. Both encode the same `to_map/1` shape, so the JSON output is
  # identical regardless of which backend a caller uses.
  defp define_json_encoder_impls(error_module) do
    jason_impl =
      if Code.ensure_loaded?(Jason) do
        quote do
          defimpl Jason.Encoder, for: unquote(error_module) do
            def encode(errata_error, opts) do
              Errata.Errors.to_json(errata_error, opts)
            end
          end
        end
      end

    native_impl =
      if Code.ensure_loaded?(JSON) do
        quote do
          defimpl JSON.Encoder, for: unquote(error_module) do
            def encode(errata_error, encoder) do
              errata_error
              |> Errata.Errors.to_map()
              |> JSON.protocol_encode(encoder)
            end
          end
        end
      end

    quote do
      unquote(jason_impl)
      unquote(native_impl)
    end
  end
end
