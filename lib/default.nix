# Pure config builder for the ai-usage query layer.
#
# This turns the evaluated Home Manager option tree into the version-1 JSON
# config document consumed by `ai-usage` (see `module/package.nix`).
#
# Purity guard: this file must not reference `config`, `pkgs`, or any host
# state. Its only input is `lib`, and the only host-derived value it takes is
# `homeDirectory`, passed explicitly. That keeps the config builder testable in
# isolation by `checks/config` and reusable by any consumer.
{lib}: let
  # A null value means "this key is absent", not "this key is null". Absent is
  # the identity for every optional field below, and the jq core uses `has`
  # rather than `// null`, so stripping keeps the document minimal and the
  # golden file readable.
  stripNull = lib.filterAttrs (_: v: v != null);

  # `required` is meaningless for a derived metric: a percentOf metric is null
  # exactly when its operands are null or the total is non-positive, which is a
  # legitimate state (an unlimited OpenRouter key). Emitting no key at all makes
  # "required percentOf metric" unrepresentable downstream (D-11).
  isDerived = m: m.from ? percentOf;

  # `floor` is emitted only when it is false. Absent means "truncate", which is
  # the overwhelmingly common case, so writing `"floor": true` onto every metric
  # would add a line of noise per metric and move three golden files without
  # changing any behaviour. Omitting the default follows `stripNull` dropping a
  # null `nullText` and `required` being absent for a derived metric.
  renderMetric = _name: m:
    stripNull ({
        inherit (m) from unit;
        nullText = m.nullText or null;
      }
      // lib.optionalAttrs (!isDerived m) {
        inherit (m) required;
      }
      // lib.optionalAttrs (!(m.floor or true)) {
        floor = false;
      });

  # Enabled extras merge into the provider's metrics here, in the pure builder,
  # and the `extras` grouping itself is never emitted: the rendered document
  # carries one flat metric set and the core has no notion of an extra (D-24).
  #
  # Merge order is unobservable. A10 and A11 guarantee the name sets are
  # pairwise disjoint, so `//` cannot overwrite anything, and `builtins.toJSON`
  # sorts keys, so the serialised document does not depend on attrset order.
  #
  # `p.extras or {}` because `providerDefaults` and the hand-written provider
  # attrsets in `checks/config` are plain data that predate the option, not
  # evaluated submodules with defaults filled in.
  effectiveMetrics = p:
    lib.foldl' (acc: e: acc // e.metrics) p.metrics
    (lib.attrValues (lib.filterAttrs (_: e: e.enable) (p.extras or {})));

  renderProvider = name: p:
    stripNull {
      # The core reads `$provider.name`. The orchestrator also injects it, but
      # pinning it here keeps hand-written check configs and generated configs
      # structurally identical.
      inherit name;
      inherit
        (p)
        enable
        timeout
        refreshInterval
        retryInterval
        maxStaleAge
        source
        rules
        format
        ;
      tooltipFormat = p.tooltipFormat or null;
      credential = p.credential or null;
      metrics = lib.mapAttrs renderMetric (effectiveMetrics p);
    };
