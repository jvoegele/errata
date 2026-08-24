# Guards the code examples and factual claims in `guides/testing.md`. The guide's
# examples are ExUnit assertions rather than `iex>` sessions, so they cannot be
# doctests; they are pinned here instead, following the same pattern as
# `design_guide_test.exs`. If one of these fails, the guide is wrong and should be
# corrected along with the code.
#
# Fixture types live at the top level of the file, above the test module — which
# is itself the guide's first piece of advice.
defmodule ErrataTestingGuideTest.OrderNotFound do
  @moduledoc false
  use Errata.DomainError,
    default_message: "the requested order does not exist",
    code: "ORDER_NOT_FOUND"
end

defmodule ErrataTestingGuideTest.LoginFailed do
  @moduledoc false
  use Errata.DomainError, default_message: "login failed", redact: [:password]
end

defmodule ErrataTestingGuideTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Errata

  alias ErrataTestingGuideTest.LoginFailed
  alias ErrataTestingGuideTest.OrderNotFound

  describe "where to define fixture error types" do
    test "the accessors work on a type defined after consolidation; only protocols break" do
      # Defined in a test body on purpose — this is the trap the guide documents.
      {{:module, module, _, _}, _} =
        Code.eval_quoted(
          quote do
            defmodule ErrataTestingGuideTest.InBody do
              use Errata.DomainError, default_message: "boom", code: "IN_BODY"
            end
          end
        )

      error = struct(module, %{reason: :x, message: "boom", context: %{}})

      # The narrower-than-it-looks claim: to_map/1 and the accessors are fine.
      assert Errata.to_map(error).code == "IN_BODY"
      assert Errata.reason(error) == :x
      assert Errata.display_message(error) == "boom"

      # The protocol path is the only one that would break — and here it does not,
      # because this project sets `consolidate_protocols: Mix.env() != :test` in
      # mix.exs, which is the second mitigation the guide recommends. That this
      # passes *is* the demonstration that the mitigation works; a project without
      # it raises Protocol.UndefinedError on the next line.
      refute Mix.Project.config()[:consolidate_protocols]
      assert to_string(error) == "boom: :x"
    end
  end

  describe "asserting on errors" do
    test "create/2 and new/1 differ only in :env" do
      created = Errata.create(OrderNotFound, reason: :not_found, context: %{order_id: 7})
      built = OrderNotFound.new(reason: :not_found, context: %{order_id: 7})

      refute created == built
      assert %{created | env: nil} == built
      refute is_nil(created.env)
      assert is_nil(built.env)
    end

    test "the accessor assertions the guide recommends" do
      error = Errata.create(OrderNotFound, reason: :not_found, context: %{order_id: 7})

      assert %OrderNotFound{} = error
      assert Errata.reason(error) == :not_found
      assert Errata.context(error) == %{order_id: 7}
    end
  end

  describe "asserting that redaction works" do
    test "redaction applies at the serialization seam, not at creation" do
      error = LoginFailed.new(context: %{password: "hunter2", user: "jane"})

      assert error.context == %{password: "hunter2", user: "jane"}
      assert Errata.context(error) == %{password: "hunter2", user: "jane"}
      assert Errata.to_map(error).context == %{password: "[REDACTED]", user: "jane"}
    end

    test ":redact misses an undeclared key and an interpolated message" do
      under_other_key = LoginFailed.new(context: %{params: %{"passwd" => "hunter2"}})
      in_message = LoginFailed.new(message: "login failed for hunter2")

      # Both sail through — this is what the guide's refute_leaks/2 exists for.
      assert inspect(Errata.to_map(under_other_key)) =~ "hunter2"
      assert Exception.message(in_message) =~ "hunter2"
    end

    test "the guide's refute_leaks/2 catches both, with no false positive" do
      assert leaks?(LoginFailed.new(context: %{params: %{"passwd" => "hunter2"}}), "hunter2")
      assert leaks?(LoginFailed.new(message: "login failed for hunter2"), "hunter2")

      # Correctly-redacted context passes.
      refute leaks?(LoginFailed.new(context: %{password: "hunter2"}), "hunter2")
    end

    defp leaks?(error, secret) do
      [
        inspect(Errata.to_map(error)),
        Exception.message(error),
        to_string(Errata.display_message(error))
      ]
      |> Enum.any?(&(&1 =~ secret))
    end
  end

  describe "testing the telemetry seam" do
    test "the :telemetry_test idiom from the guide" do
      :telemetry_test.attach_event_handlers(self(), [[:errata, :error]])

      Errata.report(OrderNotFound.new(reason: :not_found))

      assert_received {[:errata, :error], _ref, measurements, metadata}
      assert metadata.code == "ORDER_NOT_FOUND"
      assert metadata.kind == :domain
      assert measurements.count == 1
    end
  end

  describe "logs" do
    test "metadata reaches the captured log only with metadata: :all" do
      error = OrderNotFound.new(reason: :not_found)

      with_metadata = capture_log([metadata: :all], fn -> Errata.log(error) end)

      assert with_metadata =~ "code=ORDER_NOT_FOUND"
      assert with_metadata =~ "severity=error"
    end
  end

  describe "which message assert_raise matches" do
    test "it is the developer message, reason suffix included" do
      assert_raise OrderNotFound, "the requested order does not exist: :not_found", fn ->
        raise OrderNotFound, reason: :not_found
      end

      # Not the display message, which omits the reason.
      assert Errata.display_message(OrderNotFound.new(reason: :not_found)) ==
               "the requested order does not exist"
    end
  end
end
