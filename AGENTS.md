# Core Rules

## Meta Information

Project: `ai-usage`
Purpose: A declarative AI provider usage/quota query layer — a Home Manager module plus the `ai-usage` CLI, which emits a bar-agnostic JSON document. Ships `claude` and `openrouter` providers; adding a provider is data, not code.
Repository Type: Standalone Nix flake (`github:GRBurst/nix-ai-usage`). No hosts, no system configuration.
Primary Language: Nix, with a pure jq core and a POSIX shell orchestrator.
Role: Expert Nix/Home Manager engineer. Prioritize reproducibility, small correct changes, strict purity layering, explicit option boundaries, and schema stability.

## Commands

Prefer flake commands with explicit `path:` references from this checkout:

- `nix flake show path:$HOME/projects/nix/ai-usage --no-write-lock-file`
- `nix flake check path:$HOME/projects/nix/ai-usage --no-write-lock-file --keep-going`
- `nix build path:$HOME/projects/nix/ai-usage#checks.x86_64-linux.core --no-write-lock-file` (likewise `laws`, `config`, `runtime`, `module`)
- `nix fmt path:$HOME/projects/nix/ai-usage`

Pass `--keep-going` to `nix flake check`. Without it the first failing check aborts the run and masks the rest, which makes a multi-check regression look like a single failure. Build a single check by name when iterating on one layer.

Formatting is **not** part of `nix flake check`. Run the formatter explicitly.

There is no `justfile` in this project today. Do not invent `just` recipes such as `just build`, `just test`, `just lint`, or `just switch` unless a `justfile` is added first.

Use `nix fmt` or the exported formatter, Alejandra, for Nix formatting. Keep `flake.lock` unchanged unless the task explicitly requires updating inputs.

## Git And Flake References

This is an ordinary standalone Git repository with an `origin` remote; plain `git` works here. There is no dotfiles wrapper and no enclosing worktree.

For Nix commands, explicit `path:$HOME/projects/nix/ai-usage` flake references avoid accidental Git-tree filtering of uncommitted files and are the safest default while iterating: a plain `.#` reference evaluates the Git tree, so a new untracked fixture or check file will not be visible to the build.

## Agent Sandbox (nono)

Agent sessions may run inside a `nono` sandbox, which enforces filesystem and network limits at the OS level (Landlock). Denials surface as `Operation not permitted`, `Permission denied`, `EACCES`, or `EPERM` on paths that look perfectly normal. These are kernel-enforced capability boundaries, not Unix file permissions: never respond with `sudo`, `chmod`, `chown`, or by retrying the same access through a different path.

Diagnose a denial instead of guessing:

```sh
nono why --path /the/blocked/path --op read     # or --op write / --op readwrite
```

Known denials that affect this project:

- `~/.cache/nix` and `~/.local/share/nix` are not granted, so bare `nix` commands fail on `fetcher-cache-v4.sqlite` or `trusted-settings.json`. Redirect Nix state into the approved temp tree first:

```sh
export XDG_CACHE_HOME=$HOME/.cache/opencode/tmp/opencode/nixcache
export XDG_DATA_HOME=$HOME/.cache/opencode/tmp/opencode/nixdata
```

- `nix fmt path:...` may report `0 files` under the redirected state. Build the formatter and invoke it on explicit paths instead:

```sh
nix build path:$HOME/projects/nix/ai-usage#formatter.x86_64-linux \
  --no-write-lock-file --no-link --print-out-paths
# then: <out>/bin/alejandra <changed .nix files>
```

- Redirecting `XDG_CACHE_HOME` also relocates the `ai-usage` runtime cache (`$XDG_CACHE_HOME/ai-usage/`). Keep that in mind when manually validating cache behaviour; the real user cache is elsewhere.
- Network egress to provider endpoints (`api.anthropic.com`, `openrouter.ai`) is generally not granted. Do not attempt live provider calls to "verify" behaviour; use `checks/runtime`, which stubs `curl` and `secret-tool`.

