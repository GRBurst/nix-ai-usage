# ai-usage

A declarative AI provider usage/quota query layer: a Home Manager module plus a
CLI that emits a **bar-agnostic JSON document**.

Bars do not talk to providers. `ai-usage <provider>` fetches, caches, applies
threshold rules and prints one JSON object; your status bar translates that
document into its own wire format through a small adapter you own.

Ships with `claude` (Anthropic utilisation) and `openrouter` (credit balance).
Adding a provider is data, not code.

```console
$ ai-usage openrouter | jq .
{
  "version": 1,
  "provider": "openrouter",
  "severity": "ok",
  "text": "$7.42/$25.00",
  "tooltip": "used $7.42 of $25.00 · $17.58 left",
  "percentage": 29,
  "stale": false,
  "error": null,
  "metrics": { ... }
}
```

## Install

```nix
# flake.nix
inputs.ai-usage.url = "github:<owner>/ai-usage";
inputs.ai-usage.inputs.nixpkgs.follows = "nixpkgs";
```

```nix
# home-manager
{
  imports = [inputs.ai-usage.homeModules.default];
  programs.aiUsage.enable = true;
}
```

`inputs.nixpkgs.follows` is optional and does **not** affect the binary you get:
the module builds the package with `pkgs.callPackage`, i.e. from *your* nixpkgs.
This flake's own nixpkgs serves only its checks and formatter. Following is still
worth doing to keep your lockfile small.

Credentials are not managed here. `claude` reads a logged-in Claude Code session
from `~/.claude/.credentials.json`; `openrouter` reads the keyring:

```sh
secret-tool store --label='OpenRouter' service openrouter_usage account status_bar
```

## Configure

Providers are an attribute set, and the built-ins are ordinary members of it —
override a field, disable one, or add your own:

```nix
programs.aiUsage = {
  enable = true;

  # narrow the alarm band on Claude
  providers.claude.rules = [
    {metric = "fiveHour"; warnAt = 70; criticalAt = 85;}
    {metric = "sevenDay"; warnAt = 70; criticalAt = 85;}
  ];

  providers.openrouter.enable = false;

  # a provider with no usage endpoint: produce the body locally
  providers.local = {
    source.command = "cat ~/.local/state/spend.json";
    metrics = {
      spent = {from.expression = "[.entries[].cost] | add"; unit = "dollars";};
      budget = {from.path = ["budget"]; unit = "dollars";};
      percent = {from.percentOf = {of = "spent"; total = "budget";}; unit = "percent";};
    };
    rules = [{metric = "percent"; warnAt = 80; criticalAt = 95;}];
    format = "{spent}/{budget}";
  };
};
```

A provider declares where its numbers come from (`source.http` or
`source.command`), how to authenticate (`credential.file`, `credential.secretTool`
or `credential.command`), which `metrics` to extract, which `rules` map a number
onto a severity, and how to `format` the result. Metric names double as template
tokens. Misconfiguration is caught at evaluation time by nine assertions, not at
runtime in your bar.

`programs.aiUsage.settings` exposes the rendered config document read-only, so
your own tests can assert on what the module produced.

## Wiring a bar

`ai-usage <provider>` is the whole interface. Pipe it through a `jq` adapter that
emits your bar's format — for i3status-rust, `{icon, state, text}`:

```nix
pkgs.writeShellApplication {
  name = "i3status-ai-usage";
  runtimeInputs = [pkgs.jq config.programs.aiUsage.package];
  text = ''
    ${lib.getExe config.programs.aiUsage.package} "$1" \
      | jq -c --arg icon "''${2-}" '{
          icon: $icon,
          state: (if .severity == "ok" then "Good"
                  else if .severity == "critical" then "Critical"
                  else "Warning" end),
          text: .text,
        }'
  '';
}
```

The document already carries `tooltip`, `percentage` and `stale`, which is more
than most bars need; only the wire format differs.

## Output

Always exit `0`, always one valid JSON object on stdout — a failed read is a
document with `severity = "unknown"`, `text = "?"` and a non-null `error`, never
a crash that breaks your bar. Severities are `ok < warn < critical < unknown`.

Successful bodies are cached under `$XDG_CACHE_HOME/ai-usage/<provider>.json`
with a `flock`, so several bar blocks polling at once make one request. A
provider is refetched no more often than `refreshInterval` (300 s), retried no
more often than `retryInterval` (60 s) after a failure, and the last good reading
is served marked `"stale": true` for up to `maxStaleAge` (900 s) before degrading
to `?`.

Exit codes are `0` normally, `1` for a config error and `2` for a usage error.
Use `--refresh` to force a fetch, and `--config <path>` (or `$AI_USAGE_CONFIG`)
to run against a scratch config without a rebuild.

## Development

```sh
nix flake check --keep-going   # core, laws, config, runtime, module
nix fmt
```

Five test layers, each owning exactly one thing: `core` (pure jq semantics at
named points, over JSON fixtures), `laws` (the same core, but universally
quantified properties over a generated adversarial domain), `config` (golden file
pinning the shipped provider defaults), `runtime` (the orchestrator against stub
`curl`/`secret-tool`), and `module` (the Home Manager options, plus a violating
configuration for every assertion).

See [`docs/architecture.md`](docs/architecture.md) for the config, document and
cache schemas, the three-pass resolution semantics, the provider reference, and
the planned extension points.

## Licence

MIT.
