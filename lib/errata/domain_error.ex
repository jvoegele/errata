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

  defmacro __using__(opts) do
    ast = Errata.Error.__define__(:domain, __CALLER__.module, opts)

    quote do
      unquote(ast)
    end
  end
end