in {
  # mkConfig :: { providers :: attrsOf provider } -> attrs
  #
  # Disabled providers are dropped entirely rather than emitted with
  # `enable = false`, so `ai-usage <disabled>` is a usage error and a bar
  # block for a disabled provider cannot be rendered.
  mkConfig = {providers}: {
    version = 1;
    providers =
      lib.mapAttrs renderProvider
      (lib.filterAttrs (_: p: p.enable) providers);
  };

  # The shipped provider registry. This is the single definition of the built-in
  # defaults: it is both the default value of `programs.aiUsage.providers` and
  # the input to `checks/config`, which pins the rendered result against
  # `expected.json`. Every field is spelled out so `mkConfig` can read
  # attributes strictly instead of re-encoding defaults.
  providerDefaults = {homeDirectory}: {
    claude = {
      enable = true;
      timeout = 3;
      refreshInterval = 300;
      retryInterval = 60;
      maxStaleAge = 900;
      source.http = {
        url = "https://api.anthropic.com/api/oauth/usage";
        headers = {
          "Authorization" = "Bearer {credential}";
          "Content-Type" = "application/json";
          "User-Agent" = "claude-cli (external, cli)";
          "anthropic-beta" = "oauth-2025-04-20";
        };
      };
      credential.file = {
        path = "${homeDirectory}/.claude/.credentials.json";
        jqPath = ".claudeAiOauth.accessToken";
      };
      metrics = {
        fiveHour = {
          from.path = ["five_hour" "utilization"];
          unit = "percent";
          required = true;
          nullText = null;
        };
        sevenDay = {
          from.path = ["seven_day" "utilization"];
          unit = "percent";
          required = true;
          nullText = null;
        };
        # The window reset instants, exposed as epoch seconds so a consumer can
        # render "resets in 42m" without this repository owning a time format.
        #
        # `required = false` is load-bearing: Anthropic returns a null
        # `resets_at` for a window that has never been used, and a null required
        # metric degrades the whole document to `unknown`. Exposing more of the
        # payload must not make the bar go blank on a quiet account (D-22).
        #
        # `raw` because these are instants, not quantities: percent would clamp
        # them to 100 and dollars would prefix a currency symbol. They are also
        # absent from `format`, `tooltipFormat` and `rules`, which makes them
        # available to an adapter while staying invisible by default.
        fiveHourResetsAt = {
          from.timestamp.path = ["five_hour" "resets_at"];
          unit = "raw";
          required = false;
          nullText = null;
        };
        sevenDayResetsAt = {
          from.timestamp.path = ["seven_day" "resets_at"];
          unit = "raw";
          required = false;
          nullText = null;
        };
      };
      rules = [
        {
          metric = "fiveHour";
          warnAt = 80;
          criticalAt = 90;
        }
        {
          metric = "sevenDay";
          warnAt = 80;
          criticalAt = 90;
        }
      ];
      format = "{fiveHour}%·{sevenDay}%";
      tooltipFormat = "5h {fiveHour}% · 7d {sevenDay}%";

      extras = {
        # Anthropic reports spend twice: `spend` as {amount_minor, currency,
        # exponent} and `extra_usage` as {used_credits, decimal_places}. The
        # former is preferred because it is one canonical encoding with a
        # currency code a consumer can display.
        #
        # The minor-unit conversion happens here, inside the extra, so that
        # `unit = "dollars"` stays honest. Exposing `amount_minor` directly
        # would put a cents value behind a key that does not say cents, which
        # is the kind of unit confusion that surfaces as a bar showing a
        # hundred-fold overspend.
        spend = {
          enable = false;
          metrics = {
            # The API's own percentage, so no arithmetic is needed.
            spendPercent = {
              from.path = ["spend" "percent"];
              unit = "percent";
              required = false;
              nullText = null;
            };
            # Both numeric fields are type-guarded rather than merely
            # null-checked: this endpoint returns null for many fields, and a
            # null `exponent` would make the division raise. The orchestrator
            # would collapse that raise to null anyway, but depending on it
            # would be accidental correctness.
            spendUsed = {
              from.expression = ''
                (if (.spend.used | type) == "object" then .spend.used else {} end) as $m
                | if ($m.amount_minor | type) != "number" or ($m.exponent | type) != "number"
                  then null
                  else $m.amount_minor / pow(10; $m.exponent)
                  end
              '';
              unit = "dollars";
              required = false;
              nullText = null;
            };
            spendLimit = {
              from.expression = ''
                (if (.spend.limit | type) == "object" then .spend.limit else {} end) as $m
                | if ($m.amount_minor | type) != "number" or ($m.exponent | type) != "number"
                  then null
                  else $m.amount_minor / pow(10; $m.exponent)
                  end
              '';
              unit = "dollars";
              required = false;
              nullText = "∞";
            };
          };
        };
      };
    };

    openrouter = {
      enable = true;
      timeout = 3;
      refreshInterval = 300;
      retryInterval = 60;
      maxStaleAge = 900;
      source.http = {
        url = "https://openrouter.ai/api/v1/key";
        headers."Authorization" = "Bearer {credential}";
      };
      credential.secretTool = {
        service = "openrouter_usage";
        account = "status_bar";
      };
      metrics = {
        usage = {
          from.path = ["data" "usage"];
          unit = "dollars";
          required = true;
          nullText = null;
        };
        # An unlimited key reports a null limit. That is not an error, so the
        # metric is optional and renders as the nullText sigil instead.
        limit = {
          from.path = ["data" "limit"];
          unit = "dollars";
          required = false;
          nullText = "∞";
        };
        remaining = {
          from.path = ["data" "limit_remaining"];
          unit = "dollars";
          required = false;
          nullText = "∞";
        };
        # D-23. Usage against the *active limit window*. `limit_remaining` is
        # already window-scoped server-side, so subtracting it from `limit`
        # gives window spend without this configuration having to know what
        # `limit_reset` says, and without breaking on a reset period we have
        # never seen. `.data["usage_" + reset]` would couple us to that enum.
        #
        # The null guard is explicit rather than inherited: a jq error in a
        # pre-evaluated expression already collapses to null in
        # module/package.nix, but relying on that would be accidental
        # correctness. `dollars` rather than `raw` because float subtraction
        # produces artefacts, so that 20 - 12.05 is 7.949999999999999, and the
        # unit's clamp-and-floor is what hides them.
        windowUsage = {
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
        # Dividing all-time `usage` by a windowed `limit` reported a
        # long-lived account as permanently over budget. `usage` is retained
        # above as informational lifetime spend, and only the ratio moved.
        #
        # A3 holds: both operands are pass-1 metrics, `windowUsage` by
        # expression and `limit` by path, so this is not a percentOf of a
        # percentOf.
        percent = {
          from.percentOf = {
            of = "windowUsage";
            total = "limit";
          };
          unit = "percent";
          required = true;
          nullText = null;
        };
      };
      rules = [
        {
          metric = "percent";
          warnAt = 80;
          criticalAt = 90;
        }
      ];
      format = "{usage}/{limit}";
      tooltipFormat = "used {usage} of {limit} · {remaining} left";

      # Three independent windows the endpoint already reports. They are split
      # into one extra each rather than grouped, because a user wanting a daily
      # figure has no reason to also carry a monthly one, and the subset lattice
      # is what `checks/laws` quantifies non-interference over.
      extras = {
        daily = {
          enable = false;
          metrics.usageDaily = {
            from.path = ["data" "usage_daily"];
            unit = "dollars";
            required = false;
            nullText = null;
          };
        };
        weekly = {
          enable = false;
          metrics.usageWeekly = {
            from.path = ["data" "usage_weekly"];
            unit = "dollars";
            required = false;
            nullText = null;
          };
        };
        monthly = {
          enable = false;
          metrics.usageMonthly = {
            from.path = ["data" "usage_monthly"];
            unit = "dollars";
            required = false;
            nullText = null;
          };
        };
      };
    };
  };
}
