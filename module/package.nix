# ai-usage: provider-agnostic, bar-agnostic AI usage query.
#
# Purity guard: this file must not reference `config`, `osConfig` or any other
# host state. Everything provider-specific arrives through `configFile`, so the
# derivation is a pure function of nixpkgs and that one document.
#
# Contracts (see docs/architecture.md):
#   config   schema v1, read from `configFile`, overridable by
#            `$AI_USAGE_CONFIG` and `--config <path>`
#   cache    $XDG_CACHE_HOME/ai-usage/<provider>.json, schema v1
#   document schema v1 on stdout, always valid JSON
#
# Exit codes: 0 success (including a failed network read, which yields a
# `severity = "unknown"` document), 2 usage error, 1 config error.
#
# `--raw` is the one exception to "always exit 0", and deliberately so (D-26):
# document mode implements the status-bar protocol, where a non-zero child means
# a broken module, while `--raw` is an ordinary Unix filter and exits 0 if and
# only if it wrote a body.
{
  writeShellApplication,
  bash,
  coreutils,
  curl,
  jq,
  util-linux,
  libsecret,
  configFile,
}:
writeShellApplication {
  name = "ai-usage";
  runtimeInputs = [bash coreutils curl jq util-linux libsecret];
  text = ''
    defaultConfig="${configFile}"
    configPath="''${AI_USAGE_CONFIG:-$defaultConfig}"
    providerName=""
    refresh=0
    rawMode=0

    die() {
      printf 'ai-usage: %s\n' "$1" >&2
      exit "$2"
    }

    usage_error() {
      known=""
      if [ -f "$configPath" ]; then
        known=$(jq -r '(.providers // {}) | keys | join(", ")' "$configPath" 2>/dev/null) || known=""
      fi
      {
        printf 'usage: ai-usage <provider> [--refresh] [--raw] [--config <path>]\n'
        printf 'known providers: %s\n' "$known"
      } >&2
      exit 2
    }

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --refresh) refresh=1 ;;
        --raw) rawMode=1 ;;
        --config)
          shift
          [ "$#" -gt 0 ] || usage_error
          configPath="$1"
          ;;
        --config=*) configPath="''${1#--config=}" ;;
        -*) usage_error ;;
        *)
          [ -z "$providerName" ] || usage_error
          providerName="$1"
          ;;
      esac
      shift
    done

    [ -n "$providerName" ] || usage_error
    [ -f "$configPath" ] || die "config file not found: $configPath" 1

    jq -e '.version == 1' "$configPath" >/dev/null 2>&1 ||
      die "unsupported config version in $configPath (expected version 1)" 1

    provider=$(jq -c --arg n "$providerName" '(.providers[$n] // empty) + {name: $n}' "$configPath")
    [ -n "$provider" ] || usage_error
    [ "$(jq -r '.enable // false' <<<"$provider")" = true ] || usage_error

    timeout=$(jq -r '.timeout // 3' <<<"$provider")
    refreshInterval=$(jq -r '.refreshInterval // 300' <<<"$provider")
    retryInterval=$(jq -r '.retryInterval // 60' <<<"$provider")
    maxStaleAge=$(jq -r '.maxStaleAge // ((.refreshInterval // 300) * 3)' <<<"$provider")

    cacheHome="''${XDG_CACHE_HOME:-$HOME/.cache}"
    cacheDir="$cacheHome/ai-usage"
    cacheFile="$cacheDir/$providerName.json"
    mkdir -p "$cacheDir"
    now=$(date +%s)

    # Resolve the credential to stdout. Non-zero return means "cannot fetch",
    # with an actionable message already on stderr.
    read_credential() {
      kind=$(jq -r 'if (.credential // null) == null then "" else (.credential | keys_unsorted[0]) end' <<<"$provider")
      value=""
      case "$kind" in
        "")
          return 0
          ;;
        file)
          credPath=$(jq -r '.credential.file.path' <<<"$provider")
          credJqPath=$(jq -r '.credential.file.jqPath // "."' <<<"$provider")
          if [ ! -r "$credPath" ]; then
            printf 'ai-usage: %s: credential file not readable: %s\n' "$providerName" "$credPath" >&2
            return 1
          fi
          value=$(jq -r "$credJqPath // empty" "$credPath" 2>/dev/null) || value=""
          ;;
        secretTool)
          credService=$(jq -r '.credential.secretTool.service' <<<"$provider")
          credAccount=$(jq -r '.credential.secretTool.account' <<<"$provider")
          value=$(secret-tool lookup service "$credService" account "$credAccount" 2>/dev/null) || value=""
          ;;
        command)
          credCommand=$(jq -r '.credential.command' <<<"$provider")
          value=$(bash -c "$credCommand" 2>/dev/null) || value=""
          ;;
        *)
          printf 'ai-usage: %s: unsupported credential kind: %s\n' "$providerName" "$kind" >&2
          return 1
          ;;
      esac
      if [ -z "$value" ]; then
        printf 'ai-usage: %s: credential (%s) resolved empty; is the keyring locked or the token expired?\n' \
          "$providerName" "$kind" >&2
        return 1
      fi
      printf '%s' "$value"
    }

    # Emit the raw provider response on stdout.
    fetch() {
      sourceKind=$(jq -r '.source | keys_unsorted[0]' <<<"$provider")
      case "$sourceKind" in
        http)
          url=$(jq -r '.source.http.url' <<<"$provider")
          credential=$(read_credential) || return 1
          headerArgs=()
          while IFS= read -r header; do
            [ -n "$header" ] || continue
            headerArgs+=(--header "''${header//\{credential\}/$credential}")
          done < <(jq -r '(.source.http.headers // {}) | to_entries[] | "\(.key): \(.value)"' <<<"$provider")
          curl --silent --show-error --fail --max-time "$timeout" "''${headerArgs[@]}" "$url"
          ;;
        command)
          sourceCommand=$(jq -r '.source.command' <<<"$provider")
          bash -c "$sourceCommand"
          ;;
        *)
          printf 'ai-usage: %s: unsupported source kind: %s\n' "$providerName" "$sourceKind" >&2
          return 1
          ;;
      esac
    }

    cache_read() {
      if [ -f "$cacheFile" ]; then
        jq -c '.' "$cacheFile" 2>/dev/null || printf 'null'
      else
        printf 'null'
      fi
    }

    cache_write() {
      printf '%s' "$1" >"$cacheFile.tmp"
      mv -f "$cacheFile.tmp" "$cacheFile"
    }

    needs_fetch() {
      [ "$refresh" = 0 ] || return 0
      jq -e \
        --argjson now "$now" \
        --argjson refreshInterval "$refreshInterval" \
        --argjson retryInterval "$retryInterval" \
        'if . == null or (.version != 1) then true
         elif (.ok // false) then ($now - (.fetchedAt // 0)) >= $refreshInterval
         else ($now - (.fetchedAt // 0)) >= $retryInterval
         end' >/dev/null <<<"$1"
    }

    errFile=$(mktemp)
    cache=$(cache_read)

    if needs_fetch "$cache"; then
      # Only the fetch-and-write critical section is locked, so N bars cause at
      # most one request. A lock timeout is not a failure: we fall through to
      # whatever the cache holds.
      exec 9>"$cacheDir/$providerName.lock"
      if flock -w 5 9; then
        cache=$(cache_read)
        if needs_fetch "$cache"; then
          previousBody=$(jq -r '.body // ""' <<<"$cache")
          previousGoodAt=$(jq -r '.lastGoodAt // 0' <<<"$cache")
          if body=$(fetch 2>"$errFile"); then
            cache=$(jq -nc --argjson now "$now" --arg body "$body" \
              '{version: 1, fetchedAt: $now, ok: true, error: null, body: $body, lastGoodAt: $now}')
          else
            cache=$(jq -nc \
              --argjson now "$now" \
              --rawfile errorText "$errFile" \
              --arg body "$previousBody" \
              --argjson lastGoodAt "$previousGoodAt" \
              '{version: 1, fetchedAt: $now, ok: false,
                error: (($errorText | gsub("\\s+$"; "") | gsub("\n"; " "))
                        | if . == "" then "fetch failed" else . end),
                body: $body, lastGoodAt: $lastGoodAt}')
          fi
          cache_write "$cache"
          cat "$errFile" >&2
        fi
      fi
      exec 9>&-
    fi

    rm -f "$errFile"

    if [ "$(jq -r '.ok // false' <<<"$cache")" = true ]; then
      body=$(jq -r '.body // ""' <<<"$cache")
      meta='{"stale":false,"age":0,"error":null}'
    else
      body=$(jq -r '.body // ""' <<<"$cache")
      lastGoodAt=$(jq -r '.lastGoodAt // 0' <<<"$cache")
      cacheError=$(jq -r '.error // "unavailable"' <<<"$cache")
      age=$((now - lastGoodAt))
      if [ -n "$body" ] && [ "$lastGoodAt" -gt 0 ] && [ "$age" -le "$maxStaleAge" ]; then
        meta=$(jq -nc --argjson age "$age" --arg error "$cacheError" \
          '{stale: true, age: $age, error: $error}')
      else
        body=""
        meta=$(jq -nc --arg error "$cacheError" '{stale: false, age: null, error: $error}')
      fi
    fi

    # Raw mode reuses the resolution above verbatim, so it shares one cache,
    # lock and staleness policy with document mode rather than reimplementing a
    # fetch; that is why `--refresh`, throttling and stale serving come for free.
    # It sits before expression pre-evaluation because raw mode needs none of it.
    #
    # The body has round-tripped through `$(...)`, which strips trailing
    # newlines, so this is byte-exact modulo trailing whitespace. A stale body is
    # still a body: it is printed with exit 0, and the error is already on
    # stderr. `stale` and `age` are document-mode concepts.
    if [ "$rawMode" = 1 ]; then
      if [ -n "$body" ]; then
        printf '%s\n' "$body"
        exit 0
      fi
      exit 1
    fi

    # jq has no `eval`, so `expression` metrics are pre-evaluated here and
    # handed to the pure core as `--argjson expressions`.
    expressions='{}'
    while IFS= read -r metric; do
      [ -n "$metric" ] || continue
      filter=$(jq -r --arg m "$metric" '.metrics[$m].from.expression' <<<"$provider")
      value=$(printf '%s' "$body" | jq -c "$filter" 2>/dev/null) || value=null
      printf '%s' "$value" | jq -e . >/dev/null 2>&1 || value=null
      expressions=$(jq -c --arg m "$metric" --argjson v "$value" '. + {($m): $v}' <<<"$expressions")
    done < <(jq -r '(.metrics // {}) | to_entries[] | select(.value.from | has("expression")) | .key' <<<"$provider")

    exec jq -n -c --from-file ${./ai-usage.jq} \
      --argjson provider "$provider" \
      --arg body "$body" \
      --argjson expressions "$expressions" \
      --argjson meta "$meta"
  '';
}
