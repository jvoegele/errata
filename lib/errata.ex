defmodule Errata do
  @moduledoc """
  Errata provides support for creating custom error types, which can either be returned as error
  values or raised as exceptions.

  Errors fall into one of two general classifications:
  TODO: write better descriptions and link to the appropriate moduledocs

    * _Domain Errors_ represent error conditions within a problem domain or bounded context. These
      are business process violations or other errors in the problem domain, and therefore domain
      errors should be included in the Ubiquitous Language of the domain.
    * _Infrastructure Errors_ represent errors that can occur at an infrastructure level but which
      are not part of the problem domain.
  """

  @type error :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error_kind__: atom(),
          message: String.t() | nil,
          reason: atom() | nil,
          extra: map() | nil,
          env: Errata.Error.env()
        }

  @doc """
  Returns `true` if `term` is a type of `Errata.Error`; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_error(term)
           when is_struct(term) and
                  is_exception(term) and
                  is_map_key(term, :__errata_error_kind__) and
                  is_map_key(term, :message) and
                  is_map_key(term, :reason) and
                  is_map_key(term, :extra) and
                  is_map_key(term, :env)
end
