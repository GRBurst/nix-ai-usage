# ai-usage

A declarative query layer for AI provider usage and quota. It consists of a Home
Manager module and a CLI that emits a **bar-agnostic JSON document**.

Bars do not talk to providers. `ai-usage <provider>` fetches the numbers, caches
them, applies threshold rules and prints one JSON object. Your status bar then
translates that document into its own wire format through a small adapter that
you own.

The flake ships with two providers. `claude` reports Anthropic utilisation and
`openrouter` reports the credit balance. Adding a provider is data, not code.

The following run asks for the OpenRouter balance and pretty-prints the result:

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

The account has spent 7.42 of 25 dollars, which is under every threshold, so the
severity is `ok`. The reading is fresh rather than served from cache, so `stale`
is false and `error` is null.

## Install

Add the flake as an input:

```nix
# flake.nix
inputs.ai-usage.url = "github:<owner>/ai-usage";
inputs.ai-usage.inputs.nixpkgs.follows = "nixpkgs";
```

Then import the module and enable it:

```nix
# home-manager
{
  imports = [inputs.ai-usage.homeModules.default];
  programs.aiUsage.enable = true;
}
```

The second line of the flake input is optional and does **not** affect the binary
you get. The module builds the package with `pkgs.callPackage`, which means the
build uses *your* nixpkgs. This flake's own nixpkgs serves only its checks and its
formatter. Following is still worth doing, because it keeps your lockfile small.

Credentials are not managed here. The `claude` provider reads a logged-in Claude
Code session from `~/.claude/.credentials.json`, so no extra setup is needed once
you have signed in. The `openrouter` provider reads the keyring instead, so store
the key once:

```sh
secret-tool store --label='OpenRouter' service openrouter_usage account status_bar
```

## Configure

Providers are an attribute set, and the built-ins are ordinary members of it. You
can override a single field, disable a provider, or add one of your own. The
example below does all three:

