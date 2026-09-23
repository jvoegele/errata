# Fixtures for the shapes the generated `t/0` takes, read back by
# `test/errata/typespec_test.exs`. They live here rather than in the test file
# because `Code.Typespec.fetch_types/1` reads a compiled beam, and a module
# defined in a `.exs` file has none.
defmodule ErrataTypespecTest.Declared do
  @moduledoc false
  use Errata.DomainError, reasons: [:insufficient_funds, :fraud_suspected]
end

defmodule ErrataTypespecTest.Aggregate do
  @moduledoc false
  use Errata.InfrastructureError, aggregate: true
end

defmodule ErrataTypespecTest.General do
  @moduledoc false
  use Errata.Error
end