If a task genuinely requires a path or host that is not granted, say so and stop rather than working around the sandbox.

## Environment

Primary dev environment is Nix. Do not suggest `apt`, `brew`, or ad hoc package installation for project dependencies.

This flake has exactly **one** input: `nixpkgs` (`nixos-unstable`), pinned in `flake.lock`.

AGENT RULE: Do not add flake inputs. In particular, do not add `home-manager` to test the module — `checks/module` evaluates it with `lib.evalModules` against a ~20-line stub of the three Home Manager options the module touches (`home.homeDirectory`, `home.packages`, `assertions`). That is a deliberate tradeoff: single input, fast evaluation, at the cost of stub drift which consumers surface downstream. Adding an input to remove the stub is a change of direction, not a fix; ask first.

This flake's own `nixpkgs` serves only its checks and formatter. The module builds the package with `pkgs.callPackage`, so consumers get the binary from _their_ nixpkgs regardless of `inputs.nixpkgs.follows`.

## Workspace Structure

`flake.nix`: flake entrypoint — single `nixpkgs` input, `homeModules`, four `checks`, and the Alejandra `formatter`.
`flake.lock`: pinned input graph; do not update casually.
`lib/default.nix`: pure config builder. `mkConfig` (option tree → schema-v1 config document) and `providerDefaults` (the shipped `claude` and `openrouter` registry). Takes `lib` plus an explicit `homeDirectory`; nothing else.
`module/default.nix`: the Home Manager module. Declares `programs.aiUsage`, the tagged-union option types, and the nine assertions. The only file permitted to read `config.*`.
`module/package.nix`: the `ai-usage` derivation — imperative shell orchestrator (argument parsing, credential resolution, HTTP fetch, `flock`ed cache, expression pre-evaluation). Receives the config as a `configFile` path.
`module/ai-usage.jq`: the pure functional core — response body plus config to the bar-agnostic document. ~120 lines.
`checks/core/`: pure core semantics over `module/ai-usage.jq`, driven by hand-written `configs/*.json` and recorded `fixtures/*.json`.
`checks/laws/`: universally quantified properties of the same core, over instances generated in Nix (`default.nix`), executed one-per-instance by `run-instance.sh`, and verified in pure jq (`laws.jq`). Bounded-exhaustive, no randomness, reports every violation.
`checks/config/`: golden test pinning `mkConfig` output against `expected.json`, plus drift detection against `checks/core/configs`.
`checks/runtime/`: orchestrator behaviour against stub `curl`/`secret-tool` — caching, staleness, throttling, credentials, exit codes, concurrency.
`checks/module/`: option shape, `settings` contents, package installation, and a violating configuration for each of the eleven assertions.
`tools/regenerate-goldens.sh`: the only sanctioned way to re-cut the three drift-coupled golden files. `tools/json-fmt.jq` is the formatter it pipes through, and reproduces the checked-in style byte-identically.
`README.md`: the user-facing surface — install, configure, wire a bar, output contract.
`docs/architecture.md`: authoritative reference — purity layering, config/document/cache schemas, three-pass resolution semantics, module option reference, assertion register, check layers, planned extension points.
`docs/plans/`: implementation plans for accepted-but-unimplemented work. Plans, not current behaviour. Section 10 of each plan is its implementation log: what was verified, and where the plan turned out to be wrong.
`claude_payload.json`, `openrouter_payload.json`: gitignored scratch captures of real provider responses at the repository root. Not test data and not implementation sources.

## Change Routing

For provider defaults (endpoints, headers, credential locations, thresholds, templates) or the rendered config schema, start in `lib/default.nix`, then re-cut the goldens with `./tools/regenerate-goldens.sh`.
For option types, option documentation, or evaluation-time invariants, start in `module/default.nix`.
For fetching, caching, credentials, staleness, CLI flags, or exit codes, start in `module/package.nix`.
For document semantics — metric extraction, normalisation, severity, rendering — start in `module/ai-usage.jq`.
For test coverage, start in the one check layer that owns the behaviour (see the ownership table under Test-Driven Development).
For architecture context, read `docs/architecture.md` before making broad changes.

