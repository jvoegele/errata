defmodule TestError do
  use Errata.Error,
    default_message: "this is only a test",
    default_reason: :testing_123
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
      refute error.extra
      refute error.env
    end
  end

  describe "new/1" do
    test "uses default values" do
      error = TestError.new(unrecognized: "ignore me")
      assert error.message == "this is only a test"
      assert error.reason == :testing_123
      refute error.extra
      refute error.env
    end

    test "overrides default reason" do
      error = TestError.new(reason: :be_reasonable)
      assert error.message == "this is only a test"
      assert error.reason == :be_reasonable
      refute error.extra
      refute error.env
    end

    test "sets extra field from params" do
      error = TestError.new(%{extra: %{foo: "bar"}})
      assert error.message == "this is only a test"
      assert error.reason == :testing_123
      assert error.extra == %{foo: "bar"}
      refute error.env
    end
  end

  describe "create/0" do
    require TestError

    test "uses default values" do
      error = TestError.create()
      assert error.message == "this is only a test"
      assert error.reason == :testing_123
      refute error.extra

      assert %{module: module, function: _, file: _, line: _, stacktrace: stacktrace} = error.env
      assert module == Errata.ErrorTest
      assert is_list(stacktrace)
      assert [{__MODULE__, _, _, _} | _] = stacktrace
    end
  end

  describe "create/1" do
    test "uses default values" do
      error = TestError.create(unrecognized: "ignore me")
      assert error.message == "this is only a test"
      assert error.reason == :testing_123
      refute error.extra

      assert %{module: _, function: _, file: _, line: _} = error.env
    end

    test "overrides default reason" do
      error = TestError.create(reason: :be_reasonable)
      assert error.message == "this is only a test"
      assert error.reason == :be_reasonable
      refute error.extra

      assert %{module: _, function: _, file: _, line: _} = error.env
    end

    test "sets extra field from params" do
      error = TestError.create(%{extra: %{foo: "bar"}})
      assert error.message == "this is only a test"
      assert error.reason == :testing_123
      assert error.extra == %{foo: "bar"}

      assert %{module: _, function: _, file: _, line: _} = error.env
    end
  end

  describe "to_map/1" do
    test "produces a JSON-compatible map" do
      error = TestError.create(extra: %{foo: "bar"})
      map = TestError.to_map(error)

      assert map.error_type == TestError
      assert map.reason == error.reason
      assert map.message == error.message
      assert map.extra == %{foo: "bar"}

      assert map.env.module == __MODULE__
      assert map.env.file =~ ~r<error_test\.exs>
      assert is_integer(map.env.line)
      assert map.env.file_line =~ ~r<error_test\.exs:\d>
      assert map.env.function =~ ~r<test to_map/1>
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
      refute error.extra
    end

    test "raise/2 overrides default values" do
      error =
        assert_raise TestError, "this is only a test: :be_reasonable", fn ->
          raise TestError, reason: :be_reasonable, extra: %{foo: "bar"}
        end

      assert error.message == "this is only a test"
      assert error.reason == :be_reasonable
      assert error.extra == %{foo: "bar"}
    end

    test "exception message omits reason when it is nil" do
      assert_raise TestError, "this is only a test", fn ->
        raise TestError, reason: nil, extra: %{foo: "bar"}
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
          extra: %{meta: "data", danger: {:error, "tuple"}, pid: self()}
        )

      assert {:ok, decoded} = error |> Jason.encode!() |> Jason.decode(keys: :atoms)
      assert decoded.message == error.message
      assert decoded.reason == to_string(error.reason)
      assert %{meta: "data", danger: ["error", "tuple"], pid: pid_string} = decoded.extra
      assert pid_string =~ ~r(#PID<\d+\.\d+\.\d+>)

      assert %{file: file, line: line, module: module, function: function} = decoded.env
      assert file =~ ~r/error_test.exs$/
      assert is_integer(line)
      assert module == to_string(__MODULE__)

      %{module: current_module, function: {current_function, current_function_arity}} = __ENV__

      assert function ==
               Exception.format_mfa(current_module, current_function, current_function_arity)
    end
  end
end
