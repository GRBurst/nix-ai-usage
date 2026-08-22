# Pure core check for the provider-agnostic AI-usage query engine.
#
# This layer is deliberately flake-independent and liftable: it exercises
# `module/ai-usage.jq` against hand-written
# provider configs (./configs) and recorded upstream response bodies
# (./fixtures). It never evaluates a host, never touches the network and never
# reads `config.my.*`.
#
# Baseline mapping from the pre-split i3-owned implementation (M0):
#
#   old `state`                     -> new `severity`
#   Good                            -> ok
#   Warning                         -> warn
#   Critical                        -> critical
#   Warning with text == "?"        -> unknown  (text stays "?")
#
# `icon` left the document entirely; it is now the bar adapter's concern.
#
# The provider defaults mirrored by ./configs/claude.json and
# ./configs/openrouter.json are pinned against `lib/` by `checks/config`, so
# these files cannot drift from the shipped defaults.
{
  pkgs,
  lib,
  ...
}: let
  jqProgram = ../../module/ai-usage.jq;
  fixtures = ./fixtures;
  configs = ./configs;

  freshMeta = {
    stale = false;
    age = 0;
    error = null;
  };

  # case :: { name, config, provider, body|null, severity, text,
  #           meta?, expressions?, extra? }
  cases = [
    # ---------------------------------------------------------------- claude
    {
      name = "claude-good";
      config = "claude.json";
      provider = "claude";
      body = "claude-low.json";
      severity = "ok";
      text = "12%·34%";
      extra = [
        ''.tooltip == "5h 12% · 7d 34%"''
        ".percentage == 34"
        # The reset timestamps arrived with the shipped defaults, and `text`,
        # `tooltip`, `percentage` and `severity` above are byte-identical to what
        # this row asserted before them. That is D-22 at a named point: exposing
        # more of the payload adds to `metrics` and to nothing else.
        ''.metrics == {"fiveHour": 12, "fiveHourResetsAt": 1787140800, "sevenDay": 34, "sevenDayResetsAt": 1787529600}''
        ".stale == false"
        ".error == null"
      ];
    }
    {
      # 2026-08-19T12:00:00Z and 2026-08-24T00:00:00Z, cross-checked with
      # `date -u -d @N`. The fixture writes a bare `Z`; the recorded payload uses
      # fractional seconds and `+00:00`, which `claude-resets-offset` covers.
      name = "claude-resets-parse-to-epoch-seconds";
      config = "claude.json";
      provider = "claude";
      body = "claude-low.json";
      severity = "ok";
      text = "12%·34%";
      extra = [
        ".metrics.fiveHourResetsAt == 1787140800"
        ".metrics.sevenDayResetsAt == 1787529600"
      ];
    }
    {
      # The shape Anthropic actually sends: fractional seconds and an explicit
      # `+00:00` rather than `Z`.
      name = "claude-resets-offset";
      config = "claude.json";
      provider = "claude";
      body = "claude-resets-offset.json";
      severity = "critical";
      text = "91%·68%";
      extra = [
        ".metrics.fiveHourResetsAt == 1787353800"
        ".metrics.sevenDayResetsAt == 1787601600"
      ];
    }
    {
      # A window the account has never used: Anthropic sends a null `resets_at`.
      # The reset metrics are optional precisely so this stays a usable document
      # rather than degrading to `unknown` (D-22).
      name = "claude-resets-null-does-not-degrade";
      config = "claude.json";
      provider = "claude";
      body = "claude-resets-null.json";
      severity = "critical";
      text = "91%·68%";
      extra = [
        ''.tooltip == "5h 91% · 7d 68%"''
        ".metrics.fiveHourResetsAt == null"
        ".metrics.sevenDayResetsAt == null"
        ".error == null"
      ];
    }
    {
      # A non-UTC offset is rejected outright rather than reinterpreted as UTC
      # (D-21): a reset silently misplaced by hours reads as authoritative.
      name = "claude-resets-non-utc-offset-is-null";
      config = "claude.json";
      provider = "claude";
      body = "claude-resets-offset-nonutc.json";
      severity = "critical";
      text = "91%·68%";
      extra = [
        ".metrics.fiveHourResetsAt == null"
        ".metrics.sevenDayResetsAt == null"
      ];
    }
    {
      name = "claude-warn-from-7d";
      config = "claude.json";
      provider = "claude";
      body = "claude-warn7d.json";
      severity = "warn";
      text = "10%·85%";
    }
    {
      name = "claude-critical-from-5h";
      config = "claude.json";
      provider = "claude";
      body = "claude-crit5h.json";
      severity = "critical";
      text = "92%·10%";
    }
    {
      name = "claude-boundary-warn-inclusive";
      config = "claude.json";
      provider = "claude";
      body = "claude-bound-warn.json";
      severity = "warn";
      text = "80%·10%";
    }
    {
      name = "claude-boundary-crit-inclusive";
      config = "claude.json";
      provider = "claude";
      body = "claude-bound-crit.json";
      severity = "critical";
      text = "90%·10%";
    }
    {
      name = "claude-fractional-floors-down";
      config = "claude.json";
      provider = "claude";
      body = "claude-frac.json";
      severity = "ok";
      text = "79%·12%";
    }
    {
      name = "claude-clamps-out-of-range";
      config = "claude.json";
      provider = "claude";
      body = "claude-over.json";
      severity = "critical";
      text = "100%·0%";
    }
    {
      name = "claude-transport-failure";
      config = "claude.json";
      provider = "claude";
      body = null;
      severity = "unknown";
      text = "?";
      extra = [
        ".metrics == {}"
        ".percentage == null"
        ".error != null"
      ];
    }
    {
      name = "claude-401";
      config = "claude.json";
      provider = "claude";
      body = "claude-401.json";
      severity = "unknown";
      text = "?";
      extra = [".error != null"];
    }
    {
      name = "claude-garbage";
      config = "claude.json";
      provider = "claude";
      body = "garbage.txt";
      severity = "unknown";
      text = "?";
    }
    # ------------------------------------------------------------ openrouter
    {
      name = "openrouter-good";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-limited.json";
      severity = "ok";
      text = "$7/$20";
      extra = [
        ''.tooltip == "used $7 of $20 · $12 left"''
        ".percentage == 37"
      ];
    }
    {
      name = "openrouter-below-warn";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-small.json";
      severity = "ok";
      text = "$15/$20";
    }
    {
      name = "openrouter-truncates-cents";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-cents.json";
      severity = "ok";
      text = "$7/$20";
      extra = [".percentage == 39"];
    }
    {
      name = "openrouter-boundary-warn-inclusive";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-warn.json";
      severity = "warn";
      text = "$16/$20";
    }
    {
      name = "openrouter-boundary-crit-inclusive";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-crit.json";
      severity = "critical";
      text = "$18/$20";
    }
    {
      # `usage` is never clamped by the limit; only `percent` is.
      name = "openrouter-clamps-over-limit";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-over.json";
      severity = "critical";
      text = "$25/$20";
      extra = [".percentage == 100"];
    }
    {
      name = "openrouter-unlimited";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-unlimited.json";
      severity = "ok";
      text = "$7/∞";
    }
    {
      name = "openrouter-zero-limit";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-zero-limit.json";
      severity = "ok";
      text = "$0/$0";
    }
    {
      name = "openrouter-missing-usage";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-no-usage.json";
      severity = "unknown";
      text = "?";
    }
    {
      name = "openrouter-transport-failure";
      config = "openrouter.json";
      provider = "openrouter";
      body = null;
      severity = "unknown";
      text = "?";
    }
    {
      name = "openrouter-garbage";
      config = "openrouter.json";
      provider = "openrouter";
      body = "garbage.txt";
      severity = "unknown";
      text = "?";
    }
    # ------------------------------------------------- staleness passthrough
    {
      name = "claude-stale-serves-last-good";
      config = "claude.json";
      provider = "claude";
      body = "claude-low.json";
      meta = {
        stale = true;
        age = 420;
        error = "429";
      };
      severity = "ok";
      text = "12%·34%";
      extra = [
        ".stale == true"
        ".age == 420"
        ''.error == "429"''
      ];
    }
    # --------------------------------- D-10: direction inferred from ordering
    {
      name = "openrouter-remaining-descending-warn";
      config = "openrouter-remaining.json";
      provider = "openrouter";
      body = "or-warn.json";
      severity = "warn";
      text = "$16/$20";
    }
    {
      name = "openrouter-remaining-descending-critical";
      config = "openrouter-remaining.json";
      provider = "openrouter";
      body = "or-remaining-low.json";
      severity = "critical";
      text = "$19/$20";
    }
    {
      name = "openrouter-remaining-descending-ok";
      config = "openrouter-remaining.json";
      provider = "openrouter";
      body = "or-limited.json";
      severity = "ok";
      text = "$7/$20";
    }
    {
      name = "openrouter-remaining-nulltext";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-unlimited.json";
      severity = "ok";
      text = "$7/∞";
      extra = [''.tooltip | test("∞")''];
    }
    # ---------------------------------------- D-5: pre-evaluated expressions
    {
      name = "expression-metric-sums";
      config = "expression-sum.json";
      provider = "expression-sum";
      body = "expr-sum.json";
      expressions = {total = 6;};
      severity = "ok";
      text = "$6";
    }
    # ------------------------------------------------ percentOf edge and D-11
    {
      name = "percentof-null-total";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-unlimited.json";
      severity = "ok";
      text = "$7/∞";
      extra = [
        ".metrics.percent == null"
        ".percentage == null"
      ];
    }
    {
      name = "required-metric-missing";
      config = "required-missing.json";
      provider = "required-missing";
      body = "claude-low.json";
      severity = "unknown";
      text = "?";
    }
    {
      name = "optional-metric-missing";
      config = "optional-missing.json";
      provider = "optional-missing";
      body = "claude-low.json";
      severity = "ok";
      text = "x";
      extra = [".metrics.absent == null"];
    }
    # ---------------------------------------------------- document invariants
    {
      name = "percentage-is-max-of-percent-rules";
      config = "claude.json";
      provider = "claude";
      body = "claude-low.json";
      severity = "ok";
      text = "12%·34%";
      extra = [".percentage == 34"];
    }
    {
      name = "metrics-order-preserved";
      config = "openrouter.json";
      provider = "openrouter";
      body = "or-limited.json";
      severity = "ok";
      text = "$7/$20";
      extra = [
        ''(.metrics | keys_unsorted) == ["limit", "percent", "remaining", "usage"]''
      ];
    }
  ];

  mkBodyArg = c:
    if c.body == null
    then ''--arg body ""''
    else "--rawfile body ${fixtures}/${c.body}";

  mkCase = c: let
    metaJson = builtins.toJSON (freshMeta // (c.meta or {}));
    exprJson = builtins.toJSON (c.expressions or {});
    extra = lib.concatMapStrings (
      f: "assert_jq ${lib.escapeShellArg c.name} ${lib.escapeShellArg f} \"$got\"\n"
    ) (c.extra or []);
  in ''
    got=$(jq -n -c --from-file ${jqProgram} \
      --argjson provider "$(cat ${configs}/${c.config})" \
      ${mkBodyArg c} \
      --argjson expressions ${lib.escapeShellArg exprJson} \
      --argjson meta ${lib.escapeShellArg metaJson})
    assert_case ${lib.escapeShellArg c.name} ${lib.escapeShellArg c.provider} \
      ${lib.escapeShellArg c.severity} ${lib.escapeShellArg c.text} "$got"
    ${extra}
  '';
in
  pkgs.runCommand "check-ai-usage" {nativeBuildInputs = [pkgs.jq];} ''
    fail=0

    assert_jq() {
      if ! printf '%s' "$3" | jq -e "$2" >/dev/null 2>&1; then
        echo "FAIL [$1]: filter did not hold: $2" >&2
        echo "  document: $3" >&2
        fail=1
      fi
    }

    assert_case() {
      name="$1"
      want_provider="$2"
      want_severity="$3"
      want_text="$4"
      doc="$5"

      got_version=$(printf '%s' "$doc" | jq -r '.version')
      got_provider=$(printf '%s' "$doc" | jq -r '.provider')
      got_severity=$(printf '%s' "$doc" | jq -r '.severity')
      got_text=$(printf '%s' "$doc" | jq -r '.text')

      if [ "$got_version" != "1" ]; then
        echo "FAIL [$name]: version expected 1, got $got_version" >&2
        fail=1
      fi
      if [ "$got_provider" != "$want_provider" ]; then
        echo "FAIL [$name]: provider expected $want_provider, got $got_provider" >&2
        fail=1
      fi
      if [ "$got_severity" != "$want_severity" ]; then
        echo "FAIL [$name]: severity expected $want_severity, got $got_severity" >&2
        fail=1
      fi
      if [ "$got_text" != "$want_text" ]; then
        echo "FAIL [$name]: text expected '$want_text', got '$got_text'" >&2
        fail=1
      fi

      # Pango safety: i3status-rust and waybar both render markup.
      if ! printf '%s' "$doc" | jq -e '.text | test("^[^<>&]*$")' >/dev/null; then
        echo "FAIL [$name]: text is not pango-safe: $got_text" >&2
        fail=1
      fi
      if ! printf '%s' "$doc" | jq -e '(.tooltip // "") | test("^[^<>&]*$")' >/dev/null; then
        echo "FAIL [$name]: tooltip is not pango-safe" >&2
        fail=1
      fi

      # `unknown` must be a total failure, never a partially rendered document.
      if [ "$got_severity" = "unknown" ]; then
        assert_jq "$name" '.text == "?" and .metrics == {} and .percentage == null and .error != null' "$doc"
      fi
    }

    ${lib.concatMapStrings mkCase cases}

    if [ "$fail" != 0 ]; then
      echo "ai-usage core check failed" >&2
      exit 1
    fi
    touch "$out"
  ''
