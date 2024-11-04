defmodule Errata.Define do
  @moduledoc false

  def define_error(kind, module_name, opts \\ [])
      when kind in [:domain, :infrastructure] and is_atom(module_name) do
    attribute_defs = define_attributes(module_name)
    type_def = define_type(kind)
    exception_def = define_exception(kind, opts)
    errata_error_impl = define_errata_error_callbacks()
    string_chars_impl = define_string_chars_impl(module_name)
    jason_encoder_impl = define_jason_encoder_impl(module_name)

    quote do
      unquote(attribute_defs)
      unquote(type_def)
      unquote(exception_def)
      unquote(errata_error_impl)
      unquote(string_chars_impl)
      unquote(jason_encoder_impl)
    end
  end

  defp define_attributes(module_name) do
    quote do
      @__errata_error_module__ unquote(module_name)
      @behaviour Errata.Error
    end
  end

  defp define_type(:domain) do
    quote do
      @type t :: Errata.domain_error()
    end
  end

  defp define_type(:infrastructure) do
    quote do
      @type t :: Errata.infrastructure_error()
    end
  end

  defp define_exception(kind, opts) do
    default_message = Keyword.get(opts, :default_message)
    default_reason = Keyword.get(opts, :default_reason)

    quote do
      defexception __errata_error_kind__: unquote(kind),
                   message: unquote(default_message),
                   reason: unquote(default_reason),
                   extra: nil,
                   env: nil

      @impl Exception
      def exception(params) do
        Errata.Error.create(@__errata_error_module__, params)
      end

      @impl Exception
      def message(%{} = errata_error) do
        Errata.Error.format_message(errata_error)
      end

      defoverridable Exception
    end
  end

  defp define_errata_error_callbacks do
    quote do
      @impl Errata.Error
      def new(params \\ %{}), do: Errata.Error.create(@__errata_error_module__, params)

      @impl Errata.Error
      defmacro create do
        __module__ = @__errata_error_module__

        quote do
          Errata.Error.create(unquote(__module__), %{}, __ENV__)
        end
      end

      @impl Errata.Error
      defmacro create(params) do
        __module__ = @__errata_error_module__

        quote do
          Errata.Error.create(unquote(__module__), unquote(params), __ENV__)
        end
      end

      @impl Errata.Error
      def to_map(errata_error), do: Errata.Error.to_map(errata_error)
    end
  end

  defp define_string_chars_impl(error_module) do
    quote do
      defimpl String.Chars, for: unquote(error_module) do
        def to_string(errata_error), do: Errata.Error.format_message(errata_error)
      end
    end
  end

  defp define_jason_encoder_impl(error_module) do
    quote do
      defimpl Jason.Encoder, for: unquote(error_module) do
        def encode(errata_error, opts) do
          Errata.Error.to_json(errata_error, opts)
        end
      end
    end
  end
end
