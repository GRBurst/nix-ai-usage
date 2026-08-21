# Orchestrator check for the ai-usage query package.
#
# Layer 3 of the ai-usage test pyramid (see docs/architecture.md):
#   1. checks/core     pure jq core
#   2. checks/config   pure mkConfig builder
#   3. checks/runtime  this file: cache, staleness, throttling, atomicity
#   4. checks/module   Home Manager module option shape and assertions
#
# Purity guard: this file must not reference host or Home Manager state. It
# depends only on nixpkgs and on `module/package.nix`.
#
# `curl` and `libsecret` are injected as stubs through `callPackage`, because
# `writeShellApplication` prepends `runtimeInputs` to `PATH`; a stub merely
# placed on `PATH` by the builder would be shadowed by the real binary.
{
  pkgs,
  lib,
  ...
}: let
  metrics = {
    usage = {
      from.path = ["usage"];
      unit = "dollars";
      required = true;
    };
  };
  rules = [
    {
      metric = "usage";
      warnAt = 50;
      criticalAt = 90;
    }
  ];
  baseProvider = {
    enable = true;
    timeout = 3;
    refreshInterval = 300;
    retryInterval = 60;
    maxStaleAge = 900;
    inherit metrics rules;
    format = "{usage}";
    tooltipFormat = "{usage}";
  };
  httpSource = name: {
    http = {
      url = "https://ai-usage.test/${name}";
      headers.Authorization = "Bearer {credential}";
    };
  };

  # Hand-written, not produced by lib/ (D-19): the runtime
  # layer must be testable without evaluating the module tree.
  config = pkgs.writeText "ai-usage-runtime-config.json" (builtins.toJSON {
    version = 1;
    providers = {
      # command credential + http source: the main cache/staleness subject.
      httpok =
        baseProvider
        // {
          source = httpSource "httpok";
          credential.command = "printf %s cmd-token";
        };
      # file credential, read through jqPath.
      filecred =
        baseProvider
        // {
          source = httpSource "filecred";
          credential.file = {
            path = ./cred.json;
            jqPath = ".token";
          };
        };
      # secretTool credential.
      secretp =
        baseProvider
        // {
          source = httpSource "secretp";
          credential.secretTool = {
            service = "ai_usage_test";
            account = "runtime";
          };
        };
      # unreadable file credential: must degrade, never crash.
      nocred =
        baseProvider
        // {
          source = httpSource "nocred";
          credential.file = {
            path = "/nonexistent/ai-usage-test/creds.json";
            jqPath = ".token";
          };
        };
      # command source: no network at all.
      cmd =
        baseProvider
        // {
          source.command = "printf '{\"usage\":42}'";
        };
      # disabled providers are not addressable.
      disabledp =
        baseProvider
        // {
          enable = false;
          source = httpSource "disabledp";
        };
    };
  });

  configV2 = pkgs.writeText "ai-usage-runtime-config-v2.json" (builtins.toJSON {
    version = 2;
    providers = {};
  });

  stubCurl = pkgs.writeShellScriptBin "curl" ''
    printf '1\n' >>"$AI_USAGE_TEST_CALLS"
    printf '%s\n' "$@" >>"$AI_USAGE_TEST_ARGS"
    if [ -n "''${AI_USAGE_TEST_FAIL:-}" ]; then
      printf 'curl: (22) simulated HTTP 429 Too Many Requests\n' >&2
      exit 22
    fi
    cat "$AI_USAGE_TEST_BODY"
  '';

  stubSecretTool = pkgs.writeShellScriptBin "secret-tool" ''
    if [ -n "''${AI_USAGE_TEST_SECRET_FAIL:-}" ]; then
      exit 1
    fi
    printf 'secret-token\n'
  '';

  aiUsage = pkgs.callPackage ../../module/package.nix {
    configFile = config;
    curl = stubCurl;
    libsecret = stubSecretTool;
  };
