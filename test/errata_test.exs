# The three modules defined below are declared here to support doctests in the README.md file
defmodule MyApp.SomeContext.MyDomainError do
  # Define a custom domain error in some context.
  use Errata.DomainError
end

defmodule MyApp.SomeContext.MyInfrastructureError do
  # Define a custom infrastructure error in some context.
  use Errata.InfrastructureError
end

defmodule MyApp.SomeContext.MyError do
  # Define a custom error in some context.
  use Errata.Error
end

defmodule ErrataTest do
  use ExUnit.Case

  import Errata

  doctest Errata

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
end
