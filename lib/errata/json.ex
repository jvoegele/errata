defmodule Errata.JSON do
  @moduledoc false

  # Errata supports two JSON backends: Elixir's built-in `JSON` module (available
  # on Elixir 1.18+) and the optional `jason` dependency. Which are present is
  # decided at compile time. `encodable?/1` is used to sanitize the `context` map
  # at error-creation time (values that cannot be encoded are `inspect`'d), so it
  # only needs *a* working backend — it prefers the built-in one and falls back
  # to Jason.
  #
  # Errata deliberately defines no `Jason.Encoder` or `JSON.Encoder`
  # implementation for `Tuple`, or for any other built-in type. A protocol
  # implementation is global to the application that compiles it, so a library
  # installing one collides with an application that has its own: the compiler
  # reports "redefining module Jason.Encoder.Tuple", and a build using
  # `--warnings-as-errors` fails outright. Tuples are instead converted to lists
  # by `sanitize/1`, inside the map Errata itself emits, which keeps the JSON
  # shape the same without claiming the type for the whole application.

  @native Code.ensure_loaded?(JSON)

  @doc """
  Returns `value` in a form every JSON backend can encode.

  Tuples become lists, recursively through lists and plain maps, so a tuple in an
  error's context serializes as an array on either backend. A value that still
  cannot be encoded is replaced by the `inspect/1` rendering of the *original*
  value, so a tuple holding a pid reads as the tuple it was.
  """
  @spec sanitize(term()) :: term()
  def sanitize(value) do
    converted = tuples_to_lists(value)
    if encodable?(converted), do: converted, else: inspect(value)
  end

  defp tuples_to_lists(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> tuples_to_lists()

  defp tuples_to_lists([head | tail]), do: [tuples_to_lists(head) | tuples_to_lists(tail)]

  defp tuples_to_lists(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, tuples_to_lists(value)} end)

  defp tuples_to_lists(other), do: other

  # A struct is checked through its own encoder by the backend clauses below, not
  # field by field: `%DateTime{}` holds a tuple in `:microsecond` yet encodes as
  # an ISO 8601 string, and a struct with no encoder at all would pass a
  # field-wise check and then raise at encode time.
  def encodable?(map) when is_map(map) and not is_struct(map) do
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

    Code.ensure_loaded?(Jason) ->
      def encodable?(value) do
        match?({:ok, _}, Jason.encode(value))
      end

    true ->
      # No JSON backend at all: sanitization is best-effort, so treat values as
      # encodable and leave them untouched.
      def encodable?(_value), do: true
  end
end