in
  pkgs.runCommand "check-ai-usage-runtime" {
    nativeBuildInputs = [pkgs.jq pkgs.findutils aiUsage];
  } ''
    export HOME="$TMPDIR/home"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    export AI_USAGE_TEST_CALLS="$TMPDIR/calls"
    export AI_USAGE_TEST_ARGS="$TMPDIR/args"
    export AI_USAGE_TEST_BODY="$TMPDIR/body.json"
    cacheDir="$XDG_CACHE_HOME/ai-usage"
    mkdir -p "$HOME" "$XDG_CACHE_HOME"
    printf '{"usage":7}' >"$AI_USAGE_TEST_BODY"

    fail=0

    note() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

    calls() { wc -l <"$AI_USAGE_TEST_CALLS" | tr -d ' '; }
    reset_calls() { : >"$AI_USAGE_TEST_CALLS"; : >"$AI_USAGE_TEST_ARGS"; }
    reset_cache() { rm -rf "$cacheDir"; }

    # Shift fetchedAt and lastGoodAt back by $2 seconds. Uses a `.new` suffix so
    # the `*.tmp` atomicity assertion stays meaningful.
    age_cache() {
      f="$cacheDir/$1.json"
      jq --argjson d "$2" '
        .fetchedAt = (.fetchedAt - $d)
        | if (.lastGoodAt // 0) > 0 then .lastGoodAt = (.lastGoodAt - $d) else . end
      ' "$f" >"$f.new"
      mv "$f.new" "$f"
    }

    assert_eq() {
      if [ "$2" != "$3" ]; then
        note "$1: expected [$2] got [$3]"
      fi
    }

    assert_jq() {
      if ! printf '%s' "$3" | jq -e "$2" >/dev/null 2>&1; then
        note "$1: filter [$2] did not hold for $3"
      fi
    }

    assert_grep() {
      if ! grep -qF -- "$2" "$3"; then
        note "$1: [$2] not found in $3"
      fi
    }

    ##########################################################################
    # cold-fetch
    ##########################################################################
    reset_cache
    reset_calls
    doc=$(ai-usage httpok)
    assert_eq cold-fetch-calls 1 "$(calls)"
    assert_jq cold-fetch-doc \
      '.version == 1 and .provider == "httpok" and .severity == "ok" and .text == "$7" and .stale == false and .error == null' \
      "$doc"
    assert_jq cold-fetch-cache \
      '.version == 1 and .ok == true and .error == null and .lastGoodAt > 0 and .fetchedAt > 0' \
      "$(cat "$cacheDir/httpok.json")"
    assert_grep cold-fetch-credential 'Bearer cmd-token' "$AI_USAGE_TEST_ARGS"
    assert_grep cold-fetch-url 'https://ai-usage.test/httpok' "$AI_USAGE_TEST_ARGS"

    ##########################################################################
    # warm-cache-no-network
    ##########################################################################
    doc2=$(ai-usage httpok)
    assert_eq warm-cache-calls 1 "$(calls)"
    assert_eq warm-cache-document "$doc" "$doc2"

    ##########################################################################
    # refresh-forces-fetch
    ##########################################################################
    ai-usage httpok --refresh >/dev/null
    assert_eq refresh-calls 2 "$(calls)"

    ##########################################################################
    # refresh-interval-elapsed
    ##########################################################################
    reset_calls
    age_cache httpok 301
    ai-usage httpok >/dev/null
    assert_eq refresh-interval-calls 1 "$(calls)"

    ##########################################################################
    # failure-serves-stale
    ##########################################################################
    reset_calls
    export AI_USAGE_TEST_FAIL=1
    age_cache httpok 301
    doc=$(ai-usage httpok 2>/dev/null)
    assert_eq stale-calls 1 "$(calls)"
    assert_jq stale-doc \
      '.severity == "ok" and .stale == true and .age >= 301 and .text == "$7" and .error != null' \
      "$doc"

    ##########################################################################
    # retry-interval-throttles (failed cache younger than retryInterval)
    ##########################################################################
    reset_calls
    doc=$(ai-usage httpok 2>/dev/null)
    assert_eq retry-throttle-calls 0 "$(calls)"
    assert_jq retry-throttle-doc '.stale == true and .severity == "ok"' "$doc"

    ##########################################################################
    # failure-beyond-max-stale
    ##########################################################################
    reset_calls
    age_cache httpok 4000
    doc=$(ai-usage httpok 2>/dev/null)
    assert_jq max-stale-doc \
      '.severity == "unknown" and .text == "?" and .metrics == {} and .percentage == null and .error != null' \
      "$doc"

    ##########################################################################
    # recovery after failure
    ##########################################################################
    unset AI_USAGE_TEST_FAIL
    reset_calls
    doc=$(ai-usage httpok --refresh)
    assert_eq recovery-calls 1 "$(calls)"
    assert_jq recovery-doc '.severity == "ok" and .stale == false and .text == "$7"' "$doc"

    ##########################################################################
    # file credential
    ##########################################################################
    reset_calls
    doc=$(ai-usage filecred)
    assert_jq filecred-doc '.severity == "ok" and .text == "$7"' "$doc"
    assert_grep filecred-credential 'Bearer file-token' "$AI_USAGE_TEST_ARGS"

    ##########################################################################
    # secretTool credential
    ##########################################################################
    reset_calls
    doc=$(ai-usage secretp)
    assert_jq secretp-doc '.severity == "ok" and .text == "$7"' "$doc"
    assert_grep secretp-credential 'Bearer secret-token' "$AI_USAGE_TEST_ARGS"

    ##########################################################################
    # credential-missing: exit 0, unknown document, non-empty stderr, no fetch
    ##########################################################################
    reset_calls
    rc=0
    doc=$(ai-usage nocred 2>"$TMPDIR/nocred.err") || rc=$?
    assert_eq nocred-exit 0 "$rc"
    assert_jq nocred-doc '.severity == "unknown" and .text == "?" and .error != null' "$doc"
    if [ ! -s "$TMPDIR/nocred.err" ]; then
      note "nocred-stderr: expected an actionable message on stderr"
    fi
    assert_eq nocred-calls 0 "$(calls)"

    ##########################################################################
    # command-source: no network
    ##########################################################################
    reset_calls
    doc=$(ai-usage cmd)
    assert_eq cmd-calls 0 "$(calls)"
    assert_jq cmd-doc '.severity == "ok" and .text == "$42"' "$doc"

    ##########################################################################
    # unknown-provider / disabled-provider / missing argument
    ##########################################################################
    rc=0
    output=$(ai-usage nope 2>&1) || rc=$?
    assert_eq unknown-provider-exit 2 "$rc"
    printf '%s' "$output" | grep -qF httpok || note "unknown-provider-stderr: expected the known provider names"

    rc=0
    output=$(ai-usage disabledp 2>&1) || rc=$?
    assert_eq disabled-provider-exit 2 "$rc"

    rc=0
    output=$(ai-usage 2>&1) || rc=$?
    assert_eq missing-argument-exit 2 "$rc"

    ##########################################################################
    # bad-config-version, via --config and via $AI_USAGE_CONFIG
    ##########################################################################
    rc=0
    output=$(ai-usage httpok --config ${configV2} 2>&1) || rc=$?
    assert_eq bad-config-version-exit 1 "$rc"
    printf '%s' "$output" | grep -qiF version || note "bad-config-version-stderr: expected the version to be mentioned"

    rc=0
    output=$(AI_USAGE_CONFIG=${configV2} ai-usage httpok 2>&1) || rc=$?
    assert_eq env-config-override-exit 1 "$rc"

    ##########################################################################
    # atomic-write: no partial files survive
    ##########################################################################
    leftovers=$(find "$cacheDir" -name '*.tmp' | wc -l | tr -d ' ')
    assert_eq atomic-write-leftovers 0 "$leftovers"

    ##########################################################################
    # concurrent-single-fetch (best effort, never fatal)
    ##########################################################################
    reset_cache
    reset_calls
    ai-usage httpok >/dev/null &
    ai-usage httpok >/dev/null &
    wait
    concurrent=$(calls)
    if [ "$concurrent" != 1 ]; then
      printf 'WARN: concurrent-single-fetch expected 1 curl call, got %s (best effort)\n' "$concurrent" >&2
    fi

    if [ "$fail" != 0 ]; then
      printf 'ai-usage runtime check failed\n' >&2
      exit 1
    fi
    touch "$out"
  ''
