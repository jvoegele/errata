defmodule Errata.Error do
  @moduledoc """
  Support for creating custom error types, which can either be returned as error values or raised
  as exceptions.

  Errata errors can be defined by creating an Elixir module that uses the `Errata.Error`
  module. Error types defined in this way are Elixir `Exception` structs with the following keys:

    * `message` - human readable string describing the nature of the error
    * `reason` - an atom describing the reason for the error, which can be used for pattern
      matching or classifying the error
    * `context` - a map containing arbitrary contextual information or metadata about the error

  Because these error types are defined with `defexception/1`, they can be raised as exceptions
  with `raise/2`. However, because they implement the `Errata.Error` behaviour, it is also
  possible to create instances of these error structs using the generated implementations of
  `c:Errata.Error.new/1` or `c:Errata.Error.create/1` and use them as return values from
  functions, either directly or wrapped in an error tuple such as `{:error, my_error}`.

  Error types defined with `Errata.Error` are of kind `:general` by default. See also
  `Errata.DomainError` and `Errata.InfrastructureError` for defining domain errors and
  infrastructure errors, specifically.

  ## Usage

  To define a new custom error type, `use/2` the `Errata.Error` module in your own error module:

      defmodule MyApp.SomeError do
        use Errata.Error,
          default_message: "something isn't right"
      end

  > #### `use Errata.Error` {: .info}
  >
  > When you `use Errata.Error`, the `Errata.Error` module will define an exception struct with
  > `defexception/1` and will generate an implementation of the `Errata.Error` behaviour.

  The following options may be provided to `use Errata.Error`:

    * `:default_reason` - the default value to use for the `:reason` field if it is not provided
    * `:default_message` - the default value to use for the `:message` field if it is not provided
    * `:kind` - the "kind" of Errata error to create, one of `:domain`, `:infrastructure`, or
      `:general` (which is the default)

  > #### The `:kind` option {: .warning}
  >
  > Although it is possible to define domain error types or infrastructure error types by using
  > `:domain` or `:infrastructure` as the `:kind` option, it is preferred to instead define these
  > types of errors with `use Errata.DomainError` or `use Errata.InfrastructureError`. This
  > approach is more explicit and allows for easier identification of domain errors and
  > infrastructure errors within an application.

  To create instances of the error--to use as an error return value from a function, say--you can
  use either `c:new/1` or `c:create/1`, passing params with extra information as desired. Note that
  if you use `c:create/1`, you must first `require` the error module, since this callback is
  implemented as a macro. For example:

      defmodule MyApp.SomeModule do
        require MyApp.SomeError, as: SomeError

        def some_function(arg) do
          {:error, SomeError.create(reason: :helpful_tag, context: %{arbitrary: "metadata", arg: arg})}
        end
      end

  To raise errors as exceptions, simply use `raise/2` passing extra params as the second argument
  if desired:

      defmodule MyApp.SomeModule do
        require MyApp.SomeError, as: SomeError

        def some_function!(arg) do
          raise SomeError reason: :helpful_tag, context: %{arbitrary: "metadata", arg: arg}
        end
      end

  """

  @typedoc """
  Type to represent Errata error structs.

  Error structs are `Exception` structs that have additional fields to contain extra contextual
  information, such as an error reason or details about the context in which the error occurred.
  """
  @type t() :: Errata.error()

  @typedoc """
  Type to represent allowable keys to use in params used for creating error structs.

  See also `t:params/0`.
  """
  @type param :: :message | :reason | :context

  @typedoc """
  Type to represent allowable values to be passes as params for creating error structs.

  This effectively allows for using either a map or keyword list with allowable keys defined by
  `t:param/0`.
  """
  @type params :: Enumerable.t({param(), any()})

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
  `__ENV__`.

  See `c:create/1`.
  """
  @macrocallback create :: Macro.t()

  @doc """
  Invoked to create a new instance of an error struct with the given params and the current
  `__ENV__`.

  Since this is a  macro, the `__ENV__/0` special form is used to capture the `Macro.Env` struct
  for the current environment and the public fields of this struct are placed in the exception
  struct under the `:env` key. This provides access to information about the context in which the
  error was created, such as the module, function, file, and line. See `t:env/0` for further
  details.

  Note that because this is a macro, callers must `require/2` the error module to be able to use it.
  """
  @macrocallback create(params()) :: Macro.t()

  @doc """
  Invoked to convert an error to a plain, JSON-encodable map.
  """
  @callback to_map(t()) :: map()

  defmacro __using__(opts) do
    kind = Keyword.get(opts, :kind, :general)
    ast = Errata.Errors.define(kind, __CALLER__.module, opts)

    quote do
      unquote(ast)
    end
  end
end
