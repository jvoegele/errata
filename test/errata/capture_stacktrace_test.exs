# Error types backing the `:capture_stacktrace` tests, defined at the top level
# so their protocol impls are consolidated along with the rest of the suite.
defmodule ErrataCaptureStacktraceTest.Default do
  @moduledoc false
  use Errata.DomainError
end

defmodule ErrataCaptureStacktraceTest.Off do
  @moduledoc false
  use Errata.DomainError, capture_stacktrace: false
end

defmodule ErrataCaptureStacktraceTest.On do
  @moduledoc false
  use Errata.DomainError, capture_stacktrace: true
end

defmodule ErrataCaptureStacktraceTest.TwoFrames do
  @moduledoc false
  use Errata.InfrastructureError, capture_stacktrace: 2
end

defmodule ErrataCaptureStacktraceTest do
  # Not async: some tests change `config :errata, capture_stacktrace:`.
  use ExUnit.Case, async: false
  use Errata

  alias ErrataCaptureStacktraceTest.{Default, Off, On, TwoFrames}

  require Off
  require TwoFrames

  defp with_global_setting(setting, fun) do
    previous = Application.fetch_env(:errata, :capture_stacktrace)
    Application.put_env(:errata, :capture_stacktrace, setting)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:errata, :capture_stacktrace, value)
        :error -> Application.delete_env(:errata, :capture_stacktrace)
      end
    end
  end

  describe "per-type :capture_stacktrace" do
    test "captures the full stacktrace by default" do
      error = Errata.create(Default)

      assert [{__MODULE__, _, _, _} | _] = error.env.stacktrace
    end

    test "false captures no stacktrace but keeps the rest of the env" do
      for error <- [
            Errata.create(Off),
            Errata.wrap(Off, :boom),
            Off.create(reason: :boom),
            Off.wrap(:boom, reason: :boom)
          ] do
        assert %Errata.Env{module: __MODULE__, line: line, stacktrace: nil} = error.env
        assert is_integer(line)
      end
    end

    test "an integer keeps only that many frames, innermost first" do
      full = Errata.create(Default).env.stacktrace
      assert length(full) > 2

      for error <- [
            Errata.create(TwoFrames),
            Errata.wrap(TwoFrames, :boom),
            TwoFrames.create(),
            TwoFrames.wrap(:boom)
          ] do
        assert [{__MODULE__, _, _, _}, _] = error.env.stacktrace
      end
    end

    test "applies when the module is only known at runtime" do
      module = Enum.random([Off])
      assert Errata.create(module).env.stacktrace == nil
      assert Errata.wrap(module, :boom).env.stacktrace == nil
    end

    test "does not touch the stacktrace of a wrapped cause" do
      error =
        try do
          raise "boom"
        rescue
          e -> Errata.wrap(Off, e, stacktrace: __STACKTRACE__)
        end

      assert error.env.stacktrace == nil
      assert [_ | _] = error.cause.stacktrace
    end

    test "rejects an invalid value at compile time" do
      for value <- [0, -1, :some, "3"] do
        assert_raise ArgumentError,
                     ~r/:capture_stacktrace .* must be a boolean or a positive/,
                     fn ->
                       Code.eval_quoted(
                         quote do
                           defmodule ErrataCaptureStacktraceTest.Invalid do
                             use Errata.DomainError, capture_stacktrace: unquote(value)
                           end
                         end
                       )
                     end
      end
    end
  end

  describe "config :errata, capture_stacktrace:" do
    test "applies to types that declare nothing" do
      with_global_setting(false, fn ->
        assert Errata.create(Default).env.stacktrace == nil
      end)

      with_global_setting(1, fn ->
        assert [{__MODULE__, _, _, _}] = Errata.create(Default).env.stacktrace
      end)
    end

    test "a type's own option takes precedence" do
      with_global_setting(false, fn ->
        assert [_, _] = Errata.create(TwoFrames).env.stacktrace
        assert [_ | _] = Errata.create(On).env.stacktrace
      end)
    end

    test "an invalid value raises when an error is created" do
      with_global_setting(:nope, fn ->
        assert_raise ArgumentError, ~r/config :errata, capture_stacktrace: must be/, fn ->
          Errata.create(Default)
        end
      end)
    end
  end
end