## Test-Driven Development

Use a strict Red-Green-Refactor loop for feature work and bug fixes.

AGENT RULE: When adding a feature or fixing a bug, output the failing check/fixture/assertion change before outputting implementation code.

Each layer owns exactly one thing. Put a test where its owner lives; do not duplicate an invariant across layers.

| Check     | Owns                                               | Add a case here when changing                                                                                              |
| --------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `core`    | pure jq semantics                                  | extraction, units, clamping, truncation and `floor = false`, severity, templates, `percentage`, metric order, pango safety, staleness rendering |
| `laws`    | universally quantified properties of the same core | any new invariant that should hold for *all* inputs rather than at a named point: totality, ranges, monotonicity, algebraic identities, determinism |
| `config`  | the shipped defaults and the rendered config shape | provider defaults, null stripping, key omission, disabled-provider filtering                                               |
| `runtime` | the orchestrator                                   | cache, refresh/retry intervals, stale serving, credential kinds, `command` sources, exit codes, atomic writes, concurrency |
| `module`  | the Home Manager module                            | option types, `settings`, package installation, assertion firing                                                           |

`checks/config/expected.json` is the single place the shipped defaults are pinned. Changing a default means re-cutting the golden file deliberately, in the same change, with the reason stated. Do not weaken the golden diff to make a change pass.

Three files move together and must be re-cut in one step with `./tools/regenerate-goldens.sh`: `checks/config/expected.json`, `checks/core/configs/claude.json` and `checks/core/configs/openrouter.json`. `checks/config` asserts the latter two equal the shipped defaults, so editing `lib/default.nix` without regenerating fails the drift check. Never hand-edit a golden and never adjust one to match the code — the `git diff` is the review artefact.

Assertions are testable in both directions: in the module system they are _data_ (`{assertion, message}`), not exceptions. A new assertion is incomplete without a violating configuration in `checks/module` proving it actually fires.

Keep `docs/architecture.md` and `README.md` in sync when changing schemas, semantics, or user-visible behaviour.

## Nix Module Patterns

The public namespace is `programs.aiUsage`. It is the only namespace this repository owns; do not introduce a second one.

Follow existing module shape:

- Function arguments at top: `{config, lib, pkgs, ...}:`.
- Define `cfg = config.programs.aiUsage` in a `let`.
- Put option declarations under `options.programs.aiUsage`.
- Gate implementation with `config = lib.mkIf cfg.enable { ... };`.
- Use `lib.mkEnableOption`, `lib.mkOption`, and `lib.types` for typed public options.
- Prefer derived values in `let` bindings over repeated inline expressions.

Repository-specific type conventions:

- Use `lib.types.attrTag` for "one of these kinds" fields (`source`, `credential`, `metrics.<name>.from`), so `{path = ...; expression = ...;}` is unrepresentable rather than merely undefined.
- Derived, non-configurable outputs (`package`, `configFile`, `settings`) are `readOnly` options with a `default`. Consumers depend on those rather than on a package name or a re-derivation of the config.
- `settings` is typed `attrs` on purpose: its shape is pinned by the `checks/config` golden diff, and a `submodule` re-encoding would be a second owner of the same invariant.
- Every option carries a `description`; non-obvious defaults carry `defaultText`.
- New evaluation-time invariants belong in the assertion list, numbered and commented (`# A10`), with a matching violating configuration in `checks/module`.

## Architectural Patterns

### Purity layering

This is the load-bearing constraint of the repository. Four artefacts with deliberately different purity levels:

