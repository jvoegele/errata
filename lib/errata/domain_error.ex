defmodule Errata.DomainError do
  @moduledoc """
  Domain errors represent error conditions within a problem domain or bounded context.

  Domain errors are business process violations, dataa consistency errors,  or other errors in the
  problem domain. Therefore, domain errors should have a meaningful name within a particular
  context, and the precise meaning of that name should be part of the Ubiquitous Language of the
  context.

  Domain errors can be defined by creating an Elixir module that uses the `Errata.DomainError`
  module. Error types defined in this way are `Errata.Error` types of kind `:domain`. As such,
  they share the common structure of all Errata error types and support all of the callbacks
  defined by the `Errata.Error` behaviour.

  See the module docs for `Errata.Error` for more details.

  ## Usage

  To define a new custom domain error type, `use/2` the `Errata.DomainError` module in your own
  error module:

      defmodule MyApp.SomeContext.SomeError do
        use Errata.DomainError,
          default_message: "something isn't right in this context"
      end
  """

  @typedoc """
  Type to represent Errata domain errors.
  """
  @type t :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error__: true,
          __errata_error_kind__: :domain,
          message: String.t() | nil,
          reason: atom() | nil,
          context: map() | nil,
          env: Errata.Env.t() | nil
        }

  defmacro __using__(opts) do
    ast = Errata.Errors.define(:domain, __CALLER__.module, opts)

    quote do
      unquote(ast)
    end
  end
end
