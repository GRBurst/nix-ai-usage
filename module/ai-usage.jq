# Provider-agnostic AI-usage core.
#
# Inputs:
#   --argjson provider    <provider config entry, including .name>
#   --arg     body        <raw response body, "" when unreadable>
#   --argjson expressions <{metric: value} for `from.expression` metrics>
#   --argjson meta        <{stale, age, error}>
#
# Output: the v1 document. Always valid JSON; the caller always exits 0.
#
# Extraction guard: this file must never mention a provider name, `config`,
# `my.*`, `osConfig` or any home-manager concept. It is lifted verbatim into a
# standalone flake.

def parse: try fromjson catch null;
def asnum: if type == "number" then . else null end;
def pangoSafe: tostring | gsub("[<>&]"; "");

def at($doc; $path):
  if $doc == null then null else (try ($doc | getpath($path)) catch null) end;

# ISO-8601 UTC -> epoch seconds. Total: any input yields number|null, never
# raises. jq's `fromdateiso8601` accepts exactly "%Y-%m-%dT%H:%M:%SZ" -- no
# fractional seconds and no numeric offset -- so both are normalised away first.
# A non-UTC offset is rejected rather than shifted: silently reinterpreting
# someone else's wall clock as an instant is the kind of wrong answer that looks
# right in a status bar. The `test` guard states the accepted shape explicitly
# and the `try` makes totality hold even if guard and parser ever disagree.
def epoch:
  if type != "string" then null
  else
    (sub("\\.[0-9]+(?=([Z+-]|$))"; "") | sub("[+-]00:00$"; "Z"))
    | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      then (try fromdateiso8601 catch null)
      else null
      end
  end;

def unitOf($m): $m.unit // "raw";

# `unit` owns clamping, `floor` owns truncation. They are separate because a bar
# wants `77%` while an adapter summing currency wants `155.984825867`; a metric
# can need the clamp and not the truncation. Absent `floor` means true, so a
# config written before the flag existed keeps its behaviour exactly. `raw` is
# exempt from both: it always passed values through untouched, and flooring it
# now would silently truncate every existing `raw` metric.
# The parameter is `$truncate`, not `$floor`: a parameter named `floor` shadows
# the builtin of the same name inside the body, so `then floor` would return the
# flag instead of truncating the value.
def norm($unit; $truncate):
  if . == null then null
  else
    (if $unit == "percent" then (if . < 0 then 0 elif . > 100 then 100 else . end)
     elif $unit == "dollars" then (if . < 0 then 0 else . end)
     else . end)
    | if $truncate and ($unit != "raw") then floor else . end
  end;

def entries: ($provider.metrics // {}) | to_entries;

# Pass 1 -- `path`, `timestamp` and `expression` metrics, raw (un-normalised)
# values. `timestamp` needs no `asnum`: `epoch` already returns number or null.
def pass1($doc):
  reduce (entries | .[]) as $e ({};
    . + {($e.key):
      (if ($e.value.from | has("path"))
       then (at($doc; $e.value.from.path) | asnum)
       elif ($e.value.from | has("timestamp"))
       then (at($doc; $e.value.from.timestamp.path) | epoch)
       elif ($e.value.from | has("expression"))
       then ($expressions[$e.key] | asnum)
       else null
       end)});

# Pass 2 -- `percentOf` metrics, referencing pass-1 names only. Multiplying
# before dividing keeps 16/20 at exactly 80.
def pass2($raw):
  reduce (entries | .[]) as $e ($raw;
    if ($e.value.from | has("percentOf"))
    then
      ( $raw[$e.value.from.percentOf.of] as $a
      | $raw[$e.value.from.percentOf.total] as $b
      | . + {($e.key):
          (if $a == null or $b == null or $b <= 0
           then null
           else ($a * 100 / $b)
           end)} )
    else . end);

# Pass 3 -- normalisation. `unit` defines the domain and the rendering, `floor`
# whether the value is truncated to a whole number on the way out. `floor` is
# read with `has`, not `//`: `false // true` is `true` in jq, so the alternative
# operator cannot default a boolean whose meaningful value is `false` -- the
# same trap `isRequired` documents below.
def pass3($raw):
  reduce (entries | .[]) as $e ({};
    . + {($e.key):
      ($raw[$e.key]
       | norm(unitOf($e.value);
              if ($e.value | has("floor")) then $e.value.floor else true end))});

# Derived metrics are never required; a typo'd path or expression is.
# `//` cannot be used to default `required`, because `false // true` is `true`.
def isRequired($m):
  ($m.from | has("percentOf") | not)
  and (if ($m | has("required")) then $m.required else true end);

def rank: {"ok": 0, "warn": 1, "critical": 2, "unknown": 3}[.];

# Threshold direction is inferred from rule ordering, not from metric names.
def sev($v; $r):
  if $v == null then null
  elif $r.warnAt < $r.criticalAt
  then (if $v >= $r.criticalAt then "critical"
        elif $v >= $r.warnAt then "warn"
        else "ok" end)
  else (if $v <= $r.criticalAt then "critical"
        elif $v <= $r.warnAt then "warn"
        else "ok" end)
  end;

# The `$` sigil belongs to the renderer, so an unlimited limit renders `∞`
# rather than `$∞`.
#
# Every rendered value passes through `pangoSafe`, so pango safety holds by
# construction for any config -- including a hand-written one, or one reaching
# this file after the standalone-flake extraction. `nullText` is free-form in the
# schema and the module validates only the templates, so a module-level
# assertion would not protect the core.
def show($m; $v):
  (if $v == null then ($m.nullText // "")
   elif unitOf($m) == "dollars" then ("$" + ($v | tostring))
   else ($v | tostring) end)
  | pangoSafe;

def render($tpl; $vals):
  reduce (entries | .[]) as $e ($tpl // "";
    gsub("\\{" + $e.key + "\\}"; show($e.value; $vals[$e.key])));

($body | parse) as $doc
| pass2(pass1($doc)) as $raw
| pass3($raw) as $vals
| ([entries | .[] | select(isRequired(.value)) | .key]
   | all($vals[.] != null)) as $reqOk
| (($doc != null) and $reqOk) as $healthy
| ([($provider.rules // [])[] | sev($vals[.metric]; .) | select(. != null)]) as $sevs
| (if ($healthy | not) then "unknown"
   elif ($sevs | length) == 0 then "ok"
   else ($sevs | max_by(rank)) end) as $severity
| ([($provider.rules // [])[]
    | select(unitOf(($provider.metrics[.metric] // {})) == "percent")
    | $vals[.metric]
    | select(. != null)]) as $pcts
| {version: 1,
   provider: ($provider.name // null),
   severity: $severity,
   text: (if $severity == "unknown" then "?"
          else render($provider.format; $vals) end),
   tooltip: (if $severity == "unknown"
             then (($meta.error // "unavailable") | pangoSafe)
             else render(($provider.tooltipFormat // $provider.format); $vals) end),
   percentage: (if $severity == "unknown" or ($pcts | length) == 0
                then null else ($pcts | max) end),
   metrics: (if $severity == "unknown" then {} else $vals end),
   stale: ($meta.stale // false),
   age: ($meta.age // null),
   error: (if $severity == "unknown"
           then ($meta.error // "unavailable")
           else $meta.error end)}
