# Guards the "Unwrapping a wrapped error" recipe in `guides/wrapping-errors.md`.
# The `iex>` examples there are doctests run by `test/guides_test.exs`, and the
# guide's `MyAppWeb.ErrorHelpers` module is a real fixture in `test/support`
# that those doctests call directly, so it cannot drift from what is documented.
# What is left here are the behaviours the surrounding prose claims.
defmodule ErrataWrappingGuideTest do
  use ExUnit.Case, async: true

  require Errata

  alias MyApp.Http.RetriesExhausted
  alias MyApp.Orders.OrderNotFound
  alias MyAppWeb.ErrorHelpers

  describe "root_cause/1, as the recipe describes it" do
    test "an error with no cause is its own root" do
      error = OrderNotFound.new(reason: :not_found)
      assert Errata.root_cause(error) == error
    end

    test "cause/1 is the function that answers whether there is a cause" do
      assert Errata.cause(OrderNotFound.new(reason: :not_found)) == nil

      assert Errata.cause(Errata.wrap(OrderNotFound, %RuntimeError{message: "x"})) ==
               %RuntimeError{message: "x"}
    end

    test "follows the chain to the bottom, however deep" do
      inner = Errata.wrap(RetriesExhausted, %RuntimeError{message: "connection refused"})
      outer = Errata.wrap(OrderNotFound, inner)

      assert Errata.root_cause(outer) == %RuntimeError{message: "connection refused"}
    end

    test "raises on a value that is not an Errata error" do
      assert_raise ArgumentError, "expected an Errata error, got: :timeout", fn ->
        Errata.root_cause(:timeout)
      end
    end

    test "to_error/2 makes an arbitrary value safe to unwrap" do
      assert Errata.root_cause(Errata.to_error(:timeout)) == :timeout
    end
  end

  describe "the guide's ErrorHelpers module" do
    test "renders the deepest Errata error, not the foreign root cause" do
      error = Errata.wrap(RetriesExhausted, :econnrefused, reason: :timeout)

      # The root cause is a bare atom with nothing on it...
      assert Errata.root_cause(error) == :econnrefused

      # ...so what reaches the person is the wrapping error's message.
      assert ErrorHelpers.user_message(error) ==
               "the request could not be completed after 3 attempts"
    end

    test "deliberately does not surface a foreign exception's message" do
      error = Errata.wrap(RetriesExhausted, %RuntimeError{message: "connection refused"})

      assert Errata.root_cause(error) == %RuntimeError{message: "connection refused"}
      refute ErrorHelpers.user_message(error) =~ "connection refused"
    end

    test "needs no fallback for an error with no cause" do
      assert ErrorHelpers.user_message(OrderNotFound.new(reason: :not_found)) ==
               "the requested order does not exist"
    end

    test "normalizes a foreign value on the way in" do
      assert ErrorHelpers.user_message(:timeout) == "an unexpected error occurred"
    end

    test "never renders a developer message" do
      # An Errata error is also an exception, so a naive implementation reaching
      # for Exception.message/1 would leak the reason suffix onto the screen.
      error = Errata.wrap(RetriesExhausted, OrderNotFound.new(reason: :not_found))

      refute ErrorHelpers.user_message(error) =~ ":not_found"
      assert ErrorHelpers.user_message(error) == "the requested order does not exist"
    end
  end
end
