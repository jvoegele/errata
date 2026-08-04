# Error types backing the redaction tests. Defined at the top level so their
# Jason.Encoder / JSON.Encoder protocol impls are picked up at compile time —
# a module defined inside a test body would not be consolidated, and the JSON
# assertions below would fail for a reason unrelated to redaction.
defmodule ErrataRedactionTest.LoginFailed do
  @moduledoc false
  use Errata.DomainError, redact: [:password, :token]
end

defmodule ErrataRedactionTest.Plain do
  @moduledoc false
  use Errata.DomainError
end

defmodule ErrataRedactionTest.CustomRules do
  @moduledoc false
  use Errata.InfrastructureError, redact: [:authorization]

  # Full control: drop a key entirely on top of the declared redaction.
  def redact_context(%{context: context}) do
    context
    |> Map.drop([:raw_response])
    |> Errata.Redaction.redact([:authorization])
  end
end

defmodule ErrataRedactionTest.User do
  @moduledoc false
  defstruct [:email, :password]
end

# Own log handler rather than reusing the one in errata_test.exs, so this file
# passes when run on its own.
defmodule ErrataRedactionTest.LogHandler do
  @moduledoc false
  def log(event, %{config: %{pid: pid}}), do: send(pid, {:log_event, event})
end

defmodule ErrataRedactionTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  # `is_error/1` is a defguard, so it needs the require to be callable qualified.
  require Errata

  alias Errata.Redaction
  alias ErrataRedactionTest.CustomRules
  alias ErrataRedactionTest.LoginFailed
  alias ErrataRedactionTest.Plain
  alias ErrataRedactionTest.User

  doctest Errata.Redaction

  def handle_telemetry(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp with_global_redact(keys, fun) do
    previous = Application.get_env(:errata, :redact)
    Application.put_env(:errata, :redact, keys)

    try do
      fun.()
    after
      if previous, do: Application.put_env(:errata, :redact, previous)
      unless previous, do: Application.delete_env(:errata, :redact)
    end
  end

  describe "Errata.Redaction.redact/2" do
    test "replaces declared keys at the top level" do
      assert Redaction.redact(%{user: "kim", password: "hunter2"}, [:password]) ==
               %{user: "kim", password: "[REDACTED]"}
    end

    test "recurses into nested maps — the case the feature exists for" do
      context = %{params: %{"email" => "kim@example.com", "password" => "hunter2"}}

      assert Redaction.redact(context, [:password]) ==
               %{params: %{"email" => "kim@example.com", "password" => "[REDACTED]"}}
    end

    test "matches atom and binary keys alike, in both directions" do
      assert Redaction.redact(%{"password" => "x"}, [:password]) == %{"password" => "[REDACTED]"}
      assert Redaction.redact(%{password: "x"}, ["password"]) == %{password: "[REDACTED]"}
    end

    test "recurses through lists and tuples" do
      context = %{users: [%{token: "a"}, %{token: "b"}], pair: {%{token: "c"}, :ok}}

      assert Redaction.redact(context, [:token]) ==
               %{
                 users: [%{token: "[REDACTED]"}, %{token: "[REDACTED]"}],
                 pair: {%{token: "[REDACTED]"}, :ok}
               }
    end

    test "redacts struct fields and returns a struct of the same type" do
      context = %{user: %User{email: "kim@example.com", password: "hunter2"}}
      redacted = Redaction.redact(context, [:password])

      assert %User{email: "kim@example.com", password: "[REDACTED]"} = redacted.user
    end

    test "leaves the term untouched when no keys are declared" do
      context = %{password: "hunter2"}
      assert Redaction.redact(context, []) == context
    end

    test "leaves non-matching values untouched" do
      context = %{count: 1, ok?: true, nested: %{list: [1, 2, 3]}}
      assert Redaction.redact(context, [:password]) == context
    end

    test "global_keys/0 defaults to an empty list" do
      assert Redaction.global_keys() == []
    end
  end

  describe "declared :redact keys" do
    test "the error struct itself keeps the real values for local debugging" do
      error = LoginFailed.new(context: %{password: "hunter2"})
      assert error.context == %{password: "hunter2"}
    end

    test "to_map/1 redacts, including nested occurrences" do
      error =
        LoginFailed.new(
          reason: :bad_credentials,
          context: %{params: %{"password" => "hunter2"}, token: "t0ken", user: "kim"}
        )

      assert LoginFailed.to_map(error).context == %{
               params: %{"password" => "[REDACTED]"},
               token: "[REDACTED]",
               user: "kim"
             }
    end

    test "JSON encoding is redacted" do
      error = LoginFailed.new(context: %{password: "hunter2"})
      json = Jason.encode!(error)

      assert json =~ "[REDACTED]"
      refute json =~ "hunter2"
    end

    test "an error type with no :redact option is unchanged" do
      error = Plain.new(context: %{password: "hunter2"})
      assert Plain.to_map(error).context == %{password: "hunter2"}
    end

    test "a non-encodable sensitive value is redacted rather than inspected through" do
      # Without redacting first, the JSON-encodability pass would `inspect/1` the
      # pid/function into a string and carry the value out that way.
      error = LoginFailed.new(context: %{password: fn -> "hunter2" end})
      assert LoginFailed.to_map(error).context == %{password: "[REDACTED]"}
    end
  end

  describe "global redaction config" do
    test "applies to every error type, including those declaring nothing" do
      error = Plain.new(context: %{password: "hunter2"})

      with_global_redact([:password], fn ->
        assert Plain.to_map(error).context == %{password: "[REDACTED]"}
      end)
    end

    test "composes with declared keys rather than replacing them" do
      error = LoginFailed.new(context: %{password: "p", token: "t", secret: "s"})

      with_global_redact([:secret], fn ->
        assert LoginFailed.to_map(error).context == %{
                 password: "[REDACTED]",
                 token: "[REDACTED]",
                 secret: "[REDACTED]"
               }
      end)
    end

    test "is read at call time, so config changes need no recompile" do
      error = Plain.new(context: %{password: "hunter2"})
      assert Plain.to_map(error).context == %{password: "hunter2"}

      with_global_redact([:password], fn ->
        assert Plain.to_map(error).context == %{password: "[REDACTED]"}
      end)

      assert Plain.to_map(error).context == %{password: "hunter2"}
    end
  end

  describe "overriding redact_context/1" do
    test "the override governs every serialization seam" do
      error =
        CustomRules.new(context: %{authorization: "Bearer x", raw_response: "big", id: 7})

      assert CustomRules.to_map(error).context == %{authorization: "[REDACTED]", id: 7}
    end
  end

  describe "Errata.log/2" do
    test "logs redacted context as metadata" do
      assert :ok =
               :logger.add_handler(:errata_redaction_log, ErrataRedactionTest.LogHandler, %{
                 config: %{pid: self()},
                 level: :all
               })

      on_exit(fn -> :logger.remove_handler(:errata_redaction_log) end)

      error = LoginFailed.new(message: "m", reason: :boom, context: %{password: "hunter2"})
      capture_log(fn -> assert Errata.log(error, :warning) == :ok end)

      assert_received {:log_event, event}
      assert event.meta.context == %{password: "[REDACTED]"}
    end
  end

  describe "Errata.report/2" do
    setup do
      handler_id = "errata-redaction-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:errata, :error],
        &__MODULE__.handle_telemetry/4,
        %{pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "redacts the :context metadata key" do
      error = LoginFailed.new(context: %{password: "hunter2"})
      assert Errata.report(error) == :ok

      assert_received {:telemetry_event, [:errata, :error], _measurements, metadata}
      assert metadata.context == %{password: "[REDACTED]"}
    end

    test "redacts the :error struct too, so a forwarding handler can't leak it" do
      # The whole error struct is in telemetry metadata. A handler doing
      # `Sentry.capture(metadata.error)` would otherwise ship the raw context and
      # make redaction pointless in exactly the case it exists for.
      error = LoginFailed.new(context: %{password: "hunter2"})
      assert Errata.report(error) == :ok

      assert_received {:telemetry_event, [:errata, :error], _measurements, metadata}
      assert metadata.error.context == %{password: "[REDACTED]"}
    end

    test "the :error metadata is still the same error type, matchable and raisable" do
      error =
        LoginFailed.new(message: "nope", reason: :bad_credentials, context: %{password: "p"})

      assert Errata.report(error) == :ok

      assert_received {:telemetry_event, [:errata, :error], _measurements, metadata}
      assert %LoginFailed{reason: :bad_credentials} = metadata.error
      assert Errata.is_error(metadata.error)
      assert_raise LoginFailed, fn -> raise metadata.error end
    end
  end

  describe "invalid :redact option" do
    test "rejects a non-list" do
      assert_raise ArgumentError, ~r/:redact for .* must be a list/, fn ->
        defmodule BadRedactNotAList do
          use Errata.DomainError, redact: :password
        end
      end
    end

    test "rejects a list containing a non-atom, non-string" do
      assert_raise ArgumentError, ~r/:redact for .* must be a list/, fn ->
        defmodule BadRedactBadMember do
          use Errata.DomainError, redact: [:password, 42]
        end
      end
    end
  end
end
