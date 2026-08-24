# Guards the "Unwrapping a wrapped error" recipe in `guides/wrapping-errors.md`.
# The `iex>` examples there are doctests run by `test/guides_test.exs`; the
# `MyAppWeb.ErrorHelpers` module is a module definition rather than a console
# session, so it is pinned here, following `design_guide_test.exs`.
#
# This is a verbatim copy of the guide's module. If it stops compiling or its
# behaviour changes, the guide is wrong and should be corrected along with it.
defmodule ErrataWrappingGuideTest.ErrorHelpers do
  @moduledoc false
  require Errata

  def user_message(value) do
    error = Errata.to_error(value)

    case Errata.root_cause(error) do
      cause when Errata.is_error(cause) -> Errata.display_message(cause)
      %{__exception__: true} = exception -> Exception.message(exception)
      _no_cause_or_plain_term -> Errata.display_message(error)
    end
  end
end

defmodule ErrataWrappingGuideTest do
  use ExUnit.Case, async: true

  require Errata

  alias ErrataWrappingGuideTest.ErrorHelpers
  alias MyApp.Http.RetriesExhausted
  alias MyApp.Orders.OrderNotFound

  describe "root_cause/1, as the recipe describes it" do
    test "returns nil when there is no cause" do
      assert Errata.root_cause(OrderNotFound.new(reason: :not_found)) == nil
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
      error = Errata.to_error(:timeout)
      assert (Errata.root_cause(error) || error) == :timeout
    end
  end

  describe "the guide's ErrorHelpers module" do
    test "reaches the deepest exception rather than the handler's reaction" do
      wrapped = Errata.wrap(RetriesExhausted, %RuntimeError{message: "connection refused"})

      # The outer error describes the retry handler, not the failure.
      assert Errata.display_message(wrapped) ==
               "the request could not be completed after 3 attempts"

      assert ErrorHelpers.user_message(wrapped) == "connection refused"
    end

    test "an Errata cause renders through display_message, not Exception.message" do
      inner = OrderNotFound.new(reason: :not_found)
      wrapped = Errata.wrap(RetriesExhausted, inner)

      # Clause order is what makes this the display message: an Errata error is
      # also an exception, so an is_error/1 clause placed second would never run.
      assert ErrorHelpers.user_message(wrapped) == "the requested order does not exist"
      refute ErrorHelpers.user_message(wrapped) =~ ":not_found"
    end

    test "falls back to the outer message when there is no cause" do
      assert ErrorHelpers.user_message(OrderNotFound.new(reason: :not_found)) ==
               "the requested order does not exist"
    end

    test "falls back to the outer message for a plain-term cause" do
      # `to_error(:timeout)` gives an UnknownError whose cause is the bare atom —
      # not something to show a person, so the outer message wins.
      assert ErrorHelpers.user_message(:timeout) == "an unexpected error occurred"
    end
  end
end
