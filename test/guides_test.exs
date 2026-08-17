# Runs the `iex>` examples in the guides under `guides/`.
#
# The README's examples are covered by `doctest Errata` in `test/errata_test.exs`,
# since the README becomes the `Errata` moduledoc. The guides are separate ExDoc
# extras with no module behind them, so they need `doctest_file/1` — without this,
# moving an example out of the README into a guide would silently stop testing it.
#
# `doctest_file/1` requires Elixir 1.15, which is the library's minimum.
#
# Guides with no `iex>` examples (`design.md`, `observability.md`) are covered
# differently: `design.md`'s examples are module definitions rather than console
# sessions and are pinned by `test/errata/design_guide_test.exs`.
defmodule GuidesTest do
  use ExUnit.Case, async: true

  doctest_file("guides/handling-errors.md")
  doctest_file("guides/boundaries.md")
  doctest_file("guides/wrapping-errors.md")
end
