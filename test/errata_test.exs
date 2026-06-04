# The modules below back the running example used in the doctests in README.md
# (which becomes the `Errata` moduledoc).
defmodule MyApp.Orders.OrderNotFound do
  use Errata.DomainError, default_message: "the requested order does not exist"
end

defmodule MyApp.Orders.PaymentDeclined do
  use Errata.DomainError, default_message: "the payment was declined"
end

# A minimal :logger handler that forwards received log events to a test process,
# so `Errata.log/2`'s structured metadata can be asserted directly.
defmodule ErrataTest.LogHandler do
  @moduledoc false
  def log(event, %{config: %{pid: pid}}), do: send(pid, {:log_event, event})
end

defmodule ErrataTest do
  use ExUnit.Case

  import Errata
  import ExUnit.CaptureLog

  doctest Errata

  # Telemetry handler used by the report/2 tests; an MFA capture avoids the
  # local-function performance warning telemetry emits for anonymous handlers.
  def handle_telemetry(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defmodule TestGeneralError do
    use Errata.Error
  end

  defmodule TestDomainError do
    use Errata.DomainError
  end

  defmodule TestInfrastructureError do
    use Errata.InfrastructureError
  end

  defmodule NonErrataError do
    defexception [:message, :reason, :context, :env]
  end

  describe "is_error/1" do
    test "returns true for general Errata errors" do
      assert is_error(TestGeneralError.new())
      assert is_error(%TestGeneralError{})
    end

    test "returns true for domain errors" do
      assert is_error(TestDomainError.new())
      assert is_error(%TestDomainError{})
    end

    test "returns true for infrastructure errors" do
      assert is_error(TestInfrastructureError.new())
      assert is_error(%TestInfrastructureError{})
    end

    test "returns false for errors that are not Errata errors" do
      refute is_error(%RuntimeError{})
      refute is_error(%ArgumentError{})
    end

    test "returns false for errors that just look like Errata errors" do
      refute is_error(%NonErrataError{})
    end

    test "returns false for anything else" do
      refute is_error(nil)
      refute is_error(%{})
      refute is_error(message: "", reason: :because, context: %{}, env: __ENV__)
    end

    test "can be used in guard tests" do
      case TestDomainError.new() do
        e when is_error(e) -> assert true
        _ -> flunk("expected is_error to be allowed in guard test")
      end
    end
  end

  describe "is_domain_error/1" do
    test "returns false for general Errata errors" do
      refute is_domain_error(TestGeneralError.new())
      refute is_domain_error(%TestGeneralError{})
    end

    test "returns true for domain errors" do
      assert is_domain_error(TestDomainError.new())
      assert is_domain_error(%TestDomainError{})
    end

    test "returns false for infrastructure errors" do
      refute is_domain_error(TestInfrastructureError.new())
      refute is_domain_error(%TestInfrastructureError{})
    end

    test "returns false for errors that are not Errata errors" do
      refute is_domain_error(%RuntimeError{})
      refute is_domain_error(%ArgumentError{})
    end

    test "returns false for errors that just look like Errata errors" do
      refute is_domain_error(%NonErrataError{})
    end

    test "returns false for anything else" do
      refute is_domain_error(nil)
      refute is_domain_error(%{})
      refute is_domain_error(message: "", reason: :because, context: %{}, env: __ENV__)
    end

    test "can be used in guard tests" do
      case TestDomainError.new() do
        e when is_domain_error(e) -> assert true
        _ -> flunk("expected is_domain_error to be allowed in guard test")
      end
    end
  end

  describe "is_infrastructure_error/1" do
    test "returns false for general Errata errors" do
      refute is_infrastructure_error(TestGeneralError.new())
      refute is_infrastructure_error(%TestGeneralError{})
    end

    test "returns false for domain errors" do
      refute is_infrastructure_error(TestDomainError.new())
      refute is_infrastructure_error(%TestDomainError{})
    end

    test "returns false for infrastructure errors" do
      assert is_infrastructure_error(TestInfrastructureError.new())
      assert is_infrastructure_error(%TestInfrastructureError{})
    end

    test "returns false for errors that are not Errata errors" do
      refute is_infrastructure_error(%RuntimeError{})
      refute is_infrastructure_error(%ArgumentError{})
    end

    test "returns false for errors that just look like Errata errors" do
      refute is_infrastructure_error(%NonErrataError{})
    end

    test "returns false for anything else" do
      refute is_infrastructure_error(nil)
      refute is_infrastructure_error(%{})
      refute is_infrastructure_error(message: "", reason: :because, context: %{}, env: __ENV__)
    end

    test "can be used in guard tests" do
      case TestInfrastructureError.new() do
        e when is_infrastructure_error(e) -> assert true
        _ -> flunk("expected is_infrastructure_error to be allowed in guard test")
      end
    end
  end

  describe "create/2" do
    # Note: only `require Errata`/`import Errata` is needed here (already done
    # above) — no `require TestDomainError`. That is the point of this macro.
    test "builds the error, sets params, and captures the current env" do
      error = create(TestDomainError, reason: :boom, context: %{a: 1})

      assert is_domain_error(error)
      assert error.reason == :boom
      assert error.context == %{a: 1}

      assert %Errata.Env{module: module, function: _, line: line, stacktrace: stacktrace} =
               error.env

      assert module == __MODULE__
      assert is_integer(line)
      assert is_list(stacktrace)
    end

    test "works with no params" do
      error = create(TestGeneralError)

      assert is_error(error)
      assert %Errata.Env{module: __MODULE__} = error.env
    end
  end

  describe "wrap/3" do
    # As with `create/2`, only `require Errata` is needed (already done above) —
    # no `require TestDomainError`. That is the point of this macro.
    test "wraps the cause, sets params, and captures the current env" do
      original = %RuntimeError{message: "boom"}
      error = wrap(TestDomainError, original, reason: :boom, context: %{a: 1})

      assert is_domain_error(error)
      assert error.reason == :boom
      assert error.context == %{a: 1}
      assert Errata.cause(error) == original

      assert %Errata.Env{module: __MODULE__, line: line, stacktrace: stacktrace} = error.env
      assert is_integer(line)
      assert is_list(stacktrace)
    end

    test "works with no opts" do
      original = %RuntimeError{message: "boom"}
      error = wrap(TestGeneralError, original)

      assert is_error(error)
      assert Errata.cause(error) == original
      assert %Errata.Env{module: __MODULE__} = error.env
    end

    test "captures the cause stacktrace passed via :stacktrace" do
      error =
        try do
          raise "the database connection dropped"
        rescue
          e -> wrap(TestDomainError, e, stacktrace: __STACKTRACE__, reason: :boom)
        end

      assert Errata.cause(error) == %RuntimeError{message: "the database connection dropped"}
      assert %Errata.Cause{stacktrace: stacktrace} = error.cause
      assert is_list(stacktrace) and stacktrace != []
    end
  end

  describe "to_map/1" do
    test "converts any Errata error to a map without knowing its module" do
      error = TestDomainError.new(reason: :boom, context: %{a: 1})
      map = Errata.to_map(error)

      assert map.error_type == inspect(TestDomainError)
      refute map.error_type =~ "Elixir."
      assert map.reason == :boom
      assert map.context == %{a: 1}
      # matches the per-module callback for the same error
      assert map == TestDomainError.to_map(error)
    end

    test "raises ArgumentError for non-Errata values" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn ->
        Errata.to_map(%RuntimeError{})
      end

      assert_raise ArgumentError, ~r/expected an Errata error/, fn ->
        Errata.to_map(:not_an_error)
      end
    end
  end

  describe "cause/1 and root_cause/1" do
    require MyApp.Orders.OrderNotFound, as: OrderNotFound
    require MyApp.Orders.PaymentDeclined, as: PaymentDeclined

    test "cause/1 returns the immediate wrapped value" do
      original = %RuntimeError{message: "boom"}
      error = OrderNotFound.wrap(original, reason: :lookup_failed)

      assert Errata.cause(error) == original
    end

    test "cause/1 returns nil when there is no cause" do
      assert Errata.cause(OrderNotFound.new()) == nil
    end

    test "root_cause/1 walks to the deepest cause through nested Errata errors" do
      root = %RuntimeError{message: "db down"}
      inner = OrderNotFound.wrap(root, reason: :lookup_failed)
      outer = PaymentDeclined.wrap(inner, reason: :declined)

      assert Errata.cause(outer) == inner
      assert Errata.root_cause(outer) == root
    end

    test "root_cause/1 returns the immediate cause when it is already the deepest" do
      error = OrderNotFound.wrap(%RuntimeError{message: "x"}, reason: :a)
      assert Errata.root_cause(error) == %RuntimeError{message: "x"}
    end

    test "raise ArgumentError for non-Errata values" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn -> Errata.cause(:nope) end
      assert_raise ArgumentError, ~r/expected an Errata error/, fn -> Errata.root_cause(:nope) end
    end
  end

  describe "format_chain/1" do
    require MyApp.Orders.OrderNotFound, as: OrderNotFound
    require MyApp.Orders.PaymentDeclined, as: PaymentDeclined

    test "renders only the head when there is no cause" do
      error = OrderNotFound.new(reason: :not_found)

      assert Errata.format_chain(error) ==
               "MyApp.Orders.OrderNotFound: the requested order does not exist: :not_found"
    end

    test "renders a Caused by line for a wrapped exception" do
      error = OrderNotFound.wrap(%RuntimeError{message: "boom"}, reason: :lookup_failed)
      chain = Errata.format_chain(error)

      assert chain =~
               "MyApp.Orders.OrderNotFound: the requested order does not exist: :lookup_failed"

      assert chain =~ "Caused by: ** (RuntimeError) boom"
    end

    test "recurses through nested Errata causes" do
      root = %RuntimeError{message: "db down"}
      inner = OrderNotFound.wrap(root, reason: :lookup_failed)
      outer = PaymentDeclined.wrap(inner, reason: :declined)
      chain = Errata.format_chain(outer)

      assert chain =~ "MyApp.Orders.PaymentDeclined: the payment was declined: :declined"

      assert chain =~
               "Caused by: MyApp.Orders.OrderNotFound: the requested order does not exist: :lookup_failed"

      assert chain =~ "Caused by: ** (RuntimeError) db down"
    end

    test "raises ArgumentError for non-Errata values" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn ->
        Errata.format_chain(:nope)
      end
    end
  end

  describe "put_context/3" do
    test "adds a key to an existing context map" do
      error = TestDomainError.new(reason: :boom, context: %{a: 1})
      assert Errata.put_context(error, :b, 2).context == %{a: 1, b: 2}
    end

    test "overwrites an existing key" do
      error = TestDomainError.new(context: %{a: 1})
      assert Errata.put_context(error, :a, 2).context == %{a: 2}
    end

    test "initializes the context when it is nil" do
      error = TestDomainError.new(reason: :boom)
      assert error.context == nil
      assert Errata.put_context(error, :a, 1).context == %{a: 1}
    end

    test "leaves the rest of the error unchanged" do
      error = TestDomainError.new(reason: :boom, context: %{a: 1})
      updated = Errata.put_context(error, :b, 2)

      assert updated.reason == :boom
      assert updated.__struct__ == TestDomainError
      assert is_domain_error(updated)
    end

    test "raises ArgumentError for non-Errata values" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn ->
        Errata.put_context(:not_an_error, :a, 1)
      end
    end
  end

  describe "merge_context/2" do
    test "merges a map into an existing context" do
      error = TestDomainError.new(context: %{a: 1})
      assert Errata.merge_context(error, %{b: 2, c: 3}).context == %{a: 1, b: 2, c: 3}
    end

    test "the given context wins on key collisions" do
      error = TestDomainError.new(context: %{a: 1, b: 2})
      assert Errata.merge_context(error, %{b: 99}).context == %{a: 1, b: 99}
    end

    test "initializes the context when it is nil" do
      error = TestDomainError.new(reason: :boom)
      assert error.context == nil
      assert Errata.merge_context(error, %{a: 1}).context == %{a: 1}
    end

    test "raises ArgumentError for non-Errata values" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn ->
        Errata.merge_context(:not_an_error, %{a: 1})
      end
    end

    test "raises ArgumentError when the context is not a map" do
      error = TestDomainError.new()

      assert_raise ArgumentError, ~r/expected a map of context/, fn ->
        Errata.merge_context(error, a: 1)
      end
    end
  end

  describe "http_status/1" do
    test "delegates to the per-module status, defaulting off kind" do
      assert Errata.http_status(TestDomainError.new()) == 422
      assert Errata.http_status(TestInfrastructureError.new()) == 503
      assert Errata.http_status(TestGeneralError.new()) == 500
    end

    test "raises ArgumentError for non-Errata values" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn -> Errata.http_status(nil) end
    end
  end

  describe "report/2" do
    setup do
      ref = make_ref()
      handler_id = {__MODULE__, ref}

      :telemetry.attach(
        handler_id,
        [:errata, :error],
        &__MODULE__.handle_telemetry/4,
        %{pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits a telemetry event with standard measurements and metadata" do
      error = TestDomainError.new(reason: :boom, context: %{a: 1})
      assert Errata.report(error) == :ok

      assert_received {:telemetry_event, [:errata, :error], measurements, metadata}
      assert %{count: 1, system_time: system_time} = measurements
      assert is_integer(system_time)
      assert metadata.error == error
      assert metadata.kind == :domain
      assert metadata.reason == :boom
      assert metadata.error_type == TestDomainError
      assert metadata.context == %{a: 1}
    end

    test "merges caller metadata under the protected standard keys" do
      error = TestDomainError.new(reason: :boom)
      Errata.report(error, metadata: %{request_id: "abc", reason: :hijack})

      assert_received {:telemetry_event, _event, _measurements, metadata}
      assert metadata.request_id == "abc"
      # the standard key wins on collision
      assert metadata.reason == :boom
    end

    test "merges caller measurements under the protected standard keys" do
      error = TestDomainError.new()
      Errata.report(error, measurements: %{duration: 5, count: 99})

      assert_received {:telemetry_event, _event, measurements, _metadata}
      assert measurements.duration == 5
      # the standard measurement wins on collision
      assert measurements.count == 1
    end

    test "normalizes a nil context to an empty map" do
      Errata.report(TestDomainError.new(reason: :boom))
      assert_received {:telemetry_event, _event, _measurements, %{context: %{}}}
    end

    test "does not log by default" do
      assert capture_log(fn -> Errata.report(TestDomainError.new(reason: :boom)) end) == ""
    end

    test "also logs when :log is set" do
      error = TestDomainError.new(message: "boom happened", reason: :boom)
      log = capture_log(fn -> Errata.report(error, log: :warning) end)
      assert log =~ "boom happened"
      assert log =~ "[warning]"
    end

    test "raises ArgumentError for non-Errata values" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn -> Errata.report(:nope) end
    end
  end

  describe "log/2" do
    setup do
      :logger.add_handler(:errata_test_log, ErrataTest.LogHandler, %{
        config: %{pid: self()},
        level: :all
      })

      on_exit(fn -> :logger.remove_handler(:errata_test_log) end)
      :ok
    end

    test "logs the developer message at the given level" do
      error = TestDomainError.new(message: "human msg", reason: :boom)
      log = capture_log(fn -> Errata.log(error, :warning) end)
      assert log =~ "human msg: :boom"
      assert log =~ "[warning]"
    end

    test "attaches structured fields as Logger metadata, including the origin env" do
      error = create(TestDomainError, message: "m", reason: :boom, context: %{a: 1})
      capture_log(fn -> assert Errata.log(error, :warning) == :ok end)

      assert_received {:log_event, event}
      assert event.level == :warning
      assert event.meta.error_type == TestDomainError
      assert event.meta.kind == :domain
      assert event.meta.reason == :boom
      assert event.meta.context == %{a: 1}
      assert %{module: ErrataTest, file: _, line: _} = event.meta.env
    end

    test "defaults to the :error level" do
      capture_log(fn -> assert Errata.log(TestDomainError.new(reason: :boom)) == :ok end)
      assert_received {:log_event, %{level: :error}}
    end

    test "raises ArgumentError for non-Errata values" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn -> Errata.log(:nope) end
    end
  end

  describe "display_message/1" do
    test "returns the bare :message, without the reason suffix" do
      error = TestDomainError.new(message: "human readable", reason: :some_reason)

      assert Errata.display_message(error) == "human readable"
      # contrast with the developer-oriented Exception.message/1
      assert Exception.message(error) == "human readable: :some_reason"
    end

    test "returns nil when no message was set" do
      assert Errata.display_message(TestDomainError.new(reason: :some_reason)) == nil
    end

    test "raises ArgumentError for non-Errata values" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn ->
        Errata.display_message(:not_an_error)
      end
    end
  end
end
