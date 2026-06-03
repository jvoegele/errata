defmodule Errata.JSON do
  @moduledoc false

  def encodable?(map) when is_map(map) do
    Enum.all?(map, fn {k, v} ->
      (is_atom(k) or is_binary(k)) and encodable?(v)
    end)
  end

  def encodable?(value) do
    if Code.ensure_loaded?(JSON) do
      try do
        JSON.encode_to_iodata!(value)
        true
      rescue
        _ -> false
      end
    else
      if Code.ensure_loaded?(Jason) do
        match?({:ok, _}, Jason.encode(value))
      else
        false
      end
    end
  end

  for {protocol, mod} <- [
        {JSON.Encoder, JSON.Encoder.List},
        {Jason.Encoder, Jason.Encoder.List}
      ] do
    if Code.ensure_loaded?(protocol) do
      defimpl protocol, for: Tuple do
        def encode(data, opts_or_encoder) when is_tuple(data) do
          data
          |> Tuple.to_list()
          |> unquote(mod).encode(opts_or_encoder)
        end
      end
    end
  end
end