```nix
programs.aiUsage = {
  enable = true;

  # narrow the alarm band on Claude
  providers.claude.rules = [
    {metric = "fiveHour"; warnAt = 70; criticalAt = 85;}
    {metric = "sevenDay"; warnAt = 70; criticalAt = 85;}
  ];

  providers.openrouter.enable = false;

  # a provider with no usage endpoint, so the body is produced locally
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

Reading the `local` provider from the top: it runs a shell command instead of an
HTTP request, sums the cost of every entry in the resulting JSON into `spent`,
reads `budget` straight out of the body, derives `percent` from those two, warns
at 80 percent, and displays the two dollar amounts side by side.

A provider declares five things. It declares where its numbers come from, either
`source.http` or `source.command`. It declares how to authenticate, using one of
`credential.file`, `credential.secretTool` or `credential.command`. It declares
which `metrics` to extract, which `rules` map a number onto a severity, and how
to `format` the result. Metric names double as template tokens, which is why
`{spent}` above resolves to the value of the `spent` metric. Misconfiguration is
caught at evaluation time by eleven assertions rather than at runtime in your bar.

A metric can also read a timestamp. `from.timestamp.path` parses an ISO-8601 UTC
instant into epoch seconds, and yields `null` when the provider sends anything
else. The shipped `claude` provider uses this for `fiveHourResetsAt` and
`sevenDayResetsAt`. Both appear in `metrics` and in no template, so a countdown is
available to your adapter without this repository deciding how time should be
formatted.

Some payload fields are useful but not worth carrying by default, so they ship as
`extras`. These are named metric groups that you switch on individually:

```nix
programs.aiUsage.providers.openrouter.extras.weekly.enable = true;
programs.aiUsage.providers.claude.extras.spend.enable = true;
```

The `openrouter` provider ships the spend windows `daily`, `weekly` and
`monthly`. The `claude` provider ships `spend`, which converts Anthropic's minor
units into dollars. An extra can contribute metrics and nothing else. It carries
no rules and no template tokens, so enabling one adds keys to `metrics` and cannot
change `text`, `tooltip`, `severity` or `percentage`. That property is checked over
every subset of every shipped provider's extras rather than merely asserted here.

Numbers in `metrics` are truncated to whole units by default, because a bar has
room for `77%` and not for `77.9924129335%`. Set `floor = false` on a metric when
your adapter wants the provider's own precision:

```nix
programs.aiUsage.providers.openrouter.metrics.usage.floor = false;
```

With that setting `metrics` carries `155.984825867` rather than `155`. The flag is
per metric, so a truncated `limit` can sit beside a full-precision `usage` in one
document. Two consequences are worth knowing. The rendered `text` becomes whatever
the provider wrote, so a payload sending `91.0` renders as `91.0%`. A *descending*
rule also fires later, because `floor 5.5 <= 5` holds where `5.5 <= 5` does not.

`programs.aiUsage.settings` exposes the rendered config document as a read-only
option, so your own tests can assert on what the module produced.

## Wiring a bar

`ai-usage <provider>` is the whole interface. Pipe it through a `jq` adapter that
emits your bar's format. i3status-rust wants the three fields `icon`, `state` and
`text`, which the following wrapper produces:

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

The wrapper takes the provider as its first argument and an icon name as its
optional second argument. The `jq` filter then maps the four severities onto the
three states that i3status-rust knows, which is the only real translation work an
adapter has to do.

The document already carries `tooltip`, `percentage` and `stale`, which is more
than most bars need. Only the wire format differs between bars.

## Output

In document mode the CLI always exits `0` and always writes exactly one valid
JSON object to stdout. A failed read is a document with `severity = "unknown"`,
`text = "?"` and a non-null `error`, never a crash that breaks your bar. The
severities are ordered `ok < warn < critical < unknown`.

Successful bodies are cached under `$XDG_CACHE_HOME/ai-usage/<provider>.json`
behind a `flock`, so several bar blocks polling at once make a single request. A
provider is refetched no more often than `refreshInterval`, which defaults to 300
seconds. After a failure it is retried no more often than `retryInterval`, which
defaults to 60 seconds. In the meantime the last good reading is served with
`"stale": true` for up to `maxStaleAge`, which defaults to 900 seconds, and only
then does the document degrade to `?`.

The exit codes are `0` for a normal run, `1` for a config error and `2` for a
usage error. Pass `--refresh` to force a fetch, and `--config <path>` (or the
environment variable `$AI_USAGE_CONFIG`) to run against a scratch config without
a rebuild.

### `--raw`

`ai-usage <provider> --raw` prints the upstream response body instead of the
document. This is how you mint a fixture without reconstructing the request and
its credential by hand:

```sh
ai-usage claude --raw > checks/core/fixtures/my-capture.json
```

It reuses the same cache, the same lock and the same staleness policy, so
`--refresh` and throttling behave exactly as they do in document mode. It is an
ordinary Unix filter rather than the status-bar protocol, and therefore **exits
`0` if and only if it wrote a body**. An empty file is never reported as success.
A stale body still counts as a body, so it is printed with exit `0` while the
fetch error goes to stderr. Output is byte-exact apart from trailing whitespace,
which is normalised to a single newline.

## Development

```sh
nix flake check --keep-going   # core, laws, config, runtime, module
nix fmt
```

There are five test layers, and each owns exactly one thing. `core` covers pure
jq semantics at named points, driven by JSON fixtures. `laws` covers the same core
through universally quantified properties over a generated adversarial domain.
`config` is a golden file pinning the shipped provider defaults. `runtime` covers
the orchestrator against stub `curl` and `secret-tool`. `module` covers the Home
Manager options, together with a violating configuration for every assertion.

See [`docs/architecture.md`](docs/architecture.md) for the config, document and
cache schemas, the three-pass resolution semantics, the provider reference, and
the planned extension points.

## Licence

MIT.
