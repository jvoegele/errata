defmodule Errata.InfrastructureError do
  @moduledoc """
  Infrastructure errors represent errors that can occur at an infrastructure level but which
  are not part of the problem domain.

  Infrastructure errors include such things as network timeouts, database connection failures, and
  filesystem errors. Unlike domain errors, they are not part of the problem domain and so are not
  typically part of the Ubiquitous Language of the domain.

  Define an infrastructure error by creating a module that uses `Errata.InfrastructureError`. The
  resulting type is an `Errata.Error` of kind `:infrastructure`: it shares the common structure of
  all Errata errors and supports every callback of the `Errata.Error` behaviour. See `Errata.Error`
  for the full set of options and callbacks.

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
