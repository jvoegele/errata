# Fixture modules are defined at the top level rather than inside the test
# module: a module defined in a test body does not get its protocol impls
# consolidated, which matters here more than anywhere else in the suite, since
# `Errata.Convertible` is itself a protocol.
defmodule ToError.Fallback do
  @moduledoc false
  use Errata.DomainError, default_message: "the application's own catch-all"
end

# A fallback type that restricts its reasons. Deriving a reason from an atom
# must not turn normalization into a raise for types like this.
defmodule ToError.Strict do
  @moduledoc false
  use Errata.Error, default_message: "strict", reasons: [:known]
end

defmodule ToError.Foreign do
  @moduledoc false
  defstruct [:detail]
end

defimpl Errata.Convertible, for: ToError.Foreign do
  def to_error(%ToError.Foreign{detail: detail}, opts) do
    ToError.Fallback.new(reason: :converted, context: %{detail: detail, opts: opts})
  end
end

defmodule ToError.Faulty do
  @moduledoc false
  defstruct []
end

defimpl Errata.Convertible, for: ToError.Faulty do
  def to_error(_value, _opts), do: :not_an_error
end

defmodule Errata.ToErrorTest do
  use ExUnit.Case, async: true

  require Errata

  doctest Errata.UnknownError

  describe "to_error/2 with an Errata error" do
    test "returns it unchanged" do
      error = ToError.Fallback.new(reason: :whatever, context: %{a: 1})

      assert Errata.to_error(error) == error
    end

    test "is idempotent" do
      error = Errata.to_error(:timeout)

      assert Errata.to_error(Errata.to_error(error)) == error
    end

    test "ignores options rather than rewrapping" do
      error = ToError.Fallback.new(reason: :whatever)

      assert Errata.to_error(error, fallback: ToError.Strict) == error
    end
  end

  describe "to_error/2 default conversion" do
    test "is total over values of any shape" do
      values = [
        :timeout,
        "connection reset",
        {:error, :timeout},
        [reason: :timeout],
        %{code: 500},
        %RuntimeError{message: "boom"},
        123,
        self()
      ]

      for value <- values do
        error = Errata.to_error(value)

        assert Errata.is_error(error), "expected an Errata error for #{inspect(value)}"
        assert error.__struct__ == Errata.UnknownError
        assert Errata.cause(error) == value
        assert Errata.http_status(error) == 500
        assert Errata.retryable?(error) == false
        assert Errata.severity(error) == :error
      end
    end

    test "derives the reason from an atom" do
      assert Errata.to_error(:timeout) |> Errata.reason() == :timeout
    end

    test "does not derive a reason from nil or booleans" do
      for value <- [nil, true, false] do
        error = Errata.to_error(value)

        assert Errata.reason(error) == nil
        assert Errata.cause(error) == value
      end
    end

    test "an explicit reason wins over the derived one" do
      assert Errata.to_error(:timeout, reason: :upstream_down) |> Errata.reason() ==
               :upstream_down
    end

    test "does not unwrap {:error, reason} tuples" do
      error = Errata.to_error({:error, :timeout})

      assert Errata.cause(error) == {:error, :timeout}
      assert Errata.reason(error) == nil
    end

    test "does not populate :env, since the call site is the boundary" do
      assert Errata.to_error(:timeout).env == nil
    end

    test "keeps the fallback type's message rather than adopting the value's" do
      assert Errata.to_error("connection reset") |> Errata.display_message() ==
               "an unexpected error occurred"

      assert Errata.to_error(%RuntimeError{message: "boom"}) |> Errata.display_message() ==
               "an unexpected error occurred"
    end

    test "accepts error params" do
      error = Errata.to_error(:timeout, message: "upstream timed out", context: %{url: "/x"})

      assert Errata.display_message(error) == "upstream timed out"
      assert Errata.context(error) == %{url: "/x"}
    end

    test "rejects unknown params, as the other constructors do" do
      assert_raise ArgumentError, fn -> Errata.to_error(:timeout, contxt: %{}) end
    end

    test "passes :kind and :stacktrace through to the cause" do
      stacktrace = [{Foo, :bar, 1, [file: ~c"foo.ex", line: 1]}]
      error = Errata.to_error(:badarg, kind: :throw, stacktrace: stacktrace)

      assert %Errata.Cause{kind: :throw, value: :badarg, stacktrace: ^stacktrace} = error.cause
    end

    test "can be captured and passed as a function" do
      assert [first, second] = Enum.map([:timeout, "boom"], &Errata.to_error/1)
      assert Errata.reason(first) == :timeout
      assert Errata.cause(second) == "boom"
    end
  end

  describe "to_error/2 :fallback option" do
    test "wraps in the given type, taking its classification" do
      error = Errata.to_error(:timeout, fallback: ToError.Fallback)

      assert error.__struct__ == ToError.Fallback
      assert Errata.kind(error) == :domain
      assert Errata.http_status(error) == 422
      assert Errata.cause(error) == :timeout
    end

    test "skips reason derivation when the type does not declare that reason" do
      error = Errata.to_error(:timeout, fallback: ToError.Strict)

      assert Errata.reason(error) == nil
      assert Errata.cause(error) == :timeout
    end

    test "still derives a reason the type does declare" do
      assert Errata.to_error(:known, fallback: ToError.Strict) |> Errata.reason() == :known
    end

    test "an explicit invalid reason still raises, as with any constructor" do
      assert_raise ArgumentError, fn ->
        Errata.to_error(:whatever, fallback: ToError.Strict, reason: :unknown)
      end
    end

    test "rejects a module that is not an Errata error type" do
      for bad <- [NotAModule, String, :not_a_module, "MyApp.Error"] do
        assert_raise ArgumentError, ~r/:fallback must be an Errata error type/, fn ->
          Errata.to_error(:timeout, fallback: bad)
        end
      end
    end
  end

  describe "Errata.Convertible implementations" do
    test "take precedence over the default conversion" do
      error = Errata.to_error(%ToError.Foreign{detail: "d"})

      assert error.__struct__ == ToError.Fallback
      assert Errata.reason(error) == :converted
      assert Errata.context(error).detail == "d"
    end

    test "receive the options passed to to_error/2" do
      error = Errata.to_error(%ToError.Foreign{detail: "d"}, custom: :opt)

      assert Errata.context(error).opts == [custom: :opt]
    end

    test "can delegate to the Any implementation for cases they have no opinion on" do
      error = Errata.Convertible.Any.to_error(:timeout, [])

      assert error.__struct__ == Errata.UnknownError
      assert Errata.reason(error) == :timeout
    end

    test "must return an Errata error" do
      assert_raise ArgumentError, ~r/is not an Errata error/, fn ->
        Errata.to_error(%ToError.Faulty{})
      end
    end
  end

  describe "a normalized error at a boundary" do
    test "encodes to a map like any other Errata error" do
      map = Errata.to_error(%RuntimeError{message: "boom"}) |> Errata.to_map()

      assert map.error_type == "Errata.UnknownError"
      assert map.message == "an unexpected error occurred"
      assert map.cause == %{error_type: "RuntimeError", message: "boom"}
    end

    test "encodes to JSON even when the cause is not JSON-encodable" do
      json = Errata.to_error({:error, self()}) |> Jason.encode!() |> Jason.decode!()

      assert json["error_type"] == "Errata.UnknownError"
      assert is_binary(json["cause"])
    end

    test "keeps the original value reachable through the cause chain" do
      original = %RuntimeError{message: "boom"}
      error = Errata.to_error(original)

      assert Errata.root_cause(error) == original
      assert Errata.format_chain(error) =~ "Caused by: ** (RuntimeError) boom"
    end
  end
end
