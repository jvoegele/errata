# Defined at the top level so their JSON encoder impls are consolidated; a module
# defined inside a test body would not be, and the JSON assertions would fail for
# a reason unrelated to aggregation.
defmodule ErrataAggregateTest.EmailInvalid do
  @moduledoc false
  use Errata.DomainError, code: "EMAIL_INVALID", default_message: "email is invalid"
end

defmodule ErrataAggregateTest.AgeInvalid do
  @moduledoc false
  use Errata.DomainError, code: "AGE_INVALID", default_message: "age must be positive"
end

defmodule ErrataAggregateTest.Warning do
  @moduledoc false
  use Errata.DomainError, severity: :warning, default_message: "just a warning"
end

defmodule ErrataAggregateTest.Critical do
  @moduledoc false
  use Errata.DomainError, severity: :critical, default_message: "critical"
end

defmodule ErrataAggregateTest.Transient do
  @moduledoc false
  use Errata.InfrastructureError, retryable: true, http_status: 503
end

defmodule ErrataAggregateTest.Secretive do
  @moduledoc false
  use Errata.DomainError, redact: [:password]
end

defmodule ErrataAggregateTest.ValidationFailed do
  @moduledoc false
  use Errata.DomainError, aggregate: true, default_message: "validation failed"
end

defmodule ErrataAggregateTest.Plain do
  @moduledoc false
  use Errata.DomainError
end

defmodule ErrataAggregateTest.CustomMerge do
  @moduledoc false
  use Errata.DomainError, aggregate: true

  # The merge rules are defaults, not law: a type can decide its own.
  def http_status(%{errors: [first | _]}), do: Errata.http_status(first)
  def http_status(_error), do: 422
end

