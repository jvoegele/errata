defprotocol Errata.Convertible do
  @moduledoc """
  Converts a value that is not an Errata error into one.

  `Errata.to_error/2` dispatches through this protocol, which is how an
  application teaches Errata about the error shapes it receives from its
  dependencies: `Ecto.Changeset`, `DBConnection.ConnectionError`, a
  `Finch.Error`, or any other struct that arrives in an `{:error, _}` tuple.

  ## Why implement it

  Without an implementation, a foreign value normalizes to an
  `Errata.UnknownError` — HTTP status `500`, not retryable — with the original
  value kept as the cause. That is total, but it is not always _right_: a
  changeset is a `422`, and a connection timeout is a retryable `503`. An
  implementation is how a value gets the classification it deserves, so that
  the code reading `Errata.http_status/1` at a boundary does not need to know
  the value's type.

      defimpl Errata.Convertible, for: Ecto.Changeset do
        def to_error(changeset, _opts) do
          MyApp.ValidationFailed.new(
            reason: :invalid,
            context: %{errors: MyApp.Changeset.error_map(changeset)},
            cause: changeset
          )
        end
      end

  With that in place, `Errata.to_error(changeset)` returns an error whose status
  is the one `MyApp.ValidationFailed` declares, and the fallback controller
  clause that used to special-case changesets disappears.

  ## What Errata implements, and what it deliberately leaves to you

  Errata ships exactly one implementation, for `Any`. Every other type —
  including `Atom`, `BitString`, `Tuple`, `List` and `Map` — is left
  unimplemented on purpose: a protocol implementation can only be defined once,
  so any type Errata claimed would be a type an application could not claim
  without a redefinition warning.

  This is what makes the judgment calls yours. If `{:error, :timeout}` tuples
  should unwrap to their reason rather than normalize as a whole tuple, that is
  an implementation you write:

      defimpl Errata.Convertible, for: Tuple do
        def to_error({:error, reason}, opts), do: Errata.to_error(reason, opts)
        def to_error(other, opts), do: Errata.Convertible.Any.to_error(other, opts)
      end

  Note the second clause: delegating to the `Any` implementation is how an
  implementation handles the cases it has no opinion about, rather than having
  to reimplement the default.

  ## Implementations must return an Errata error

  `Errata.to_error/2` raises `ArgumentError` if an implementation returns
  anything else, so a faulty implementation fails at the conversion site rather
  than several accessor calls later.
  """

  @fallback_to_any true

  @doc """
  Converts `value` into an Errata error.

  Implementations receive the options passed to `Errata.to_error/2` and may
  interpret or ignore them. Implementations that build an error directly should
  keep the original `value` as the `:cause`, so that `Errata.root_cause/1` and
  `Errata.format_chain/1` can still reach it.
  """
  @spec to_error(t(), keyword()) :: Errata.error()
  def to_error(value, opts)
end

# The default conversion, used for any value with no implementation of its own:
# wrap it in `Errata.UnknownError` (or the type given by the `:fallback` option),
# keeping the original value as the cause. ExDoc does not publish implementation
# modules, so this is a comment rather than a `@moduledoc`; the behaviour is
# documented on the protocol above, where a reader will look for it.
defimpl Errata.Convertible, for: Any do
  def to_error(value, opts) do
    {fallback, opts} = Keyword.pop(opts, :fallback, Errata.UnknownError)

    Errata.Errors.normalize(fallback, value, opts)
  end
end
