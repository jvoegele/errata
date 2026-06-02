defmodule Errata.DomainError do
  @moduledoc """
  Domain errors represent error conditions within a problem domain or bounded context.

  Domain errors are business-process violations, data-consistency errors, or other errors within
  the problem domain. As such, a domain error should have a meaningful name within its context,
  and the precise meaning of that name should be part of the Ubiquitous Language of the domain.

  Define a domain error by creating a module that uses `Errata.DomainError`. The resulting type
  is an `Errata.Error` of kind `:domain`: it shares the common structure of all Errata errors and
  supports every callback of the `Errata.Error` behaviour. See `Errata.Error` for the full set of
  options and callbacks.

  ## Usage

  To define a new custom domain error type, `use/2` the `Errata.DomainError` module in your own
  error module:

      defmodule MyApp.Orders.OrderNotFound do
        use Errata.DomainError,
          default_message: "the requested order does not exist"
      end
  """

  @typedoc """
  Type to represent Errata domain errors.
  """
  @type t :: Errata.domain_error()

  defmacro __using__(opts) do
    ast = Errata.Errors.define(:domain, __CALLER__.module, opts)

    quote do
      unquote(ast)
    end
  end
end
