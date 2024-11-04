defmodule Errata.Env do
  @moduledoc """
  A struct that holds compile time environment information that is used for the `:env` field of
  Errata error types.

  This struct is a subset of `Macro.Env` and includes the following fields:

    * `context` - the context of the environment; it can be nil (default context), :guard
      (inside a guard) or :match (inside a match)
    * `context_modules` - a list of modules defined in the current context
    * `file` - the current absolute file name as a binary
    * `function` - a tuple as {atom, integer}, where the first element is the function name and
      the second its arity; returns nil if not inside a function
    * `line` - the current line as an integer
    * `module` - the current module name
  """

  @typedoc """
  Type to represent the `:env` field of error structs.

  This struct is a subset of `Macro.Env`.
  """
  @type t :: %Errata.Env{
          context: Macro.Env.context(),
          context_modules: Macro.Env.context_modules(),
          file: Macro.Env.file(),
          function: Macro.Env.name_arity() | nil,
          line: Macro.Env.line(),
          module: module()
        }

  @typedoc """
  Type to represent an `Errata.Env` struct as a plain, JSON-encodable map.
  """
  @type env_map :: %{
          module: module(),
          function: String.t(),
          file: Macro.Env.file(),
          line: Macro.Env.line(),
          file_line: String.t()
        }

  defstruct [:context, :context_modules, :file, :function, :line, :module]

  @doc """
  Creates a new `Errata.Env` struct from the given `Macro.Env` struct.
  """
  @spec new(Macro.Env.t()) :: Errata.Env.t()
  def new(%Macro.Env{} = env) do
    struct(__MODULE__, Map.from_struct(env))
  end

  @doc """
  Converts the given `Errata.Env` struct to a plain, JSON-encodable map.
  """
  @spec to_map(Errata.Env.t()) :: Errata.Env.env_map()
  def to_map(%__MODULE__{module: module, file: file, line: line} = env) do
    %{
      module: module,
      function: format_mfa(env),
      file: file,
      line: line,
      file_line: Exception.format_file_line(file, line)
    }
  end

  def to_map(_), do: %{}

  defp format_mfa(%{module: module, function: {function, arity}}),
    do: Exception.format_mfa(module, function, arity)

  defp format_mfa(_), do: nil
end
