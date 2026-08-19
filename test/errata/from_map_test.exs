# Defined at the top level so their String.Chars / JSON encoder protocol impls
# are consolidated at compile time; a module defined inside a test body does not
# get consolidated impls, and the JSON assertions below would fail for unrelated
# reasons.
defmodule FromMap.Declared do
  @moduledoc false
  use Errata.DomainError,
    default_message: "the order does not exist",
    reasons: [:not_found, :archived],
    code: "ORDER_NOT_FOUND"
end

defmodule FromMap.Open do
  @moduledoc false
  use Errata.InfrastructureError, default_message: "the upstream call failed"
end

defmodule FromMap.Computed do
  @moduledoc false
  use Errata.InfrastructureError, reasons: [:timeout, :refused]

  def http_status(%{reason: :timeout}), do: 504
  def http_status(_error), do: 503
end

defmodule FromMap.Aggregate do
  @moduledoc false
  use Errata.DomainError, aggregate: true
end

defmodule FromMap.Redacted do
  @moduledoc false
  use Errata.DomainError, redact: [:password]
end

defmodule Errata.FromMapTest do
  use ExUnit.Case, async: true

  require Errata

  alias FromMap.Aggregate
  alias FromMap.Computed
  alias FromMap.Declared
  alias FromMap.Open
  alias FromMap.Redacted

  describe "from_map/3 round trip" do
    test "restores reason, message and context" do
      error = Declared.new(reason: :not_found, context: %{order_id: 42})

      assert {:ok, decoded} = Errata.from_map(Declared, Errata.to_map(error))

      assert decoded.__struct__ == Declared
      assert Errata.reason(decoded) == :not_found
      assert Errata.display_message(decoded) == "the order does not exist"
      assert Errata.context(decoded) == %{"order_id" => 42}
    end

    test "accepts the atom-keyed map from to_map/1 and the string-keyed map from JSON" do
      error = Declared.new(reason: :archived)

      from_atoms = Errata.from_map(Declared, Errata.to_map(error))
      from_json = Errata.from_map(Declared, error |> Jason.encode!() |> Jason.decode!())

      assert {:ok, a} = from_atoms
      assert {:ok, j} = from_json
      assert Errata.reason(a) == Errata.reason(j)
      assert Errata.display_message(a) == Errata.display_message(j)
    end

    test "the decoded error satisfies the guards and matches its concrete type" do
      {:ok, decoded} = Errata.from_map(Declared, Errata.to_map(Declared.new(reason: :not_found)))

      assert Errata.is_error(decoded)
      assert Errata.is_domain_error(decoded)
      refute Errata.is_infrastructure_error(decoded)
      assert match?(%Declared{}, decoded)
    end

    test "falls back to the type's defaults when the encoded form has no reason" do
      {:ok, decoded} = Errata.from_map(Open, %{})

      assert Errata.reason(decoded) == nil
      assert Errata.display_message(decoded) == "the upstream call failed"
    end
  end

  describe "from_map/3 fidelity limits" do
    # `:env` describes a location in the *sending* process. Carrying it over would
    # attach a plausible-looking file and line that mean nothing here.
    test "env is always nil, even when the encoded form carries one" do
      require Errata
      error = Errata.create(Declared, reason: :not_found)

      assert %Errata.Env{} = error.env
      assert {:ok, decoded} = Errata.from_map(Declared, Errata.to_map(error))
      assert decoded.env == nil
    end

    test "classification is recomputed locally, not read from the encoded form" do
      encoded =
        Computed.new(reason: :timeout)
        |> Errata.to_map()
        |> Map.merge(%{http_status: 999, severity: :debug, retryable: false, kind: :domain})

      assert {:ok, decoded} = Errata.from_map(Computed, encoded)

      assert Errata.http_status(decoded) == 504
      assert Errata.severity(decoded) == :error
      assert Errata.retryable?(decoded) == true
      assert Errata.kind(decoded) == :infrastructure
    end

    test "the cause is kept as the decoded value rather than rebuilt into an error" do
      error = Declared.new(reason: :not_found, cause: Open.new(reason: :timeout))

      assert {:ok, decoded} = Errata.from_map(Declared, Errata.to_map(error))

      cause = Errata.cause(decoded)
      refute Errata.is_error(cause)
      assert cause["error_type"] || cause[:error_type]
    end

    test "context redacted on the way out stays redacted" do
      error = Redacted.new(context: %{password: "hunter2", user: "kim"})

      assert {:ok, decoded} = Errata.from_map(Redacted, Errata.to_map(error))

      assert Errata.context(decoded)["password"] == "[REDACTED]"
      assert Errata.context(decoded)["user"] == "kim"
    end
  end

  describe "from_map/3 reason decoding" do
    # A declared :reasons set makes decoding a lookup against atoms that already
    # exist, so nothing from the wire is ever passed to String.to_atom/1.
    test "a declared reason is matched against the declared set" do
      assert {:ok, decoded} = Errata.from_map(Declared, %{"reason" => "archived"})
      assert Errata.reason(decoded) == :archived
    end

    test "a reason outside the declared set is rejected" do
      assert Errata.from_map(Declared, %{"reason" => "not_a_declared_reason"}) ==
               {:error, {:unknown_reason, "not_a_declared_reason"}}
    end

    # The declared set is the authority, not "does this atom happen to exist".
    # `:timeout` is a perfectly good atom in this VM but is not one of Declared's
    # reasons, so it must be refused — and refused cleanly, as an {:error, _}
    # rather than the ArgumentError that construction would raise. Decoding via
    # String.to_existing_atom/1 instead would accept it here and blow up later.
    test "rejects a reason whose atom exists but is not declared" do
      assert :timeout == String.to_existing_atom("timeout")

      assert Errata.from_map(Declared, %{"reason" => "timeout"}) ==
               {:error, {:unknown_reason, "timeout"}}
    end

    test "an undeclared type accepts any reason whose atom already exists" do
      assert {:ok, decoded} = Errata.from_map(Open, %{"reason" => "timeout"})
      assert Errata.reason(decoded) == :timeout
    end

    test "an undeclared type rejects a reason with no existing atom" do
      assert {:error, {:unknown_reason, unknown}} =
               Errata.from_map(Open, %{"reason" => "no_atom_by_this_name_exists_anywhere_1234"})

      assert unknown == "no_atom_by_this_name_exists_anywhere_1234"
    end

    test "rejects a reason that is neither a string nor an atom" do
      assert Errata.from_map(Open, %{"reason" => 42}) == {:error, {:invalid_reason, 42}}
    end
  end

  describe "from_map/3 :keys option" do
    # Both modes rewrite keys, so the result depends only on the option — a map
    # straight from `to_map/1` (atom keys) decodes to the same shape as the same
    # map after a JSON round trip (string keys).
    test "defaults to string keys, whatever the input had" do
      from_to_map = Errata.to_map(Declared.new(context: %{order_id: 42}))
      from_json = Declared.new(context: %{order_id: 42}) |> Jason.encode!() |> Jason.decode!()

      assert {:ok, a} = Errata.from_map(Declared, from_to_map)
      assert {:ok, b} = Errata.from_map(Declared, from_json)

      assert Errata.context(a) == %{"order_id" => 42}
      assert Errata.context(b) == %{"order_id" => 42}
    end

    test ":existing_atoms converts keys that already exist, recursively" do
      encoded = %{"context" => %{"order_id" => 1, "nested" => %{"order_id" => 2}}}

      assert {:ok, decoded} = Errata.from_map(Declared, encoded, keys: :existing_atoms)

      assert Errata.context(decoded) == %{order_id: 1, nested: %{order_id: 2}}
    end

    test ":existing_atoms leaves a key with no existing atom as a string" do
      encoded = %{"context" => %{"order_id" => 1, "no_atom_named_this_5678" => 2}}

      assert {:ok, decoded} = Errata.from_map(Declared, encoded, keys: :existing_atoms)

      assert Errata.context(decoded) == %{"no_atom_named_this_5678" => 2, order_id: 1}
    end

    test ":existing_atoms recurses through lists" do
      encoded = %{"context" => %{"items" => [%{"order_id" => 1}, %{"order_id" => 2}]}}

      assert {:ok, decoded} = Errata.from_map(Declared, encoded, keys: :existing_atoms)

      assert Errata.context(decoded) == %{items: [%{order_id: 1}, %{order_id: 2}]}
    end

    test "rejects an unknown :keys value" do
      assert Errata.from_map(Declared, %{}, keys: :atoms) ==
               {:error, {:invalid_option, {:keys, :atoms}}}
    end
  end

  describe "from_map/3 rejections" do
    test "rejects a non-map" do
      assert Errata.from_map(Declared, "not a map") == {:error, {:invalid_map, "not a map"}}
      assert Errata.from_map(Declared, nil) == {:error, {:invalid_map, nil}}
    end

    # Members carry their type only as a name; resolving those is the registry
    # that taking the type as an argument exists to avoid.
    test "refuses an aggregate type rather than silently dropping its members" do
      assert Errata.from_map(Aggregate, %{}) == {:error, {:unsupported, :aggregate}}
    end

    # A bad module is a programming error, not bad data, so it raises in both
    # variants rather than becoming an {:error, _} the caller has to handle.
    test "raises when given something that is not an Errata error type" do
      assert_raise ArgumentError, ~r/the error type must be an Errata error type/, fn ->
        Errata.from_map(RuntimeError, %{})
      end

      assert_raise ArgumentError, ~r/the error type must be an Errata error type/, fn ->
        Errata.from_map(:not_a_module, %{})
      end
    end
  end

  describe "from_map!/3" do
    test "returns the error directly" do
      encoded = Errata.to_map(Declared.new(reason: :not_found))

      assert %Declared{} = error = Errata.from_map!(Declared, encoded)
      assert Errata.reason(error) == :not_found
    end

    test "raises with a message naming the type and the problem" do
      assert_raise ArgumentError, ~r/could not decode FromMap.Declared/, fn ->
        Errata.from_map!(Declared, %{"reason" => "nope"})
      end
    end

    test "explains why an aggregate cannot be decoded" do
      assert_raise ArgumentError, ~r/aggregate error types cannot be decoded/, fn ->
        Errata.from_map!(Aggregate, %{})
      end
    end
  end

  describe "a full boundary round trip" do
    test "an error survives JSON in both directions and answers the same questions" do
      original = Computed.new(reason: :timeout, context: %{url: "https://example.com"})

      decoded =
        original
        |> Jason.encode!()
        |> Jason.decode!()
        |> then(&Errata.from_map!(Computed, &1, keys: :existing_atoms))

      assert Errata.reason(decoded) == Errata.reason(original)
      assert Errata.http_status(decoded) == Errata.http_status(original)
      assert Errata.retryable?(decoded) == Errata.retryable?(original)
      assert Errata.severity(decoded) == Errata.severity(original)
      assert Errata.context(decoded) == Errata.context(original)
      assert Errata.code(decoded) == Errata.code(original)
    end
  end
end