defmodule ErrataAggregateTest do
  use ExUnit.Case

  require Errata

  alias ErrataAggregateTest.AgeInvalid
  alias ErrataAggregateTest.Critical
  alias ErrataAggregateTest.CustomMerge
  alias ErrataAggregateTest.EmailInvalid
  alias ErrataAggregateTest.Plain
  alias ErrataAggregateTest.Secretive
  alias ErrataAggregateTest.Transient
  alias ErrataAggregateTest.ValidationFailed
  alias ErrataAggregateTest.Warning, as: WarningError

  doctest Errata.Aggregate

  def handle_telemetry(_event, _measurements, metadata, pid), do: send(pid, {:meta, metadata})

  defp members, do: [EmailInvalid.new(reason: :format), AgeInvalid.new(reason: :negative)]

  describe "construction" do
    test "new/1 accepts member errors" do
      error = ValidationFailed.new(errors: members())

      assert length(error.errors) == 2
      assert [%EmailInvalid{}, %AgeInvalid{}] = error.errors
    end

    test "defaults to no members" do
      assert ValidationFailed.new().errors == []
    end

    test "create/1 accepts member errors and still captures the env" do
      require ValidationFailed
      error = ValidationFailed.create(errors: members())

      assert length(error.errors) == 2
      assert %Errata.Env{module: __MODULE__} = error.env
    end

    test "an aggregate is an ordinary Errata error" do
      error = ValidationFailed.new(errors: members())

      assert Errata.is_error(error)
      assert Errata.is_domain_error(error)
      assert %ValidationFailed{} = error
    end

    test "an aggregate can be raised and rescued" do
      assert_raise ValidationFailed, fn -> raise ValidationFailed, errors: members() end
    end
  end

  describe "member validation" do
    test "rejects a member that is not an Errata error" do
      assert_raise ArgumentError, ~r/must contain only Errata errors/, fn ->
        ValidationFailed.new(errors: [%{field: :email}])
      end
    end

    test "rejects a plain exception as a member" do
      assert_raise ArgumentError, ~r/must contain only Errata errors/, fn ->
        ValidationFailed.new(errors: [%RuntimeError{message: "nope"}])
      end
    end

    test "rejects a non-list" do
      assert_raise ArgumentError, ~r/must be a list of Errata errors/, fn ->
        ValidationFailed.new(errors: :nope)
      end
    end

    test "rejects :errors on a type that is not an aggregate" do
      # Without this, `struct/2` would silently drop the members on a type with no
      # `:errors` field — precisely the typo the param check exists to catch.
      assert_raise ArgumentError, ~r/invalid param key\(s\)/, fn ->
        Plain.new(errors: [])
      end
    end

    test "rejects a non-boolean :aggregate option" do
      assert_raise ArgumentError, ~r/:aggregate for .* must be true or false/, fn ->
        defmodule BadAggregateOpt do
          use Errata.DomainError, aggregate: :yes
        end
      end
    end
  end

  describe "severity merges to the most severe member" do
    test "all members equally severe" do
      error = ValidationFailed.new(errors: [WarningError.new(), WarningError.new()])
      assert Errata.severity(error) == :warning
    end

    test "the most severe member wins" do
      error = ValidationFailed.new(errors: [WarningError.new(), Critical.new()])
      assert Errata.severity(error) == :critical
    end

    test "order does not matter" do
      error = ValidationFailed.new(errors: [Critical.new(), WarningError.new()])
      assert Errata.severity(error) == :critical
    end

    test "an empty aggregate falls back to its own severity" do
      assert Errata.severity(ValidationFailed.new()) == :error
    end
  end

  describe "retryable? merges conservatively" do
    test "retryable only when every member is" do
      error = ValidationFailed.new(errors: [Transient.new(), Transient.new()])
      assert Errata.retryable?(error)
    end

    test "one non-retryable member makes the aggregate non-retryable" do
      error = ValidationFailed.new(errors: [Transient.new(), WarningError.new()])
      refute Errata.retryable?(error)
    end

    test "an empty aggregate falls back to its own retryability" do
      refute Errata.retryable?(ValidationFailed.new())
    end
  end

  describe "http_status merges by unanimity" do
    test "a status shared by every member is used" do
      error = ValidationFailed.new(errors: [Transient.new(), Transient.new()])
      assert Errata.http_status(error) == 503
    end

    test "members that disagree fall back to the aggregate's own status" do
      # 503 and 422: there is no meaningful maximum, so the container answers.
      error = ValidationFailed.new(errors: [Transient.new(), WarningError.new()])
      assert Errata.http_status(error) == 422
    end

    test "an empty aggregate falls back to its own status" do
      assert Errata.http_status(ValidationFailed.new()) == 422
    end
  end

  describe "merge rules are overridable" do
    test "a type can define its own" do
      error = CustomMerge.new(errors: [Transient.new(), WarningError.new()])

      # Default would be 422 (members disagree); this type takes the first member.
      assert Errata.http_status(error) == 503
    end
  end

  describe "message" do
    test "summarises the members after the aggregate's own message" do
      message = Exception.message(ValidationFailed.new(errors: members()))

      assert message =~ "validation failed"
      assert message =~ "2 error(s)"
      assert message =~ "email is invalid"
      assert message =~ "age must be positive"
    end

    test "an aggregate with no members reads as an ordinary error" do
      assert Exception.message(ValidationFailed.new()) == "validation failed"
    end

    test "with no message of its own, the summary stands alone" do
      message = Exception.message(ValidationFailed.new(message: nil, errors: members()))

      assert message =~ "2 error(s)"
      refute String.starts_with?(message, " (")
    end
  end

  describe "serialization" do
    test "to_map/1 includes the members, each keeping its type and code" do
      map = Errata.to_map(ValidationFailed.new(errors: members()))

      assert [email, age] = map.errors
      assert email.error_type == "ErrataAggregateTest.EmailInvalid"
      assert email.code == "EMAIL_INVALID"
      assert email.reason == :format
      assert age.code == "AGE_INVALID"
    end

    test "a non-aggregate has no :errors key at all" do
      refute Map.has_key?(Errata.to_map(Plain.new()), :errors)
    end

    test "JSON encoding includes the members" do
      json = Jason.encode!(ValidationFailed.new(errors: members()))

      assert json =~ "EMAIL_INVALID"
      assert json =~ "AGE_INVALID"
    end

    test "aggregates nest" do
      inner = ValidationFailed.new(errors: members())
      outer = ValidationFailed.new(errors: [inner])

      map = Errata.to_map(outer)

      assert [inner_map] = map.errors
      assert length(inner_map.errors) == 2
    end
  end

  describe "redaction of members" do
    setup do
      handler = "aggregate-redaction-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:errata, :error],
        &__MODULE__.handle_telemetry/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "a member's context is redacted in to_map/1" do
      member = Secretive.new(context: %{password: "hunter2"})
      map = Errata.to_map(ValidationFailed.new(errors: [member]))

      assert [%{context: %{password: "[REDACTED]"}}] = map.errors
    end

    test "a member's context is redacted inside the telemetry :error struct" do
      # Without this, a handler forwarding `metadata.error` would ship every
      # member's raw context — the same hole struct-level redaction closes, one
      # level down.
      member = Secretive.new(context: %{password: "hunter2"})
      assert Errata.report(ValidationFailed.new(errors: [member])) == :ok

      assert_receive {:meta, metadata}
      assert [%Secretive{context: %{password: "[REDACTED]"}}] = metadata.error.errors
    end

    test "redaction reaches members of nested aggregates" do
      member = Secretive.new(context: %{password: "hunter2"})
      inner = ValidationFailed.new(errors: [member])
      assert Errata.report(ValidationFailed.new(errors: [inner])) == :ok

      assert_receive {:meta, metadata}
      assert [%ValidationFailed{errors: [nested]}] = metadata.error.errors
      assert nested.context == %{password: "[REDACTED]"}
    end

    test "the error you hold locally still has the real value" do
      member = Secretive.new(context: %{password: "hunter2"})
      error = ValidationFailed.new(errors: [member])

      assert [%Secretive{context: %{password: "hunter2"}}] = error.errors
    end
  end

  describe "Errata.errors/1 and aggregate?/1" do
    test "errors/1 returns the members of an aggregate" do
      error = ValidationFailed.new(errors: members())
      assert length(Errata.errors(error)) == 2
    end

    test "errors/1 returns [] for an ordinary error, so callers need not branch" do
      assert Errata.errors(Plain.new()) == []
    end

    test "aggregate?/1 reflects the type, not the contents" do
      assert Errata.aggregate?(ValidationFailed.new())
      refute Errata.aggregate?(Plain.new())
    end

    test "both raise for a non-error" do
      assert_raise ArgumentError, fn -> Errata.errors(:nope) end
      assert_raise ArgumentError, fn -> Errata.aggregate?(:nope) end
    end
  end
end
