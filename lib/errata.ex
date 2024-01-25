defmodule Errata do
  @moduledoc """
  Errata provides support for creating custom error types, which can either be returned as error
  values or raised as exceptions.

  Errors fall into one of two general classifications:
  TODO: write better descriptions and link to the appropriate moduledocs

    * _Domain Errors_ represent error conditions within a problem domain or bounded context. These
      are business process violations or other errors in the problem domain, and therefore domain
      errors should be included as part of the Ubiquitous Language of the domain.
    * _Infrastructure Errors_ represent errors that can occur at an infrastructure level but which
      are not part of the problem domain. Infrastructure errors include such things as network
      timeouts, database connection failures, filesystem errors, etc.
  """

  @typedoc """
  Type to represent the various kinds of Errata errors.
  """
  @type error_kind :: :domain | :infrastructure

  @typedoc """
  Type to represent Errata domain errors.
  """
  @type domain_error :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error_kind__: :domain,
          message: String.t() | nil,
          reason: atom() | nil,
          extra: map() | nil,
          env: Errata.Env.t() | nil
        }

  @typedoc """
  Type to represent Errata infrastructure errors.
  """
  @type infrastructure_error :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error_kind__: :infrastructure,
          message: String.t() | nil,
          reason: atom() | nil,
          extra: map() | nil,
          env: Errata.Env.t() | nil
        }

  @typedoc """
  Type to represent any kind of Errata error.

  Errata errors are `Exception` structs that have additional fields to contain extra contextual
  information, such as an error reason or details about the context in which the error occurred.
  """
  @type error :: domain_error() | infrastructure_error()

  @doc """
  Returns `true` if `term` is a type of `Errata.Error`; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_error(term)
           when is_struct(term) and
                  is_exception(term) and
                  is_map_key(term, :__errata_error_kind__) and
                  :erlang.map_get(:__errata_error_kind__, term) in [:domain, :infrastructure] and
                  is_map_key(term, :message) and
                  is_map_key(term, :reason) and
                  is_map_key(term, :extra) and
                  is_map_key(term, :env)

  @doc """
  Returns `true` if `term` is a type of `Errata.DomainError`; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_domain_error(term)
           when is_error(term) and
                  :erlang.map_get(:__errata_error_kind__, term) == :domain

  @doc """
  Returns `true` if `term` is a type of `Errata.InfrastructureError`; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_infrastructure_error(term)
           when is_error(term) and
                  :erlang.map_get(:__errata_error_kind__, term) == :infrastructure
end
