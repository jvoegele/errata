defmodule ErrataUseTest do
  use ExUnit.Case

  # This module deliberately does NOT `import Errata` — it relies solely on
  # `use Errata` to bring the guards into scope (and, via the implied `require`,
  # to make the qualified `create/2` and `wrap/3` macros callable). That is the
  # whole point of the macro under test, so importing Errata here would defeat it.
  use Errata

  defmodule UseDomainError do
    use Errata.DomainError
  end

  defmodule UseInfraError do
    use Errata.InfrastructureError
  end

  # The guards must be usable unqualified in a function head, not just inline.
  defp classify(e) when is_domain_error(e), do: :domain
  defp classify(e) when is_infrastructure_error(e), do: :infrastructure
  defp classify(e) when is_error(e), do: :error
  defp classify(_), do: :other

  describe "use Errata" do
    test "brings the guards into scope unqualified" do
      assert is_error(UseDomainError.new())
      assert is_domain_error(UseDomainError.new())
      assert is_infrastructure_error(UseInfraError.new())
      refute is_domain_error(UseInfraError.new())
      refute is_error(%RuntimeError{})
    end

    test "guards work unqualified in a function head" do
      assert classify(UseDomainError.new()) == :domain
      assert classify(UseInfraError.new()) == :infrastructure
      assert classify(%RuntimeError{}) == :other
    end

    test "the implied require makes the qualified create/2 and wrap/3 macros callable" do
      error = Errata.create(UseDomainError, reason: :boom)
      assert is_domain_error(error)
      assert %Errata.Env{module: __MODULE__} = error.env

      wrapped = Errata.wrap(UseDomainError, %RuntimeError{message: "x"}, reason: :boom)
      assert Errata.cause(wrapped) == %RuntimeError{message: "x"}
    end
  end
end
