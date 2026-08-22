# Pure check for the Home Manager module (`module/default.nix`).
#
# This is layer 4 of the ai-usage test pyramid:
#
#   1. checks/core     pure core semantics (jq + fixtures + configs)
#   2. checks/config   mkConfig output vs a golden JSON
#   3. checks/runtime  orchestrator (cache, staleness, throttling)
#   4. checks/module   THIS FILE: option shape and assertion behaviour
#
# Assertions in the module system are *data*, not exceptions: `config.assertions`
# is a list of `{assertion, message}` that a host evaluator later forces. That
# makes them testable in both directions, which is the capability this layer
# adds: every assertion gets a overlaid configuration proving it actually
# fires, not merely that its message evaluates.
#
# The module is evaluated with `lib.evalModules` against a minimal stub of the
# Home Manager options it touches (D-3). That keeps this repository at a single
# flake input and keeps evaluation fast. The cost is stub drift: if Home Manager
# changes the type of `home.packages`, this check will not notice. Consumers
# evaluate the module inside a real `home-manager` configuration, so drift
# surfaces there (see `docs/architecture.md` § test layers).
{
  pkgs,
  lib,
  ...
}: let
  aiLib = import ../../lib {inherit lib;};

  # The complete Home Manager surface this module touches. `home.homeDirectory`
  # is the module's only host-derived read; `home.packages` and `assertions` are
  # the only things it writes.
  stubHome = {lib, ...}: {
    options = {
      home.homeDirectory = lib.mkOption {
        type = lib.types.str;
        default = "/home/testuser";
      };
      home.packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
      };
      assertions = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            assertion = lib.mkOption {type = lib.types.bool;};
            message = lib.mkOption {type = lib.types.str;};
          };
        });
        default = [];
      };
    };
  };

  eval = extra:
    (lib.evalModules {
      modules = [stubHome ../../module extra];
      specialArgs = {inherit pkgs;};
    })
    .config;

  failures = c: lib.filter (a: !a.assertion) c.assertions;

  # Substring rather than regex: the messages contain `[a-zA-Z0-9]*`, `(`, `)`
  # and `.`, none of which should be read as metacharacters here.
  firesWith = c: needle: lib.any (a: lib.hasInfix needle a.message) (failures c);

  base = {programs.aiUsage.enable = true;};

  ok = eval base;
  sigma = ok.programs.aiUsage.settings;

  # `providers` carries a whole-option default, so a definition of any nested
  # path would discard the shipped defaults and leave required sub-options
  # undefined (an evaluation error, not an assertion failure). Every perturbed
  # configuration therefore restates the full registry with one field changed.
  # Most such configurations are violating ones, but not all: `overlaid` is the
  # neutral mechanism, and the rows say which direction they expect.
  defaults = aiLib.providerDefaults {homeDirectory = "/home/testuser";};

  overlaid = overlay:
    eval {
      programs.aiUsage.enable = true;
      programs.aiUsage.providers = lib.recursiveUpdate defaults overlay;
    };

  # M2 -- `from.timestamp` is a new arm of the extraction union (D-20). Two
  # properties need proving at this layer: the arm is accepted and reaches
  # `settings`, and `attrTag` still makes the union exclusive (D-4). The second
  # is why no assertion rejects a double tag: it is a *type* error, and a type
  # error is an evaluation failure rather than an assertion, so it is observed
  # with `tryEval` over a `deepSeq` that forces the whole rendered document.
  withTimestamp = overlaid {
    claude.metrics.resetsAt = {
      from.timestamp.path = ["five_hour" "resets_at"];
      unit = "raw";
      required = false;
    };
  };

  forces = c: (builtins.tryEval (builtins.deepSeq c.programs.aiUsage.settings true)).success;

  doubleTagged = overlaid {
    claude.metrics.fiveHour.from.timestamp.path = ["five_hour" "resets_at"];
  };

  vA1 = overlaid {
    claude.rules = [
      {
        metric = "nope";
        warnAt = 80;
        criticalAt = 90;
      }
    ];
  };
  vA2 = overlaid {
    claude.rules = [
      {
        metric = "fiveHour";
        warnAt = 80;
        criticalAt = 80;
      }
    ];
  };
  vA3 = overlaid {openrouter.metrics.percent.from.percentOf.total = "nope";};
  vA4 = overlaid {
    claude.metrics.bad_name = {
      from.path = ["five_hour" "utilization"];
      unit = "raw";
      required = false;
    };
  };
  vA5 = overlaid {claude.format = "{fiveHour}<b>";};
  vA6 = overlaid {claude.format = "{nosuch}";};
  vA7 = overlaid {
    claude.enable = false;
    openrouter.enable = false;
  };
  vA8 = overlaid {claude.maxStaleAge = 1;};
  vA9 = overlaid {claude.credential = null;};

  rows = [
    # ---- positive: the shipped defaults satisfy every assertion ----
    {
      name = "defaults-hold";
      condition = failures ok == [];
      message = "the shipped provider defaults violate an assertion of this module";
    }
    {
      name = "package-installed";
      condition = lib.any (p: p.name == "ai-usage") ok.home.packages;
      message = "enabling the module must install the ai-usage package";
    }
    {
      name = "disabled-noop";
      condition = (eval {programs.aiUsage.enable = false;}).home.packages == [];
      message = "a disabled module must install nothing";
    }

    # ---- the rendered document (`settings`) is the module's public output ----
    {
      name = "settings-version";
      condition = sigma.version == 1;
      message = "settings must be a schema version 1 document";
    }
    {
      name = "settings-providers";
      condition = builtins.attrNames sigma.providers == ["claude" "openrouter"];
      message = "settings must render exactly the shipped providers";
    }
    {
      name = "settings-matches-config-file-source";
      condition = sigma == aiLib.mkConfig {providers = ok.programs.aiUsage.providers;};
      message = "settings must be the same document that generates configFile";
    }
    {
      name = "settings-drops-disabled";
      condition =
        !(
          (overlaid {openrouter.enable = false;})
          .programs
          .aiUsage
          .settings
          .providers
          ? openrouter
        );
      message = "a disabled provider must not appear in settings";
    }
    {
      name = "credential-derived-from-home";
      condition =
        (eval {
          programs.aiUsage.enable = true;
          home.homeDirectory = "/home/zz";
        })
        .programs
        .aiUsage
        .settings
        .providers
        .claude
        .credential
        .file
        .path
        == "/home/zz/.claude/.credentials.json";
      message = "the claude credential path must be derived from home.homeDirectory";
    }

    # ---- the extraction union: `timestamp` accepted, exclusivity preserved ----
    {
      name = "timestamp-arm-accepted";
      condition =
        forces withTimestamp
        && withTimestamp.programs.aiUsage.settings.providers.claude.metrics.resetsAt.from
        == {timestamp.path = ["five_hour" "resets_at"];};
      message = "from.timestamp must be an accepted extraction kind and render into settings";
    }
    {
      name = "timestamp-holds-no-assertion";
      condition = failures withTimestamp == [];
      message = "a timestamp metric absent from every rule and template must violate no assertion";
    }
    {
      name = "extraction-union-stays-exclusive";
      condition = !(forces doubleTagged);
      message = "a metric carrying both path and timestamp must be a type error, not a rendered config";
    }

    # ---- negative: each assertion fires on a overlaid configuration ----
    {
      name = "A1-rule-references-unknown-metric";
      condition = firesWith vA1 "rule references unknown metric 'nope'";
      message = "a rule naming a metric that does not exist must be rejected";
    }
    {
      name = "A2-rule-thresholds-must-differ";
      condition = firesWith vA2 "must not set warnAt == criticalAt";
      message = "warnAt == criticalAt must be rejected: the ordering encodes direction";
    }
    {
      name = "A3-percentof-operand-must-exist";
      condition = firesWith vA3 "which must be an existing non-percentOf metric";
      message = "a percentOf metric naming an unknown operand must be rejected";
    }
    {
      name = "A4-metric-name-is-a-template-token";
      condition = firesWith vA4 "metric name 'bad_name' must match";
      message = "a metric name that cannot appear in a template must be rejected";
    }
    {
      name = "A5-template-is-pango-safe";
      condition = firesWith vA5 "must not contain <, > or &";
      message = "a template carrying pango markup must be rejected";
    }
    {
      name = "A6-template-references-unknown-metric";
      condition = firesWith vA6 "references unknown metric 'nosuch'";
      message = "a template token with no matching metric must be rejected";
    }
    {
      name = "A7-some-provider-must-be-enabled";
      condition = firesWith vA7 "is enabled but every provider is disabled";
      message = "enabling the module with no enabled provider must be rejected";
    }
    {
      name = "A8-maxStaleAge-covers-refreshInterval";
      condition = firesWith vA8 "must be at least refreshInterval";
      message = "a maxStaleAge below refreshInterval must be rejected";
    }
    {
      name = "A9-credential-substitution-needs-a-credential";
      condition = firesWith vA9 "but no credential source is configured";
      message = "a header substituting {credential} with no credential must be rejected";
    }
  ];

  failed = lib.filter (r: !r.condition) rows;
in
  pkgs.runCommand "check-ai-usage-module" {} ''
    fail=0

    ${lib.concatMapStrings (r: ''
        echo 'FAIL: ${r.name}: ${r.message}' >&2
        fail=1
      '')
      failed}

    if [ "$fail" != 0 ]; then
      echo 'ai-usage module check failed' >&2
      exit 1
    fi

    touch "$out"
  ''
