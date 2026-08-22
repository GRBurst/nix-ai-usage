# Implementation Plan: payload exposure, extras, `--raw`, law-based tests

Status: ready for implementation. Design phase closed.
Hand-over target: senior developer. Read section 4 before editing anything.

Implementation progress and verified preconditions are logged in section 10. Read it
before starting a milestone; append to it when finishing one.

## 1. Motivation

Three defects and three gaps, addressed as one coherent change:

| #      | Kind                     | Statement                                                                                                                                                                                                                                     |
| ------ | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G1     | gap                      | Claude `resets_at` (5h/7d) is unexposed. Users cannot know when the subscription frees up.                                                                                                                                                     |
| **D1** | **defect**               | OpenRouter `percent` = `usage` (all-time) / `limit` (windowed). With a monthly limit this is **arithmetically wrong** and grows without bound. Proof: `limit - limit_remaining = 200 - 44.015... = 155.984825867 = usage_monthly != usage` in general. |
| **D2** | **defect**               | `nullText` reaches `text`/`tooltip` unescaped (`module/ai-usage.jq:85-88`); A5 only guards `format`/`tooltipFormat`. `nullText = "<b>?</b>"` violates the pango invariant `checks/core` already asserts universally.                            |
| G2     | gap                      | No declarative opt-in for provider-specific optional field groups (Claude `spend`, OpenRouter daily/weekly/monthly).                                                                                                                           |
| G3     | gap                      | No way to inspect the upstream body, hence no way to mint a fixture without hand-crafting curl plus credential extraction.                                                                                                                     |
| **D3** | **defect (latent)**      | The test suite is example-based. Universal properties (severity lattice, normalisation, totality) are asserted at ~30 sampled points; the two genuine laws in `assert_case` are the exception.                                                  |

## 2. Approach

Keep the functional core (`module/ai-usage.jq`) **pure, numeric, and time-free**. All six
items are then either (a) new *data* in the pure config builder, (b) one new total
extraction primitive, (c) an imperative-shell flag, or (d) test infrastructure.

No change to: the severity engine, the `rules` schema, `percentage` semantics, the `meta`
schema, or the two-pass metric evaluation (D-6).

Blast radius by file:

| File                                              | Change                                                                       |
| ------------------------------------------------- | ---------------------------------------------------------------------------- |
| `module/ai-usage.jq`                              | `+epoch` def, `+timestamp` branch in `pass1`, `show` escapes its output       |
| `module/default.nix`                              | `+timestamp` arm in `valueType`, `+extras` option, A4 extended, `+A10`/`+A11` |
| `lib/default.nix`                                 | `+timestamp` in `renderMetric`, `+extras` merge, new provider defaults        |
| `module/package.nix`                              | `+--raw`                                                                     |
| `checks/laws/`                                    | **new** layer: generate -> execute -> verify                                 |
| `checks/config/expected.json`                     | regenerated (shipped defaults changed)                                       |
| `checks/core/`, `checks/runtime/`, `checks/module/` | **additive only** (see section 7)                                            |
| `docs/architecture.md`, `README.md`               | D-20..D-28, exit-code table, deliberately-unused field register              |

## 3. Decisions

Numbered `D-20`..`D-28`, deliberately starting above every citation already in the tree.

There is no decision register document in the repository; `D-n` exists only as inline
citations. An audit of every citation outside this directory found `D-3`, `D-4`, `D-5`,
`D-6`, `D-10`, `D-11`, `D-13`, `D-17`, `D-19` in use. This plan originally numbered its
decisions `D-11`..`D-19`, colliding with four of those on different meanings. Renumbering
the plan to `D-20`..`D-28` leaves every committed citation untouched; M6 writes the
reconciled register into `docs/architecture.md`.

### D-20 - `from.timestamp = { path = [...]; }`, emitting epoch seconds, `unit = "raw"`

Parse-Don't-Validate at the extraction boundary: the core stays numeric from pass 1
onward, so every existing law (`asnum`, `norm`, `percentOf`, `sev`) is untouched.

Absolute epoch, not remaining-seconds: a remaining value is computed at fetch time and is
therefore **wrong by up to `maxStaleAge` (900 s) whenever the document is served from
cache**. Absolute epochs are stale-immune.

Rejected:

- `$meta.now` injection - breaks purity and determinism, contradicts the contract header
  of `ai-usage.jq`, and makes countdown tests unreproducible.
- `unit = "duration"` plus formatting - the user's position: *"visualization /
  representation has to be done somewhere else, it is not part of this module"*.
- Per-metric `from.expression` with a duplicated sanitising regex - anti-declarative,
  duplicated at every call site.

### D-21 - non-UTC offsets parse to `null`, not to a shifted epoch

`fromdateiso8601` accepts exactly `%Y-%m-%dT%H:%M:%SZ` (literal trailing `Z`, no
fractional seconds, no numeric offset). Anthropic sends `...:00.029760+00:00`. Sanitise
fractional seconds and rewrite `+-00:00` to `Z`; **any other offset yields `null`**.

A silent hour-shift is strictly worse than a visible missing value. Full offset arithmetic
is additive later, behind the same law.

### D-22 - `resetsAt` metrics are `required = false`, and absent from `format`

`nimbus_quill.resets_at` and `limits[weekly_scoped].resets_at` are `null` in the real
payload. `required = true` implies `$reqOk` false, implies `$healthy` false, implies the
**entire Claude block renders `?`**.

