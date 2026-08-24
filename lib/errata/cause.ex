defmodule Errata.Cause do
  @moduledoc """
  A struct that holds the original error wrapped (chained) by an Errata error.

  When an Errata error is created with a `:cause` (typically via the generated
  `c:Errata.Error.wrap/2` macro), the original error is stored in the error's
  `:cause` field as an `Errata.Cause` struct. This preserves the context of the
  underlying failure without losing the benefits of a structured Errata error.

  The struct has the following fields:

    * `kind` - the kind of the wrapped error, one of `:error`, `:throw`, or
      `:exit`, mirroring the first argument of `Exception.format/3`. Defaults to
      `:error`.
    * `value` - the wrapped error itself. This can be any term: another Errata
      error, a standard exception struct, or an arbitrary value such as the
      `reason` from an `{:error, reason}` tuple.
    * `stacktrace` - the stacktrace captured at the point the original error was
      caught (typically `__STACKTRACE__` from a `rescue`/`catch` clause), or
      `nil` if none was provided.

  Whereas the `:env` field of an Errata error records _where the error was
  wrapped_, the `:stacktrace` of the cause records _where the original error
  occurred_.

  Use `Errata.cause/1`, `Errata.root_cause/1` and `Errata.root_error/1` to access the wrapped value(s),
  and `Errata.format_chain/1` to render a full cause chain for logging.
  """

  @typedoc """
  Type to represent the kind of a wrapped error.

  Mirrors the kinds accepted by `Exception.format/3`.
  """
  @type kind :: :error | :throw | :exit

  @typedoc """
  Type to represent a wrapped (chained) error.
  """
  @type t :: %Errata.Cause{
          kind: kind(),
          value: term(),
          stacktrace: Exception.stacktrace() | nil
        }

  defstruct kind: :error, value: nil, stacktrace: nil

  @doc """
  Normalizes a value into an `Errata.Cause` struct.

  If `value` is already an `Errata.Cause`, it is returned unchanged. Otherwise a
  new struct is built, wrapping `value`. The following options are supported:

    * `:kind` - the kind of the wrapped error (see `t:kind/0`); defaults to `:error`
    * `:stacktrace` - the stacktrace captured where the original error occurred
  """
  @spec new(term(), keyword()) :: t()
  def new(value, opts \\ [])
  def new(%__MODULE__{} = cause, _opts), do: cause

  def new(value, opts) do
    %__MODULE__{
      kind: Keyword.get(opts, :kind, :error),
      value: value,
      stacktrace: Keyword.get(opts, :stacktrace)
    }
  end
end
