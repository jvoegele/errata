# Errata

<!-- README START -->

Errata is an Elixir library that promotes a consistent and structured approach to
error handling.

Errata provides support for defining custom structured error types, which can
either be returned as error values or raised as exceptions.

Errata errors are named, structured types that represent error conditions in an
application or library. Being named types means that errors have a unique and
meaningful name within a particular context. Being structured types means that
errors have a well-defined, consistent structure identifying the nature of the
error, and can also have arbitrary contextual information attached to them for
logging or debugging purposes.

Errata errors fall into one of three general classifications:

- _Domain Errors_ represent error conditions within a problem domain or bounded
  context. These are business process violations or other errors in the problem
  domain, and therefore domain errors should be included as part of the
  [Ubiquitous Language](https://martinfowler.com/bliki/UbiquitousLanguage.html)
  of the domain.
- _Infrastructure Errors_ represent errors that can occur at an infrastructure
  level but which are not part of the problem domain. Infrastructure errors
  include such things as network timeouts, database connection failures,
  filesystem errors, etc.
- _General Errors_ represent errors that do not fall into either of the above
  categories. General errors can include errors that emanate from library code
  (as opposed to application code) or any other sort of error condition for
  which there is no need to distinguish based on classification.

## Defining custom error types

Errata makes it easy to define custom error types for applications or libraries.
The following examples demonstrate how to define domain errors, infrastructure
errors, and general errors.

```elixir
defmodule MyApp.SomeContext.MyDomainError do
  # Define a custom domain error in some context.
  use Errata.DomainError
end

defmodule MyApp.SomeContext.MyInfrastructureError do
  # Define a custom infrastructure error in some context.
  use Errata.InfrastructureError
end

defmodule MyApp.SomeContext.MyError do
  # Define a custom error in some context.
  use Errata.Error
end
```

Each of these custom error types will define an exception struct that conforms
to the `t:Errata.error/0` type and will implement the `Errata.Error` behaviour.
Additionally, implementations for the `String.Chars` protocol and the
`Jason.Encoder` protocol are provided so that these errors can be converted to
string form or encoded as JSON automatically.

## Raising Errata errors as exceptions

Since Errata errors are just regular Elixir exceptions with a well-defined
structure, they can be raised just like any other type of exception.

```elixir
raise MyApp.SomeContext.MyDomainError, reason: :invalid_data, context: %{foo: "bar"}
```

## Using Errata errors as return values

Errata errors can be created by using the `new/1` or `create/1` functions for
the error type. Once created, they can be used as return values from functions,
preferably wrapped in an error tuple. This approach allows for creating errors
with full contextual details at the site of the error, while separating the
handling of errors by letting them propagate up the call stack and logging
or reporting the errors at the boundaries of the system.

Using the `new/1` function creates an error with the provided data, but does
not include any data in the `:env` field of the error struct:

```elixir
iex> alias MyApp.SomeContext.MyError
iex> MyError.new(reason: :invalid_data, context: %{foo: "bar"})
%MyError{reason: :invalid_data, context: %{foo: "bar"}, env: nil}
```

Using the `create/1` macro, on the other hand, fills in the `:env` field of
the error struct with information from the current `__ENV__` struct and
the current stacktrace. To use the `create/1` macro, you must first
`require/2` the error module:

```elixir
iex> require MyApp.SomeContext.MyError, as: MyError
iex> error = MyError.create(reason: :invalid_data, context: %{foo: "bar"})
iex> error.reason == :invalid_data
true
iex> error.context == %{foo: "bar"}
true
iex> match?(%Errata.Env{stacktrace: stacktrace} when is_list(stacktrace), error.env)
true
```

Whether `new/1` or `create/1` is used to create the error, it is preferable to
wrap the error in a tuple when returning it as a value from functions:

```elixir
{:error, MyError.new(reason: :invalid_data)}
{:error, MyError.create(reason: :invalid_data)}
```

## Handling Errata errors

Since error types defined using Errata are standard Elixir exceptions, they can
be handled in the same way as any other exception. Specifically, they can be
used in the `rescue` clause of a `try` block or function, and the
`Kernel.is_exception/1` guard will always return `true` for them. Additionally,
Errata provides custom guards for handling Errata error types specifically:

- `Errata.is_error/1`
- `Errata.is_domain_error/1`
- `Errata.is_infrastructure_error/1`

To use these custom guards, `import` or `require` the `Errata` module.

The following example demonstrates handling Errata errors both as raised
exceptions and as error values returned from functions.

```elixir
defmodule MyApp.SomeContext do
  # require the Errata module to use the custom guards
  require Errata

  def handle_errata_error_as_exception do
    try do
      function_that_raises_errata_error!()
    rescue
      e in [MyApp.SomeContext.MyDomainError] ->
        # Errata errors can be rescued by their specific type
        handle_my_domain_error(e)

      e when Errata.is_error(e) ->
        # Or they can be rescued using one of the custom guards defined in the
        # Errata module
        handle_errata_error(e)

      e ->
        # Regular exceptions may be handled separately if desired
        handle_other_error(e)
    end
  end

  def handle_errata_error_as_value do
    case function_that_returns_errata_error_as_value() do
      {:ok, result} ->
        handle_ok_result(result)

      {:error, %MyApp.SomeContext.MyDomainError{} = error} ->
        # Errata errors can be pattern matched by their specific type
        handle_my_domain_error(error)

      {:error, error} when Errata.is_error(error) ->
        # Or they can be identified using one of the custom guards defined in
        # the Errata module
        handle_errata_error(e)

      {:error, reason} ->
        # Other errors may be handled separately if desired
        handle_other_error(reason)
    end
  end
end
```

## Compared to traditional approaches to error handling

It is common practice in Elixir (and Erlang) to use error tuples of the form
`{:error, reason}` as return values from functions to indicate an error
condition. However, the `reason` value that is used as the second element
in the tuple is often a simple value such as an atom or (worse) a string, and
does not typically include sufficient context for interpreting the error.
While these simple `reason` values are often sufficient for human readers of
the code when viewed in context, they do not provide enough context to be
interpreted by code or when viewed as log messages or error reports, where
the context of where and when the error was originally detected and created
is not readily apparent.

It is a less common but still widespread practice to raise exceptions for
errors, instead of or in addition to returning error values from functions.
Although exceptions do include some contextual information (including, in
particular, a stacktrace), they lack a common, uniform structure that can be
used for logging and error handling in general.

Errata, on the other hand, defines a uniform structure that all errors share,
and allows errors to be created with full contextual details, including
arbitrary context metadata. This full context is embedded into the error struct
so that it propagates with the error, whether the error is raised as an
exception or returned as an error value from a function. Errata errors are also
JSON-encodable so that they can be easily published to external issue tracking
systems such as Sentry, for example.

Consider the common pattern pattern of using a `with` expression with a series
of function calls, each of which is expected to return a tuple either of the
form `{:ok, result}` or `{:error, reason}`. If the error `reason` does not
contain sufficient contextual detail about the nature and cause of the error,
then the `with` expression is forced to handle all possible error values in an
`else` clause, in order to log or report the error in a meaningful way.

If, instead, the error `reason` for each error is a structured type with full
context, the `with` expression can omit the `else` clause altogether and allow
the error to propagate to callers. Since the error includes sufficient context
it can be logged or reported to an issue tracking system at the boundaries,
such as a Phoenix controller or a bounded context, without losing the context
necessary for interpreting or debugging the error.

Chris Keathley provides an in-depth discussion of this point in his blog post
[Good and Bad Elixir](https://keathley.io/blog/good-and-bad-elixir.html), in
the section "Avoid `else` in `with` blocks".

<!-- README END -->

## Installation

`errata` can be installed by adding it to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:errata, "~> 0.8.0"}
  ]
end
```

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/errata/index.html) and be found at
<https://hexdocs.pm/errata/index.html>.