Exposure is via `metrics` - `ai-usage.jq:118` emits *all* metrics regardless of `format` -
so `text` is byte-unchanged.

### D-23 - OpenRouter: `windowUsage = limit - limit_remaining`; `percent = percentOf(windowUsage, limit)`

`limit_remaining` is already window-scoped server-side, so this needs no knowledge of the
`limit_reset` enum and cannot break on an unseen value. Legal under A3, which forbids only
percentOf-of-percentOf; `windowUsage` is a pass-1 metric. `usage` is retained as
informational all-time.

Rejected:

- `.data["usage_" + $r]` - couples the config to an enum.
- `percentOf(remaining, limit)` with descending rules - inverts `percentage`, which bars
  read as fullness.
- A new `minus` op or `percentOf.invert` - schema for one call site.

### D-24 - `extras.<name>.enable`; extras may add metrics only

Extras never touch `format`, `tooltipFormat`, or `rules`.

Consequence, and the entire point: **non-interference is provable**. No new rules implies
`severity` fixed; `percentage` (`ai-usage.jq:104-107`) is a max over percent-unit metrics
*named by a rule*, so it is fixed; `format` fixed implies `text` fixed. Enabling any extra
can only add keys to `metrics`.

Merge order is unobservable because `builtins.toJSON` sorts keys. Merging happens in the
config layer before `mkConfig`, so **the jq core and its input schema are untouched**.

Rejected:

- `listOf str` opt-in - order-sensitive, poor cross-file composition.
- `metrics.<name>.enable` - one flag per field rather than per feature; A6 would have to
  become enable-aware; users must know upstream field names.
- Bundles exported from `lib/` - manual merge, docs-only discoverability, collisions
  constructible by the user.

### D-25 - no API severity

Thresholds remain the single severity engine; `rules` is untouched. Observed `severity`
values are only `"normal"` and `"critical"`; the middle token is **unobserved**, and
guessing it wrong maps silently to `ok`. Documented as deliberately unused.

Permission to break the `rules` schema was granted and is declined - YAGNI.

### D-26 - `--raw` exits 0 if and only if it wrote a body; otherwise 1

`ai-usage claude --raw > fixture.json` must not create an empty file and report success.

- `1` is the Unix catch-all (`cat missing` yields 1 plus stderr).
- The repository already reads as `0 = ok`, `1 = error`, `2 = usage`, so no new code is
  needed and `2` already matches the near-universal getopt convention.
- `curl --fail` is already in use, so 4xx/5xx already fails non-zero upstream; propagating
  is consistent, swallowing into 0 is not.
- `sysexits.h` self-declares as "BSD", "a few programs", and "the choice of an appropriate
  exit value is often ambiguous", so `69` would be the bespoke invention here.

**The asymmetry with document mode (always 0) is deliberate.** Document mode implements
the status-bar protocol: waybar, i3blocks and polybar treat a non-zero child as a broken
module, which is why failure is expressed *in the payload* as `severity: "unknown"`.
`--raw` is an ordinary Unix filter and obeys ordinary Unix rules. Two modes, two
contracts, each following its own established convention. This must be documented.

Corollary: "HTTP 200, empty body" is not a distinguishable state anywhere in the system -
`ok: true, body: ""` already collapses to `unknown` at `ai-usage.jq:94`. `--raw` must not
invent a distinction that exists nowhere else.

### D-27 - bounded-exhaustive laws generated in Nix; no PBT framework

Determinism implies every counterexample is minimal by construction, implies **no
shrinking is needed**. No language runtime enters a repository proud of one input. No
irreproducible failures in `nix flake check`.

Rejected: Hypothesis or proptest driving jq as a subprocess (adds a runtime, slow, random
failures irreproducible unless the seed is pinned - at which point it is a fixed suite
with extra steps); a hand-rolled jq PRNG (no shrinking, real complexity for less power
than exhaustiveness).

Honest ceiling: this is *bounded verification*, not proof. Machine-checked proof requires
the typed-core port already listed as an extension point in `docs/architecture.md`, at
which point `proptest` plus `kani` bounded model checking apply.

### D-28 - laws drive the core through its real CLI interface, not via a jq module split

One `jq` invocation per instance, parallelised with `xargs -P`.

`norm` and `sev` are fully observable through `.metrics` and `.severity`, so nothing is
lost. Idempotence-style laws that need `f(f(x))` are expressed as two invocations feeding
output back as input, which is *stronger*: it exercises the real boundary.

This keeps `ai-usage.jq` a single self-contained file, preserving the extraction guard
verbatim. Splitting into `document.jq` (defs only) plus a two-line entry point remains the
escalation if wall-clock time becomes a problem; it is a pure refactor and does not
invalidate any law written here.

## 4. Step 0 - files the implementor must read first

Do not edit anything before reading all of these.

Design and contract:

- `docs/architecture.md` - authoritative. In particular D-3 (providers are data), D-4
  (attrTag), D-5 (expressions pre-evaluated in the shell because jq has no `eval`), D-6
  (two-pass metric evaluation), D-10 (direction inferred from threshold ordering); the
  four-layer check ownership table; the purity table; the extraction guard.
- `README.md` - user-facing option surface and exit codes.

Production:

- `module/ai-usage.jq` - all 123 lines. Critical: `asnum` (L16), `pangoSafe` (L17), `norm`
  (L24-28), `pass1` (L33-41), `pass2` (L45-56), `pass3` (L59-61), `isRequired` (L65-67),
  `rank` (L69), `sev` (L72-81), `show` (L85-88), `render` (L90-92), main (L94-123).
