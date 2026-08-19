# Guards the code examples and factual claims in `guides/design.md`. The README
# examples are doctests, but the guide's examples are module definitions rather
# than `iex>` sessions, so they are pinned here instead. If one of these fails,
# the guide is wrong and should be corrected along with the code.
defmodule ErrataDesignGuideTest.Domain do
  @moduledoc false
  use Errata.DomainError
end

defmodule ErrataDesignGuideTest.Infrastructure do
  @moduledoc false
  use Errata.InfrastructureError
end

defmodule ErrataDesignGuideTest.General do
  @moduledoc false
  use Errata.Error
end

# "Treat the http_status/1 default as a starting point" — the guide's override.
defmodule ErrataDesignGuideTest.OrderNotFound do
  @moduledoc false
  use Errata.DomainError, http_status: 404
end

# The "External-service errors" section.
defmodule ErrataDesignGuideTest.GatewayUnavailable do
  @moduledoc false
  use Errata.InfrastructureError,
    default_message: "the payment gateway is unavailable",
    http_status: 502,
    code: "GATEWAY_UNAVAILABLE"
end

defmodule ErrataDesignGuideTest.CarrierTimeout do
  @moduledoc false
  use Errata.InfrastructureError
end

# The "Ignoring the taxonomy" section: no kind chosen, classifications explicit.
defmodule ErrataDesignGuideTest.TaxonomyFree do
  @moduledoc false
  use Errata.Error,
    default_message: "the requested order does not exist",
    http_status: 404,
    retryable: false
end

defmodule ErrataDesignGuideTest.Redacted do
  @moduledoc false
  use Errata.Error, redact: [:password]
end

defmodule ErrataDesignGuideTest.Aggregate do
  @moduledoc false
  use Errata.Error, aggregate: true, default_message: "validation failed"
end

# The ownership guard the guide offers in place of a fourth kind.
defmodule ErrataDesignGuideTest.Errors do
  @moduledoc false
  @external [ErrataDesignGuideTest.GatewayUnavailable, ErrataDesignGuideTest.CarrierTimeout]

  defguard is_external_error(term)
           when is_struct(term) and :erlang.map_get(:__struct__, term) in @external
end

defmodule ErrataDesignGuideTest.Boundary do
  @moduledoc false
  import ErrataDesignGuideTest.Errors

  def handle(error) when is_external_error(error), do: :open_circuit
  def handle(_error), do: :normal
end

# The "When the list gets long" subsection: definition-site tags via a wrapper
# macro, offered as the alternative to the hand-maintained list above.
defmodule ErrataDesignGuideTest.TaggedError do
  @moduledoc false

  defmacro __using__(opts) do
    {tags, errata_opts} = Keyword.pop(opts, :tags, [])
    {base, errata_opts} = Keyword.pop(errata_opts, :base, Errata.DomainError)

    quote do
      use unquote(base), unquote(errata_opts)

      def __tags__, do: unquote(tags)
    end
  end

  def tags(%mod{}) do
    if declares_tags?(mod), do: mod.__tags__(), else: []
  end

  def tagged?(error, tag), do: tag in tags(error)

  defp declares_tags?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__tags__, 0)
  end
end

defmodule ErrataDesignGuideTest.TaggedGatewayUnavailable do
  @moduledoc false
  use ErrataDesignGuideTest.TaggedError,
    base: Errata.InfrastructureError,
    tags: [:payments, :external],
    default_message: "the payment gateway is unavailable",
    code: "GATEWAY_UNAVAILABLE"
end

defmodule ErrataDesignGuideTest.UntaggedDomain do
  @moduledoc false
  use Errata.DomainError
end

