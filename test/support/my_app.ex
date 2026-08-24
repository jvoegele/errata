# Fixture error types backing the running example used in the doctests in
# README.md (which becomes the `Errata` moduledoc) and in the guides under
# `guides/`, which are run by `test/guides_test.exs`.
#
# These live in `test/support` — compiled only in the `:test` env, see
# `elixirc_paths/1` in `mix.exs` — rather than at the top of a test file, so that
# any single test file that needs them can be run on its own.
defmodule MyApp.Orders.OrderNotFound do
  @moduledoc false
  use Errata.DomainError,
    default_message: "the requested order does not exist",
    code: "ORDER_NOT_FOUND"
end

defmodule MyApp.Orders.PaymentDeclined do
  @moduledoc false
  use Errata.DomainError, default_message: "the payment was declined"
end

# Backs the "Dynamic messages" doctests: a type whose user-facing message is
# computed from its context, with the static `:default_message` as the fallback.
defmodule MyApp.Orders.ItemOutOfStock do
  @moduledoc false
  use Errata.DomainError, default_message: "the item is out of stock"

  def display_message(%{context: %{sku: sku, available: available}}),
    do: "only #{available} of #{sku} left in stock"

  def display_message(error), do: error.message
end

# Backs the `Errata.to_error/2` examples: a stand-in for a foreign error struct
# from a dependency (something Errata knows nothing about), the application's own
# error type for it, and the dispatch function that joins them.
defmodule MyApp.Http.Timeout do
  @moduledoc false
  defstruct [:url]
end

defmodule MyApp.Http.RequestFailed do
  @moduledoc false
  use Errata.InfrastructureError, default_message: "the request to an upstream service failed"
end

defmodule MyApp.Errors do
  @moduledoc false

  alias MyApp.Http.RequestFailed

  def to_error(%MyApp.Http.Timeout{url: url} = timeout),
    do: RequestFailed.new(reason: :timeout, context: %{url: url}, cause: timeout)

  def to_error(other), do: Errata.to_error(other)
end

# Backs the worked boundary example: an aggregate validation failure and two
# member errors, which together render a real validation response body.
defmodule MyApp.Orders.EmailInvalid do
  @moduledoc false
  use Errata.DomainError, default_message: "email is not a valid address", code: "EMAIL_INVALID"
end

defmodule MyApp.Orders.PostcodeRequired do
  @moduledoc false
  use Errata.DomainError, default_message: "postcode is required", code: "POSTCODE_REQUIRED"
end

defmodule MyApp.Orders.ValidationFailed do
  @moduledoc false
  use Errata.DomainError,
    aggregate: true,
    default_message: "the order could not be validated",
    code: "VALIDATION_FAILED"
end
