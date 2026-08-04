defmodule ErrataAccessorsTest.Sample do
  @moduledoc false
  use Errata.DomainError, code: "SAMPLE", default_message: "sample failed"
end

defmodule ErrataAccessorsTest.Infra do
  @moduledoc false
  use Errata.InfrastructureError
end

defmodule ErrataAccessorsTest do
  @moduledoc """
  Tests for the accessors added in #39, and for the compile-time behaviour the
  README now documents.

  The issue's premise was that Errata's structural guards are invisible to the
  set-theoretic checker, so the library's generic-handling idiom warns. Measured
  on the pinned toolchain, that is no longer the whole story: field access after a
  structural guard is clean, and the one shape that still warns — a variable bound
  by a bare `rescue e ->` — warns for *any* exception, not just an Errata one.
  The accessors are the idiomatic answer there.
  """

  use ExUnit.Case, async: true

  alias ErrataAccessorsTest.Infra
  alias ErrataAccessorsTest.Sample

  describe "reason/1" do
    test "returns the reason" do
      assert Errata.reason(Sample.new(reason: :not_found)) == :not_found
    end

    test "returns nil when there is none" do
      assert Errata.reason(Sample.new()) == nil
    end

    test "raises for a non-error" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn -> Errata.reason(:nope) end
    end
  end

  describe "context/1" do
    test "returns the context" do
      assert Errata.context(Sample.new(context: %{order_id: 42})) == %{order_id: 42}
    end

    test "returns an empty map rather than nil when there is none" do
      # So calling code can treat the result as a map unconditionally.
      assert Errata.context(Sample.new()) == %{}
    end

    test "returns the unredacted context" do
      # Redaction applies to what Errata serializes and emits, not to the error in
      # your own hands. The accessor reflects that.
      defmodule Secretive do
        @moduledoc false
        use Errata.DomainError, redact: [:password]
      end

      error = Secretive.new(context: %{password: "hunter2"})

      assert Errata.context(error) == %{password: "hunter2"}
      assert Errata.to_map(error).context == %{password: "[REDACTED]"}
    end

    test "raises for a non-error" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn -> Errata.context(:nope) end
    end
  end

  describe "kind/1" do
    test "returns the kind" do
      assert Errata.kind(Sample.new()) == :domain
      assert Errata.kind(Infra.new()) == :infrastructure
    end

    test "raises for a non-error" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn -> Errata.kind(:nope) end
    end
  end

  describe "the accessor set is complete" do
    test "every documented field has an accessor" do
      error = Sample.new(reason: :boom, context: %{a: 1})

      # The set the README points people at. `reason/1`, `context/1`, and `kind/1`
      # were the gaps.
      assert Errata.reason(error) == :boom
      assert Errata.context(error) == %{a: 1}
      assert Errata.kind(error) == :domain
      assert Errata.code(error) == "SAMPLE"
      assert Errata.severity(error) == :error
      assert Errata.http_status(error) == 422
      assert Errata.retryable?(error) == false
      assert Errata.cause(error) == nil
    end
  end

  describe "compile-time warning behaviour" do
    # These pin what the README claims. If a future Elixir changes any of them,
    # these fail and the docs get updated with them.
    defp warnings_for(body) do
      source = """
      defmodule ErrataWarnProbe#{System.unique_integer([:positive])} do
        require Errata
        #{body}
      end
      """

      {_result, diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(source) end)
      Enum.count(diagnostics, &String.contains?(&1.message, "unknown key"))
    end

    test "an accessor is warning-free inside a bare rescue" do
      assert warnings_for("""
             def f(fun) do
               fun.()
             rescue
               e -> Errata.reason(e)
             end
             """) == 0
    end

    # Elixir gained the set-theoretic type checker in 1.17; on 1.15 and 1.16 there
    # is nothing to emit these warnings, as the CI matrix confirmed. The advice
    # (use an accessor) is version-independent — only the diagnostic is not.
    @checker_present Version.match?(System.version(), ">= 1.17.0")

    test "direct field access inside a bare rescue does warn" do
      # The shape the accessors exist for.
      if @checker_present do
        assert warnings_for("""
               def f(fun) do
                 fun.()
               rescue
                 e -> e.reason
               end
               """) > 0
      end
    end

    test "the same warning occurs for a non-Errata exception" do
      # Which is why the README frames this as ordinary Elixir behaviour rather
      # than something Errata does to you.
      if @checker_present do
        assert warnings_for("""
               def f(fun) do
                 fun.()
               rescue
                 e -> e.message
               end
               """) > 0
      end
    end

    test "field access after a structural guard is warning-free" do
      # The case the old info box told people to work around with `Map.fetch!/2`.
      # Verified clean on every version the CI matrix covers, 1.15 through 1.20.
      assert warnings_for("def f({:error, e}) when Errata.is_error(e), do: e.reason") == 0
    end
  end
end