- `lib/default.nix` - `stripNull`, `isDerived`, `renderMetric`, `renderProvider`,
  `mkConfig`, `providerDefaults`.
- `module/default.nix` - the `valueType` / `sourceType` / `credentialType` attrTags,
  `metricType`, `ruleType`, `providerType`, `templateTokens`, `pangoSafe`, assertions
  A1-A9.
- `module/package.nix` - the arg loop (L51-67), `now` (L88), `read_credential`, `fetch`,
  cache / lock / staleness (L163-216), expression pre-evaluation (L231-240), the final
  `exec jq` (L244-248).

Tests:

- `checks/core/default.nix` - especially `mkCase` and `assert_case` (L379-422). The two
  existing universal invariants there are the germ of the law harness.
- `checks/core/configs/*.json` and a sample of `checks/core/fixtures/*.json`.
- `checks/config/default.nix` and `checks/config/expected.json`.
- `checks/runtime/default.nix` and `cred.json` - the stub curl / secret-tool mechanism.
- `checks/module/default.nix` - the home-manager stub and the assertion-as-data technique.
- `flake.nix` - how checks are wired.

Payloads (ground truth):

- `claude_payload.json`, `openrouter_payload.json`.

## 5. Milestones

Dependency order. **M1 and M5 are independent of everything and of each other**, so they
are parallelisable.

| M  | Content                                                             | Gate                                    |
| -- | ------------------------------------------------------------------- | --------------------------------------- |
| M0 | Read section 4. No edits.                                           | -                                       |
| M1 | Law harness skeleton, generalised existing invariants, **D2 fix**    | `nix flake check`                       |
| M2 | `from.timestamp` (D-20, D-21) plus Claude `resetsAt` (D-22)          | golden re-cut, `unknown <=>` law        |
| M3 | OpenRouter window fix (D-23)                                        | golden re-cut                           |
| M4 | `extras` (D-24) plus shipped extras                                 | non-interference law over all subsets   |
| M5 | `--raw` (D-26)                                                      | `--raw` biconditional law               |
| M6 | Docs (D-20..D-28), exit-code table, unused-field register           | review                                  |

## 6. Test-driven implementation plan

### M1 - harness plus D2

Do this first: smallest cycle, and it fixes a live bug independent of every new feature.

#### M1.1 - test infrastructure, no new assertions yet

Create `checks/laws/default.nix` with a three-stage shape.

```nix
# generate -> execute -> verify
{ lib, runCommand, jq, ... }:
let
  jqProgram = ../../module/ai-usage.jq;

  # ---- domains: small, adversarial, boundary-dense ----
  percentVals = [ (-1) 0 0.4 0.5 1 79 79.9 80 80.1 89 90 90.1 99 99.9 100 100.1 ];
  dollarVals  = [ (-1) 0 0.99 1 155.984825867 200 ];
  units       = [ "percent" "dollars" "raw" ];
  thresholds  = [ { warnAt = 80; criticalAt = 90; }   # ascending  -> alarms high
                  { warnAt = 90; criticalAt = 80; }   # descending -> alarms low
                  { warnAt = 0;  criticalAt = 100; } ];
  nullTexts   = [ "" "∞" "?" "<b>x</b>" "a&b" "a<b>c" ];

  # lib.cartesianProductOfSets, or lib.cartesianProduct on newer nixpkgs.
  # Each instance: { name; pairId?; provider; body; expressions; meta; expect; }
  instances = /* ... */;

  instancesFile = builtins.toFile "instances.json" (builtins.toJSON instances);
in
runCommand "ai-usage-laws" { nativeBuildInputs = [ jq ]; } ''
  # ---- stage 2: execute, one invocation per instance, in parallel ----
  mkdir -p out
  # for each instance: emit {instance, doc} onto results.jsonl
  # parallelise with: xargs -P "$NIX_BUILD_CORES"
  # jq -n -c --from-file ${jqProgram} \
  #   --argjson provider "$p" --arg body "$b" \
  #   --argjson expressions "$e" --argjson meta "$m"

  # ---- stage 3: verify, pure jq over the whole result set ----
  jq -s -f ${./laws.jq} results.jsonl > violations.json
  if [ "$(jq 'length' violations.json)" != 0 ]; then
    echo "LAW VIOLATIONS:" >&2
    jq . violations.json >&2
    exit 1
  fi
  touch $out
''
```

Constraints on the harness, all load-bearing:

- Stage 3 reports **every** violation, never just the first. A law harness whose output is
  a single counterexample is a worse debugger than an example suite.
- Each violation record is `{ law, instance, doc, detail }`. The instance must be
  sufficient to reproduce by hand.
- Parallelism via `xargs -P "$NIX_BUILD_CORES"`.
- Two-invocation laws (idempotence, permutation, determinism, non-interference) are
  expressed as *paired* instances sharing a `pairId`; stage 3 groups by `pairId`. This is
  the mechanism that makes `f(f(x)) = f(x)` expressible without splitting the core
  (D-28).

`checks/laws/laws.jq` - pure verifier, defs plus one trailing expression:

