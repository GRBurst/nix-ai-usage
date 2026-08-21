# Pure check for the ai-usage config builder (`modules/lib/ai-usage`).
#
# This is layer 2 of the ai-usage test pyramid:
#
#   1. checks/ai-usage          pure core semantics (jq + fixtures + configs)
#   2. checks/ai-usage-config   THIS FILE: mkConfig output vs a golden JSON
#   3. checks/ai-usage-runtime  orchestrator (cache, staleness, throttling)
#   4. checks/eval-assertions   integration over evaluated hosts
#
# `expected.json` is the single place where the shipped provider defaults
# (endpoints, headers, credential locations, thresholds, templates) are pinned.
# It replaces the old "must track the module defaults" duplication that used to
# live in `checks/ai-usage/default.nix`.
#
# Extraction guard: this check must not reference `config`, `my.*`, `osConfig`,
# `home-manager` or `modules/lib/style`, so that `modules/lib/ai-usage` stays
# liftable into a standalone flake together with its check.
{
  pkgs,
  lib,
  ...
}: let
  aiLib = import ../../modules/lib/ai-usage {inherit lib;};

  # `homeDirectory` is the only host-derived input to the defaults. The golden
  # file pins the pallon value because `checks/ai-usage/configs/claude.json`
  # (layer 1) uses the same path, and the identity rows below compare the two.
  actual = aiLib.mkConfig {
    providers = aiLib.providerDefaults {homeDirectory = "/home/pallon";};
  };

  golden = builtins.fromJSON (builtins.readFile ./expected.json);

  # Layer-1 fixtures must not drift from the shipped defaults.
  coreClaude = builtins.fromJSON (builtins.readFile ../ai-usage/configs/claude.json);
  coreOpenrouter = builtins.fromJSON (builtins.readFile ../ai-usage/configs/openrouter.json);

  # A disabled provider must disappear from the rendered config entirely, so an
  # entry for a disabled provider is unrepresentable downstream (D-17).
  withDisabled = aiLib.mkConfig {
    providers =
      (aiLib.providerDefaults {homeDirectory = "/home/pallon";})
      // {
        openrouter =
          (aiLib.providerDefaults {homeDirectory = "/home/pallon";}).openrouter
          // {enable = false;};
      };
  };

  actualFile = pkgs.writeText "ai-usage-config-actual.json" (builtins.toJSON actual);
  goldenFile = pkgs.writeText "ai-usage-config-golden.json" (builtins.toJSON golden);

  rows = [
    {
      name = "core-fixture-claude-matches-defaults";
      condition = actual.providers.claude == coreClaude;
      message = "checks/ai-usage/configs/claude.json has drifted from providerDefaults.claude";
    }
    {
      name = "core-fixture-openrouter-matches-defaults";
      condition = actual.providers.openrouter == coreOpenrouter;
      message = "checks/ai-usage/configs/openrouter.json has drifted from providerDefaults.openrouter";
    }
    {
      name = "version-is-1";
      condition = actual.version == 1;
      message = "mkConfig must emit version = 1";
    }
    {
      name = "disabled-provider-is-omitted";
      condition = !(withDisabled.providers ? openrouter);
      message = "mkConfig must drop providers with enable = false";
    }
    {
      name = "enabled-provider-survives-filtering";
      condition = withDisabled.providers ? claude;
      message = "mkConfig must keep providers with enable = true";
    }
    {
      name = "percentof-metric-has-no-required-key";
      condition = !(actual.providers.openrouter.metrics.percent ? required);
      message = "percentOf metrics are never required and must not emit a required key (D-11)";
    }
    {
      name = "path-metric-has-required-key";
      condition = actual.providers.openrouter.metrics.usage ? required;
      message = "path metrics must emit an explicit required key";
    }
    {
      name = "null-nullText-is-stripped";
      condition = !(actual.providers.claude.metrics.fiveHour ? nullText);
      message = "a null nullText must be stripped rather than emitted as JSON null";
    }
    {
      name = "provider-name-is-injected";
      condition =
        actual.providers.claude.name
        == "claude"
        && actual.providers.openrouter.name == "openrouter";
      message = "mkConfig must inject the attribute name as provider.name";
    }
  ];

  failures = lib.filter (r: !r.condition) rows;
in
  pkgs.runCommand "check-ai-usage-config" {
    nativeBuildInputs = [pkgs.jq];
  } ''
    fail=0

    ${lib.concatMapStrings (r: ''
        echo 'FAIL: ${r.name}: ${r.message}' >&2
        fail=1
      '')
      failures}

    # Readable drift output: diff the pretty-printed documents rather than
    # relying on a bare Nix equality assertion.
    jq -S . ${goldenFile} > golden.json
    jq -S . ${actualFile} > actual.json
    if ! diff -u golden.json actual.json; then
      echo 'FAIL: mkConfig output drifted from checks/ai-usage-config/expected.json' >&2
      fail=1
    fi

    if [ "$fail" != 0 ]; then
      echo 'ai-usage config check failed' >&2
      exit 1
    fi

    touch "$out"
  ''
