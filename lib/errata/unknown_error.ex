defmodule Errata.UnknownError do
  @moduledoc """
  The error type that `Errata.to_error/2` produces for values it does not
  recognize.

  This is the only concrete error type Errata itself defines. It exists so that
  normalization is zero-configuration: an application (or a library built on
  Errata) can call `Errata.to_error/1` without first having to declare a
  catch-all error type of its own.

  It is an ordinary `:general` error, and so takes the defaults for that kind:
  HTTP status `500`, severity `:error`, and not retryable. That is the honest
  classification for a value nothing knows anything about — if a more specific
  classification is possible, the value is not really unknown, and the way to
  say so is an `Errata.Convertible` implementation or the `:fallback` option.

      iex> error = Errata.to_error(:enoent)
      iex> error.__struct__
      Errata.UnknownError
      iex> Errata.http_status(error)
      500
      iex> Errata.retryable?(error)
      false

  The original value is preserved as the error's cause, so nothing is lost by
  normalizing:

      iex> Errata.to_error(:enoent) |> Errata.root_cause()
      :enoent

  Applications that would rather see their own type at the end of the chain can
  pass one: `Errata.to_error(value, fallback: MyApp.UnexpectedError)`.
  """

  use Errata.Error, default_message: "an unexpected error occurred"
end
