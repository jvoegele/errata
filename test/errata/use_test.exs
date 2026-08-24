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

  # A `use` option is written once, at type definition, so a misspelled one is a
  # permanent and invisible misconfiguration — the same defect class as #3, which
  # was fixed for `new/1`/`create/1` params but not here. See #62.
  describe "use option validation" do
    # Each of these defines a module inside the test body, which is fine: the
    # `use` is expected to raise before any protocol implementation is reached.
    defp define!(ast) do
      {{:module, module, _binary, _result}, _binding} = Code.eval_quoted(ast)
      module
    end

    test "rejects a misspelled option" do
      assert_raise ArgumentError, ~r/invalid option\(s\).*:htp_status/s, fn ->
        define!(
          quote do
            defmodule ErrataUseTest.Opts.Typo do
              use Errata.DomainError, htp_status: 404
            end
          end
        )
      end
    end

    test "rejects an entirely unrecognized option" do
      assert_raise ArgumentError, ~r/invalid option\(s\).*:reasonz/s, fn ->
        define!(
          quote do
            defmodule ErrataUseTest.Opts.Invented do
              use Errata.DomainError, reasonz: [:a]
            end
          end
        )
      end
    end

    test "reports every unknown option at once, and lists the valid ones" do
      error =
        assert_raise(ArgumentError, fn ->
          define!(
            quote do
              defmodule ErrataUseTest.Opts.ManyTypos do
                use Errata.Error, htp_status: 404, defualt_message: "oops", reasonz: [:a]
              end
            end
          )
        end)

      message = error.message

      assert message =~ ":htp_status"
      assert message =~ ":defualt_message"
      assert message =~ ":reasonz"
      assert message =~ ":default_message"
      assert message =~ ":http_status"
    end

    test "accepts every documented option" do
      define!(
        quote do
          defmodule ErrataUseTest.Opts.AllOpts do
            use Errata.Error,
              kind: :domain,
              default_reason: :a,
              default_message: "oops",
              reasons: [:a, :b],
              http_status: 404,
              code: "ALL_OPTS",
              severity: :warning,
              retryable: false,
              redact: [:password],
              aggregate: false
          end
        end
      )
    end

    test "rejects :kind on the per-kind entry points, and says where it belongs" do
      for entry_point <- [Errata.DomainError, Errata.InfrastructureError] do
        error =
          assert_raise(ArgumentError, fn ->
            define!(
              quote do
                defmodule unquote(Module.concat(ErrataUseTest.Opts.KindOn, entry_point)) do
                  use unquote(entry_point), kind: :general
                end
              end
            )
          end)

        message = error.message

        assert message =~ ":kind"
        assert message =~ "use Errata.Error"
      end
    end

    test "accepts :kind via use Errata.Error, and rejects an invalid value" do
      module =
        define!(
          quote do
            defmodule ErrataUseTest.Opts.KindOk do
              use Errata.Error, kind: :infrastructure
            end
          end
        )

      # `struct/1` rather than `KindOk.new()`: the module does not exist until
      # this test runs, so a direct call would warn at compile time. The kind is
      # a struct default set by the option under test, so this reads it directly.
      assert Errata.kind(struct(module)) == :infrastructure

      assert_raise ArgumentError, ~r/:kind.*must be one of.*got: :bogus/s, fn ->
        define!(
          quote do
            defmodule ErrataUseTest.Opts.KindBogus do
              use Errata.Error, kind: :bogus
            end
          end
        )
      end
    end
  end
end
