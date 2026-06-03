defmodule Errata.JSON do
  @moduledoc false

  # Errata supports two JSON backends: Elixir's built-in `JSON` module (available
  # on Elixir 1.18+) and the optional `jason` dependency. Which are present is
  # decided at compile time. `encodable?/1` is used to sanitize the `context` map
  # at error-creation time (values that cannot be encoded are `inspect`'d), so it
  # only needs *a* working backend — it prefers the built-in one and falls back
  # to Jason.

  @native Code.ensure_loaded?(JSON)
  @jason Code.ensure_loaded?(Jason)

  def encodable?(map) when is_map(map) do
    Enum.all?(map, fn {k, v} ->
      (is_atom(k) or is_binary(k)) and encodable?(v)
    end)
  end

  cond do
    @native ->
      def encodable?(value) do
        JSON.encode!(value)
        true
      rescue
        Protocol.UndefinedError -> false
      end

    @jason ->
      def encodable?(value) do
        match?({:ok, _}, Jason.encode(value))
      end

    true ->
      # No JSON backend at all: sanitization is best-effort, so treat values as
      # encodable and leave them untouched.
      def encodable?(_value), do: true
  end

  # Tuples have no JSON representation in either backend by default; Errata
  # encodes them as arrays so that tuple values in `context` serialize the same
  # way regardless of which backend a caller uses.
  if @jason do
    defimpl Jason.Encoder, for: Tuple do
      def encode(data, options) when is_tuple(data) do
        data
        |> Tuple.to_list()
        |> Jason.Encoder.List.encode(options)
      end
    end
  end

  if @native do
    defimpl JSON.Encoder, for: Tuple do
      def encode(data, encoder) when is_tuple(data) do
        data
        |> Tuple.to_list()
        |> JSON.protocol_encode(encoder)
      end
    end
  end
end
