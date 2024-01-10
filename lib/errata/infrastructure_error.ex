defmodule Errata.InfrastructureError do
  @moduledoc """
  TODO
  """

  defmacro __using__(opts) do
    default_message = Keyword.get(opts, :default_message)
    default_reason = Keyword.get(opts, :default_reason)

    quote do
      @behaviour Errata.Error

      defexception __errata_error_kind__: :infrastructure,
                   message: unquote(default_message),
                   reason: unquote(default_reason),
                   extra: nil,
                   env: nil

      @type t :: Errata.InfrastructureError.t()

      @impl Exception
      def exception(params), do: Errata.Error.create(__MODULE__, params)

      @impl Exception
      def message(%__MODULE__{} = infrastructure_error),
        do: Errata.Error.format_message(infrastructure_error)

      @impl Errata.Error
      def new(params \\ %{}), do: Errata.Error.create(__MODULE__, params)

      @impl Errata.Error
      defmacro create do
        quote do
          Errata.Error.create(unquote(__MODULE__), %{}, __ENV__)
        end
      end

      @impl Errata.Error
      defmacro create(params) do
        quote do
          Errata.Error.create(unquote(__MODULE__), unquote(params), __ENV__)
        end
      end

      @impl Errata.Error
      def to_map(infrastructure_error), do: Errata.Error.to_map(infrastructure_error)

      defoverridable Exception

      defimpl String.Chars, for: __MODULE__ do
        def to_string(infrastructure_error), do: Errata.Error.format_message(infrastructure_error)
      end

      defimpl Jason.Encoder, for: __MODULE__ do
        def encode(infrastructure_error, opts) do
          Errata.Error.to_json(infrastructure_error, opts)
        end
      end
    end
  end
end