```jq
def law($name; $r; $ok):
  if $ok then empty else { law: $name, instance: $r.instance, doc: $r.doc } end;

def schemaKeys:
  [ "version","provider","severity","text","tooltip",
    "percentage","metrics","stale","age","error" ];

# unary laws
def unary($r):
    law("json-shape";    $r; ($r.doc | keys_unsorted | sort) == (schemaKeys | sort))
  , law("version-1";     $r; $r.doc.version == 1)
  , law("pango-text";    $r; $r.doc.text    | test("^[^<>&]*$"))
  , law("pango-tooltip"; $r; $r.doc.tooltip | test("^[^<>&]*$"))
  , law("unknown-shape"; $r; $r.doc.severity != "unknown"
        or ($r.doc.text == "?" and $r.doc.metrics == {}
            and $r.doc.percentage == null and $r.doc.error != null))
  , law("unknown-iff";   $r; ($r.doc.severity == "unknown") == $r.expect.degenerate)
  , law("render-total";  $r; ($r.doc.text + $r.doc.tooltip) | test("\\{[a-zA-Z]") | not)
  , law("pct-range";     $r; $r.doc.percentage == null
        or ($r.doc.percentage >= 0 and $r.doc.percentage <= 100))
  , law("error-iff";     $r; ($r.doc.error != null)
        == ($r.doc.severity == "unknown" or $r.doc.stale))
  ;

[ .[] | unary(.) ] + ( group_by(.pairId) | map(binary) | flatten )
```

At this point the harness must **pass**: it only restates what `assert_case` already
guarantees. That green run over generated inputs, with zero production change, is the
baseline.

#### M1.2 - RED

Extend the generated domain with a metric that is `required = false`, has body value
`null`, draws `nullText` from `nullTexts` (which includes `"<b>x</b>"`, `"a&b"`,
`"a<b>c"`), and appears in `format`.

`pango-text` and `pango-tooltip` **must now fail**. Confirm the failure, read the
counterexample, and do not proceed until it fails for the expected reason.

#### M1.3 - GREEN

`module/ai-usage.jq` - escape inside `show`, by construction:

```jq
def show($m; $v):
  ( if $v == null then ($m.nullText // "")
    elif unitOf($m) == "dollars" then ("$" + ($v | tostring))
    else ($v | tostring)
    end
  ) | pangoSafe;
```

Preferred over an `A10: pangoSafe nullText` module assertion: the core must be safe for
*any* config, including hand-written ones and the standalone-flake extraction. Validation
at the module layer does not protect the core.

#### M1.4

`nix flake check`. Confirm all ~30 `checks/core` cases still pass unchanged. The shipped
`nullText` values are `null` and `"∞"`, which contain no `<`, `>` or `&`, so `text` output
is byte-identical.

#### M1.5

Add the remaining laws that require no new production code. Promote the example rows they
subsume, but **keep those rows** (see section 7).

- Normalisation: range and integrality per unit; monotone `x <= y => norm(x) <= norm(y)`;
  operation order, i.e. `percentOf(16, 20) == 80` exactly, pinning `floor(a*100/b)` rather
  than `floor(a)*100/floor(b)`.
- Severity lattice: boundary inclusivity over generated thresholds, `sev(warnAt) = warn`
  and `sev(criticalAt) = critical`; monotone in metric value per direction, which
  **proves D-10's direction inference** where three example rows only sampled it.
- Paired: idempotence `norm(norm(x)) = norm(x)`, by feeding `.metrics.x` back as the body;
  rule-order permutation invariance; monotone under rule-set inclusion, `rules ⊆ rules'`
  implies `rank(sev) <= rank(sev')`; **determinism**, identical inputs yield
  byte-identical stdout, which is the permanent guard that nobody reintroduces `now` into
  the core.

### M2 - `from.timestamp` plus Claude `resetsAt`

#### M2.1 - RED, core

Add a `timestamp` metric over a generated string set:

| Input                                | Expected                                     |
| ------------------------------------ | -------------------------------------------- |
| `"2026-08-21T23:10:00.029760+00:00"` | `1787353800` - Anthropic's real shape        |
| `"2026-08-24T20:00:00.029792+00:00"` | `1787601600`                                 |
| `"2027-08-05T12:19:00.001Z"`         | parses - OpenRouter's shape                  |
| `"2026-08-21T23:10:00Z"`             | parses                                       |
| `"2026-08-21T23:10:00-05:00"`        | `null` - D-21, no silent shift               |
| `"2026-08-21T23:10:00"`              | `null`                                       |
| `""`, `"  "`, `"not-a-date"`, `"1787440200"` | `null`                               |
| `null`, `0`, `[]`, `{}`, `true`      | `null`                                       |

New law **`timestamp-total`**: for all inputs the result is a number or `null`, and the
process never exits non-zero. This fails now, since there is no `timestamp` branch.

#### M2.2 - GREEN, core

`module/ai-usage.jq` - new def near `asnum`:

```jq
# ISO-8601 UTC -> epoch seconds. Total: any input yields number|null, never raises.
# jq's fromdateiso8601 accepts exactly "%Y-%m-%dT%H:%M:%SZ": no fractional
# seconds, no numeric offset. Non-UTC offsets are rejected rather than shifted.
def epoch:
  if type != "string" then null
  else
    ( sub("\\.[0-9]+(?=([Z+-]|$))"; "")   # drop fractional seconds
    | sub("[+-]00:00$"; "Z")              # UTC offset -> Z
    )
    | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      then (try fromdateiso8601 catch null)
      else null
      end
  end;
```

and a third branch in `pass1`, alongside `has("path")` and `has("expression")`:

```jq
elif ($e.value.from | has("timestamp"))
then ($doc | getpath($e.value.from.timestamp.path) | epoch)
```

