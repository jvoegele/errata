# Errata and AI coding agents

Errata ships agent-facing rules inside the package: a condensed account of the
error kinds, the creation macros, and — the part that earns its keep — the traps
where the obvious guess is wrong. This guide is for the person wiring them into
an application that uses Errata.

What the rules *say* is [Errata usage rules](usage-rules.md), published here and
readable on its own. This guide is about getting them in front of your agent.

Nothing here is specific to one agent. `AGENTS.md` is the instruction file most
coding agents now read; where a path below has to be concrete it is the default,
and the setting that changes it is named alongside.

## Why bother

Errata's failure modes are unusually bad for an agent working from analogy. They
compile, they read naturally, and they break somewhere other than where they
were written:

  * **Defining an error type in a test module body.** The obvious place to put a
    fixture. Protocols are consolidated at compile time, so the type silently
    gets no `String.Chars` and no JSON encoder, and the failure surfaces much
    later as a `Protocol.UndefinedError` from a `to_string/1` call in unrelated
    code. This is Rule 0 in the shipped rules, and it is first for a reason.
  * **Reaching for an accessor without guarding.** `Errata.reason/1` and friends
    raise on a value that is not an Errata error, so a handler that assumes
    every `{:error, _}` holds one dies on the first foreign error. The rules
    give both shapes — guard first, or normalise first with `Errata.to_error/2`.
  * **Reading `e.reason` directly after a guard.** `is_error/1` matches on
    struct shape, which does not refine a struct type, so the Elixir type
    checker warns on 1.18+. The fix is the accessor, and an agent will not guess
    it.
  * **Using `new/1` where `create/2` belongs.** Both build the error; only
    `create/2` captures the module, function, line, and stacktrace. Code written
    with `new/1` throughout works perfectly and quietly throws away the most
    useful thing an error has.

They are versioned with the library, so they stay right as it changes.

## What ships in the package

One file, at `deps/errata/usage-rules.md` after `mix deps.get` — about 11 KB.
Nothing to download separately.

It covers setup and `use Errata`; Rule 0; defining a type and choosing a kind;
the three ways to create an error; the cause chain and `Errata.wrap/3`; handling
errors and the accessor traps above; boundary classification; `Errata.log/2` and
`Errata.report/2`; the two type-checker surprises; and aggregates.

## Setup with `usage_rules`

[`usage_rules`](https://hex.pm/packages/usage_rules) reads a config block in your
`mix.exs` and writes the rules into your agent file for you. It is a dev-only
dependency of your application, not of Errata.

```elixir
# mix.exs
def project do
  [
    # ...
    usage_rules: usage_rules()
  ]
end

defp deps do
  [
    {:errata, "~> 1.9"},
    {:usage_rules, "~> 1.2", only: [:dev]}
  ]
end

defp usage_rules do
  [
    file: "AGENTS.md",
    usage_rules: [:errata]
  ]
end
```

Then:

```sh
mix deps.get
mix usage_rules.sync
```

That inlines the rules into `AGENTS.md`. Set `file:` to whichever instruction
file your agent reads, and commit the result so everyone on the team — and every
CI agent — gets the same instructions.

If you would rather not spend the context on every session, link instead of
inlining:

```elixir
usage_rules: [{:errata, link: :markdown}]
```

That writes a few hundred bytes pointing at `deps/errata/usage-rules.md`, which
the agent reads when it needs to. Inlining is the better default here — 11 KB is
small, and an agent that has to decide whether to go and read something often
decides not to.

Re-run `mix usage_rules.sync` after upgrading Errata, so the rules in your
repository match the version you actually depend on.

## Without `usage_rules`

The file is plain Markdown at a predictable path, so nothing here needs a tool.
Add a section to your instruction file pointing at it:

```markdown
## Errata

This project uses Errata for structured error handling. Before defining an error
type, creating an error, or writing code that inspects one, read
`deps/errata/usage-rules.md`.
```

If your agent supports imports and you would rather have the rules resident than
fetched, write that path in whatever import form it uses —
`@deps/errata/usage-rules.md` in Claude Code.

## What to add yourself

The shipped rules describe the library. They cannot know your application's
conventions, and those are usually what an agent gets wrong next. Worth adding
to your own instruction file:

  * **Where your error types live.** `lib/my_app/errors.ex`, or one module per
    context, or alongside the code that raises them — an agent will invent a
    location otherwise, and Rule 0 makes a bad guess expensive.
  * **Which kind is the default.** If nearly everything in your system is a
    domain error, say so, rather than letting each new type be a coin flip.
  * **What your boundary already does.** If you have a fallback controller or an
    error view that reads `:http_status` and `:code`, an agent should set those
    on new types instead of adding another `case`.

---

**Previous:** [Design notes](design.md) ·
**Next:** [Usage rules](usage-rules.md)
