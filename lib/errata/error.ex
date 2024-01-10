defmodule Errata.Error do
  @moduledoc """
  Defines callbacks and types common to all kinds of Errata errors.
  """

  import Errata

  @typedoc """
  Type to represent Errata error structs.

  Error structs are `Exception` structs that have additional fields to contain extra contextual
  information, such as an error reason or details about the context in which the error occurred.
  """
  @type t() :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error_kind__: atom(),
          message: String.t() | nil,
          reason: atom() | nil,
          extra: map() | nil,
          env: env()
        }

  @typedoc """
  Type to represent allowable keys to use in params used for creating error structs.

  See also `t:params/0`.
  """
  @type param :: :message | :reason | :extra

  @typedoc """
  Type to represent allowable values to be passes as params for creating error structs.

  This effectively allows for using either a map or keyword list with allowable keys defined by
  `t:param/0`.
  """
  @type params :: Enumerable.t({param(), any()})

  @typedoc """
  Type to represent the `:env` field of error structs.

  This struct is a subset of of `Macro.Env` and contains the following fields:

    * `context` - the context of the environment; it can be nil (default context), :guard
      (inside a guard) or :match (inside a match)
    * `context_modules` - a list of modules defined in the current context
    * `file` - the current absolute file name as a binary
    * `function` - a tuple as {atom, integer}, where the first element is the function name and
      the second its arity; returns nil if not inside a function
    * `line` - the current line as an integer
    * `module` - the current module name
  """
  @type env :: %{
          context: Macro.Env.context(),
          context_modules: Macro.Env.context_modules(),
          file: Macro.Env.file(),
          function: Macro.Env.name_arity() | nil,
          line: Macro.Env.line(),
          module: module()
        }
  @doc """
  Invoked to create a new instance of an error struct with default values.

  See `c:new/1`.
  """
  @callback new :: t()

  @doc """
  Invoked to create a new instance of an error struct with the given params.
  """
  @callback new(params()) :: t()

  @doc """
  Invoked to create a new instance of an error struct with default values and the current
  __ENV__.

  See `c:create/1`.
  """
  @macrocallback create :: Macro.t()

  @doc """
  Invoked to create a new instance of an error struct with the given params and the current
  __ENV__.

  Since this is a  macro, the `__ENV__/0` special form is used to capture the `Macro.Env` struct
  for the current environment and the public fields of this struct are placed in the exception
  struct under the `:env` key. This provides access to information about the context in which the
  error was created, such as the module, function, file, and line. See `t:env/0` for further
  details.

  Note that because this is a macro, callers must `require/2` the error module to be able to use it.
  """
  @macrocallback create(params()) :: Macro.t()

  @doc """
  Invoked to convert an error to a plain, JSON-compatible map.
  """
  @callback to_map(t()) :: map()

  @doc false
  @spec create(module() | struct(), Errata.Error.params()) :: t()
  def create(error_type, params) do
    struct(error_type, params)
  end

  @doc false
  @spec create(module() | struct(), Errata.Error.params(), Macro.Env.t()) :: t()
  def create(error_type, params, %Macro.Env{} = env) do
    error = struct(error_type, params)

    %{error | env: make_env(env)}
  end

  @doc false
  def to_map(%error_type{} = error) when is_error(error) do
    %{
      error_type: error_type,
      reason: error.reason,
      message: error.message,
      env: env_map(error),
      extra: extra_map(error)
    }
  end

  @doc false
  @spec format_message(t()) :: String.t()
  def format_message(error)

  def format_message(%{message: message, reason: reason} = error)
      when is_error(error) and is_binary(message) do
    if reason, do: "#{message}: #{inspect(reason)}", else: message
  end

  @doc false
  def to_json(error, opts) do
    error
    |> to_map()
    |> Errata.JSON.encode(opts)
  end

  @doc false
  @spec make_env(Macro.Env.t()) :: Errata.Error.env()
  def make_env(%Macro.Env{} = env),
    do: Map.take(env, [:context, :context_modules, :file, :function, :line, :module])

  @doc false
  defp env_map(%{env: %{module: module, file: file, line: line} = env}) do
    %{
      module: module,
      function: format_mfa(env),
      file: file,
      line: line,
      file_line: Exception.format_file_line(file, line)
    }
  end

  defp env_map(_), do: %{}

  defp format_mfa(%{module: module, function: {function, arity}}),
    do: Exception.format_mfa(module, function, arity)

  defp format_mfa(_), do: nil

  @doc false
  defp extra_map(%{extra: extra}) when is_map(extra) do
    # Make sure that all of the data in the `extra` map is JSON-encodable
    Enum.reduce(extra, Map.new(), fn {key, value}, acc ->
      if Errata.JSON.encodable?(value) do
        Map.put(acc, key, value)
      else
        Map.put(acc, key, inspect(value))
      end
    end)
  end

  defp extra_map(_), do: %{}
end
