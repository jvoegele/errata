defmodule Errata.Aggregate do
  @moduledoc """
  Errors that hold several other errors.

  Validation is the shape this exists for: a request fails and there are five
  reasons, all of which the caller needs. Modelling that as one error with a list
  of maps in `:context` throws away everything Errata is for — each sub-failure
  loses its type, code, HTTP status, severity, and retryability, and becomes
  inert data.

  An aggregate type keeps them as errors:

      defmodule MyApp.Orders.ValidationFailed do
        use Errata.DomainError, aggregate: true
      end

      ValidationFailed.new(errors: [email_error, age_error])

  The aggregate is itself an ordinary Errata error — `Errata.is_error/1` holds,
  it can be raised and returned in an `{:error, _}` tuple, and it serializes
  through `to_map/1` and the JSON encoders like any other. Its members serialize
  with it, each keeping its own type, code, and redaction rules.

  ## Members must be Errata errors

  Every member has to satisfy `Errata.is_error/1`; anything else raises
  `ArgumentError` when the aggregate is built. This is deliberate rather than
  incidental: the merge rules below are defined in terms of `severity/1`,
  `retryable?/1`, and `http_status/1`, and a bare map or a foreign exception
  cannot answer them. Wrap a foreign error in an Errata type first — that is what
  `Errata.wrap/3` is for.

  ## Merge rules

  An aggregate has to answer `severity/1`, `retryable?/1`, and `http_status/1`
  for a collection rather than one failure. The three do **not** merge the same
  way, because the right answer differs:

    * **`severity/1` — the most severe member.** Severities are totally ordered,
      so the maximum is unambiguous, and it is what a log level should be: if any
      member is `:error`, the aggregate is at least `:error`. Anything less would
      under-report a real failure.

    * **`retryable?/1` — retryable only if *every* member is.** Retrying the
      aggregate helps only if all of it could succeed next time. A single
      permanent failure makes the retry pointless, so the conservative reading is
      the correct one.

    * **`http_status/1` — the members' status if they all agree, otherwise the
      aggregate's own.** There is no meaningful maximum over status codes: 503 is
      numerically greater than 500 but that ordering means nothing, so picking a
      "highest" would be arbitrary. Unanimity is the only member-derived answer
      that is never wrong, and for a heterogeneous bag the container's declared
      status is the honest one.

  An aggregate with no members falls back to its own declared values for all
  three, since there is nothing to merge.

  Each of the three remains overridable per type, so a type that wants different
  rules — first member wins, say, or a fixed status regardless — just defines the
  function.
  """

  # `is_error/1` is a defguard, so it must be required to be called qualified.
  require Errata

  # Most to least severe. Kept in step with `Errata.Errors`' list of valid
  # `:severity` values.
  @severity_levels [
    :emergency,
    :alert,
    :critical,
    :error,
    :warning,
    :notice,
    :info,
    :debug
  ]

  @severity_rank @severity_levels |> Enum.with_index() |> Map.new()

  @doc """
  Returns the most severe severity among `errors`, or `fallback` when empty.
  """
  @spec severity([Errata.error()], Logger.level()) :: Logger.level()
  def severity([], fallback), do: fallback

  def severity(errors, _fallback) when is_list(errors) do
    Enum.min_by(errors, &Map.fetch!(@severity_rank, Errata.severity(&1)))
    |> Errata.severity()
  end

  @doc """
  Returns `true` only when every error in `errors` is retryable; `fallback` when
  empty.
  """
  @spec retryable?([Errata.error()], boolean()) :: boolean()
  def retryable?([], fallback), do: fallback

  def retryable?(errors, _fallback) when is_list(errors),
    do: Enum.all?(errors, &Errata.retryable?/1)

  @doc """
  Returns the HTTP status shared by every error in `errors`, or `fallback` when
  they disagree or the list is empty.
  """
  @spec http_status([Errata.error()], non_neg_integer()) :: non_neg_integer()
  def http_status([], fallback), do: fallback

  def http_status(errors, fallback) when is_list(errors) do
    case errors |> Enum.map(&Errata.http_status/1) |> Enum.uniq() do
      [status] -> status
      _disagree -> fallback
    end
  end

  @doc """
  Raises `ArgumentError` unless every member of `errors` is an Errata error.

  Returns the list unchanged when valid.
  """
  @spec validate_members!(term(), module()) :: [Errata.error()]
  def validate_members!(errors, error_type) when is_list(errors) do
    Enum.each(errors, fn member ->
      unless Errata.is_error(member) do
        raise ArgumentError,
              ":errors for #{inspect(error_type)} must contain only Errata errors, got: " <>
                "#{inspect(member)}. Wrap a foreign error in an Errata type first — see " <>
                "`Errata.wrap/3`."
      end
    end)

    errors
  end

  def validate_members!(other, error_type) do
    raise ArgumentError,
          ":errors for #{inspect(error_type)} must be a list of Errata errors, got: " <>
            inspect(other)
  end

  @doc """
  Appends a summary of `errors` to an aggregate's own `message`.

  The member messages are the actionable part of an aggregate — "validation
  failed" alone tells you nothing — so they are rendered inline rather than left
  for `to_map/1` to carry.
  """
  @spec format_message(String.t(), [Errata.error()]) :: String.t()
  def format_message(message, []), do: message

  def format_message(message, errors) when is_list(errors) do
    summary = "#{length(errors)} error(s): #{Enum.map_join(errors, "; ", &Exception.message/1)}"

    case message do
      "" -> summary
      message -> "#{message} (#{summary})"
    end
  end
end
