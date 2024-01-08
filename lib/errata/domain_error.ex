defmodule Errata.DomainError do
  @moduledoc """
  Support for creating custom domain error types, which can either be returned as error values or
  raised as exceptions.

  Domain errors are named, structured types that represent error conditions within a problem
  domain or bounded context. Being named types means that errors have a meaningful name within a
  particular context, and that name should be part of the Ubiquitous Language of the context.
  Being structured types means that errors can have arbitrary contextual information attached to
  them for logging or debugging purposes.

  Domain errors can be defined by creating an Elixir module that uses the `Errata.DomainError`
  module. Error types defined in this way are Elixir `Exception` structs with the following keys:

    * `message` - human readable string describing the nature of the error
    * `reason` - an atom describing the reason for the error, which can be used for pattern
      matching or classifying the error
    * `extra` - a map containing arbitrary contextual information or metadata about the error

  Because these error types are defined with `defexception/1`, they can be raised as exceptions
  with `raise/2`. However, because they represent domain errors rather than system or
  infrastructure errors, in most cases it is more appropriate to create instances of the error
  structs using `c:new/1` or `c:create/1` and use them as return values from domain functions,
  either directly or wrapped in an error tuple such as `{:error, my_domain_error}`.

  ## Usage

  To define a new custom domain error type, `use/2` the `Errata.DomainError` module in your own
  error module:

      defmodule MyApp.SomeError do
        use Errata.DomainError,
          default_message: "something isn't right"
      end

  To create instances of the error, to use as an error return value from a function, say, you can
  use either `c:new/1` or `c:create/1`, passing params with extra information as desired. Note that
  if you use `c:create/1`, you must first `require` the error module, since this callback is
  implemented as a macro. For example:

      defmodule MyApp.SomeModule do
        require MyApp.SomeError, as: SomeError

        def some_function(arg) do
          {:error, SomeError.create(reason: :helpful_tag, extra: %{arbitrary: "metadata", arg: arg})}
        end
      end

  To raise errors as exceptions, simply use `raise/2` passing extra params as the second argument
  if desired:

      defmodule MyApp.SomeModule do
        require MyApp.SomeError, as: SomeError

        def some_function!(arg) do
          raise SomeError reason: :helpful_tag, extra: %{arbitrary: "metadata", arg: arg}
        end
      end
  """

  @typedoc """
  Type to represent allowable keys to use in params use for creating domain error structs.

  See also `t:params/0`.
  """
  @type param :: :message | :reason | :extra

  @typedoc """
  Type to represent allowable values to be passes as params for creating domain error structs.

  This effectively allows for using either a map or keyword list with allowable keys defined by
  `t:param/0`.
  """
  @type params :: Enumerable.t({param(), any()})

  @typedoc """
  Type to represent the `:env` field of domain error structs.

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

  @typedoc """
  Type to represent domain error structs as defined by this module.

  Error structs are `Exception` structs that have additional fields to contain extra contextual
  information, such as an error reason or details about the context in which the error occurred.
  """
  @type t() :: %{
          :__struct__ => module(),
          :__exception__ => true,
          :message => String.t(),
          :reason => atom() | nil,
          :extra => map() | nil,
          :env => env() | nil,
          optional(atom()) => any()
        }

  @doc """
  Invoked to create a new instance of a domain error struct with the given params.
  """
  @callback new(params()) :: t()

  @doc """
  Invoked to create a new instance of a domain error struct with default values.

  See `c:new/1`.
  """
  @callback new :: t()

  @doc """
  Invoked to create a new instance of a domain error struct with the given params and the current
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
  Invoked to create a new instance of a domain error struct with default values and the current
  __ENV__.

  See `c:create/1`.
  """
  @macrocallback create :: Macro.t()

  @doc """
  Invoked to convert a domain error to a plain, JSON-compatible map.
  """
  @callback to_map(t()) :: map()

  @doc """
  Returns `true` if `term` is a type of `Errata.DomainError`; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_domain_error(term)
           when is_struct(term) and
                  is_exception(term) and
                  is_map_key(term, :message) and
                  is_map_key(term, :reason) and
                  is_map_key(term, :extra) and
                  is_map_key(term, :env)

  defmacro __using__(opts) do
    default_message = Keyword.get(opts, :default_message)
    default_reason = Keyword.get(opts, :default_reason)

    quote do
      @behaviour Errata.DomainError

      defexception message: unquote(default_message),
                   reason: unquote(default_reason),
                   extra: nil,
                   env: nil

      @type t :: Errata.DomainError.t()

      @impl Exception
      def exception(params), do: Errata.DomainError.create(__MODULE__, params)

      @impl Exception
      def message(%__MODULE__{} = domain_error),
        do: Errata.DomainError.format_message(domain_error)

      @impl Errata.DomainError
      def new(params \\ %{}), do: Errata.DomainError.create(__MODULE__, params)

      @impl Errata.DomainError
      defmacro create do
        quote do
          Errata.DomainError.create(unquote(__MODULE__), %{}, __ENV__)
        end
      end

      @impl Errata.DomainError
      defmacro create(params) do
        quote do
          Errata.DomainError.create(unquote(__MODULE__), unquote(params), __ENV__)
        end
      end

      @impl Errata.DomainError
      def to_map(domain_error), do: Errata.DomainError.to_map(domain_error)

      defoverridable Exception

      defimpl String.Chars, for: __MODULE__ do
        def to_string(domain_error), do: Errata.DomainError.format_message(domain_error)
      end

      defimpl Jason.Encoder, for: __MODULE__ do
        def encode(domain_error, opts) do
          Errata.DomainError.to_json(domain_error, opts)
        end
      end
    end
  end

  defimpl Jason.Encoder, for: Tuple do
    def encode(data, options) when is_tuple(data) do
      data
      |> Tuple.to_list()
      |> Jason.Encoder.List.encode(options)
    end
  end

  @doc """
  Creates a new domain error struct of the given `error_type` using the given `params`.
  """
  @spec create(module() | struct(), params()) :: t()
  def create(error_type, params) do
    struct(error_type, params)
  end

  @doc """
  Creates a new domain error struct of the given `error_type` using the given `params` and `env`.
  """
  @spec create(module() | struct(), params(), Macro.Env.t()) :: t()
  def create(error_type, params, %Macro.Env{} = env) do
    domain_error = struct(error_type, params)

    %{domain_error | env: make_env(env)}
  end

  def to_map(%error_type{} = error) when is_domain_error(error) do
    %{
      error_type: error_type,
      reason: error.reason,
      message: error.message,
      env: env_map(error),
      extra: extra_map(error)
    }
  end

  @doc """
  Formats the given `domain_error` as a string.

  Uses the `:message` field of the domain_error and combines the `:reason` field with it, if it is not nil.
  """
  @spec format_message(t()) :: String.t()
  def format_message(domain_error)

  def format_message(%{message: message, reason: reason} = domain_error)
      when is_domain_error(domain_error) and is_binary(message) do
    if reason, do: "#{message}: #{inspect(reason)}", else: message
  end

  def to_json(domain_error, opts) do
    domain_error
    |> to_map()
    |> Jason.Encode.map(opts)
  end

  @doc false
  @spec make_env(Macro.Env.t()) :: env()
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
      if match?({:ok, _}, Jason.encode(value)) do
        Map.put(acc, key, value)
      else
        Map.put(acc, key, inspect(value))
      end
    end)
  end

  defp extra_map(_), do: %{}
end
