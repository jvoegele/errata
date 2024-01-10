defmodule Errata.DomainError do
  @moduledoc """
  Support for creating custom domain error types, which can either be returned as error values or
  raised as exceptions.

  Domain errors are named, structured types that represent error conditions within a problem
  domain or bounded context. Being named types means that errors have a meaningful name within a
  particular context, and that name should be part of the Ubiquitous Language of the context.
  Being structured types means that errors have a well-defined structure identifying the nature of
  the error, and can also have arbitrary contextual information attached to them for logging or
  debugging purposes.

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
  Type to represent domain error structs as defined by this module.
  """
  @type t() :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error_kind__: Errata.DomainError,
          message: String.t() | nil,
          reason: atom() | nil,
          extra: map() | nil,
          env: Errata.Error.env()
        }

  @doc """
  Returns `true` if `term` is a type of `Errata.DomainError`; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_domain_error(term)
           when is_struct(term) and
                  is_exception(term) and
                  is_map_key(term, :__errata_error_kind__) and
                  term.__errata_error_kind__ == Errata.DomainError and
                  is_map_key(term, :message) and
                  is_map_key(term, :reason) and
                  is_map_key(term, :extra) and
                  is_map_key(term, :env)

  defmacro __using__(opts) do
    default_message = Keyword.get(opts, :default_message)
    default_reason = Keyword.get(opts, :default_reason)

    quote do
      @behaviour Errata.Error

      defexception __errata_error_kind__: Errata.DomainError,
                   message: unquote(default_message),
                   reason: unquote(default_reason),
                   extra: nil,
                   env: nil

      @type t :: Errata.DomainError.t()

      @impl Exception
      def exception(params), do: Errata.Error.create(__MODULE__, params)

      @impl Exception
      def message(%__MODULE__{} = domain_error),
        do: Errata.Error.format_message(domain_error)

      @impl Errata.Error
      def new(params \\ %{}), do: Errata.Error.create(__MODULE__, params)

      @impl Errata.Error
      defmacro create do
        quote do
          Errata.Error.create(unquote(__MODULE__), %{}, __ENV__)
        end
      end

      @impl Errata.Error
      defmacro create(params) do
        quote do
          Errata.Error.create(unquote(__MODULE__), unquote(params), __ENV__)
        end
      end

      @impl Errata.Error
      def to_map(domain_error), do: Errata.Error.to_map(domain_error)

      defoverridable Exception

      defimpl String.Chars, for: __MODULE__ do
        def to_string(domain_error), do: Errata.Error.format_message(domain_error)
      end

      defimpl Jason.Encoder, for: __MODULE__ do
        def encode(domain_error, opts) do
          Errata.Error.to_json(domain_error, opts)
        end
      end
    end
  end
end
