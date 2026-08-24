# Fixture error types live at the top level of the file, above the test module,
# so their protocol implementations are consolidated. See CLAUDE.md.
defmodule ErrataToMapProjectionTest.Inner do
  @moduledoc false
  use Errata.InfrastructureError, default_message: "the upstream call failed", code: "UPSTREAM"
end

defmodule ErrataToMapProjectionTest.Outer do
  @moduledoc false
  use Errata.DomainError, default_message: "the order could not be placed", code: "ORDER_FAILED"
end

defmodule ErrataToMapProjectionTest.Invalid do
  @moduledoc false
  use Errata.DomainError, default_message: "the order is invalid", aggregate: true
end

defmodule ErrataToMapProjectionTest.Bare do
  @moduledoc false
  use Errata.DomainError
end

defmodule ErrataToMapProjectionTest do
  @moduledoc """
  Tests for `Errata.to_map/2`'s projection options and for the repo-relative
  source path on the wire (#63), plus the application-level display-message
  fallback (#64).
  """

  use ExUnit.Case, async: false

  require Errata

  alias ErrataToMapProjectionTest.Bare
  alias ErrataToMapProjectionTest.Inner
  alias ErrataToMapProjectionTest.Invalid
  alias ErrataToMapProjectionTest.Outer

  describe "to_map/2 :except" do
    test "drops the named keys" do
      map = Errata.to_map(Outer.new(reason: :declined), except: [:env, :context])

      refute Map.has_key?(map, :env)
      refute Map.has_key?(map, :context)
      assert map.code == "ORDER_FAILED"
      assert map.reason == :declined
    end

    test "reaches into a wrapped Errata cause" do
      inner = Inner.new(reason: :timeout)
      outer = Errata.wrap(Outer, inner, reason: :declined)

      # Both levels carry an :env before projection, which is the trap.
      full = Errata.to_map(outer)
      assert is_map(full.env) and full.env != %{}
      assert is_map(full.cause.env)

      projected = Errata.to_map(outer, except: [:env])
      refute Map.has_key?(projected, :env)
      refute Map.has_key?(projected.cause, :env)
      assert projected.cause.code == "UPSTREAM"
    end

    test "reaches into aggregate members" do
      aggregate =
        Errata.create(Invalid,
          reason: :invalid,
          errors: [Errata.create(Outer, reason: :declined)]
        )

      assert [member] = Errata.to_map(aggregate).errors
      assert is_map(member.env) and member.env != %{}

      assert [projected] = Errata.to_map(aggregate, except: [:env]).errors
      refute Map.has_key?(projected, :env)
    end

    test "leaves a non-Errata cause alone" do
      outer = Errata.wrap(Outer, %RuntimeError{message: "econnrefused"}, reason: :declined)
      projected = Errata.to_map(outer, except: [:env])

      assert projected.cause == %{error_type: "RuntimeError", message: "econnrefused"}
    end
  end

  describe "to_map/2 :only" do
    test "keeps just the named keys" do
      map = Errata.to_map(Outer.new(reason: :declined), only: [:code, :message, :retryable])

      assert Map.keys(map) |> Enum.sort() == [:code, :message, :retryable]
      assert map.message == "the order could not be placed"
    end

    test "applies to aggregate members too" do
      aggregate =
        Errata.create(Invalid, reason: :invalid, errors: [Outer.new(reason: :declined)])

      map = Errata.to_map(aggregate, only: [:code, :message, :errors])

      assert [member] = map.errors
      assert Map.keys(member) |> Enum.sort() == [:code, :message]
    end
  end

  describe "to_map/2 option validation" do
    test "to_map/1 is unchanged" do
      map = Errata.to_map(Outer.new(reason: :declined))

      assert Map.has_key?(map, :env)
      assert Map.has_key?(map, :context)
    end

    test "an empty option list is the full map" do
      error = Outer.new(reason: :declined)
      assert Errata.to_map(error, []) == Errata.to_map(error)
    end

    test "rejects :only and :except together" do
      assert_raise ArgumentError, ~r/but not both/, fn ->
        Errata.to_map(Outer.new(), only: [:code], except: [:env])
      end
    end

    test "rejects an unrecognized option" do
      assert_raise ArgumentError, ~r/invalid option\(s\).*:excpet/s, fn ->
        Errata.to_map(Outer.new(), excpet: [:env])
      end
    end

    test "rejects a misspelled key rather than silently selecting nothing" do
      assert_raise ArgumentError, ~r/invalid key\(s\).*:envv/s, fn ->
        Errata.to_map(Outer.new(), except: [:envv])
      end
    end

    test "rejects a non-list value" do
      assert_raise ArgumentError, ~r/must be a list of keys/, fn ->
        Errata.to_map(Outer.new(), except: :env)
      end
    end

    test "still raises on a non-Errata value" do
      assert_raise ArgumentError, ~r/expected an Errata error/, fn ->
        Errata.to_map(:oops, except: [:env])
      end
    end
  end

  describe "source path on the wire (#63)" do
    test "the emitted :file is relative to the project root" do
      error = Errata.create(Outer, reason: :declined)

      # The struct keeps the absolute path it was compiled with...
      assert String.starts_with?(error.env.file, "/")

      # ...but what crosses the wire is repo-relative.
      env = Errata.to_map(error).env
      assert env.file == "test/errata/to_map_projection_test.exs"
      assert env.file_line == "test/errata/to_map_projection_test.exs:#{env.line}"
      refute String.starts_with?(env.file, "/")
    end

    test "a JSON encoding carries no absolute build path" do
      json = Errata.to_map(Errata.create(Outer, reason: :declined)) |> inspect()
      refute json =~ File.cwd!()
    end
  end

  describe "default display message (#64)" do
    setup do
      on_exit(fn -> Application.delete_env(:errata, :default_display_message) end)
    end

    test "is nil by default, preserving pre-1.8 behaviour" do
      assert Errata.display_message(Bare.new(reason: :oops)) == nil
      assert Errata.to_map(Bare.new(reason: :oops)).message == nil
    end

    test "applies to a type that declares no :default_message" do
      Application.put_env(:errata, :default_display_message, "something went wrong")

      assert Errata.display_message(Bare.new(reason: :oops)) == "something went wrong"
      assert Errata.to_map(Bare.new(reason: :oops)).message == "something went wrong"
    end

    test "a declared :default_message wins over the global fallback" do
      Application.put_env(:errata, :default_display_message, "something went wrong")

      assert Errata.display_message(Outer.new()) == "the order could not be placed"
    end

    test "a per-error :message wins too" do
      Application.put_env(:errata, :default_display_message, "something went wrong")

      assert Errata.display_message(Bare.new(message: "specific")) == "specific"
    end

    test "does not affect the developer message" do
      Application.put_env(:errata, :default_display_message, "something went wrong")

      assert Exception.message(Bare.new(reason: :oops)) == ":oops"
    end
  end
end
