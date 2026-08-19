defmodule TestError do
  use Errata.Error,
    default_message: "this is only a test",
    default_reason: :testing_123
end

defmodule ReasonedError do
  use Errata.DomainError, reasons: [:alpha, :beta, :gamma]
end

defmodule DefaultReasonedError do
  use Errata.DomainError, default_reason: :alpha, reasons: [:alpha, :beta]
end

defmodule StatusOverrideError do
  use Errata.DomainError, http_status: 404
end

defmodule DynamicStatusError do
  use Errata.DomainError, reasons: [:missing, :conflict]
  def http_status(%{reason: :missing}), do: 404
  def http_status(%{reason: :conflict}), do: 409
  def http_status(_error), do: 422
end

defmodule CodedError do
  use Errata.DomainError, code: "ORDER_NOT_FOUND"
end

defmodule DynamicCodeError do
  use Errata.DomainError, reasons: [:expired, :revoked]
  def code(%{reason: :expired}), do: "TOKEN_EXPIRED"
  def code(%{reason: :revoked}), do: "TOKEN_REVOKED"
  def code(_error), do: "TOKEN_INVALID"
end

defmodule SeverityOverrideError do
  use Errata.DomainError, severity: :warning
end

defmodule DynamicSeverityError do
  use Errata.DomainError, reasons: [:minor, :major]
  def severity(%{reason: :minor}), do: :info
  def severity(_error), do: :error
end

defmodule PlainInfrastructureError do
  use Errata.InfrastructureError
end

defmodule NotRetryableInfrastructureError do
  use Errata.InfrastructureError, retryable: false
end

defmodule DynamicRetryableError do
  use Errata.InfrastructureError, reasons: [:not_found, :timeout]
  def retryable?(%{reason: :not_found}), do: false
  def retryable?(_error), do: true
end

