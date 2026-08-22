# Bar-agnostic AI usage telemetry.
#
# This module owns *acquisition* and *policy*: which providers exist, where
# their numbers come from, how credentials are resolved, and which thresholds
# map a number onto a severity. It owns no presentation: the output is a
# provider-agnostic JSON document (see `docs/architecture.md` § document
# schema) which each bar adapts to its own protocol.
#
# The three artefacts below have deliberately different purity levels:
#
#   ../lib                    pure data transformation (no config, no pkgs)
#   ./package.nix             pure derivation (config arrives as a file path)
#   ./default.nix (this file) the only place that may read `config.*`
#
# That layering keeps everything except this file consumable outside Home
# Manager; do not read `config.*` from any sibling.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.aiUsage;
  aiLib = import ../lib {inherit lib;};

  configJson =
    pkgs.writeText "ai-usage-config.json"
    (builtins.toJSON cfg.settings);

  aiUsage = pkgs.callPackage ./package.nix {configFile = configJson;};

  # A tagged union makes `{path = ...; expression = ...;}` unrepresentable, so
  # "which extraction kind is this?" has exactly one answer (D-4).
  valueType = lib.types.attrTag {
    path = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = ["five_hour" "utilization"];
      description = "Path into the parsed response body.";
    };
    percentOf = lib.mkOption {
      type = lib.types.submodule {
        options = {
          of = lib.mkOption {
            type = lib.types.str;
            description = "Numerator metric name.";
          };
          total = lib.mkOption {
            type = lib.types.str;
            description = "Denominator metric name.";
          };
        };
      };
      description = ''
        Derive a percentage from two other metrics. Resolved in a second pass,
        so it may only reference `path` or `expression` metrics.
      '';
    };
    timestamp = lib.mkOption {
      type = lib.types.submodule {
        options.path = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          example = ["five_hour" "resets_at"];
          description = "Path into the parsed response body.";
        };
      };
      description = ''
        ISO-8601 UTC timestamp at `path`, parsed to epoch seconds; null when
        absent or unparsable. A non-UTC numeric offset is deliberately rejected
        rather than shifted (D-21). Pair with `unit = "raw"`: percent and dollar
        normalisation would clamp an epoch to 100 or floor it to nothing.
      '';
    };
    expression = lib.mkOption {
      type = lib.types.str;
      example = "[.data[].amount] | add";
      description = ''
        jq expression evaluated against the raw body by the orchestrator and
        handed to the core as a pre-computed value (D-5).
      '';
    };
  };

  metricType = lib.types.submodule {
    options = {
      from = lib.mkOption {
        type = valueType;
        description = "How this metric is extracted.";
      };
      unit = lib.mkOption {
        type = lib.types.enum ["percent" "dollars" "raw"];
        default = "raw";
        description = ''
          Normalisation and rendering. `percent` clamps to 0-100 then floors,
          `dollars` clamps at 0 then floors and renders with a leading `$`,
          `raw` passes the value through untouched.
        '';
      };
      nullText = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "∞";
        description = "Rendered in place of a null value. Empty string when null.";
      };
      required = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          A null required metric makes the whole document `unknown`, so a
          mistyped path fails loudly instead of rendering empty text (D-11).
          Ignored for `percentOf` metrics, which are never required.
        '';
      };
    };
  };

  # A named, individually switchable group of additional metrics (D-24). An extra
  # may contribute metrics and nothing else: no rules, no template tokens, no
  # interval of its own. That restriction is what makes non-interference
  # provable rather than merely likely -- with no new rules `severity` and
  # `percentage` are fixed, and with `format` untouched `text` is fixed, so
  # enabling any combination of extras can only add keys to `metrics`.
  extraType = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to merge this group's metrics into the provider. Extras are
          off by default: the payloads they expose are useful to an adapter but
          would otherwise grow every user's document for no benefit.
        '';
      };

      metrics = lib.mkOption {
        type = lib.types.attrsOf metricType;
        default = {};
        description = ''
          Metrics contributed when this group is enabled. Names must not
          collide with the provider's base metrics (A10) or with another
          group's (A11), so the merge order is unobservable.
        '';
      };
    };
  };

  ruleType = lib.types.submodule {
    options = {
      metric = lib.mkOption {
        type = lib.types.str;
        description = "Name of the metric this rule watches.";
      };
      warnAt = lib.mkOption {
        type = lib.types.number;
        description = "Threshold for the `warn` severity.";
      };
      criticalAt = lib.mkOption {
        type = lib.types.number;
        description = ''
          Threshold for the `critical` severity. Direction is inferred from the
          ordering: `warnAt < criticalAt` alarms on high values,
          `warnAt > criticalAt` alarms on low values (D-10).
        '';
      };
    };
  };

  sourceType = lib.types.attrTag {
    http = lib.mkOption {
      type = lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Endpoint to GET.";
          };
          headers = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = ''
              Request headers. The literal token `{credential}` is replaced by
              the resolved credential at runtime, so the secret never appears in
              the Nix store.
            '';
          };
        };
      };
      description = "Fetch the body over HTTP.";
    };
    command = lib.mkOption {
      type = lib.types.str;
      description = ''
        Shell command whose stdout is the response body. Required for providers
        that expose no usage endpoint at all.
      '';
    };
  };

  credentialType = lib.types.attrTag {
    file = lib.mkOption {
      type = lib.types.submodule {
        options = {
          path = lib.mkOption {
            type = lib.types.str;
            description = "File to read the credential from.";
          };
          jqPath = lib.mkOption {
            type = lib.types.str;
            default = ".";
            description = "jq path selecting the credential inside the file.";
          };
        };
      };
      description = "Read the credential out of a JSON file.";
    };
    secretTool = lib.mkOption {
      type = lib.types.submodule {
        options = {
          service = lib.mkOption {type = lib.types.str;};
          account = lib.mkOption {type = lib.types.str;};
        };
      };
      description = "Look the credential up in the libsecret keyring.";
    };
    command = lib.mkOption {
      type = lib.types.str;
      description = "Shell command whose stdout is the credential.";
    };
  };

  providerType = lib.types.submodule ({config, ...}: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Disabled providers are dropped from the generated config entirely, so
          querying one is a usage error rather than a silent empty result.
        '';
      };
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Network timeout in seconds for a single fetch.";
      };
      refreshInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = ''
          Minimum seconds between successful network fetches. Independent of any
          bar's poll interval, so bars may render fast without hitting the
          network (D-13).
        '';
      };
      retryInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Minimum seconds between retries after a failed fetch.";
      };
      maxStaleAge = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3 * config.refreshInterval;
        defaultText = lib.literalExpression "3 * refreshInterval";
        description = ''
          How long the last good response may still be served after a failure
          before the document degrades to `unknown`.
        '';
      };
      source = lib.mkOption {
        type = sourceType;
        description = "Where the raw response body comes from.";
      };
      credential = lib.mkOption {
        type = lib.types.nullOr credentialType;
        default = null;
        description = "How to resolve the credential, if the source needs one.";
      };
      metrics = lib.mkOption {
        type = lib.types.attrsOf metricType;
        description = ''
          Named numbers extracted from the response. Metric names are the
          template tokens, and the generated config orders them
          lexicographically.
        '';
      };
      rules = lib.mkOption {
        type = lib.types.listOf ruleType;
        default = [];
        description = ''
          Threshold rules. The document's severity is the highest severity any
          rule yields; no rules means always `ok`.
        '';
      };
      format = lib.mkOption {
        type = lib.types.str;
        example = "{used}/{limit}";
        description = "Text template. `{metric}` tokens are substituted.";
      };
      tooltipFormat = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Tooltip template. Falls back to `format` when null.";
      };
      extras = lib.mkOption {
        type = lib.types.attrsOf extraType;
        default = {};
        description = ''
          Optional metric groups, each switchable with `extras.<name>.enable`.
          Enabled groups merge into `metrics`; the concept itself never reaches
          the rendered config, so the pure core has no notion of an extra.
        '';
      };
    };
  });

  # --- assertion helpers -----------------------------------------------------

  providerList = lib.mapAttrsToList (name: provider: {inherit name provider;}) cfg.providers;

  # Collect `{token}` occurrences from a template. Used both to validate that
  # every token names a real metric and to keep `gsub` in the jq core safe.
  # `builtins.split` takes a POSIX ERE, where `\{` is not a valid escape, so the
  # braces are matched through bracket expressions instead.
  templateTokens = template: let
    parts = builtins.split "[{]([^{}]*)[}]" template;
  in
    map builtins.head (builtins.filter builtins.isList parts);

  templatesOf = provider:
    [provider.format] ++ lib.optional (provider.tooltipFormat != null) provider.tooltipFormat;

  isDerived = metric: metric.from ? percentOf;

  # Two different metric sets, and which assertion uses which is load-bearing.
  #
  # `effectiveMetrics` is what the document will actually contain, so the
  # assertions about the emitted document -- A1, A3, A6 -- quantify over it.
  #
  # `declaredMetricNames` covers every extra whether enabled or not, because
  # A4, A10 and A11 are properties of the *declaration*. Checking those only
  # against the enabled subset would mean a user's `enable = true` is what
  # breaks the build, leaving them to work out which of 2^n subsets are legal.
  # Rejecting the declaration makes the error appear where the mistake is.
  effectiveMetrics = provider:
    lib.foldl' (acc: extra: acc // extra.metrics) provider.metrics
    (lib.attrValues (lib.filterAttrs (_: e: e.enable) provider.extras));

  declaredMetricNames = provider:
    lib.unique (lib.attrNames provider.metrics
      ++ lib.concatMap (e: lib.attrNames e.metrics) (lib.attrValues provider.extras));

  pangoSafe = text: builtins.match ".*[<>&].*" text == null;

  concatMapProviders = f: lib.concatMap f providerList;