Note the belt and braces: the `test` guard makes the accepted shape explicit so unexpected
input fails loudly, while `try`/`catch` makes totality unconditional even if the regex and
jq's parser ever disagree. `asnum` is deliberately **not** applied - `epoch` already
returns number or null.

#### M2.3 - RED then GREEN, module

`checks/module` first: assert the new arm exists and that the union stays exclusive. Then
`module/default.nix`, inside the `valueType` `attrTag`:

```nix
timestamp = mkOption {
  description = "ISO-8601 UTC timestamp at `path`, parsed to epoch seconds (null if unparsable).";
  type = types.submodule {
    options.path = mkOption { type = types.listOf types.str; };
  };
};
```

`attrTag` (D-4) makes `{ path = ...; timestamp = ...; }` unrepresentable - a *type error*,
not an assertion, so no new assertion is needed.

Verify A3's percentOf-operand check still holds. A `timestamp` metric is a legal operand
type-wise; it is nonsensical semantically but harmless. Do **not** add an assertion for it
(YAGNI).

#### M2.4

`lib/default.nix` - `renderMetric` must emit the `timestamp` tag. `isDerived` stays
`m: m.from ? percentOf`.

#### M2.5 - RED, config

Extend `checks/config` expectations, then add to `lib/default.nix`
`providerDefaults.claude.metrics`:

```nix
fiveHourResetsAt = {
  from.timestamp.path = [ "five_hour" "resets_at" ];
  unit = "raw";
  required = false;
  nullText = null;
};
sevenDayResetsAt = {
  from.timestamp.path = [ "seven_day" "resets_at" ];
  unit = "raw";
  required = false;
  nullText = null;
};
```

`format` and `tooltipFormat` are **unchanged** (D-22). `rules` unchanged.

#### M2.6

Regenerate `checks/config/expected.json` from the module's `settings` output. **Never
hand-edit it**; the diff is the review artifact. Expected: exactly two new keys under
`providers.claude.metrics`, nothing else.

#### M2.7

The `unknown-iff` law is the guard for D-22. Add a generated instance using the real
Claude payload with both `resets_at` null, plus a variant with `required = true`, and
confirm the `<=` direction catches the accidental `unknown`. This is the law the old suite
could not express.

#### M2.8

`nix flake check`. All existing core cases unchanged - no `checks/core/configs/*` edits
(section 7).

### M3 - OpenRouter window

#### M3.1 - RED

New `checks/core` fixture and config, both additive: the real `openrouter_payload.json`
shape, expecting `metrics.percent == 77` (`155.984825867 / 200 -> 77.99... -> floor 77`).
Document the delta against the old config's wrong value. Add boundary cases:
`limit = null`, `limit_remaining = null`, `limit = 0`.

#### M3.2 - GREEN

`lib/default.nix`, `providerDefaults.openrouter.metrics`:

```nix
windowUsage = {
  # `limit_remaining` is window-scoped server-side, so this is usage against
  # the active limit window whatever `limit_reset` says.
  from.expression = ''
    if (.data.limit == null) or (.data.limit_remaining == null)
    then null
    else .data.limit - .data.limit_remaining
    end
  '';
  unit = "dollars";
  required = false;
  nullText = "∞";
};
percent = {
  from.percentOf = { of = "windowUsage"; total = "limit"; };
  unit = "percent";
  required = true;
  nullText = null;
};
```

The explicit null guard makes intent visible. `module/package.nix:231-240` would collapse
a jq error to `null` anyway, but relying on that is accidental correctness.

A3 holds: `windowUsage` is pass-1 (`expression`), `limit` is pass-1 (`path`), neither is
`percentOf`.

#### M3.3

Regenerate the config golden. Verify `percentage` still derives only from `percent`, the
only percent-unit rule metric.

#### M3.4

`nix flake check`.

### M4 - `extras`

#### M4.1 - RED, module

`checks/module`. Assertions are data, so test **both directions**:

- A10 fires if and only if some provider has an extra whose metric names intersect the
  base metric names.
- A11 fires if and only if two distinct extras of one provider have intersecting metric
  names.
- A4 (name regex) fires for a bad name in a **disabled** extra - correctness by
  construction, not per-subset validation.

#### M4.2 - GREEN, module

`module/default.nix`:

```nix
extraType = types.submodule {
  options = {
    enable  = mkOption { type = types.bool; default = false; };
    metrics = mkOption { type = types.attrsOf metricType; default = {}; };
  };
};

# in providerType.options:
extras = mkOption { type = types.attrsOf extraType; default = {}; };
```

Assertion scope table - get this exactly right:

| Assertion                  | Metric set it quantifies over    |
| -------------------------- | -------------------------------- |
| A1 (rule metric exists)    | base + **enabled** extras        |
| A3 (percentOf operands)    | base + **enabled** extras        |
| A4 (name regex)            | base + **all** extras            |
| A6 (format tokens)         | base + **enabled** extras        |
| A10 (extra ∩ base = ∅)     | **all** extras                   |
| A11 (extra ∩ extra = ∅)    | **all** extras                   |

Rationale: A4, A10 and A11 are *static* properties of the declaration, so quantifying over
all extras turns "some subset is invalid" into an eval-time error. A1, A3 and A6 concern
the emitted document, so they follow the enabled set. Since extras add no rules and no
format tokens, A1 and A6 over the enabled set are equivalent to over base today; use
effective metrics anyway for future-proofing.

#### M4.3

`lib/default.nix` - merge in the pure builder:

