defmodule Errata do
  @moduledoc """
  Errata provides support for creating custom structured error types, which can either be
  returned as error values or raised as exceptions.

  Errata errors are named, structured types that represent error conditions in an application
  or library. Being named types means that errors have a unique, meaningful name within a
  particular context. Being structured types means that errors have a well-defined, consistent
  structure identifying the nature of the error, and can also have arbitrary contextual
  information attached to them for logging or debugging purposes.

  Errata errors fall into one of three general classifications:

    * _Domain Errors_ represent error conditions within a problem domain or bounded context. These
      are business process violations or other errors in the problem domain, and therefore domain
      errors should be included as part of the
      [Ubiquitous Language](https://martinfowler.com/bliki/UbiquitousLanguage.html) of the domain.
    * _Infrastructure Errors_ represent errors that can occur at an infrastructure level but which
      are not part of the problem domain. Infrastructure errors include such things as network
      timeouts, database connection failures, filesystem errors, etc.
    * _General Errors_ represent errors that do not fall into either of the above categories.
      General errors can include errors that emanate from library code (as opposed to application
      code) or any other sort of error condition for which there is no need to distinguish based
      on classification.

  ## Defining custom error types

  Errata makes it easy to define custom error types for applications or libraries. The following
  examples demonstrate how to define domain errors, infrastructure errors, and general errors.

  ```elixir
  defmodule MyApp.SomeContext.MyDomainError do
    # Define a custom domain error type in some context.
    use Errata.DomainError
  end

  defmodule MyApp.SomeContext.MyInfrastructureError do
    # Define a custom infrastructure error type in some context.
    use Errata.InfrastructureError
  end

  defmodule MyApp.SomeContext.MyError do
    # Define a custom error type in some context.
    use Errata.Error
  end
  ```

  Each of these custom error types will define an exception struct that conforms to the
  `t:Errata.error/0` type and will implement the `Errata.Error` behaviour. Additionally,
  implementations for the `String.Chars` protocol and the `Jason.Encoder` protocol are ptovided
  so that these errors can be converted to string form or encoded as JSON automatically.

  ## Raising Errata errors as exceptions

  Since Errata errors are just regular Elixir exceptions with a well-defined structure, they can
  be raised just like any other type of exception.

  ## Using Errata errors as return values

  Errata errors can be created by using the `new/1` or `create/1` functions for the error type.
  Once created, they can be used as return values from functions, preferably wrapped in an error
  tuple. This approach allows for creating errors with full contextual details at the site of the 
  error, while separating the handling of errors.

  ## Handling Errata errors

  Since error types defined using Errata are standard Elixir exceptions, they can be handled in
  the same way as any other exception. Specifically, they can be used in the `rescue` clause of
  a `try` block or function, and the `Kernel.is_exception/1` guard will always return `true`
  for them. Additionally, Errata provides custom guards for handling Errata error types
  specifically:

    * `Errata.is_error/1`
    * `Errata.is_domain_error/1`
    * `Errata.is_infrastructure_error/1`

  To use these custom guards, `import` or `require` the `Errata` module.

  The following example demonstrates handling Errata errors both as raised exceptions and as
  error values returned from functions.

  ```elixir
  defmodule MyApp.SomeContext do
    # require the Errata module to use the custom guards
    require Errata

    def handle_errata_error_as_exception do
      try do
        function_that_raises_errata_error!()
      rescue
        e in [MyApp.SomeContext.MyDomainError] ->
          # Errata errors can be rescued by their specific type
          handle_my_domain_error(e)

        e when Errata.is_error(e) ->
          # Or they can be rescued using one of the custom guards defined in the Errata module
          handle_errata_error(e)

        e ->
          # Regular exceptions may be handled separately if desired
          handle_other_error(e)
      end
    end

    def handle_errata_error_as_value do
      case function_that_returns_errata_error_as_value() do
        {:ok, result} ->
          handle_ok_result(result)

        {:error, %MyApp.SomeContext.MyDomainError{} = error} ->
          # Errata errors can be pattern matched by their specific type
          handle_my_domain_error(error)

        {:error, error} when Errata.is_error(error) ->
          # Or they can be identified using one of the custom guards defined in the Errata module
          handle_errata_error(e)

        {:error, reason} ->
          # Other errors may be handled separately if desired
          handle_other_error(reason)
      end
    end
  end
  ```
  """

  @typedoc """
  Type to represent the various kinds of Errata errors.
  """
  @type error_kind :: :domain | :infrastructure | :general | nil

  @typedoc """
  Type to represent any kind of Errata error.

  Errata errors are `Exception` structs that have additional fields to contain extra contextual
  information, such as an error reason or details about the context in which the error occurred.
  """
  @type error :: Errata.Error.t()

  @typedoc """
  Type to represent Errata domain errors.
  """
  @type domain_error :: Errata.DomainError.t()

  @typedoc """
  Type to represent Errata infrastructure errors.
  """
  @type infrastructure_error :: Errata.InfrastructureError.t()

  @doc """
  Returns `true` if `term` is any Errata error type; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_error(term)
           when is_struct(term) and
                  is_exception(term) and
                  is_map_key(term, :__errata_error__) and
                  :erlang.map_get(:__errata_error__, term) == true and
                  is_map_key(term, :__errata_error_kind__) and
                  :erlang.map_get(:__errata_error_kind__, term) in [
                    :domain,
                    :infrastructure,
                    :general
                  ] and
                  is_map_key(term, :message) and
                  is_map_key(term, :reason) and
                  is_map_key(term, :extra) and
                  is_map_key(term, :env)

  @doc """
  Returns `true` if `term` is an Errata domain error type; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_domain_error(term)
           when is_error(term) and
                  :erlang.map_get(:__errata_error_kind__, term) == :domain

  @doc """
  Returns `true` if `term` is an Errata infrastructure error type; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_infrastructure_error(term)
           when is_error(term) and
                  :erlang.map_get(:__errata_error_kind__, term) == :infrastructure
end
