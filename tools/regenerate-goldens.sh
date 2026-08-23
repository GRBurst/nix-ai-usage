#!/usr/bin/env sh
# Re-cut every golden file from `lib/default.nix`.
#
# Three files pin the shipped defaults and must move together, because
# `checks/config` asserts the two `checks/core/configs` fixtures equal the
# rendered defaults (drift detection):
#
#   checks/config/expected.json          the whole rendered config document
#   checks/core/configs/claude.json      the claude provider, as layer 1 sees it
#   checks/core/configs/openrouter.json  likewise for openrouter
#
# `AGENTS.md` requires these to be regenerated deliberately rather than
# hand-edited, so run this, then read `git diff` as the review artefact. If the
# diff contains anything you did not intend to change, the change is wrong.
# Do not adjust the golden to match the code.
#
# `homeDirectory` is the only host-derived input to `mkConfig`, and the goldens
# pin a neutral `/home/testuser` so the files are reproducible off any machine.

set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
home=/home/testuser
fmt="$repo/tools/json-fmt.jq"

# `--impure` plus `getFlake` rather than a flake output: the rendered config is
# check input, not something consumers should depend on, so exposing it as an
# output would make it public API. `path:` avoids git-tree filtering, so an
# uncommitted `lib/` edit is visible here.
config=$(nix eval --impure --raw --no-write-lock-file --expr "
  let
    flake = builtins.getFlake \"path:$repo\";
    lib = flake.inputs.nixpkgs.lib;
    aiLib = import $repo/lib {inherit lib;};
  in
    builtins.toJSON (aiLib.mkConfig {
      providers = aiLib.providerDefaults {homeDirectory = \"$home\";};
    })")

printf '%s' "$config" | jq -r -f "$fmt" >"$repo/checks/config/expected.json"

for provider in claude openrouter; do
  printf '%s' "$config" |
    jq -c --arg p "$provider" '.providers[$p]' |
    jq -r -f "$fmt" >"$repo/checks/core/configs/$provider.json"
done

printf 'regenerated 3 goldens. review with: git diff -- %s\n' \
  'checks/config/expected.json checks/core/configs'
