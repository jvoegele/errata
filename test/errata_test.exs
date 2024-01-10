defmodule ErrataTest do
  use ExUnit.Case

  require Errata

  doctest Errata

  defmodule TestDomainError do
    use Errata.DomainError
  end

  defmodule NonErrataError do
    defexception [:message, :reason, :extra, :env]
  end

  describe "is_error/1" do
    test "returns true for domain errors" do
      assert Errata.is_error(TestDomainError.new())
      assert Errata.is_error(%TestDomainError{})
    end

    test "returns false for errors that are not Errata errors" do
      refute Errata.is_error(%RuntimeError{})
      refute Errata.is_error(%ArgumentError{})
    end

    test "returns false for errors that just look like Errata errors" do
      refute Errata.is_error(%NonErrataError{})
    end

    test "can be used in guard tests" do
      case TestDomainError.new() do
        e when Errata.is_error(e) -> assert true
        _ -> flunk("expected Errata.is_error to be allowed in guard test")
      end
    end
  end
end
