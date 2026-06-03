defmodule Errata.Errors do
  @moduledoc false

  # Import only the guard we use; a bare `import Errata` would also pull in
  # `Errata.to_map/1`, which conflicts with this module's local `to_map/1`.
  import Errata, only: [is_error: 1]

  # The only keys callers are allowed to set when creating an error. Internal
  # fields (`:kind`, `:env`, `:__errata_error__`) are managed by Errata itself.
  @allowed_param_keys [:message, :reason, :context, :cause]

  @doc false
  @spec create(module() | struct(), Errata.Error.params()) :: Errata.Error.t()
  def create(error_type, params) do
    error_type
    |> struct(validate_params!(params))
    |> normalize_cause()
    |> validate_reason!()
  end

  @doc false
  @spec create(module() | struct(), Errata.Error.params(), Macro.Env.t(), Exception.stacktrace()) ::
          Errata.error()
  def create(error_type, params, %Macro.Env{} = env, stacktrace) do
    error =
      error_type
      |> struct(validate_params!(params))
      |> normalize_cause()
      |> validate_reason!()

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

  # The `:cause` param may be given as a raw value (e.g. via `new(cause: ...)`);
  # normalize it into an `Errata.Cause` struct. A `nil` cause means "no cause".
  defp normalize_cause(%{cause: nil} = error), do: error
  defp normalize_cause(%{cause: %Errata.Cause{}} = error), do: error
  defp normalize_cause(%{cause: value} = error), do: %{error | cause: Errata.Cause.new(value)}
  defp normalize_cause(error), do: error

  # Reject unknown/misspelled param keys instead of silently dropping them
  # (which `struct/2` would do). Returns the params unchanged when valid.
  defp validate_params!(params) do
    invalid =
      params
      |> Enum.map(fn {key, _value} -> key end)
      |> Enum.reject(&(&1 in @allowed_param_keys))

    case invalid do
      [] ->
        params

      keys ->
        raise ArgumentError,
              "invalid param key(s) for an Errata error: #{inspect(keys)}. " <>
                "Allowed keys are #{inspect(@allowed_param_keys)}."
    end
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
      reason: error.reason,
      message: error.message,
      cause: cause_map(error.cause),
      env: Errata.Env.to_map(error.env),
      context: context_map(error)
    }
  end

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
  def format_message(%{message: nil, reason: nil}), do: ""
  def format_message(%{message: nil, reason: reason}) when is_atom(reason), do: inspect(reason)
  def format_message(%{message: message, reason: nil}) when is_binary(message), do: message

  def format_message(%{message: message, reason: reason})
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
      when kind in [:domain, :infrastructure, :general] and is_atom(module_name) do
    reasons = Keyword.get(opts, :reasons)
    validate_reasons_opt!(module_name, reasons, Keyword.get(opts, :default_reason))

    attribute_defs = define_attributes(module_name)
    type_def = define_type(kind)
    reasons_def = define_reasons(reasons)
    http_status_def = define_http_status(kind, module_name, opts)
    exception_def = define_exception(kind, opts)
    errata_error_impl = define_errata_error_callbacks()
    string_chars_impl = define_string_chars_impl(module_name)
    json_encoder_impls = define_json_encoder_impls(module_name)

    quote do
      unquote(attribute_defs)
      unquote(type_def)
      unquote(reasons_def)
      unquote(http_status_def)
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

  # Validate the `:reasons` option at the `use` site (compile time). When given,
  # it must be a non-empty list of atoms, and any `:default_reason` must be one
  # of the declared reasons.
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
  defp context_map(%{context: context}) when is_map(context) do
    # Make sure that all of the data in the `context` map is JSON-encodable
    Enum.reduce(context, Map.new(), fn {key, value}, acc ->
      if Errata.JSON.encodable?(value) do
        Map.put(acc, key, value)
      else
        Map.put(acc, key, inspect(value))
      end
    end)
  end

  defp context_map(_), do: %{}

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

    quote do
      defexception __errata_error__: true,
                   kind: unquote(kind),
                   message: unquote(default_message),
                   reason: unquote(default_reason),
                   context: nil,
                   cause: nil,
                   env: nil

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

  defp define_string_chars_impl(error_module) do
    quote do
      defimpl String.Chars, for: unquote(error_module) do
        def to_string(errata_error), do: Errata.Errors.format_message(errata_error)
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
