# Error types backing the message-rendering tests. Defined at the top level so
# their String.Chars / JSON encoder protocol impls are consolidated at compile
# time; a module defined inside a test body would not be.
defmodule ErrataMessageTest.Plain do
  @moduledoc false
  use Errata.DomainError, default_message: "the requested order does not exist"
end

# Overrides the *developer* rendering only.
defmodule ErrataMessageTest.DevOverride do
  @moduledoc false
  use Errata.DomainError, default_message: "the requested order does not exist"

  @impl Exception
  def message(%{context: %{order_id: id}}), do: "order #{id} does not exist"
  def message(error), do: super(error)
end

# Overrides the *display* rendering only.
defmodule ErrataMessageTest.DisplayOverride do
  @moduledoc false
  use Errata.DomainError, default_message: "the requested order does not exist"

  def display_message(%{context: %{order_id: id}}), do: "order #{id} does not exist"
  def display_message(error), do: error.message
end

defmodule ErrataMessageTest.NoMessage do
  @moduledoc false
  use Errata.DomainError
end

defmodule ErrataMessageTest do
  use ExUnit.Case, async: true

  alias ErrataMessageTest.DevOverride
  alias ErrataMessageTest.DisplayOverride
  alias ErrataMessageTest.NoMessage
  alias ErrataMessageTest.Plain

  describe "the two renderings are distinct" do
    test "Exception.message/1 includes the reason; display_message/1 does not" do
      error = Plain.new(reason: :not_found)

      assert Exception.message(error) == "the requested order does not exist: :not_found"
      assert Errata.display_message(error) == "the requested order does not exist"
    end

    test "to_string/1 agrees with Exception.message/1" do
      error = Plain.new(reason: :not_found)

      assert to_string(error) == Exception.message(error)
    end

    test "display_message/1 is nil when no message was set" do
      assert Errata.display_message(NoMessage.new(reason: :nope)) == nil
    end
  end

  describe "overriding message/1 (the developer rendering)" do
    setup do
      {:ok, error: DevOverride.new(reason: :not_found, context: %{order_id: 42})}
    end

    test "applies to Exception.message/1", %{error: error} do
      assert Exception.message(error) == "order 42 does not exist"
    end

    # The regression this file exists for: `to_string/1` used to call
    # `format_message/1` directly and silently ignore the override.
    test "applies to to_string/1", %{error: error} do
      assert to_string(error) == "order 42 does not exist"
      assert to_string(error) == Exception.message(error)
    end

    test "falls back to super/1 when the clause does not match" do
      error = DevOverride.new(reason: :not_found)

      assert Exception.message(error) == "the requested order does not exist: :not_found"
      assert to_string(error) == Exception.message(error)
    end

    test "does not change the display rendering", %{error: error} do
      assert Errata.display_message(error) == "the requested order does not exist"
      assert Errata.to_map(error).message == "the requested order does not exist"
    end
  end

  describe "overriding display_message/1 (the user-facing rendering)" do
    setup do
      {:ok, error: DisplayOverride.new(reason: :not_found, context: %{order_id: 42})}
    end

    test "applies to Errata.display_message/1", %{error: error} do
      assert Errata.display_message(error) == "order 42 does not exist"
    end

    test "applies to to_map/1", %{error: error} do
      assert Errata.to_map(error).message == "order 42 does not exist"
    end

    test "applies to the JSON encoding", %{error: error} do
      assert %{"message" => "order 42 does not exist"} =
               error |> Jason.encode!() |> Jason.decode!()
    end

    if Code.ensure_loaded?(JSON) do
      test "applies to the native JSON encoding", %{error: error} do
        assert %{"message" => "order 42 does not exist"} =
                 error |> JSON.encode!() |> JSON.decode!()
      end
    end

    test "does not change the developer rendering", %{error: error} do
      assert Exception.message(error) == "the requested order does not exist: :not_found"
      assert to_string(error) == Exception.message(error)
    end

    test "falls back to the :message field when the clause does not match" do
      error = DisplayOverride.new(reason: :not_found)

      assert Errata.display_message(error) == "the requested order does not exist"
    end
  end

  describe "the default display_message/1" do
    test "is generated on every error type and returns the :message field" do
      error = Plain.new(reason: :not_found)

      assert Plain.display_message(error) == error.message
      assert Errata.display_message(error) == error.message
    end
  end
end
