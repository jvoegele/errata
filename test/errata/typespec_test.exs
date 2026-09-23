defmodule Errata.TypespecTest do
  use ExUnit.Case, async: true

  use Errata
  alias MyApp.Orders.{OrderNotFound, PaymentDeclined}
  require PaymentDeclined

  # The generated `t/0`, rendered as source with the whitespace collapsed.
  defp t(module) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    Enum.find_value(types, fn
      {:type, {:t, _, []} = type} -> type |> Code.Typespec.type_to_quoted() |> to_source()
      _ -> nil
    end)
  end

  defp specs(module, name) do
    {:ok, specs} = Code.Typespec.fetch_specs(module)

    for {{^name, _arity}, clauses} <- specs,
        clause <- clauses,
        do: name |> Code.Typespec.spec_to_quoted(clause) |> to_source()
  end

  # Expand a call as this module would see it: `Errata` is required by
  # `use Errata` and `PaymentDeclined` by the `require` above.
  defp expand(call), do: call |> Macro.expand(__ENV__) |> to_source()

  defp to_source(quoted), do: quoted |> Macro.to_string() |> String.replace(~r/\s+/, " ")

  describe "the generated t/0" do
    test "names the module's own struct, so two types of one kind are distinct" do
      assert t(PaymentDeclined) =~ "t() :: %MyApp.Orders.PaymentDeclined{"
      assert t(OrderNotFound) =~ "t() :: %MyApp.Orders.OrderNotFound{"
      refute t(PaymentDeclined) == t(OrderNotFound)
    end

    test "spells out every field the kind-level types require, with the same types" do
      type = t(PaymentDeclined)

      assert type =~ "__exception__: true"
      assert type =~ "__errata_error__: true"
      assert type =~ "kind: :domain"
      assert type =~ "message: String.t() | nil"
      assert type =~ "reason: atom() | nil"
      assert type =~ "context: map() | nil"
      assert type =~ "cause: Errata.Cause.t() | nil"
      assert type =~ "env: Errata.Env.t() | nil"
      refute type =~ "errors:"
    end

    test "carries the kind" do
      assert t(MyApp.Http.RequestFailed) =~ "kind: :infrastructure"
      assert t(ErrataTypespecTest.General) =~ "kind: :general"
    end

    test "narrows reason to the declared reason/0 when there is one" do
      assert t(ErrataTypespecTest.Declared) =~ "reason: reason() | nil"
    end

    test "adds the errors field on an aggregate type" do
      assert t(ErrataTypespecTest.Aggregate) =~ "errors: [Errata.error()]"
    end
  end

  describe "the constructors" do
    test "new/0 and new/1 are specced to return t/0" do
      assert Enum.sort(specs(PaymentDeclined, :new)) == [
               "new() :: t()",
               "new(Errata.Error.params()) :: t()"
             ]
    end

    test "__errata_create__/3 and __errata_wrap__/4 are specced to return t/0" do
      assert specs(PaymentDeclined, :__errata_create__) == [
               "__errata_create__(Errata.Error.params(), Macro.Env.t(), Exception.stacktrace()) :: t()"
             ]

      assert specs(PaymentDeclined, :__errata_wrap__) == [
               "__errata_wrap__(term(), Errata.Error.params(), Macro.Env.t(), Exception.stacktrace()) :: t()"
             ]
    end

    test "the per-module create and wrap macros expand to the specced functions" do
      assert expand(quote(do: PaymentDeclined.create())) =~
               "MyApp.Orders.PaymentDeclined.__errata_create__(%{}, "

      assert expand(quote(do: PaymentDeclined.create(reason: :declined))) =~
               "MyApp.Orders.PaymentDeclined.__errata_create__([reason: :declined], "

      assert expand(quote(do: PaymentDeclined.wrap(:boom))) =~
               "MyApp.Orders.PaymentDeclined.__errata_wrap__(:boom, [], "

      assert expand(quote(do: PaymentDeclined.wrap(:boom, reason: :declined))) =~
               "MyApp.Orders.PaymentDeclined.__errata_wrap__(:boom, [reason: :declined], "
    end

    test "Errata.create/2 and Errata.wrap/3 do the same when the module is a literal" do
      for call <- [
            quote(do: Errata.create(PaymentDeclined)),
            quote(do: Errata.create(MyApp.Orders.PaymentDeclined, reason: :declined))
          ] do
        assert expand(call) =~ "MyApp.Orders.PaymentDeclined.__errata_create__("
      end

      for call <- [
            quote(do: Errata.wrap(PaymentDeclined, :boom)),
            quote(do: Errata.wrap(PaymentDeclined, :boom, reason: :declined))
          ] do
        assert expand(call) =~ "MyApp.Orders.PaymentDeclined.__errata_wrap__(:boom, "
      end
    end

    test "Errata.create/2 and Errata.wrap/3 go through Errata.Errors for a runtime module" do
      assert expand(quote(do: Errata.create(error_module, reason: :declined))) =~
               "Errata.Errors.create(error_module, "

      assert expand(quote(do: Errata.wrap(error_module, :boom))) =~
               "Errata.Errors.wrap(error_module, "
    end

    # Compiles `body` inside a fresh module and returns every diagnostic the
    # compiler emitted, so that the constructors' expansion is held to producing
    # none. A `%Module{} = ...` match in the expansion pinned the struct for
    # Dialyzer but made Elixir's type checker treat the result as static, and
    # reading `error.env.file` then warned because `:env` could not be inferred
    # precisely. The spec'd-function expansion keeps the result dynamic.
    defp diagnostics_for(body) do
      source = """
      defmodule ErrataTypespecProbe#{System.unique_integer([:positive])} do
        use Errata
        alias ErrataTypespecTest.Aggregate
        require Aggregate
        #{body}
      end
      """

      {_result, diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(source) end)
      Enum.map(diagnostics, & &1.message)
    end

    test "reading fields of a freshly built error is warning-free under the type checker" do
      assert diagnostics_for("""
             def f do
               e = Aggregate.create(errors: [])
               {e.env.file, e.env.line, length(e.errors), e.reason, e.cause}
             end

             def g do
               e = Errata.create(Aggregate, errors: [])
               {e.env.file, length(e.errors)}
             end

             def h do
               e = Errata.wrap(Aggregate, :boom, errors: [])
               {e.env.file, e.cause.value, length(e.errors)}
             end

             def i do
               e = Aggregate.wrap(:boom)
               {e.env.file, e.cause.value}
             end
             """) == []
    end

    test "every entry point builds the same error" do
      params = [reason: :declined, context: %{amount: 1}]
      expected = PaymentDeclined.new(params)
      error_module = PaymentDeclined

      for error <- [
            PaymentDeclined.create(params),
            Errata.create(PaymentDeclined, params),
            Errata.create(error_module, params)
          ] do
        assert %PaymentDeclined{env: %Errata.Env{module: __MODULE__}} = error
        assert %{error | env: nil} == expected
      end

      for error <- [
            PaymentDeclined.wrap(:boom, params),
            Errata.wrap(PaymentDeclined, :boom, params),
            Errata.wrap(error_module, :boom, params)
          ] do
        assert %PaymentDeclined{env: %Errata.Env{module: __MODULE__}} = error
        assert Errata.cause(error) == :boom
        assert error.reason == :declined
      end
    end
  end
end
