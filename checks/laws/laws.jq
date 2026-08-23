# Stage 3 of the law harness: a pure verifier over the whole result set.
#
# Input:  the slurped array of {instance, raw, status, doc} records.
# Output: an array of violations. Empty means every law held.
#
# Every violation is reported, never just the first: a law suite whose output is
# a single counterexample is a worse debugger than an example suite. Each record
# carries the full instance, so a failure is reproducible by hand.

def law($name; $r; $ok; $detail):
  if $ok then empty
  else {law: $name, instance: $r.instance, doc: $r.doc, detail: $detail}
  end;

def law($name; $r; $ok): law($name; $r; $ok; null);

def schemaKeys:
  ["version", "provider", "severity", "text", "tooltip",
   "percentage", "metrics", "stale", "age", "error"];

def rank: {"ok": 0, "warn": 1, "critical": 2, "unknown": 3}[.];

# Anchored classes are avoided: in Oniguruma a negated class matches a newline
# and `^`/`$` are line anchors, so `test("^[^<>&]*$")` would pass a document
# whose second line carries markup. Test for the forbidden characters instead.
def hasMarkup: test("[<>&]");
def hasToken: test("\\{[a-zA-Z]");

def unitOf($r; $name): ($r.instance.provider.metrics[$name].unit) // "raw";

# The percent-unit metrics named by rules, which is what `percentage` maximises.
def rulePercents($r):
  [$r.instance.provider.rules[]?
   | select(unitOf($r; .metric) == "percent")
   | $r.doc.metrics[.metric]
   | select(. != null)];

# ---------------------------------------------------------------- unary laws

# The document schema, restated independently of checks/core's assert_case.
def shape($r):
    law("json-shape"; $r;
        ($r.doc | keys_unsorted | sort) == (schemaKeys | sort);
        {keys: ($r.doc | keys_unsorted)})
  , law("version-1"; $r; $r.doc.version == 1; {version: $r.doc.version})
  , law("pango-text"; $r; ($r.doc.text | hasMarkup | not); {text: $r.doc.text})
  , law("pango-tooltip"; $r;
        ($r.doc.tooltip | hasMarkup | not); {tooltip: $r.doc.tooltip})
  , law("render-total"; $r;
        (($r.doc.text + $r.doc.tooltip) | hasToken | not);
        {text: $r.doc.text, tooltip: $r.doc.tooltip})

  # `unknown` is the degraded document the bar contract requires.
  , law("unknown-shape"; $r;
        $r.doc.severity != "unknown"
        or ($r.doc.text == "?" and $r.doc.metrics == {}
            and $r.doc.percentage == null and $r.doc.error != null);
        {severity: $r.doc.severity, text: $r.doc.text,
         metrics: $r.doc.metrics, percentage: $r.doc.percentage,
         error: $r.doc.error})

  # The reverse direction the example suite never checked: a document must not
  # degrade for any reason other than an unparsable body or a null required
  # metric. This is what catches an accidentally-required new metric.
  , law("unknown-iff"; $r;
        ($r.doc.severity == "unknown") == $r.instance.expect.degenerate;
        {severity: $r.doc.severity, degenerate: $r.instance.expect.degenerate})

  , law("error-iff"; $r;
        ($r.doc.error != null)
        == ($r.doc.severity == "unknown" or $r.doc.stale);
        {error: $r.doc.error, severity: $r.doc.severity, stale: $r.doc.stale})
  ;

# `unit` defines the domain of the normalised value, so every reported metric
# must already sit inside it, which is also idempotence stated pointwise.
#
# Clamping and truncation are separate concerns and so are their laws.
# `norm-domain` covers the clamp, which `unit` owns unconditionally.
# `norm-integral` covers the truncation, which the per-metric `floor` flag owns,
# so it must not fire on a metric that deliberately opted out. Read with
# `has("floor")` rather than `//`: the alternative operator cannot default a
# boolean whose meaningful value is `false`, a trap the core walked into once.
def truncatesOf($r; $name):
  ($r.instance.provider.metrics[$name]) as $m
  | if ($m | type) == "object" and ($m | has("floor")) then $m.floor else true end;

def normalisation($r):
    ( $r.doc.metrics
      | to_entries[]
      | . as $m
      | law("norm-domain"; $r;
            $m.value == null
            or unitOf($r; $m.key) == "raw"
            or ($m.value >= 0
                and (unitOf($r; $m.key) != "percent" or $m.value <= 100));
            {metric: $m.key, unit: unitOf($r; $m.key), value: $m.value})
      , law("norm-integral"; $r;
            $m.value == null
            or unitOf($r; $m.key) == "raw"
            or (truncatesOf($r; $m.key) | not)
            or ($m.value | floor) == $m.value;
            {metric: $m.key, unit: unitOf($r; $m.key), value: $m.value,
             truncates: truncatesOf($r; $m.key)}) )
  , law("pct-range"; $r;
        $r.doc.percentage == null
        or ($r.doc.percentage >= 0 and $r.doc.percentage <= 100);
        {percentage: $r.doc.percentage})
  , (rulePercents($r) as $p
     | law("pct-max"; $r;
           $r.doc.severity == "unknown"
           or (if ($p | length) == 0
               then $r.doc.percentage == null
               else $r.doc.percentage == ($p | max) end);
           {percentage: $r.doc.percentage, candidates: $p}))
  ;

