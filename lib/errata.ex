defmodule Errata do
  # Pull in the moduledocs from the demarcated section of the README file
  @external_resource Path.expand("./README.md")
  @moduledoc File.read!(Path.expand("./README.md"))
             |> String.split("<!-- README START -->")
             |> Enum.at(1)
             |> String.split("<!-- README END -->")
             |> List.first()

  @typedoc """
  Type to represent the various kinds of Errata errors.
  """
  @type error_kind :: :domain | :infrastructure | :general | nil

  @typedoc """
  Type to represent any kind of Errata error.

  Errata errors are `Exception` structs that have additional fields to contain extra contextual
  information, such as an error reason or details about the context in which the error occurred.
  """
  @type error :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error__: true,
          kind: Errata.error_kind(),
          message: String.t() | nil,
          reason: atom() | nil,
          context: map() | nil,
          env: Errata.Env.t()
        }

  @typedoc """
  Type to represent Errata domain errors.
  """
  @type domain_error :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error__: true,
          kind: :domain,
          message: String.t() | nil,
          reason: atom() | nil,
          context: map() | nil,
          env: Errata.Env.t() | nil
        }

  @typedoc """
  Type to represent Errata infrastructure errors.
  """
  @type infrastructure_error :: %{
          __struct__: module(),
          __exception__: true,
          __errata_error__: true,
          kind: :infrastructure,
          message: String.t() | nil,
          reason: atom() | nil,
          context: map() | nil,
          env: Errata.Env.t() | nil
        }

  @doc """
  Returns `true` if `term` is any Errata error type; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_error(term)
           when is_struct(term) and
                  is_exception(term) and
                  is_map_key(term, :__errata_error__) and
                  :erlang.map_get(:__errata_error__, term) == true and
                  is_map_key(term, :kind) and
                  :erlang.map_get(:kind, term) in [
                    :domain,
                    :infrastructure,
                    :general
                  ] and
                  is_map_key(term, :message) and
                  is_map_key(term, :reason) and
                  is_map_key(term, :context) and
                  is_map_key(term, :env)

  @doc """
  Returns `true` if `term` is an Errata domain error type; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_domain_error(term)
           when is_error(term) and
                  :erlang.map_get(:kind, term) == :domain

  @doc """
  Returns `true` if `term` is an Errata infrastructure error type; otherwise returns `false`.

  Allowed in guard tests.
  """
  defguard is_infrastructure_error(term)
           when is_error(term) and
                  :erlang.map_get(:kind, term) == :infrastructure

  @doc """
  Creates an error of the given `error_module`, capturing the current `__ENV__`
  and stacktrace into the `:env` field.

  This is a convenience equivalent to the per-module `c:Errata.Error.create/1`
  macro, but it lives on the `Errata` module. Because you typically already
  `require Errata` (to use the guards above), you can `alias` your error modules
  and call `Errata.create/2` for any of them without a separate `require` for
  each error type:

      defmodule MyApp.SomeContext do
        require Errata
        alias MyApp.SomeContext.{UnknownThing, ThingConflict}

        def fetch(id) do
          {:error, Errata.create(UnknownThing, reason: :not_found, context: %{id: id})}
        end
      end

  Compare to the per-module macro, which requires a `require` for every error
  type used in the module:

      require MyApp.SomeContext.UnknownThing, as: UnknownThing
      require MyApp.SomeContext.ThingConflict, as: ThingConflict
  """
  defmacro create(error_module, params \\ Macro.escape(%{})) do
    quote do
      {:current_stacktrace, [_process_info_call | stacktrace]} =
        Process.info(self(), :current_stacktrace)

      Errata.Errors.create(unquote(error_module), unquote(params), __ENV__, stacktrace)
    end
  end
end
