defmodule Errata.InfrastructureError do
  @moduledoc """
  Infrastructure errors represent errors that can occur at an infrastructure level but which
  are not part of the problem domain.

  Infrastructure errors include such things as network timeouts, database connection failures,
  filesystem errors, etc. Unlike domain errors, infrastructure errors are not part of the problem
  domain and therefore are not typically part of the Ubiquitous Language of the domain.

  Infrastructure errors can be defined by creating an Elixir module that uses the
  `Errata.InfrastructureError` module. Error types defined in this way are `Errata.Error` types of
  kind `:infrastructure`. As such, they share the common structure of all Errata error types and
  support all of the callbacks defined by the `Errata.Error` behaviour.

  See the module docs for `Errata.Error` for more details.

  ## Usage

  To define a new custom infrastructure error type, `use/2` the `Errata.InfrastructureError`
  module in your own error module:

      defmodule MyApp.SomeContext.SomeError do
        use Errata.InfrastructureError,
          default_message: "something isn't right with the infrastructure"
      end
  """

  @typedoc """
  Type to represent Errata infrastructure errors.
  """
  @type t :: Errata.infrastructure_error()

  defmacro __using__(opts) do
    ast = Errata.Errors.define(:infrastructure, __CALLER__.module, opts)

    quote do
      unquote(ast)
    end
  end
end
