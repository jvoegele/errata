defmodule Errata.Redaction do
  @moduledoc """
  Removes sensitive values from error context before it leaves the process.

  Errata encourages putting arbitrary metadata in an error's `:context`, and then
  ships that context outward — `Errata.to_map/1` (and therefore the JSON encoding),
  `Errata.log/2` as Logger metadata, and `Errata.report/2` as `[:errata, :error]`
  telemetry metadata. Without redaction, this puts a password in your log
  aggregator the first time someone writes `context: %{params: params}`.

  Redaction applies at the **serialization seam**, not at creation. The error
  struct you hold locally keeps the real values, so `inspect/1`, a debugger, and a
  `rescue` clause all still show you what actually happened. Only the copies
  Errata emits are redacted.

  ## Declaring keys

  Most types declare their sensitive keys with the `:redact` option:

      defmodule MyApp.Auth.LoginFailed do
        use Errata.DomainError, redact: [:password, :token]
      end

  For a floor of protection across every error type in an application, set the
  keys globally:

      config :errata, redact: [:password, :token, :secret, :authorization, :api_key]

  The two compose: a type redacts its declared keys plus the global ones. The
  global default is `[]`, so redaction is opt-in and no existing context changes
  shape until you ask for it.

  ## Nesting

  Redaction is recursive. This is the point rather than a bonus — the common way
  to leak a secret is not `context: %{password: pw}` but a whole map or struct
  captured wholesale:

      context: %{params: %{"email" => email, "password" => pw}}

  A declared key is replaced wherever it appears: at the top level, inside nested
  maps, and inside lists and tuples of those. Both atom and binary keys match, so
  declaring `:password` also covers the `"password"` string key that arrives from
  a JSON body or a Plug params map.

  Structs in the context are traversed as well, and come back as structs of the
  same type — a redacted `%MyApp.User{}` is still a `%MyApp.User{}`, with its
  sensitive fields replaced.

  ## Custom rules

  When a key list isn't enough, override `redact_context/1` on the error module.
  It receives the error and returns the context map to serialize:

      defmodule MyApp.Api.CallFailed do
        use Errata.InfrastructureError

        def redact_context(%{context: context}) do
          context
          |> Map.drop([:raw_response])
          |> Errata.Redaction.redact([:authorization])
        end
      end
  """

  @redacted "[REDACTED]"

  @doc """
  Returns the marker substituted for a redacted value: `#{inspect(@redacted)}`.
  """
  @spec redacted_marker() :: String.t()
  def redacted_marker, do: @redacted

  @doc """
  Replaces the value of every occurrence of `keys` in `term` with
  `#{inspect(@redacted)}`.

  Recurses through maps, structs, lists, and tuples. A key matches whether it is
  written as an atom or as a binary, so `redact(term, [:password])` also redacts
  a `"password"` key.

  Returns `term` unchanged when `keys` is empty.

  ## Examples

      iex> Errata.Redaction.redact(%{user: "kim", password: "hunter2"}, [:password])
      %{user: "kim", password: "[REDACTED]"}

      iex> Errata.Redaction.redact(%{params: %{"token" => "abc"}}, [:token])
      %{params: %{"token" => "[REDACTED]"}}

      iex> Errata.Redaction.redact(%{user: "kim"}, [])
      %{user: "kim"}
  """
  @spec redact(term(), [atom() | String.t()]) :: term()
  def redact(term, []), do: term

  def redact(term, keys) when is_list(keys) do
    redact_term(term, MapSet.new(keys, &normalize_key/1))
  end

  # Structs are rebuilt as the same struct so a redacted %User{} stays a %User{}.
  # `:__struct__` is dropped before mapping and restored after, since it is not a
  # field a caller would ever want redacted.
  defp redact_term(%_{} = struct, keys) do
    struct
    |> Map.from_struct()
    |> redact_term(keys)
    |> Map.put(:__struct__, struct.__struct__)
  end

  defp redact_term(map, keys) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if MapSet.member?(keys, normalize_key(key)) do
        {key, @redacted}
      else
        {key, redact_term(value, keys)}
      end
    end)
  end

  defp redact_term(list, keys) when is_list(list) do
    Enum.map(list, &redact_term(&1, keys))
  end

  defp redact_term(tuple, keys) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&redact_term(&1, keys))
    |> List.to_tuple()
  end

  defp redact_term(other, _keys), do: other

  # Keys are compared as strings so that `:password` and `"password"` are the same
  # key. Params arriving from a JSON body or a Plug conn have binary keys, and a
  # declaration that only covered the atom form would miss exactly the case this
  # feature exists for.
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)

  @doc """
  Returns the globally configured redaction keys (`config :errata, redact: [...]`).

  Defaults to `[]`, so nothing is redacted until an application opts in.
  """
  @spec global_keys() :: [atom() | String.t()]
  def global_keys, do: Application.get_env(:errata, :redact, [])
end
