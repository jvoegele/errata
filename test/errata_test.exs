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
    defexception [:message, :reason, :extra, :env]
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
      refute is_error(message: "", reason: :because, extra: %{}, env: __ENV__)
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
      refute is_domain_error(message: "", reason: :because, extra: %{}, env: __ENV__)
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
      refute is_infrastructure_error(message: "", reason: :because, extra: %{}, env: __ENV__)
    end

    test "can be used in guard tests" do
      case TestInfrastructureError.new() do
        e when is_infrastructure_error(e) -> assert true
        _ -> flunk("expected is_infrastructure_error to be allowed in guard test")
      end
    end
  end
end