defmodule ErrataDesignGuideTest do
  use ExUnit.Case, async: true

  import Errata

  alias ErrataDesignGuideTest.Aggregate
  alias ErrataDesignGuideTest.Boundary
  alias ErrataDesignGuideTest.Domain
  alias ErrataDesignGuideTest.GatewayUnavailable
  alias ErrataDesignGuideTest.General
  alias ErrataDesignGuideTest.Infrastructure
  alias ErrataDesignGuideTest.OrderNotFound
  alias ErrataDesignGuideTest.Redacted
  alias ErrataDesignGuideTest.TaxonomyFree

  describe "the \"what the kind decides\" table" do
    test "http_status defaults are 422 / 503 / 500" do
      assert Errata.http_status(Domain.new()) == 422
      assert Errata.http_status(Infrastructure.new()) == 503
      assert Errata.http_status(General.new()) == 500
    end

    test "retryable? defaults are false / true / false" do
      refute Errata.retryable?(Domain.new())
      assert Errata.retryable?(Infrastructure.new())
      refute Errata.retryable?(General.new())
    end

    test "severity defaults to :error for every kind, and does not derive from kind" do
      assert Errata.severity(Domain.new()) == :error
      assert Errata.severity(Infrastructure.new()) == :error
      assert Errata.severity(General.new()) == :error
    end

    test "code has no default" do
      assert Errata.code(Domain.new()) == nil
      assert Errata.code(Infrastructure.new()) == nil
      assert Errata.code(General.new()) == nil
    end

    test "the http_status default is overridable per type" do
      assert Errata.http_status(OrderNotFound.new()) == 404
      assert Errata.kind(OrderNotFound.new()) == :domain
    end
  end

  describe "external-service errors" do
    test "are infrastructure, retryable by default, with a specific status" do
      error = GatewayUnavailable.new(reason: :timeout)

      assert Errata.kind(error) == :infrastructure
      assert Errata.retryable?(error)
      assert Errata.http_status(error) == 502
      assert Errata.code(error) == "GATEWAY_UNAVAILABLE"
    end

    test "an application-defined ownership guard works in a function head" do
      assert Boundary.handle(GatewayUnavailable.new()) == :open_circuit
      assert Boundary.handle(ErrataDesignGuideTest.CarrierTimeout.new()) == :open_circuit
      assert Boundary.handle(Domain.new()) == :normal
      assert Boundary.handle(%RuntimeError{}) == :normal
    end

    test "definition-site tags are readable off any error" do
      alias ErrataDesignGuideTest.TaggedError
      alias ErrataDesignGuideTest.TaggedGatewayUnavailable

      error = TaggedGatewayUnavailable.new()

      assert TaggedError.tags(error) == [:payments, :external]
      assert TaggedError.tagged?(error, :external)
      refute TaggedError.tagged?(error, :shipping)
    end

    test "a type that declares no tags reports none rather than raising" do
      alias ErrataDesignGuideTest.TaggedError

      assert TaggedError.tags(ErrataDesignGuideTest.UntaggedDomain.new()) == []
      refute TaggedError.tagged?(ErrataDesignGuideTest.UntaggedDomain.new(), :external)
    end

    # The guide claims a tagged type is an ordinary Errata error "in every other
    # respect"; this is what that claim means concretely.
    test "a tagged type is unaffected as an Errata error" do
      alias ErrataDesignGuideTest.TaggedGatewayUnavailable

      error = TaggedGatewayUnavailable.new(reason: :down)

      assert Errata.is_error(error)
      assert Errata.is_infrastructure_error(error)
      assert Errata.kind(error) == :infrastructure
      assert Errata.http_status(error) == 503
      assert Errata.code(error) == "GATEWAY_UNAVAILABLE"
      assert Errata.retryable?(error)
      assert Errata.to_map(error).code == "GATEWAY_UNAVAILABLE"
    end
  end

  describe "ignoring the taxonomy" do
    test "a type defined with the base Errata.Error carries kind :general" do
      error = TaxonomyFree.new(reason: :not_found)

      assert Errata.kind(error) == :general
      assert Errata.http_status(error) == 404
      refute Errata.retryable?(error)
      assert is_error(error)
    end

    test "the kind guards are what is given up" do
      error = TaxonomyFree.new()

      refute is_domain_error(error)
      refute is_infrastructure_error(error)
    end

    test "status-range dispatch replaces the kind guards" do
      assert dispatch(TaxonomyFree.new()) == {:client, 404}
      assert dispatch(Infrastructure.new()) == {:server, 503}
    end

    test "redaction is unaffected by kind" do
      error = Redacted.new(context: %{password: "hunter2", user: "jv"})

      assert Errata.to_map(error).context == %{password: "[REDACTED]", user: "jv"}
    end

    test "aggregation is defined over the classification functions, not the kind" do
      aggregate = Aggregate.new(errors: [OrderNotFound.new(), GatewayUnavailable.new()])

      assert is_error(aggregate)
      # Members disagree on status, so the aggregate falls back to its own default.
      assert Errata.http_status(aggregate) == 500
      # Retryable only when every member is; the domain error is not.
      refute Errata.retryable?(aggregate)
    end
  end

  describe "the fallback controller example" do
    test "display_message/1 is nil for a type with no :default_message" do
      assert Errata.display_message(Domain.new()) == nil
      assert Errata.display_message(GatewayUnavailable.new()) =~ "payment gateway"
    end
  end

  defp dispatch(error) when is_error(error) do
    case Errata.http_status(error) do
      status when status < 500 -> {:client, status}
      status -> {:server, status}
    end
  end
end