defmodule Errata.ErrorTest do
  @moduledoc "Tests for the Errata.Error module"

  use ExUnit.Case

  require TestError

  describe "new/0" do
    test "uses default values" do
      error = TestError.new()
      assert error.message == "this is only a test"
      assert error.reason == :testing_123
      refute error.context
      refute error.env
    end
  end

  describe "new/1" do
    test "raises ArgumentError on unrecognized param keys" do
      assert_raise ArgumentError, ~r/invalid param key\(s\).*:unrecognized/, fn ->
        TestError.new(unrecognized: "ignore me")
      end
    end

    test "overrides default reason" do
      error = TestError.new(reason: :be_reasonable)
      assert error.message == "this is only a test"
      assert error.reason == :be_reasonable
      refute error.context
      refute error.env
    end

    test "sets context field from params" do
      error = TestError.new(%{context: %{foo: "bar"}})
      assert error.message == "this is only a test"
      assert error.reason == :testing_123
      assert error.context == %{foo: "bar"}
      refute error.env
    end
  end

  describe "create/0" do
    require TestError

    test "uses default values" do
      error = TestError.create()
      assert error.message == "this is only a test"
      assert error.reason == :testing_123
      refute error.context

      assert %{module: module, function: _, file: _, line: _, stacktrace: stacktrace} = error.env
      assert module == Errata.ErrorTest
      assert is_list(stacktrace)
      assert [{__MODULE__, _, _, _} | _] = stacktrace
    end
  end

  describe "create/1" do
    test "raises ArgumentError on unrecognized param keys" do
      assert_raise ArgumentError, ~r/invalid param key\(s\).*:unrecognized/, fn ->
        TestError.create(unrecognized: "ignore me")
      end
    end

    test "overrides default reason" do
      error = TestError.create(reason: :be_reasonable)
      assert error.message == "this is only a test"
      assert error.reason == :be_reasonable
      refute error.context

      assert %{module: _, function: _, file: _, line: _} = error.env
    end

    test "sets context field from params" do
      error = TestError.create(%{context: %{foo: "bar"}})
      assert error.message == "this is only a test"
      assert error.reason == :testing_123
      assert error.context == %{foo: "bar"}

      assert %{module: _, function: _, file: _, line: _} = error.env
    end
  end

  describe "new/1 with a :cause" do
    test "normalizes a raw cause value into an Errata.Cause" do
      original = %RuntimeError{message: "boom"}
      error = TestError.new(cause: original)

      assert %Errata.Cause{kind: :error, value: ^original, stacktrace: nil} = error.cause
      refute error.env
    end
  end

  describe "wrap/1" do
    test "wraps a value as the cause and captures the current env" do
      original = %RuntimeError{message: "boom"}
      error = TestError.wrap(original)

      assert %Errata.Cause{kind: :error, value: ^original, stacktrace: nil} = error.cause
      assert %Errata.Env{module: __MODULE__} = error.env
      # default message/reason still apply
      assert error.message == "this is only a test"
      assert error.reason == :testing_123
    end
  end

  describe "wrap/2" do
    test "stores params alongside the cause and preserves the original stacktrace" do
      {original, stacktrace} =
        try do
          raise "kaboom"
        rescue
          e -> {e, __STACKTRACE__}
        end

      error = TestError.wrap(original, reason: :wrapped, context: %{a: 1}, stacktrace: stacktrace)

      assert error.reason == :wrapped
      assert error.context == %{a: 1}
      assert %Errata.Cause{kind: :error, value: ^original, stacktrace: ^stacktrace} = error.cause
      assert is_list(error.cause.stacktrace)
      assert %Errata.Env{module: __MODULE__} = error.env
    end

    test "supports a :kind for thrown/exited causes" do
      error = TestError.wrap(:boom, kind: :throw)
      assert %Errata.Cause{kind: :throw, value: :boom} = error.cause
    end

    test "accepts a non-exception term as the cause" do
      error = TestError.wrap({:error, :db_timeout}, reason: :infra)
      assert Errata.cause(error) == {:error, :db_timeout}
    end

    test "rejects unknown param keys" do
      assert_raise ArgumentError, ~r/invalid param key\(s\).*:bogus/, fn ->
        TestError.wrap(%RuntimeError{}, bogus: true)
      end
    end
  end

  describe "to_map/1 cause serialization" do
    test "renders a wrapped standard exception by type and message" do
      error = TestError.new(cause: %RuntimeError{message: "boom"})
      assert TestError.to_map(error).cause == %{error_type: "RuntimeError", message: "boom"}
    end

    test "recurses into a wrapped Errata error cause" do
      inner = TestError.new(reason: :inner)
      map = TestError.new(cause: inner) |> TestError.to_map()

      assert map.cause.error_type == inspect(TestError)
      assert map.cause.reason == :inner
    end

    test "is nil when there is no cause" do
      assert TestError.new().cause == nil
      assert TestError.to_map(TestError.new()).cause == nil
    end
  end

  describe "to_map/1" do
    test "produces a JSON-compatible map" do
      error = TestError.create(context: %{foo: "bar"})
      map = TestError.to_map(error)

      assert map.error_type == inspect(TestError)
      refute map.error_type =~ "Elixir."
      assert map.reason == error.reason
      assert map.message == error.message
      assert map.context == %{foo: "bar"}

      assert map.env.module == inspect(__MODULE__)
      refute map.env.module =~ "Elixir."
      assert map.env.file =~ ~r<error_test\.exs>
      assert is_integer(map.env.line)
      # file_line has no trailing colon
      assert map.env.file_line =~ ~r<error_test\.exs:\d+$>
      assert map.env.function =~ ~r<test to_map/1>
    end

    test "includes the code key, which is nil when the type declares none" do
      map = TestError.to_map(TestError.new())

      assert Map.has_key?(map, :code)
      assert map.code == nil
    end

    test "includes the declared code" do
      assert CodedError.to_map(CodedError.new()).code == "ORDER_NOT_FOUND"

      assert DynamicCodeError.to_map(DynamicCodeError.new(reason: :expired)).code ==
               "TOKEN_EXPIRED"
    end

    test "includes the code of a wrapped Errata error cause" do
      map = TestError.to_map(TestError.new(cause: CodedError.new()))
      assert map.cause.code == "ORDER_NOT_FOUND"
    end
  end

  # The classification is what a consumer on the far side of the wire acts on,
  # so it has to survive serialization: without these keys the receiving end can
  # read the message but cannot tell a 404 from a 503, or whether to retry.
  describe "to_map/1 classification" do
    test "includes the classification keys with their defaults" do
      map = TestError.to_map(TestError.new())

      assert map.kind == :general
      assert map.http_status == 500
      assert map.severity == :error
      assert map.retryable == false
    end

    test "reflects the kind the type was defined with" do
      assert CodedError.to_map(CodedError.new()).kind == :domain

      assert PlainInfrastructureError.to_map(PlainInfrastructureError.new()).kind ==
               :infrastructure
    end

    test "reflects declared classification options" do
      assert StatusOverrideError.to_map(StatusOverrideError.new()).http_status == 404
      assert SeverityOverrideError.to_map(SeverityOverrideError.new()).severity == :warning

      assert PlainInfrastructureError.to_map(PlainInfrastructureError.new()).retryable == true

      assert NotRetryableInfrastructureError.to_map(NotRetryableInfrastructureError.new()).retryable ==
               false
    end

    # These dispatch through the overridable generated functions rather than
    # reading a field, so a type that computes its classification from :reason
    # serializes the computed value.
    test "dispatches through overridden classification functions" do
      assert DynamicStatusError.to_map(DynamicStatusError.new(reason: :conflict)).http_status ==
               409

      assert DynamicSeverityError.to_map(DynamicSeverityError.new(reason: :minor)).severity ==
               :info

      assert DynamicRetryableError.to_map(DynamicRetryableError.new(reason: :not_found)).retryable ==
               false

      assert DynamicRetryableError.to_map(DynamicRetryableError.new(reason: :timeout)).retryable ==
               true
    end

    test "agrees with the Errata accessors" do
      error = DynamicStatusError.new(reason: :missing)
      map = Errata.to_map(error)

      assert map.kind == Errata.kind(error)
      assert map.http_status == Errata.http_status(error)
      assert map.severity == Errata.severity(error)
      assert map.retryable == Errata.retryable?(error)
    end

    test "a wrapped Errata cause carries its own classification" do
      map = TestError.to_map(TestError.new(cause: PlainInfrastructureError.new()))

      assert map.cause.kind == :infrastructure
      assert map.cause.http_status == 503
      assert map.cause.retryable == true

      # ...and does not overwrite the outer error's own classification.
      assert map.kind == :general
      assert map.retryable == false
    end

    test "a non-Errata cause carries none" do
      map = TestError.to_map(TestError.new(cause: %RuntimeError{message: "boom"}))

      assert map.cause == %{error_type: "RuntimeError", message: "boom"}
    end
  end

  describe "raising as an exception" do
    test "raise/1 uses default values" do
      error =
        assert_raise TestError, "this is only a test: :testing_123", fn ->
          raise TestError
        end

      assert error.message == "this is only a test"
      assert error.reason == :testing_123
      refute error.context
    end

    test "raise/2 overrides default values" do
      error =
        assert_raise TestError, "this is only a test: :be_reasonable", fn ->
          raise TestError, reason: :be_reasonable, context: %{foo: "bar"}
        end

      assert error.message == "this is only a test"
      assert error.reason == :be_reasonable
      assert error.context == %{foo: "bar"}
    end

    test "exception message omits reason when it is nil" do
      assert_raise TestError, "this is only a test", fn ->
        raise TestError, reason: nil, context: %{foo: "bar"}
      end
    end
  end

  describe "declared :reasons" do
    require ReasonedError

    test "accepts a declared reason" do
      assert ReasonedError.new(reason: :beta).reason == :beta
      assert ReasonedError.create(reason: :gamma).reason == :gamma
    end

    test "allows a nil (unspecified) reason" do
      assert ReasonedError.new().reason == nil
      assert ReasonedError.new(reason: nil).reason == nil
    end

    test "rejects an undeclared reason from new/1" do
      assert_raise ArgumentError, ~r/invalid reason :delta.*Declared reasons are/, fn ->
        ReasonedError.new(reason: :delta)
      end
    end

    test "rejects an undeclared reason from create/1" do
      assert_raise ArgumentError, ~r/invalid reason :delta/, fn ->
        ReasonedError.create(reason: :delta)
      end
    end

    test "rejects an undeclared reason from wrap/2" do
      assert_raise ArgumentError, ~r/invalid reason :delta/, fn ->
        ReasonedError.wrap(%RuntimeError{}, reason: :delta)
      end
    end

    test "rejects an undeclared reason from raise/2" do
      assert_raise ArgumentError, ~r/invalid reason :delta/, fn ->
        raise ReasonedError, reason: :delta
      end
    end

    test "a declared :default_reason is applied and is valid by construction" do
      assert DefaultReasonedError.new().reason == :alpha
    end

    test "types without declared reasons remain unrestricted" do
      assert TestError.new(reason: :anything_at_all).reason == :anything_at_all
    end

    test "rejects a non-atom-list :reasons at compile time" do
      assert_raise ArgumentError, ~r/must be a non-empty list of atoms/, fn ->
        Code.compile_string("""
        defmodule Errata.ErrorTest.BadReasons do
          use Errata.DomainError, reasons: [:a, "b"]
        end
        """)
      end
    end

    test "rejects a :default_reason not among :reasons at compile time" do
      assert_raise ArgumentError, ~r/default_reason :nope.*is not one of the declared/, fn ->
        Code.compile_string("""
        defmodule Errata.ErrorTest.BadDefault do
          use Errata.DomainError, default_reason: :nope, reasons: [:a, :b]
        end
        """)
      end
    end
  end

  describe "http_status/1" do
    test "defaults off the error kind" do
      # TestError is a :general error
      assert TestError.http_status(TestError.new()) == 500
      # ReasonedError is a :domain error
      assert ReasonedError.http_status(ReasonedError.new()) == 422
    end

    test "the :http_status option overrides the kind default" do
      assert StatusOverrideError.http_status(StatusOverrideError.new()) == 404
    end

    test "can be overridden to compute a status from the error" do
      assert DynamicStatusError.http_status(DynamicStatusError.new(reason: :missing)) == 404
      assert DynamicStatusError.http_status(DynamicStatusError.new(reason: :conflict)) == 409
      assert DynamicStatusError.http_status(DynamicStatusError.new()) == 422
    end

    test "rejects an out-of-range :http_status at compile time" do
      assert_raise ArgumentError, ~r/must be an integer HTTP status code/, fn ->
        Code.compile_string("""
        defmodule Errata.ErrorTest.BadStatus do
          use Errata.DomainError, http_status: 999_999
        end
        """)
      end
    end
  end

  describe "code/1" do
    test "is nil when the error type does not declare one" do
      assert TestError.code(TestError.new()) == nil
      assert ReasonedError.code(ReasonedError.new()) == nil
    end

    test "returns the declared :code" do
      assert CodedError.code(CodedError.new()) == "ORDER_NOT_FOUND"
    end

    test "can be overridden to derive a code from the error" do
      assert DynamicCodeError.code(DynamicCodeError.new(reason: :expired)) == "TOKEN_EXPIRED"
      assert DynamicCodeError.code(DynamicCodeError.new(reason: :revoked)) == "TOKEN_REVOKED"
      assert DynamicCodeError.code(DynamicCodeError.new()) == "TOKEN_INVALID"
    end

    test "rejects a :code that is not a non-empty string at compile time" do
      assert_raise ArgumentError, ~r/must be a non-empty string/, fn ->
        Code.compile_string("""
        defmodule Errata.ErrorTest.BadCodeAtom do
          use Errata.DomainError, code: :ORDER_NOT_FOUND
        end
        """)
      end

      assert_raise ArgumentError, ~r/must be a non-empty string/, fn ->
        Code.compile_string("""
        defmodule Errata.ErrorTest.BadCodeEmpty do
          use Errata.DomainError, code: ""
        end
        """)
      end
    end
  end

  describe "severity/1" do
    test "defaults to :error for every kind" do
      assert TestError.severity(TestError.new()) == :error
      assert ReasonedError.severity(ReasonedError.new()) == :error
    end

    test "the :severity option overrides the default" do
      assert SeverityOverrideError.severity(SeverityOverrideError.new()) == :warning
    end

    test "can be overridden to compute a severity from the error" do
      assert DynamicSeverityError.severity(DynamicSeverityError.new(reason: :minor)) == :info
      assert DynamicSeverityError.severity(DynamicSeverityError.new(reason: :major)) == :error
    end

    test "rejects a :severity that is not a Logger level at compile time" do
      assert_raise ArgumentError, ~r/must be one of the Logger levels/, fn ->
        Code.compile_string("""
        defmodule Errata.ErrorTest.BadSeverity do
          use Errata.DomainError, severity: :catastrophe
        end
        """)
      end

      assert_raise ArgumentError, ~r/must be one of the Logger levels/, fn ->
        Code.compile_string("""
        defmodule Errata.ErrorTest.BadSeverityType do
          use Errata.DomainError, severity: "warning"
        end
        """)
      end
    end
  end

  describe "retryable?/1" do
    test "defaults off the error kind" do
      # TestError is a :general error, ReasonedError a :domain error
      refute TestError.retryable?(TestError.new())
      refute ReasonedError.retryable?(ReasonedError.new())
      assert PlainInfrastructureError.retryable?(PlainInfrastructureError.new())
    end

    test "the :retryable option overrides the kind default" do
      assert NotRetryableInfrastructureError.retryable?(NotRetryableInfrastructureError.new()) ==
               false
    end

    test "can be overridden to decide from the error" do
      refute DynamicRetryableError.retryable?(DynamicRetryableError.new(reason: :not_found))
      assert DynamicRetryableError.retryable?(DynamicRetryableError.new(reason: :timeout))
    end

    test "rejects a non-boolean :retryable at compile time" do
      assert_raise ArgumentError, ~r/:retryable .* must be a boolean/, fn ->
        Code.compile_string("""
        defmodule Errata.ErrorTest.BadRetryable do
          use Errata.DomainError, retryable: :sometimes
        end
        """)
      end
    end
  end

  describe "String.Chars protocol implementation:" do
    test "string representation uses message and reason when both are present" do
      assert to_string(TestError.new()) == "this is only a test: :testing_123"
    end

    test "string representation omits reason when it is nil" do
      assert to_string(TestError.new(reason: nil)) == "this is only a test"
    end
  end

  describe "Jason.Encoder protocol implementation:" do
    require TestError

    test "produces JSON data for the relevant fields" do
      error =
        TestError.create(
          reason: :to_believe,
          context: %{meta: "data", danger: {:error, "tuple"}, pid: self()}
        )

      assert {:ok, decoded} = error |> Jason.encode!() |> Jason.decode(keys: :atoms)
      assert decoded.message == error.message
      assert decoded.reason == to_string(error.reason)
      assert %{meta: "data", danger: ["error", "tuple"], pid: pid_string} = decoded.context
      assert pid_string =~ ~r(#PID<\d+\.\d+\.\d+>)

      assert %{file: file, line: line, module: module, function: function} = decoded.env
      assert file =~ ~r/error_test.exs$/
      assert is_integer(line)
      assert module == inspect(__MODULE__)
      refute module =~ "Elixir."

      %{module: current_module, function: {current_function, current_function_arity}} = __ENV__

      assert function ==
               Exception.format_mfa(current_module, current_function, current_function_arity)
    end

    # The point of serializing the classification is that a consumer holding
    # only the decoded JSON — possibly not even an Elixir program — can route on
    # it. Atoms arrive as strings; the status stays an integer and retryable a
    # boolean, so neither needs parsing.
    test "carries the classification, needing no Errata modules to interpret" do
      json = Jason.encode!(DynamicStatusError.new(reason: :conflict))

      assert {:ok, decoded} = Jason.decode(json)

      assert decoded["kind"] == "domain"
      assert decoded["http_status"] == 409
      assert decoded["severity"] == "error"
      assert decoded["retryable"] == false
    end
  end

  # The built-in JSON module (and JSON.Encoder protocol) is only available on
  # Elixir 1.18+; this block compiles away on earlier versions. It asserts the
  # native backend produces the same JSON shape as the Jason backend above.
  if Code.ensure_loaded?(JSON) do
    describe "JSON.Encoder protocol implementation (built-in JSON):" do
      require TestError

      test "produces the same JSON shape as the Jason backend" do
        error =
          TestError.create(
            reason: :to_believe,
            context: %{meta: "data", danger: {:error, "tuple"}, pid: self()}
          )

        decoded = error |> JSON.encode!() |> JSON.decode!()

        assert decoded["message"] == error.message
        assert decoded["reason"] == to_string(error.reason)

        assert %{"meta" => "data", "danger" => ["error", "tuple"], "pid" => pid_string} =
                 decoded["context"]

        assert pid_string =~ ~r(#PID<\d+\.\d+\.\d+>)

        assert %{"file" => file, "module" => module} = decoded["env"]
        assert file =~ ~r/error_test.exs$/
        assert module == inspect(__MODULE__)
        refute module =~ "Elixir."
      end

      test "carries the classification, identically to the Jason backend" do
        error = DynamicStatusError.new(reason: :conflict)

        assert JSON.encode!(error) |> JSON.decode!() ==
                 Jason.encode!(error) |> Jason.decode!()

        decoded = error |> JSON.encode!() |> JSON.decode!()

        assert decoded["kind"] == "domain"
        assert decoded["http_status"] == 409
        assert decoded["severity"] == "error"
        assert decoded["retryable"] == false
      end
    end
  end
end