in {
  options.programs.aiUsage = {
    enable = lib.mkEnableOption "bar-agnostic AI usage telemetry";

    providers = lib.mkOption {
      type = lib.types.attrsOf providerType;
      default = aiLib.providerDefaults {inherit (config.home) homeDirectory;};
      defaultText = lib.literalExpression "the built-in claude and openrouter providers";
      description = ''
        Provider registry. The built-in `claude` and `openrouter` entries are
        ordinary members of this attribute set, not special cases, so adding a
        provider is data rather than code (D-3).
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = aiUsage;
      defaultText = lib.literalExpression "ai-usage built from this configuration";
      description = ''
        The `ai-usage` query tool. Bar modules depend on this rather than
        re-implementing acquisition; it emits the bar-agnostic document.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = configJson;
      defaultText = lib.literalExpression "generated ai-usage config JSON";
      description = "Generated version-1 config document consumed by the query tool.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = aiLib.mkConfig {providers = cfg.providers;};
      defaultText = lib.literalExpression "mkConfig applied to the enabled providers";
      description = ''
        Rendered ai-usage configuration document (schema v1) for the enabled
        providers. Read-only; derived from `providers`. Exposed so downstream
        configurations can assert on what this module produced without
        re-deriving it or reading the generated file from the store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          # A7
          assertion = lib.any (p: p.provider.enable) providerList;
          message = "programs.aiUsage is enabled but every provider is disabled.";
        }
      ]
      # A1: a rule may only watch a metric that exists.
      ++ concatMapProviders ({
        name,
        provider,
      }:
        map (rule: {
          assertion = effectiveMetrics provider ? ${rule.metric};
          message = "aiUsage provider '${name}': rule references unknown metric '${rule.metric}'.";
        })
        provider.rules)
      # A2: equal thresholds leave the alarm direction undefined (D-10).
      ++ concatMapProviders ({
        name,
        provider,
      }:
        map (rule: {
          assertion = rule.warnAt != rule.criticalAt;
          message = "aiUsage provider '${name}': rule on '${rule.metric}' must not set warnAt == criticalAt; the ordering encodes the alarm direction.";
        })
        provider.rules)
      # A3: percentOf operands must exist and must not themselves be derived,
      # which is what makes the two-pass resolution terminating (D-6).
      ++ concatMapProviders ({
        name,
        provider,
      }:
        lib.concatMap (
          metricName: let
            metrics = effectiveMetrics provider;
            metric = metrics.${metricName};
          in
            lib.optionals (isDerived metric) (map (operand: {
              assertion =
                metrics
                ? ${operand}
                && !(isDerived metrics.${operand});
              message = "aiUsage provider '${name}': metric '${metricName}' references '${operand}', which must be an existing non-percentOf metric.";
            }) [metric.from.percentOf.of metric.from.percentOf.total])
        ) (lib.attrNames (effectiveMetrics provider)))
      # A4: metric names are interpolated into a jq regex, so restrict them.
      ++ concatMapProviders ({
        name,
        provider,
      }:
        map (metricName: {
          assertion = builtins.match "[a-zA-Z][a-zA-Z0-9]*" metricName != null;
          message = "aiUsage provider '${name}': metric name '${metricName}' must match [a-zA-Z][a-zA-Z0-9]* (it is used as a regex and as a template token).";
        }) (declaredMetricNames provider))
      # A5: i3status-rust renders custom block text as pango markup.
      ++ concatMapProviders ({
        name,
        provider,
      }:
        map (template: {
          assertion = pangoSafe template;
          message = "aiUsage provider '${name}': template '${template}' must not contain <, > or & (pango markup).";
        }) (templatesOf provider))
      # A6: an unknown token would render literally and silently.
      ++ concatMapProviders ({
        name,
        provider,
      }:
        lib.concatMap (template:
          map (token: {
            assertion = effectiveMetrics provider ? ${token};
            message = "aiUsage provider '${name}': template '${template}' references unknown metric '${token}'.";
          }) (templateTokens template)) (templatesOf provider))
      # A8: the stale window must cover at least one missed refresh.
      ++ concatMapProviders ({
        name,
        provider,
      }: [
        {
          assertion = provider.maxStaleAge >= provider.refreshInterval;
          message = "aiUsage provider '${name}': maxStaleAge (${toString provider.maxStaleAge}) must be at least refreshInterval (${toString provider.refreshInterval}).";
        }
      ])
      # A9: a header asking for a credential must have one to substitute.
      ++ concatMapProviders ({
        name,
        provider,
      }:
        lib.optionals (provider.source ? http) [
          {
            assertion =
              !(lib.any (value: lib.hasInfix "{credential}" value)
                (lib.attrValues provider.source.http.headers))
              || provider.credential != null;
            message = "aiUsage provider '${name}': a header substitutes {credential} but no credential source is configured.";
          }
        ])
      # A10: an extra must not shadow a base metric. Without this, enabling a
      # group would silently redefine a metric a rule or template depends on,
      # and `severity` would move -- exactly what extras must not be able to do.
      ++ concatMapProviders ({
        name,
        provider,
      }:
        lib.concatMap (
          extraName:
            map (metricName: {
              assertion = !(provider.metrics ? ${metricName});
              message = "aiUsage provider '${name}': extra '${extraName}' defines metric '${metricName}', but the provider already defines metric '${metricName}'.";
            }) (lib.attrNames provider.extras.${extraName}.metrics)
        ) (lib.attrNames provider.extras))
      # A11: two extras must not define the same metric. Merge order over an
      # attrset is not something a user should have to reason about, so make
      # the ambiguity unrepresentable rather than resolving it silently.
      ++ concatMapProviders ({
        name,
        provider,
      }: let
        extraNames = lib.attrNames provider.extras;
        pairs = lib.concatMap (
          i:
            map (j: {
              a = builtins.elemAt extraNames i;
              b = builtins.elemAt extraNames j;
            }) (lib.range (i + 1) (builtins.length extraNames - 1))
        ) (lib.range 0 (builtins.length extraNames - 1));
      in
        lib.concatMap (
          pair:
            map (metricName: {
              assertion = false;
              message = "aiUsage provider '${name}': extras '${pair.a}' and '${pair.b}' both define metric '${metricName}'.";
            }) (lib.intersectLists
              (lib.attrNames provider.extras.${pair.a}.metrics)
              (lib.attrNames provider.extras.${pair.b}.metrics))
        )
        pairs);

    home.packages = [aiUsage];
  };
}