# `from.timestamp` resolves to whole epoch seconds or null, for any input at
# all, whether that input is a string, a number, a container, or absent. jq has
# no type system, so this law is the only statement that the parse is total.
# `unit` is irrelevant here, because an epoch
# is `raw` precisely because percent and dollar clamping would destroy it.
def timestamps($r):
  $r.instance.provider.metrics
  | to_entries[]
  | select(.value.from | has("timestamp"))
  | .key as $name
  | ($r.doc.metrics[$name]) as $v
  | law("timestamp-total"; $r;
        $v == null or (($v | type) == "number" and ($v | floor) == $v);
        {metric: $name, value: $v, type: ($v | type)});

# Pinned expectations, present only on the instances that carry them. These are
# the named points that make a generated suite readable.
def pinned($r):
    law("severity-expected"; $r;
        $r.instance.expect.severity == null
        or $r.doc.severity == $r.instance.expect.severity;
        {expected: $r.instance.expect.severity, actual: $r.doc.severity})
  , law("metrics-expected"; $r;
        $r.instance.expect.metrics == null
        or ($r.instance.expect.metrics
            | to_entries
            | all(.value == $r.doc.metrics[.key]));
        {expected: $r.instance.expect.metrics, actual: $r.doc.metrics})
  ;

def unary($r):
    law("core-exit-0"; $r; $r.status == 0; {status: $r.status, raw: $r.raw})
  , law("core-json"; $r; ($r.doc | type) == "object"; {raw: $r.raw})
  , (if ($r.doc | type) == "object"
     then shape($r), normalisation($r), timestamps($r), pinned($r)
     else empty end)
  ;

# --------------------------------------------------------------- paired laws

def pairDetail($a; $b):
  {a: {name: $a.instance.name, doc: $a.doc},
   b: {name: $b.instance.name, doc: $b.doc}};

def relation($a; $b):
  ($a.instance.expect.pair) as $rel
  | if $rel == "determinism"
    then law("determinism"; $a; $a.raw == $b.raw; {a: $a.raw, b: $b.raw})

    # `max_by(rank)` is commutative, so rule order cannot reach the document.
    elif $rel == "rule-permutation"
    then law("rule-permutation"; $a; $a.doc == $b.doc; pairDetail($a; $b))

    # A superset of rules can only raise severity, never lower it.
    elif $rel == "rule-inclusion"
    then law("rule-inclusion"; $a;
             ($a.doc.severity | rank) <= ($b.doc.severity | rank);
             pairDetail($a; $b))

    # Proves that threshold direction is inferred from rule ordering: the same
    # value pair must move severity opposite ways under opposite orderings.
    elif $rel == "value-monotone"
    then ( law("severity-monotone"; $a;
               (if $a.instance.expect.direction == "ascending"
                then ($a.doc.severity | rank) <= ($b.doc.severity | rank)
                else ($a.doc.severity | rank) >= ($b.doc.severity | rank)
                end);
               pairDetail($a; $b) + {direction: $a.instance.expect.direction})
         , law("norm-monotone"; $a;
               ($a.doc.metrics.x == null or $b.doc.metrics.x == null
                or $a.doc.metrics.x <= $b.doc.metrics.x);
               pairDetail($a; $b)) )

    # norm . norm = norm, by feeding the reported value back as the body.
    elif $rel == "norm-idempotent"
    then ( $a.instance.expect.metric as $m
         | law("norm-idempotent"; $a;
               $a.doc.metrics[$m] == $b.doc.metrics[$m]
               and $a.doc.text == $b.doc.text;
               pairDetail($a; $b) + {metric: $m}) )

    # Extras non-interference (D-24). $a is the smaller subset, $b the larger.
    # An extra may contribute metrics and nothing else, so enabling any
    # combination must leave the rendered document alone and only add keys.
    # This is the law that justifies the restriction: without it, "extras are
    # harmless" would be a claim about the four groups that ship today rather
    # than a property of the mechanism.
    elif $rel == "extras-noninterference"
    then ( law("extras-text"; $a; $a.doc.text == $b.doc.text; pairDetail($a; $b))
         , law("extras-severity"; $a;
               $a.doc.severity == $b.doc.severity; pairDetail($a; $b))
         , law("extras-percentage"; $a;
               $a.doc.percentage == $b.doc.percentage; pairDetail($a; $b))
         , law("extras-tooltip"; $a;
               $a.doc.tooltip == $b.doc.tooltip; pairDetail($a; $b))
         # metrics grows monotonically ...
         , law("extras-metrics-grow"; $a;
               (($a.doc.metrics | keys) - ($b.doc.metrics | keys)) == [];
               pairDetail($a; $b)
               + {missing: (($a.doc.metrics | keys) - ($b.doc.metrics | keys))})
         # ... and agrees on every key the smaller subset already had, so an
         # extra cannot redefine a base metric even by coincidence (A10, A11).
         , law("extras-metrics-agree"; $a;
               ($a.doc.metrics | keys) | all(. as $k
                 | $a.doc.metrics[$k] == $b.doc.metrics[$k]);
               pairDetail($a; $b)) )

    else law("unknown-relation"; $a; false; {relation: $rel})
    end;

def binary($g):
  ($g | sort_by(.instance.pairIndex)) as $s
  | if ($s | length) != 2
    then law("pair-cardinality"; $s[0]; false;
             {size: ($s | length), pairId: $s[0].instance.pairId})
    elif (($s[0].doc | type) != "object") or (($s[1].doc | type) != "object")
    then empty # already reported by core-json
    else relation($s[0]; $s[1])
    end;

. as $results
| [$results[] | unary(.)]
+ ([$results[] | select(.instance.pairId != null)]
   | group_by(.instance.pairId)
   | map(binary(.))
   | flatten)