| Artefact             | May read                    | Why                                                                                      |
| -------------------- | --------------------------- | ---------------------------------------------------------------------------------------- |
| `lib/default.nix`    | `lib` only                  | pure data transformation, unit-testable without a host                                   |
| `module/ai-usage.jq` | its jq arguments            | pure function; every semantic rule testable against a fixture                            |
| `module/package.nix` | its `callPackage` arguments | ordinary derivation; config arrives as a _file path_, so the package never sees `config` |
| `module/default.nix` | `config.*`                  | the only file allowed to; wires the three above together                                 |

AGENT RULE: `lib/default.nix`, `module/package.nix` and `module/ai-usage.jq` must never mention `config`, `osConfig`, `home-manager`, or any host state. If a value is host-derived, thread it through explicitly (as `homeDirectory` is) rather than reaching for `config`.

### Functional core, imperative shell

Impure work lives in the orchestrator; semantics live in the pure core.

- The shell performs I/O: credential resolution, HTTP, cache reads/writes, locking, clock reads, and jq `expression` pre-evaluation.
- The jq core is a total, time-free function of its arguments. It receives pre-computed expression values rather than evaluating filters itself, so a malformed user filter cannot corrupt the document.
- Nix generates data (config document, derivations, assertions) and performs no I/O.

Do not move time, network, or filesystem access into the core to simplify a call site.

### Scope boundary

This repository owns **acquisition and policy**: which providers exist, where their numbers come from, how credentials resolve, and which thresholds map a number onto a severity.

It owns **no presentation**. Bar translation is deliberately out of scope: `ai-usage <provider>` emits one bar-agnostic document and a consumer adapts it in a small `jq` adapter it owns. Do not add a waybar/polybar/i3status module, an `icon` field, or any bar-specific wire format here. The document already carries `tooltip`, `percentage` and `stale`, which is more than most bars need.

### Contract stability

Three versioned schemas are public: config (v1), document (v1), cache (v1). Consumers' adapters and tests read the document; the CLI surface (`<provider> [--refresh] [--config <path>]`, `$AI_USAGE_CONFIG`, exit codes `0`/`1`/`2`) is equally public.

Additive changes are cheap; breaking ones are not. A field removal, a rename, a severity-lattice change, or an exit-code change requires a version bump and an explicit migration note, not a silent edit. Prefer designing new capability as new data in the config schema.

## Safety

The `ai-usage` CLI must always exit `0` on a normal run and always print exactly one valid JSON object on stdout. Bars typically treat a non-zero exit or unparsable output as a hard block error, so a failed read must still be a well-formed document with `severity = "unknown"`, `text = "?"` and a non-null `error`. Never introduce a code path that crashes, prints partial JSON, or writes non-JSON to stdout.

Credentials are not managed by this repository and must never enter the Nix store. The `{credential}` token in a header value is substituted at runtime, in the shell. Do not interpolate a secret in Nix, do not log a credential, and do not echo a resolved credential for debugging.

Do not commit real provider responses containing account identifiers, balances, or tokens. `claude_payload.json` and `openrouter_payload.json` are untracked scratch; if a fixture is needed, mint a redacted one under `checks/core/fixtures/`.

Do not weaken the pango-safety invariant. Bars that render markup commonly do not escape it, so `<`, `>` and `&` must not reach `text` or `tooltip`.

Cache writes must stay atomic (`.tmp` + `mv`) and serialised (`flock`). Several bar blocks poll concurrently; a torn cache file is a user-visible failure.

The Anthropic utilisation endpoint is undocumented and may change or disappear without notice. Treat graceful degradation as a requirement, not a nicety.

## Shell Scripts In Nix

Generated scripts should be strict and dependency-explicit:

- Use `pkgs.writeShellApplication`.
- Put every runtime dependency in `runtimeInputs`; avoid relying on ambient host packages.
- Keep the orchestrator POSIX-compatible in style, as it is today (`[ ... ]`, `case`, no bashisms where avoidable).
- Use Nix interpolation carefully inside shell strings; `''${...}` escapes a shell expansion and preserving that convention matters.
- Prefer `jq` for JSON parsing instead of ad hoc text parsing.

