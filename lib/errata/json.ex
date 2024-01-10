defmodule Errata.JSON do
  @moduledoc false

  def encode(error_as_map, opts) do
    Jason.Encode.map(error_as_map, opts)
  end

  def encodable?(map) when is_map(map) do
    Enum.all?(map, fn {k, v} ->
      (is_atom(k) or is_binary(k)) and encodable?(v)
    end)
  end

  def encodable?(value) do
    match?({:ok, _}, Jason.encode(value))
  end

  defimpl Jason.Encoder, for: Tuple do
    def encode(data, options) when is_tuple(data) do
      data
      |> Tuple.to_list()
      |> Jason.Encoder.List.encode(options)
    end
  end
end
