# Dialyzer guard for the generated `t/0` (see #65). The type names the module's
# struct, and it must stay a subtype of the kind-level types so that a spec
# written against a kind keeps accepting every generated type. Each function
# below would draw an `invalid_contract` warning if that stopped holding. CI
# runs Dialyzer in the test environment so that this file is analysed.
#
# The converse, that Dialyzer *does* warn when the wrong type is passed, cannot
# live here without failing the build; `test/errata/typespec_test.exs` checks
# the shape of what is generated instead.
defmodule MyApp.TypespecGuards do
  @moduledoc false

  use Errata
  alias MyApp.Http.RequestFailed
  alias MyApp.Orders.PaymentDeclined
  require PaymentDeclined

  @spec as_domain(PaymentDeclined.t()) :: Errata.domain_error()
  def as_domain(error), do: error

  @spec as_infrastructure(RequestFailed.t()) :: Errata.infrastructure_error()
  def as_infrastructure(error), do: error

  @spec as_error(PaymentDeclined.t()) :: Errata.error()
  def as_error(error), do: error

  @spec as_behaviour_type(PaymentDeclined.t()) :: Errata.Error.t()
  def as_behaviour_type(error), do: error

  # Every constructor is typed as producing the module's own `t/0`.
  @spec built_with_new() :: PaymentDeclined.t()
  def built_with_new, do: PaymentDeclined.new(reason: :declined)

  @spec built_with_create() :: PaymentDeclined.t()
  def built_with_create, do: PaymentDeclined.create(reason: :declined)

  @spec built_with_errata_create() :: PaymentDeclined.t()
  def built_with_errata_create, do: Errata.create(PaymentDeclined, reason: :declined)

  @spec built_with_wrap() :: PaymentDeclined.t()
  def built_with_wrap, do: PaymentDeclined.wrap(:boom)

  @spec built_with_errata_wrap() :: PaymentDeclined.t()
  def built_with_errata_wrap, do: Errata.wrap(PaymentDeclined, :boom)
end