```nix
enabledExtras = p: lib.filterAttrs (_: e: e.enable) (p.extras or {});

effectiveMetrics = p:
  lib.foldl' (acc: e: acc // e.metrics) p.metrics
    (lib.attrValues (enabledExtras p));
```

`renderProvider` uses `effectiveMetrics p` and **does not emit `extras`** into the
document config - the core never sees the concept.

Merge order is unobservable: A10 and A11 guarantee disjointness, and `builtins.toJSON`
sorts keys.

#### M4.4 - RED, laws

The highest-value generated law. For each shipped provider, over **every subset**
`S ⊆ extras`:

```
for all S, S' ⊆ extras.  S ⊆ S'  =>
      doc(S).text       = doc(S').text
  and doc(S).severity   = doc(S').severity
  and doc(S).percentage = doc(S').percentage
  and keys(doc(S).metrics) ⊆ keys(doc(S').metrics)
  and for all k in keys(doc(S).metrics). doc(S).metrics[k] = doc(S').metrics[k]
```

Plus, at the config layer: for all `S`, `mkConfig (providers with extras = S)` satisfies
A1-A11.

With three OpenRouter extras and one Claude extra this is `2^3 + 2^1 = 10` configs -
exhaustive and trivially cheap. **This law proves flags cannot construct an invalid or
display-altering configuration**, which is the entire justification for D-24's
restriction.

#### M4.5 - GREEN, shipped extras

`lib/default.nix`:

```nix
# claude
extras.spend = {
  enable = false;
  metrics = {
    # `spend` uses {amount_minor, currency, exponent}; prefer it over
    # `extra_usage`'s parallel {used_credits, decimal_places} encoding.
    spendPercent = {
      from.path = [ "spend" "percent" ];
      unit = "percent"; required = false; nullText = null;
    };
    spendUsed = {
      from.expression = ''
        if (.spend.used.amount_minor == null) then null
        else .spend.used.amount_minor / pow(10; .spend.used.exponent)
        end
      '';
      unit = "dollars"; required = false; nullText = null;
    };
    spendLimit = {
      from.expression = ''
        if (.spend.limit.amount_minor == null) then null
        else .spend.limit.amount_minor / pow(10; .spend.limit.exponent)
        end
      '';
      unit = "dollars"; required = false; nullText = "∞";
    };
  };
};

# openrouter
extras.daily = {
  enable = false;
  metrics.usageDaily = {
    from.path = [ "data" "usage_daily" ];
    unit = "dollars"; required = false; nullText = null;
  };
};
extras.weekly = {
  enable = false;
  metrics.usageWeekly = {
    from.path = [ "data" "usage_weekly" ];
    unit = "dollars"; required = false; nullText = null;
  };
};
extras.monthly = {
  enable = false;
  metrics.usageMonthly = {
    from.path = [ "data" "usage_monthly" ];
    unit = "dollars"; required = false; nullText = null;
  };
};
```

Minor-unit conversion happens **inside the extra**, so `unit = "dollars"` stays honest.
Rejected: exposing `amount_minor` raw, since the key name would not say "cents" - a
semantic landmine; and a new exponent-carrying unit, which is schema creep for one field.
`spendPercent` uses the API's own percent, so no arithmetic is needed.

All extras are `required = false`: an extra must never be able to render the whole block
`?`. M4.4's law enforces this.

Deferred as YAGNI: `extras.perModelLimits` over `limits[]`.
`limits[session].percent == 91 == five_hour.utilization` and
`limits[weekly_all].percent == 68 == seven_day.utilization`, so the array is redundant with
the base metrics; its only novel content today is a single `weekly_scoped` entry at
`percent: 0`. It is also the only extra needing array aggregation, since `from.path` is
`getpath` and therefore static. Addable later as pure provider data, zero schema change.

#### M4.6

Regenerate the config golden. Expected diff: extras appear only as merged metrics when
enabled, so **with all defaults (`enable = false`) the golden shows no extras at all**.
That absence is itself the assertion that extras are opt-in.

### M5 - `--raw`

Independent of M1-M4; may run in parallel.

#### M5.1 - RED, runtime

`checks/runtime` - the `--raw` law as a biconditional, against the existing stub curl and
secret-tool harness:

| #  | Scenario                                                                   | Expected                                                     |
| -- | -------------------------------------------------------------------------- | ------------------------------------------------------------ |
| 1  | stub 200 with body                                                         | exit 0; stdout == body (modulo trailing newline); stderr empty |
| 2  | stub 200; stdout parses and equals the body the document was derived from   | exit 0                                                       |
| 3  | stub fails, cold cache                                                     | exit 1; stdout empty; stderr non-empty                       |
| 4  | stub fails, warm cache within `maxStaleAge`                                | exit 0; stdout == last good body; stderr carries the error    |
| 5  | stub fails, cache beyond `maxStaleAge`                                     | exit 1; stdout empty                                         |
| 6  | second call within `refreshInterval`                                       | exit 0; no new fetch (stub call counter unchanged)            |
| 7  | `--raw --refresh`                                                          | exit 0; fetch occurred                                       |
| 8  | `--raw --config <path>`                                                    | honours the alternate config                                 |
| 9  | `--raw` with unknown provider                                              | exit 2                                                       |
| 10 | `--raw` with unknown flag                                                  | exit 2                                                       |
| L  | **law:** `exit == 0` if and only if stdout is non-empty, over scenarios 1-8 | -                                                            |

Scenario 2 is what makes `--raw` self-verifying rather than a second untested path.

