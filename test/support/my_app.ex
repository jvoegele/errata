# Fixture error types backing the running example used in the doctests in
# README.md (which becomes the `Errata` moduledoc) and in the guides under
# `guides/`, which are run by `test/guides_test.exs`.
#
# These live in `test/support` — compiled only in the `:test` env, see
# `elixirc_paths/1` in `mix.exs` — rather than at the top of a test file, so that
# any single test file that needs them can be run on its own.
defmodule MyApp.Orders.OrderNotFound do
  @moduledoc false
  use Errata.DomainError, default_message: "the requested order does not exist"
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