## Observability And Errors

Write actionable errors to stderr; stdout is reserved for the document.

Failure classification is part of the contract: a fetch failure (unreadable credential file, locked keyring, dead endpoint, unparsable body) degrades the document and keeps exit `0`. Exit `1` is a config error (missing config, wrong schema version). Exit `2` is a usage error (no provider, unknown provider, disabled provider, extra argument, unknown flag).

Avoid `echo` or `printf` debug noise in the orchestrator or generated config. Every line on stdout or stderr is either the document, a user-facing usage message, or actionable error context.

## Documentation

Update documentation when behaviour, schemas, user-visible workflows, or invariants change.

Use:

- `README.md` for the user-facing surface: install, configure, wire a bar, output contract, development entrypoints. Keep it short and example-led.
- `docs/architecture.md` as the authoritative reference: schemas, semantics, option reference, assertion register, check ownership, planned extension points.
- `docs/plans/*.md` for accepted-but-unimplemented work. When a plan lands, fold its decisions into `docs/architecture.md` rather than leaving the plan as the only record.

Do not treat `docs/plans/` as current behaviour, and do not treat the root `*_payload.json` captures as implementation sources.

## Code Expectations

Prefer small incremental diffs over broad rewrites.
Keep formatting consistent with Alejandra.
Preserve existing option names, schema fields, and CLI behaviour unless the request explicitly calls for a versioned migration.
Add or update the owning check layer with every behaviour change.
Use typed options and assertions for invariants instead of implicit assumptions.
Keep the cache path and config path stable unless coordinating a migration.
Avoid unrelated flake input updates and lockfile churn.
Preserve the existing comment style: files and non-obvious decisions carry a short rationale comment explaining _why_, often citing a decision or assertion identifier. Match it; do not strip it.
Skip generic explanations when repo-specific facts are available.

## Known State And Caveats

Systems are `x86_64-linux` and `aarch64-linux`; there is no host configuration in this repository and nothing to `nixos-rebuild`.

Two shipped providers: `claude` (Anthropic utilisation, credential from `~/.claude/.credentials.json`) and `openrouter` (credit balance, credential from the libsecret keyring under service `openrouter_usage`, account `status_bar`). Both runtime dependencies are unenforced by Nix and degrade the corresponding provider when absent.

Eleven module assertions, `A1`..`A11`, are numbered in comments in `module/default.nix` and tabulated in `docs/architecture.md`. `A10` and `A11` police extras: no extra may shadow a base metric, and no two extras of one provider may collide.

Design decisions are cited as `D-N` in code comments, but there is still **no decision register document** — writing one is M6 of the plan below. The numbering collision that used to exist has been resolved: the plan's decisions were renumbered to `D-20`..`D-28`, and every pre-existing in-tree citation (`D-3`..`D-19`, with `D-11` meaning "a null required metric makes the document unknown") was left untouched. Do not introduce a new `D-N` outside the `D-20`..`D-28` range until the register lands; describe the reason inline instead.

`docs/plans/payload-exposure-extras-raw-laws.md` is **largely implemented**. Milestones M1 through M4b have landed: the law harness, `nullText` escaping in the core, `from.timestamp`, the OpenRouter window-scoped `percent` fix, opt-in `extras`, and the per-metric `floor` flag. Section 10 records what was verified and where the plan was wrong. Only `M5` (`--raw`) and `M6` (docs, decision register, unused-field register) remain unimplemented; treat those two sections as a plan and everything above them as current behaviour.

`checks/module` uses a Home Manager stub, so stub drift is invisible here by design.

Formatting is not enforced by `nix flake check`.

## Collaboration Rules

Output incremental changes and diffs.
If a request is ambiguous, implies a schema-breaking change, or would cross a purity or scope boundary described above, ask for clarification before committing to a direction.
When changing repo instructions or durable project lessons, update this file instead of leaving the lesson implicit.
If follow-ups are required after a change, state them explicitly.