#### M5.2 - GREEN

`module/package.nix`. In the arg loop (L51-67) add `--raw) rawMode=1 ;;`; everything
unmatched still falls through to `usage_error` (exit 2).

Then, **after** body and meta resolution (around L216) and **before** expression
pre-evaluation (L231):

```bash
if [ "$rawMode" = 1 ]; then
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
    exit 0
  fi
  exit 1
fi
```

Placement rationale: after resolution so `--raw` reuses the identical cache, lock and
staleness path - no second fetch implementation (DRY), and it is why scenarios 4, 6 and 7
fall out for free. Before expression pre-evaluation so raw mode does no useless work.

Diagnostics already go to stderr at L208, so stdout stays pure.

Honest caveat to document: the body round-trips through `$(...)` command substitution,
which strips trailing newlines, so `--raw` is byte-exact *modulo trailing whitespace*.
`printf '%s\n'` emits exactly one newline - correct for `> fixture.json`, and consistent
with `--rawfile` plus `fromjson`, which tolerate trailing whitespace.

Also document: `--raw` on a stale cache prints the stale body and exits 0. It does not
distinguish staleness; `stale` and `age` are document-mode concepts, and stderr already
carries the error text.

#### M5.3

Update the usage string and `README.md`. `writeShellApplication` runs `shellcheck` and
`bash -n` at build time, so a malformed edit fails the derivation.

### M6 - docs

- `docs/architecture.md`: record D-20 through D-28 in the existing decision-log style.
- Exit-code table, including the document-mode versus `--raw` asymmetry and its
  justification (D-26).
- A **deliberately unused fields** register:
  - `limits[].severity`, `spend.severity` (D-25).
  - `extra_usage.*` - superseded by `spend`'s better-typed encoding;
    `extra_usage.utilization` is `null` while `spend.percent` is populated.
  - `rate_limit` - self-declared deprecated by OpenRouter,
    `note: "This field is deprecated and safe to ignore."`.
  - `.data.label` - masked API key, useless and semi-sensitive.
  - Anthropic's codenamed cohort keys `tangelo`, `iguana_necktie`,
    `omelette_promotional`, `cinder_cove`, `amber_ladder`, `nimbus_quill`,
    `seven_day_*` - all-null or single-account, not stable API surface.
- Update the four-layer check-ownership table with `checks/laws`.
- Extraction guard: confirm still satisfied. No new file may mention `config`,
  `osConfig`, `home-manager`, or a provider name inside `ai-usage.jq`.
