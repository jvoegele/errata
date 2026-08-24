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
    * `stacktrace` - the stacktrace for the current process at the time of creation
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
          module: module(),
          stacktrace: Exception.stacktrace() | nil
        }

  @typedoc """
  Type to represent an `Errata.Env` struct as a plain, JSON-encodable map.
  """
  @type env_map :: %{
          module: String.t(),
          function: String.t(),
          file: Macro.Env.file(),
          line: Macro.Env.line(),
          file_line: String.t()
        }

  defstruct [:context, :context_modules, :file, :function, :line, :module, :stacktrace]

  @doc """
  Creates a new `Errata.Env` struct from the given `Macro.Env` struct.
  """
  @spec new(Macro.Env.t()) :: Errata.Env.t()
  def new(%Macro.Env{} = env, stacktrace \\ nil) do
    stacktrace =
      if is_list(stacktrace) do
        stacktrace
      else
        {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
        stacktrace
      end

    params =
      env
      |> Map.from_struct()
      |> Map.put(:stacktrace, stacktrace)

    struct(__MODULE__, params)
  end

  @doc """
  Converts the given `Errata.Env` struct to a plain, JSON-encodable map.

  The `:file` in the struct is the absolute path on the machine that compiled the
  code. When `source_root` is given, the emitted `:file` and `:file_line` are made
  relative to it, so a serialized error carries `lib/my_app/orders.ex:29` rather
  than the build tree's layout. A path that does not live under `source_root` is
  emitted unchanged.
  """
  @spec to_map(Errata.Env.t() | nil, Path.t() | nil) :: Errata.Env.env_map() | %{}
  def to_map(env, source_root \\ nil)

  def to_map(%__MODULE__{module: module, file: file, line: line} = env, source_root) do
    file = relative_to_source_root(file, source_root)

    %{
      # Use `inspect/1` so module names serialize as "MyApp.Foo" rather than
      # the raw atom form "Elixir.MyApp.Foo".
      module: inspect(module),
      function: format_mfa(env),
      file: file,
      line: line,
      # `Exception.format_file_line/2` appends a trailing ":"; drop it.
      file_line: String.trim_trailing(Exception.format_file_line(file, line), ":")
    }
  end

  def to_map(_, _), do: %{}

  defp relative_to_source_root(file, nil), do: file
  defp relative_to_source_root(nil, _source_root), do: nil

  defp relative_to_source_root(file, source_root) when is_binary(file),
    do: Path.relative_to(file, source_root)

  defp relative_to_source_root(file, _source_root), do: file

  defp format_mfa(%{module: module, function: {function, arity}}),
    do: Exception.format_mfa(module, function, arity)

  defp format_mfa(_), do: nil
end
