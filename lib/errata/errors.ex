defmodule Errata.Errors do
  @moduledoc false

  # Import only the guard we use; a bare `import Errata` would also pull in
  # `Errata.to_map/1`, which conflicts with this module's local `to_map/1`.
  import Errata, only: [is_error: 1]

  # The only keys callers are allowed to set when creating an error. Internal
  # fields (`:kind`, `:env`, `:__errata_error__`) are managed by Errata itself.
  @allowed_param_keys [:message, :reason, :context]

  @doc false
  @spec create(module() | struct(), Errata.Error.params()) :: Errata.Error.t()
  def create(error_type, params) do
    struct(error_type, validate_params!(params))
  end

  @doc false
  @spec create(module() | struct(), Errata.Error.params(), Macro.Env.t(), Exception.stacktrace()) ::
          Errata.error()
  def create(error_type, params, %Macro.Env{} = env, stacktrace) do
    error = struct(error_type, validate_params!(params))

    %{error | env: Errata.Env.new(env, stacktrace)}
  end

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

  @doc false
  def to_map(%error_type{} = error) when is_error(error) do
    %{
      error_type: error_type,
      reason: error.reason,
      message: error.message,
      env: Errata.Env.to_map(error.env),
      context: context_map(error)
    }
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

  @doc false
  def to_json(error, opts) do
    error
    |> to_map()
    |> Errata.JSON.encode(opts)
  end

  @doc false
  def define(kind, module_name, opts \\ [])
      when kind in [:domain, :infrastructure, :general] and is_atom(module_name) do
    attribute_defs = define_attributes(module_name)
    type_def = define_type(kind)
    exception_def = define_exception(kind, opts)
    errata_error_impl = define_errata_error_callbacks()
    string_chars_impl = define_string_chars_impl(module_name)
    jason_encoder_impl = define_jason_encoder_impl(module_name)

    quote do
      unquote(attribute_defs)
      unquote(type_def)
      unquote(exception_def)
      unquote(errata_error_impl)
      unquote(string_chars_impl)
      unquote(jason_encoder_impl)
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

  defp define_jason_encoder_impl(error_module) do
    quote do
      defimpl Jason.Encoder, for: unquote(error_module) do
        def encode(errata_error, opts) do
          Errata.Errors.to_json(errata_error, opts)
        end
      end
    end
  end
end