- `README.md`: `extras`, `from.timestamp` (the epoch-seconds contract, and that formatting
  is the bar's job), `--raw`.

## 7. Preservation rule (non-negotiable)

**Do not edit any existing `checks/core/configs/*.json` or `checks/core/fixtures/*.json`.
Add new ones.**

Consequence: all ~30 existing `checks/core` cases pass **unchanged**, including
`metrics-order-preserved`, which pins
`keys_unsorted == ["limit","percent","remaining","usage"]` against a config fixture we are
not touching.

New behaviour gets new fixtures - `claude-timestamps.json`, `openrouter-window.json`,
`openrouter-extras.json` - whose own order expectations are
`["limit","percent","remaining","usage","windowUsage"]` and
`["fiveHour","fiveHourResetsAt","sevenDay","sevenDayResetsAt"]` (lexicographic, via
`builtins.toJSON`).

The only file legitimately rewritten is `checks/config/expected.json`, because the shipped
*defaults* change by design. Regenerate it, never hand-edit it, and treat the diff as the
review artifact.

Laws **supplement** examples, they do not replace them. Delete no example row, even where a
law subsumes it: examples are documentation and pin *intent* at named points
(`percentOf(16, 20) == 80`), whereas laws pin *structure*. A green law suite with no
examples is unreadable to the next maintainer.

## 8. Type-checking strategy

| Layer                                | Checker                                                                                          | When to run                                        |
| ------------------------------------ | ------------------------------------------------------------------------------------------------ | -------------------------------------------------- |
| `module/default.nix`, `lib/default.nix` | **the Nix module system is the typechecker** - `nix eval .#...settings`, `nix flake check`      | after **every** edit, before writing the next one   |
| `valueType` union                    | `types.attrTag` (D-4) makes `{ path; timestamp; }` a **type error**, not an assertion             | eval time                                          |
| `module/package.nix`                 | `writeShellApplication` runs `shellcheck` and `bash -n`                                          | derivation build                                   |
| `module/ai-usage.jq`                 | **no typechecker exists** - see below                                                            | -                                                  |
| golden                               | `nix build .#checks.<system>.config`                                                             | after any `lib/default.nix` change                 |

jq substitute, in ascending strength:

1. **Syntax gate** - fast, run after every jq edit:

   ```
   jq -n --from-file module/ai-usage.jq \
     --argjson provider '{}' --arg body '' \
     --argjson expressions '{}' --argjson meta '{}'
   ```

   Must exit 0 and emit a valid document. Catches parse errors and unguarded null
   arithmetic in one command.

2. **Totality laws** - `timestamp-total`, `json-shape`, `render-total`. These *are* the
   type system: the core's contract is
   `(provider, body, expressions, meta) -> Document`, total, and only laws can state that.

3. **Determinism law** - identical inputs yield byte-identical stdout. Mechanically
   enforces the purity row of the architecture table.

Ordering discipline within each milestone: **module and lib edits before jq edits before
shell edits**, because the checkers get weaker in that order. Spend the strongest
checker's feedback first.

## 9. Testing strategy

Layer ownership after this work:

| Layer            | Owns                                                                | Style                            |
| ---------------- | ------------------------------------------------------------------- | -------------------------------- |
| `checks/core`    | named semantic points, one fixture each                             | examples (~35 rows)              |
| **`checks/laws`** | universally quantified properties of the core                      | bounded-exhaustive generation    |
| `checks/config`  | the shipped defaults, byte-pinned                                   | single golden                    |
| `checks/module`  | assertions A1-A11, **both directions**                              | examples as data                 |
| `checks/runtime` | shell, cache, locking, staleness, exit codes, `--raw`               | stub-driven scenarios            |

Law catalogue. A star marks laws new in this work.

**Severity as a lattice.** Rule-order permutation invariance, since `max_by(rank)` is
commutative, associative and idempotent. Monotone under rule-set inclusion: adding a rule
can only raise severity. Monotone in metric value per direction, which **proves D-10**.
Boundary inclusivity over generated thresholds.

**Normalisation.** Idempotence, `norm . norm = norm`. Range and integrality per unit.
Monotonicity, `x <= y => norm(x) <= norm(y)`, which catches accidental rounding changes.
Operation order, `floor(a*100/b)` and not `floor(a)*100/floor(b)`.

**Document totality.** Always valid JSON with exactly the schema key set and
`version == 1`. **`unknown` if and only if the body is unparsable or some required metric
is null** - today only the forward direction is checked, and the reverse direction is
precisely what catches D-22's accidental-`unknown` trap. `unknown` implies
`text == "?"`, `metrics == {}`, `percentage == null`, `error != null`. Render totality: no
residual `{token}`. `error != null` if and only if `unknown` or `stale`. `percentage` is
the max over percent-unit rule metrics, and is null or within `[0, 100]`.

**Star. Pango safety by construction.** Holds for all inputs including `nullText`, because
escaping lives in `show` (M1.3) rather than in a validator.

**Star. Timestamp parse totality.** Any input yields a number or null, never a crash.
Non-UTC offsets yield null, never a shifted epoch (D-21).

**Determinism.** Identical inputs yield byte-identical output. A permanent guard against
reintroducing `now` into the core.

**Star. Extras non-interference.** Over **every subset** of extras: `text`, `severity` and
`percentage` are invariant; `metrics` grows monotonically with agreeing values; and all of
A1-A11 still hold. Proves flags cannot construct an invalid or display-altering config
(D-24).

**Shell and cache.** Cache round-trip: rendering from a fresh fetch equals rendering from
cache for the same body, pinning the documented "cache stores the raw body" claim. Star:
the `--raw` biconditional, `exit 0` if and only if stdout is non-empty, and when 0, stdout
equals the body the document was derived from. Staleness thresholds around `maxStaleAge`.
Document mode exits 0 for every input including every failure mode - that is the bar
contract, so it deserves to be a law rather than a convention.

Stated ceiling, to be recorded in `docs/architecture.md`: exhaustive laws over a small
adversarial domain are **bounded verification, not proof**. jq is not verifiable. The
escalation path is the typed-core port already listed as an extension point, at which point
`proptest` and `kani` bounded model checking apply, and this fixture and law suite transfers
unchanged.

## 10. Implementation log

Append one subsection per milestone. Record what was *verified*, not what was intended, so
a fresh session can resume without re-deriving it.

### M0 - preconditions verified

Environment. `nix flake check path:$HOME/projects/nix/ai-usage --no-write-lock-file
--keep-going` is green at `6b0652c` for all four existing checks. jq is `1.8.2` both in
this flake's nixpkgs and on the developer's path. Only `x86_64-linux` is built locally.

The `epoch` definition of M2.2 was executed under jq 1.8.2 against the full adversarial
input list of M2.1. Every input yielded `number|null`, nothing raised, exit 0. Two
findings:

- Oniguruma supports the lookahead `(?=[Z+-])` in jq 1.8.2, so the `sub` chain is valid as
  written. No rewrite needed.
- **The plan's expected epochs were wrong by exactly one day (86400 s).** It claimed
  `1787440200` and `1787688000`; the correct values are `1787353800`
  (`2026-08-21T23:10:00Z`) and `1787601600` (`2026-08-24T20:00:00Z`), cross-checked with
  `date -u -d @<ts>`. The table in M2.1 has been corrected in place. Use the corrected
  values.

`checks/config` cross-layer coupling, which section 7 does not mention:
`checks/config/default.nix` also asserts `actual.providers.claude` equals
`checks/core/configs/claude.json`, and likewise for `openrouter`, as drift detection.
Changing a shipped default therefore forces an update to those two `checks/core/configs`
files. They are the sole exception to section 7's "do not edit any existing
`checks/core/configs/*.json`", and the exception is compelled by an existing check rather
than discretionary.

`checks/module` coupling: `programs.aiUsage.providers` carries a whole-option default, so
every violating configuration restates the full registry via `lib.recursiveUpdate defaults
overlay`. New assertions must follow that pattern or they will fire for the wrong reason.

OpenRouter capture caveat for M3: in `openrouter_payload.json`, `limit - limit_remaining =
155.98482586700001` while `usage = 155.984825867`, so both floor to `77` and the D-23 fix
is **invisible in this capture**. The defect is general - all-time `usage` over a windowed
`limit` - so the new fixture must use values where the two genuinely differ, or the check
proves nothing.
