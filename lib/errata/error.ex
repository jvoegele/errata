defmodule Errata.Error do
  @moduledoc """
  Support for creating custom error types, which can either be returned as error values or raised
  as exceptions.

  Errata errors can be defined by creating an Elixir module that uses the `Errata.Error`
  module. Error types defined in this way are Elixir `Exception` structs with the following keys:

    * `message` - human readable string describing the nature of the error
    * `reason` - an atom describing the reason for the error, which can be used for pattern
      matching or classifying the error
    * `context` - a map containing arbitrary contextual information or metadata about the error

  Note the distinction between two ways of rendering an error as a string.
  `Exception.message/1` (and the `String.Chars` implementation) return a
  _developer-oriented_ message that combines `message` and `reason` (for
  example, `"the requested order does not exist: :not_found"`) — useful in logs
  and raised-exception output. `Errata.display_message/1` returns just the
  human-readable `message`, intended for rendering to end users.

  Because these error types are defined with `defexception/1`, they can be raised as exceptions
  with `raise/2`. However, because they implement the `Errata.Error` behaviour, it is also
  possible to create instances of these error structs using the generated implementations of
  `c:Errata.Error.new/1` or `c:Errata.Error.create/1` and use them as return values from
  functions, either directly or wrapped in an error tuple such as `{:error, my_error}`.

  Error types defined with `Errata.Error` are of kind `:general` by default. Since most errors
  are either domain errors or infrastructure errors, prefer `Errata.DomainError` or
  `Errata.InfrastructureError` (which share all of the functionality described here) when
  defining custom error types, and use `Errata.Error` directly only for general errors that fit
  neither category, such as errors originating in library code.

  ## Usage

  To define a new custom error type, `use/2` the `Errata.Error` module in your own error module:

      defmodule MyApp.UnexpectedError do
        use Errata.Error,
          default_message: "an unexpected error occurred"
      end

  > #### `use Errata.Error` {: .info}
  >
  > When you `use Errata.Error`, the `Errata.Error` module will define an exception struct with
  > `defexception/1` and will generate an implementation of the `Errata.Error` behaviour.

  The following options may be provided to `use Errata.Error`. The list is closed: an option that
  is misspelled or unrecognized raises `ArgumentError` at compile time rather than being silently
  ignored, since a `use` option is written once and a misconfiguration would otherwise be permanent
  and invisible.

    * `:default_reason` - the default value to use for the `:reason` field if it is not provided
    * `:default_message` - the default value to use for the `:message` field if it is not provided.
      This is a static string; to compute a user-facing message from the error's `:reason` or
      `:context` (naming the particular order or item, say), override the generated
      `display_message/1` function instead — `Errata.display_message/1` and `c:to_map/1` both
      dispatch through it. See `Errata.display_message/1`.

      A type that declares no `:default_message` renders as `nil` through every display path.
      To give every such type a floor rather than repeating a fallback at each boundary, set an
      application-wide default:

          config :errata, default_display_message: "an unexpected error occurred"

      It applies only where the type declares nothing and the caller passed no `:message`, and
      defaults to `nil`, which is the historical behaviour. This mirrors `config :errata, redact:`
      — a global floor that individual types refine.
    * `:reasons` - an optional list of atoms enumerating the valid reasons for this error type.
      When given, creating an error (via `c:new/1`, `c:create/1`, `c:wrap/2`, or `raise/2`) with a
      `:reason` outside this set raises an `ArgumentError`. A `nil` (unspecified) reason is always
      allowed, and a `:default_reason`, if also given, must be one of the declared `:reasons`.
      Declaring reasons also generates a `reason/0` type enumerating them, so the valid reasons are
      visible in the generated documentation.
    * `:http_status` - the HTTP status code to associate with this error type, returned by the
      generated `http_status/1` function (and `Errata.http_status/1`). When omitted, the status
      defaults off the error's kind (`:domain` → `422`, `:infrastructure` → `503`, `:general` →
      `500`). The generated `http_status/1` is overridable, so it can instead be defined to compute
      a status from the error's `:reason` or `:context`.
    * `:code` - a stable external code for this error type (such as `"ORDER_NOT_FOUND"`),
      returned by the generated `code/1` function (and `Errata.code/1`) and included in
      `c:to_map/1`. A code is independent of the module name, so it remains a valid contract with
      external consumers even if the module is renamed or moved. There is no default: types that
      do not declare one return `nil`. The generated `code/1` is overridable, so it can instead be
      defined to derive a code from the error's `:reason` or `:context`.
    * `:severity` - the severity of this error type, as a `t:Logger.level/0`, returned by the
      generated `severity/1` function (and `Errata.severity/1`). Defaults to `:error` for every
      kind. This is the level at which `Errata.log/2` logs the error when no level is given
      explicitly, and it is included in the metadata emitted by `Errata.log/2` and
      `Errata.report/2`. The generated `severity/1` is overridable, so it can instead be defined
      to compute a severity from the error's `:reason` or `:context`.
    * `:retryable` - whether errors of this type are retryable, returned by the generated
      `retryable?/1` function (and `Errata.retryable?/1`). When omitted, this defaults off the
      error's kind: `:infrastructure` errors are retryable, `:domain` and `:general` errors are
      not. The generated `retryable?/1` is overridable, so it can instead be defined to decide
      from the error's `:reason` or `:context`.
    * `:redact` - a list of context keys whose values are sensitive, replaced with
      `"[REDACTED]"` everywhere Errata serializes the context: `c:to_map/1` and the JSON
      encoding, `Errata.log/2` metadata, and `Errata.report/2` telemetry metadata. Redaction
      is recursive and matches atom and binary keys alike, so `redact: [:password]` covers a
      password nested inside a captured params map with string keys, and `{key, value}` pairs
      count, so `redact: [:authorization]` covers the header in a captured `conn.req_headers`
      list. The error struct keeps
      the real values, so they remain available locally for debugging. Defaults to `[]`; add a
      global floor with `config :errata, redact: [...]`. The generated `redact_context/1` is
      overridable for rules a key list can't express. See `Errata.Redaction`.
    * `:aggregate` - when `true`, this type can hold member errors, for the "several things
      went wrong at once" shape that validation produces. Adds an `:errors` field (a list of
      Errata errors, empty by default) that `new/1` and `create/1` accept, includes the members
      in `c:to_map/1` and the message, and merges `severity/1`, `retryable?/1`, and
      `http_status/1` across them — each by a different rule, and each still overridable. Members
      must themselves be Errata errors. Defaults to `false`. See `Errata.Aggregate`.
    * `:capture_stacktrace` - how much of the stacktrace `c:create/1`, `c:wrap/2`,
      `Errata.create/2`, and `Errata.wrap/3` record in `env.stacktrace`: `true` (the default)
      keeps every frame the VM captures, a positive integer keeps only that many of the innermost
      frames, and `false` skips the capture entirely and leaves `env.stacktrace` as `nil`. The
      rest of `:env` (module, function, file, line) is recorded either way. Useful for a type
      created at high volume, or one whose origin says all there is to know. Set a global default
      for every type that declares nothing with:

          config :errata, capture_stacktrace: 5

      This is read at runtime, so it can differ between environments without recompiling. It
      governs only the error's own `:env`; the `:stacktrace` passed to `c:wrap/2` for the cause
      is always kept as given.
    * `:kind` - the "kind" of Errata error to create, one of `:domain`, `:infrastructure`, or
      `:general` (which is the default). Accepted only here: `use Errata.DomainError` and
      `use Errata.InfrastructureError` set the kind themselves and reject the option.

  > #### The `:kind` option {: .warning}
  >
  > Although it is possible to define domain error types or infrastructure error types by using
  > `:domain` or `:infrastructure` as the `:kind` option, it is preferred to instead define these
  > types of errors with `use Errata.DomainError` or `use Errata.InfrastructureError`. This
  > approach is more explicit and allows for easier identification of domain errors and
  > infrastructure errors within an application.

  To create instances of the error — to use as an error return value from a function, say — the
  recommended path is `Errata.create/2`, which captures the current `__ENV__` and stacktrace into
  the `:env` field. Because it takes the error type as an argument, a single `require Errata` covers
  every error type the module creates, with no per-type `require` — and `use Errata`, the usual
  setup line, does that `require` as a consequence of importing the guards:

      defmodule MyApp.SomeModule do
        use Errata

        alias MyApp.UnexpectedError

        def some_function(arg) do
          {:error, Errata.create(UnexpectedError, reason: :unexpected, context: %{arg: arg})}
        end
      end

  The generated `c:create/1` does the same thing and reads more directly when a module works mostly
  with one error type, at the cost of a `require` for that module, since the callback is implemented
  as a macro. `require` with `:as` requires and aliases in one line; a module that already aliases
  the type needs only a `require UnexpectedError` added next to the `alias`:

      defmodule MyApp.SomeModule do
        require MyApp.UnexpectedError, as: UnexpectedError

        def some_function(arg) do
          {:error, UnexpectedError.create(reason: :unexpected, context: %{arg: arg})}
        end
      end

  `c:new/1` is a plain function that builds the error without environment info. See `c:new/1` for
  when that is the right choice.

  To raise errors as exceptions, simply use `raise/2` passing extra params as the second argument
  if desired. `raise/2` is not a macro on the error module, so no `require` is needed:

      defmodule MyApp.SomeModule do
        alias MyApp.UnexpectedError

        def some_function!(arg) do
          raise UnexpectedError, reason: :unexpected, context: %{arg: arg}
        end
      end

  ## The generated `t/0` type

  Every generated error type gets a `t/0` type naming its own struct, so a spec
  written against it means what a reader expects:

      @spec refund(Order.t(), PaymentDeclined.t()) :: :ok

  accepts a `PaymentDeclined` and nothing else. The type spells out every field
  with the same types the kind-level `t:Errata.error/0`,
  `t:Errata.domain_error/0` and `t:Errata.infrastructure_error/0` maps use, so it
  is a subtype of each of them: a spec that accepts a kind still accepts every
  generated type. Where a type declares `:reasons`, its `reason` field narrows to
  the generated `reason/0` enumeration, and an aggregate type adds
  `errors: [Errata.error()]`.

  The constructors are typed to match. The generated `new/1` carries a spec
  returning `t/0`, and the `create` and `wrap` macros, both the per-module ones
  and `Errata.create/2` / `Errata.wrap/3` with a literal module, expand to calls
  of generated functions whose specs return `t/0` as well. Dialyzer therefore
  sees `OrderNotFound.create()` as an `OrderNotFound.t()` rather than as some
  Errata error, and flags it where a `PaymentDeclined.t()` was specced. The one
  gap is `Errata.create/2` or `Errata.wrap/3` with the module in a variable,
  which cannot be known at compile time and stays kind-level.

  Only Dialyzer reads these specs. Elixir's own type checker ignores them, so
  none of this changes what the compiler warns about.

  ## Dialyzer's `:extra_return` flag

  The generated `http_status/1`, `code/1`, `severity/1` and `retryable?/1` carry
  behaviour-level specs while their default bodies return a compile-time literal.
  A type declaring `code: "ORDER_NOT_FOUND"` therefore has success typing
  `<<_::176>>` against a spec that also admits `nil`, and one that never overrides
  `retryable?/1` has success typing `false` against `boolean()`. With
  `flags: [:extra_return]`, Dialyzer reports an `extra_range` warning for each,
  and the count grows with every error type an application defines.

  Narrowing the specs per type would trade this warning for a worse one: a type
  declared `retryable: false` would get `@spec retryable?(...) :: false`, and the
  first override returning `true` for a particular reason — the extension point
  these functions exist for — would then be the thing Dialyzer flagged, in user
  code. **`:extra_return` is best left off in a project that uses Errata.**

  """

  @typedoc """
  Type to represent Errata error structs.

  Error structs are `Exception` structs that have additional fields to contain extra contextual
  information, such as an error reason or details about the context in which the error occurred.

  This is the kind-level type covering every Errata error, the one the behaviour's callbacks are
  written against. Each generated error module also has its own `t/0`, which names that module's
  struct and is a subtype of this one; see "The generated `t/0` type" above.
  """
  @type t() :: Errata.error()

  @typedoc """
  Type to represent allowable keys to use in params used for creating error structs.

  See also `t:params/0`.
  """
  @type param :: :message | :reason | :context | :cause

  @typedoc """
  Type to represent allowable values to be passed as params for creating error structs.

  This effectively allows for using either a map or keyword list with allowable keys defined by
  `t:param/0`.
  """
  @type params :: Enumerable.t({param(), any()})

  @doc """
  Invoked to create a new instance of an error struct with default values.

  See `c:new/1`.
  """
  @callback new :: t()

  @doc """
  Invoked to create a new instance of an error struct with the given params.

  Unlike `c:create/1`, this leaves the `:env` field `nil`: it records nothing
  about where the error was created. Prefer `c:create/1` or `Errata.create/2`
  unless you need one of the things a macro cannot do — calling it dynamically
  with `apply/3`, or capturing it as `&SomeError.new/1` to pass around. It is
  also convenient in tests and fixtures, where `env: nil` keeps error structs
  easy to compare.
  """
  @callback new(params()) :: t()

  @doc """
  Invoked to create a new instance of an error struct with default values and the current
  `__ENV__`.

  See `c:create/1`.
  """
  @macrocallback create :: Macro.t()

  @doc """
  Invoked to create a new instance of an error struct with the given params and the current
  `__ENV__`.

  Since this is a macro, the `__ENV__/0` special form is used to capture the `Macro.Env` struct
  for the current environment and the public fields of this struct are placed in the exception
  struct under the `:env` key. This provides access to information about the context in which the
  error was created, such as the module, function, file, and line. See `t:env/0` for further
  details.

  Note that because this is a macro, callers must `require/2` the error module to be able to use it.
  `Errata.create/2` avoids that per-module `require` — it takes the error type as an argument, so a
  single `use Errata` (or `require Errata`) covers every error type a module creates, with the same
  `:env` capture. Prefer it when a module works with several error types.

  Capturing the environment walks the process stack, which costs on the order of a microsecond per
  error — negligible against almost any operation that can fail, including in `with` chains at
  request volume. The stacktrace is already capped by the VM (8 frames by default), so the cost does
  not grow with stack depth. Reach for `c:new/1` only when you need a plain function, not to avoid
  this cost; to skip or shorten the stacktrace itself, use the `:capture_stacktrace` option.
  """
  @macrocallback create(params()) :: Macro.t()

  @doc """
  Invoked to wrap an existing error, exception, or arbitrary value as the
  `:cause` of a new error struct, capturing the current `__ENV__`.

  This is the idiomatic way to translate a lower-level failure into a structured
  Errata error without losing the context of the original. It is equivalent to
  `c:create/1` with the given `cause` placed in the `:cause` field. See
  `c:wrap/2` to also provide params (such as a `:reason`) and the original
  stacktrace.

  Like `c:create/1`, this is a macro, so callers must `require/2` the error module.
  """
  @macrocallback wrap(cause :: Macro.t()) :: Macro.t()

  @doc """
  Invoked to wrap an existing error as the `:cause` of a new error struct, with
  the given `opts`, capturing the current `__ENV__`.

  In addition to the standard params accepted by `c:create/1` (`:message`,
  `:reason`, `:context`), `opts` may include:

    * `:stacktrace` - the stacktrace where the original error occurred, typically
      `__STACKTRACE__` from within a `rescue`/`catch` clause
    * `:kind` - the kind of the wrapped error, one of `:error` (the default),
      `:throw`, or `:exit`

  The wrapped value is stored as an `Errata.Cause` in the `:cause` field, and can
  be retrieved with `Errata.cause/1`. The typical use is to translate a rescued
  exception while preserving its original stacktrace:

      try do
        Jason.decode!(payload)
      rescue
        e ->
          {:error, MyApp.InvalidPayload.wrap(e, stacktrace: __STACKTRACE__, reason: :malformed_json)}
      end

  Like `c:create/1`, this is a macro, so callers must `require/2` the error module.
  """
  @macrocallback wrap(cause :: Macro.t(), opts :: Macro.t()) :: Macro.t()

  @doc """
  Invoked to convert an error to a plain, JSON-encodable map.
  """
  @callback to_map(t()) :: map()

  defmacro __using__(opts) do
    kind = Keyword.get(opts, :kind, :general)
    Errata.Errors.validate_kind_opt!(__CALLER__.module, kind)
    # `:kind` is consumed here, so strip it before `define/3` validates the rest
    # against its allowlist. The per-kind entry points do not strip it, which is
    # what makes `use Errata.DomainError, kind: :general` a compile error.
    ast = Errata.Errors.define(kind, __CALLER__.module, Keyword.delete(opts, :kind))

    quote do
      unquote(ast)
    end
  end
end
