defmodule Errata.InfrastructureError do
  @moduledoc """
  Support for creating custom infrastructure error types.
  """

  defmacro __using__(opts) do
    ast = Errata.Error.__define__(:infrastructure, __CALLER__.module, opts)

    quote do
      unquote(ast)
    end
  end
end
