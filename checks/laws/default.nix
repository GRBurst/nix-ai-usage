# Law-based check over the pure core: universally quantified properties, tested
# by bounded-exhaustive generation rather than by named examples.
#
# Three stages -- generate (Nix), execute (one core invocation per instance),
# verify (pure jq over the whole result set). The core is driven through its real
# argument interface, so no jq module split is needed to make a def observable:
# the artefact under test is exactly the artefact that ships.
#
# This layer supplements checks/core, it does not replace it. Examples pin intent
# at named points and are readable; laws pin structure everywhere and are not.
#
# Ceiling, stated honestly: exhaustive laws over a small adversarial domain are
# bounded verification, not proof. jq is not verifiable.
{
  lib,
  runCommand,
  jq,
}: let
  jqProgram = ../../module/ai-usage.jq;

  # Restricted to the three meta shapes module/package.nix actually emits: fresh
  # after a good fetch, stale while serving a last-good body, dead once past
  # maxStaleAge. Generating a stale meta with a null error, or an error beside a
  # good body, would fail `error-iff` against a document that cannot occur.
  freshMeta = {
    stale = false;
    age = 0;
    error = null;
  };
  staleMeta = {
    stale = true;
    age = 420;
    error = "curl: (22) simulated failure";
  };
  deadMeta = {
    stale = false;
    age = null;
    error = "curl: (22) simulated failure";
  };

  # Boundary-dense by construction: every threshold used below, each threshold
  # displaced by 0.1, both clamp edges and their overshoots, and the fractional
  # values that tell floor apart from round. 155.984825867 is the real OpenRouter
  # usage figure from the recorded payload.
  percentVals = [(-1) 0 0.4 0.5 1 79 79.9 80 80.1 89 90 90.1 99 99.9 100 100.1];
  dollarVals = [(-1) 0 0.99 1 155.984825867 200];
  numVals = lib.unique (percentVals ++ dollarVals);

  units = ["percent" "dollars" "raw"];

  ascending = {
    warnAt = 80;
    criticalAt = 90;
  };
  descending = {
    warnAt = 90;
    criticalAt = 80;
  };
  atEdges = {
    warnAt = 0;
    criticalAt = 100;
  };
  thresholds = [ascending descending atEdges];

  directionOf = t:
    if t.warnAt < t.criticalAt
    then "ascending"
    else "descending";

  # Every instance carries every field, so the verifier and the runner can read
  # them unconditionally rather than defaulting in two places.
  mkInstance = i:
    {
      pairId = null;
      pairIndex = 0;
      feedback = null;
      expressions = {};
      meta = freshMeta;
    }
    // i
    // {
      expect =
        {
          degenerate = false;
          severity = null;
          metrics = null;
          pair = null;
          direction = null;
          metric = null;
        }
        // (i.expect or {});
    };

  # A pair shares a `pairId`; the verifier groups on it and orders by
  # `pairIndex`. This is the mechanism that makes two-invocation laws expressible
  # without splitting the core.
  mkPair = {
    id,
    relation,
    providers,
    bodies,
    direction ? null,
    metas ? [freshMeta freshMeta],
  }:
    lib.imap0 (idx: _:
      mkInstance {
        name = "${id}-${toString idx}";
        pairId = id;
        pairIndex = idx;
        provider = builtins.elemAt providers idx;
        body = builtins.elemAt bodies idx;
        meta = builtins.elemAt metas idx;
        expect = {
          pair = relation;
          inherit direction;
        };
      }) [0 1];

  # One metric, one rule on it, both templates referencing it. Every token
  # resolves, so a residual `{token}` in the output is a core defect and not a
  # malformed instance.
  singleProvider = {
    unit,
    threshold,
    required ? true,
    nullText ? null,
  }: {
    name = "laws";
    metrics.x = lib.filterAttrs (_: v: v != null) {
      from = {path = ["x"];};
      inherit unit required nullText;
    };
    rules = [({metric = "x";} // threshold)];
    format = "{x}";
    tooltipFormat = "x={x}";
  };

  twoMetricProvider = rules: {
    name = "laws";
    metrics = {
      x = {
        from = {path = ["x"];};
        unit = "percent";
        required = true;
      };
      y = {
        from = {path = ["y"];};
        unit = "percent";
        required = true;
      };
    };
    inherit rules;
    format = "{x}/{y}";
    tooltipFormat = "x={x} y={y}";
  };

  ruleX = {
    metric = "x";
    warnAt = 80;
    criticalAt = 90;
  };
  ruleY = {
    metric = "y";
    warnAt = 80;
    criticalAt = 90;
  };

  jsonX = value: builtins.toJSON {x = value;};

  # ------------------------------------------------------------ unary families

  # Family A -- a numeric body across every unit, value and threshold. Carries
  # normalisation, severity, percentage and rendering.
  familyA = lib.imap0 (i: c:
    mkInstance {
      name = "single-${c.unit}-${toString i}";
      provider = singleProvider {inherit (c) unit threshold;};
      body = jsonX c.value;
    }) (lib.cartesianProduct {
    unit = units;
    value = numVals;
    threshold = thresholds;
  });

  # Family A' -- the same shape served from a stale cache, which is the only way
  # a healthy document carries a non-null error.
  familyStale = lib.imap0 (i: c:
    mkInstance {
      name = "stale-${c.unit}-${toString i}";
      provider = singleProvider {
        inherit (c) unit;
        threshold = ascending;
      };
      body = jsonX c.value;
      meta = staleMeta;
    }) (lib.cartesianProduct {
    unit = units;
    value = [0 80 100];
  });

  # Family B -- bodies that yield no number at `.x`. `parses` distinguishes an
  # unparsable body, which degrades regardless of `required`, from a parsable one
  # that merely lacks the value.
  badBodies = [
    {
      label = "empty";
      body = "";
      parses = false;
    }
    {
      label = "garbage";
      body = "not json at all";
      parses = false;
    }
    {
      label = "truncated";
      body = "{\"x\":";
      parses = false;
    }
    {
      # `fromjson` succeeds and yields null, which the core treats as no
      # document at all -- the same degradation as a parse failure.
      label = "json-null";
      body = "null";
      parses = false;
    }
    {
      label = "empty-object";
      body = "{}";
      parses = true;
    }
    {
      # `getpath` on an array with a string key raises; the core must catch it.
      label = "array";
      body = "[]";
      parses = true;
    }
    {
      label = "null-value";
      body = "{\"x\":null}";
      parses = true;
    }
    {
      label = "string-value";
      body = "{\"x\":\"abc\"}";
      parses = true;
    }
    {
      label = "bool-value";
      body = "{\"x\":true}";
      parses = true;
    }
    {
      label = "other-key";
      body = "{\"y\":1}";
      parses = true;
    }
  ];

  familyB = lib.imap0 (i: c:
    mkInstance {
      name = "degenerate-${toString i}-${c.bad.label}";
      provider = singleProvider {
        inherit (c) unit required;
        threshold = ascending;
      };
      inherit (c.bad) body;
      meta =
        if c.bad.parses
        then freshMeta
        else deadMeta;
      expect = {degenerate = !c.bad.parses || c.required;};
    }) (lib.cartesianProduct {
    bad = badBodies;
    required = [true false];
    unit = units;
  });

  # Family C -- an optional metric with no value, rendering `nullText` into both
  # templates. Half of these carry pango markup, which is representable in the
  # config schema: `nullText` is a free-form string and A5 constrains only the
  # templates. The core must therefore be safe by construction rather than by
  # module-level validation, which a hand-written config would bypass anyway.
  nullTexts = ["" "∞" "?" "<b>x</b>" "a&b" "a<b>c"];

  familyC = lib.imap0 (i: c:
    mkInstance {
      name = "nulltext-${toString i}-${c.unit}";
      provider = singleProvider {
        inherit (c) unit nullText;
        threshold = ascending;
        required = false;
      };
      body = "{}"; # parses, so the document stays healthy; `.x` is absent
    }) (lib.cartesianProduct {
    unit = units;
    nullText = nullTexts;
  });

  # Family D -- severity at and around each threshold, with the expected verdict
  # written out by hand. Values are integers inside [0, 100], so no unit changes
  # them and the expectation is unit-independent -- which is itself the claim that
  # severity reads the value, not the unit.
  boundaryCases = [
    {
      threshold = ascending;
      value = 79;
      severity = "ok";
    }
    {
      threshold = ascending;
      value = 80;
      severity = "warn";
    } # inclusive
    {
      threshold = ascending;
      value = 89;
      severity = "warn";
    }
    {
      threshold = ascending;
      value = 90;
      severity = "critical";
    } # inclusive
    {
      threshold = ascending;
      value = 100;
      severity = "critical";
    }
    {
      threshold = descending;
      value = 100;
      severity = "ok";
    }
    {
      threshold = descending;
      value = 91;
      severity = "ok";
    }
    {
      threshold = descending;
      value = 90;
      severity = "warn";
    } # inclusive
    {
      threshold = descending;
      value = 81;
      severity = "warn";
    }
    {
      threshold = descending;
      value = 80;
      severity = "critical";
    } # inclusive
    {
      threshold = descending;
      value = 0;
      severity = "critical";
    }
    {
      threshold = atEdges;
      value = 0;
      severity = "warn";
    }
    {
      threshold = atEdges;
      value = 50;
      severity = "warn";
    }
    {
      threshold = atEdges;
      value = 100;
      severity = "critical";
    }
  ];

  familyBoundary = lib.imap0 (i: c:
    mkInstance {
      name = "boundary-${toString i}-${c.unit}";
      provider = singleProvider {
        inherit (c) unit;
        inherit (c.case) threshold;
      };
      body = jsonX c.case.value;
      expect = {inherit (c.case) severity;};
    }) (lib.cartesianProduct {
    case = boundaryCases;
    unit = units;
  });

  # Family E -- `percentOf`. Pins operation order: the ratio is taken over the
  # raw pass-1 values, so 16.5/20 is 82 and not the 80 that flooring the operands
  # first would give.
  ratioProvider = {
    name = "laws";
    metrics = {
      a = {
        from = {path = ["a"];};
        unit = "dollars";
        required = true;
      };
      b = {
        from = {path = ["b"];};
        unit = "dollars";
        required = false;
        nullText = "∞";
      };
      p = {
        from = {
          percentOf = {
            of = "a";
            total = "b";
          };
        };
        unit = "percent";
      };
    };
    rules = [
      {
        metric = "p";
        warnAt = 80;
        criticalAt = 90;
      }
    ];
    format = "{a}/{b}";
    tooltipFormat = "{a} of {b} = {p}";
  };

  ratioCases = [
    {
      a = 16;
      b = 20;
      metrics = {
        a = 16;
        b = 20;
        p = 80;
      };
    }
    {
      a = 16.5;
      b = 20;
      metrics = {
        a = 16;
        b = 20;
        p = 82;
      };
    }
    {
      a = 0;
      b = 20;
      metrics = {
        a = 0;
        b = 20;
        p = 0;
      };
    }
    {
      a = 20;
      b = 20;
      metrics = {
        a = 20;
        b = 20;
        p = 100;
      };
    }
    {
      a = 25;
      b = 20;
      metrics = {
        a = 25;
        b = 20;
        p = 100;
      };
    } # clamped
    {
      a = 155.984825867;
      b = 200;
      metrics = {
        a = 155;
        b = 200;
        p = 77;
      };
    }
    {
      a = 1;
      b = 0;
      metrics = {
        a = 1;
        b = 0;
        p = null;
      };
    } # total <= 0
    {
      a = 1;
      b = -1;
      metrics = {
        a = 1;
        b = 0;
        p = null;
      };
    }
  ];

  familyRatio = lib.imap0 (i: c:
    mkInstance {
      name = "ratio-${toString i}";
      provider = ratioProvider;
      body = builtins.toJSON {inherit (c) a b;};
      expect = {inherit (c) metrics;};
    })
  ratioCases;

  # Family F -- `from.expression`, whose value the orchestrator pre-computes and
  # passes in. Nothing else exercises that branch of pass 1 under generation.
  familyExpression = lib.imap0 (i: c:
    mkInstance {
      name = "expression-${toString i}";
      provider = {
        name = "laws";
        metrics.x = {
          from = {expression = "[.a, .b] | add";};
          unit = c.unit;
          required = true;
        };
        rules = [({metric = "x";} // ascending)];
        format = "{x}";
        tooltipFormat = "x={x}";
      };
      body = "{\"a\":1,\"b\":2}";
      expressions = {x = c.value;};
      expect = {degenerate = c.value == null;};
    }) (lib.cartesianProduct {
    unit = units;
    value = [0 3 80 90 100 null];
  });

  # ------------------------------------------------------------- pair families

  pairDeterminism = lib.concatMap (c:
    mkPair {
      id = "determinism-${c.unit}-${toString c.value}";
      relation = "determinism";
      providers = let
        p = singleProvider {
          inherit (c) unit;
          threshold = ascending;
        };
      in [p p];
      bodies = let
        b = jsonX c.value;
      in [b b];
    }) (lib.cartesianProduct {
    unit = units;
    value = [0 80 100];
  });

  pairPermutation = lib.concatMap (c:
    mkPair {
      id = "permutation-${toString c.x}-${toString c.y}";
      relation = "rule-permutation";
      providers = [
        (twoMetricProvider [ruleX ruleY])
        (twoMetricProvider [ruleY ruleX])
      ];
      bodies = let
        b = builtins.toJSON {inherit (c) x y;};
      in [b b];
    }) (lib.cartesianProduct {
    x = [0 85 95];
    y = [0 85 95];
  });

  pairInclusion = lib.concatMap (c:
    mkPair {
      id = "inclusion-${toString c.x}-${toString c.y}";
      relation = "rule-inclusion";
      providers = [
        (twoMetricProvider [ruleX])
        (twoMetricProvider [ruleX ruleY])
      ];
      bodies = let
        b = builtins.toJSON {inherit (c) x y;};
      in [b b];
    }) (lib.cartesianProduct {
    x = [0 85 95];
    y = [0 85 95];
  });

  monotoneVals = [0 1 79 80 89 90 99 100];
  adjacent = xs: lib.zipListsWith (a: b: {inherit a b;}) (lib.init xs) (lib.tail xs);

  pairMonotone = lib.concatMap (c:
    mkPair {
      # Both ascending thresholds must stay distinguishable, or two pairs share
      # an id and the group has four members instead of two.
      id = "monotone-${c.unit}-${toString c.threshold.warnAt}-${toString c.threshold.criticalAt}-${toString c.step.a}";
      relation = "value-monotone";
      direction = directionOf c.threshold;
      providers = let
        p = singleProvider {inherit (c) unit threshold;};
      in [p p];
      bodies = [(jsonX c.step.a) (jsonX c.step.b)];
    }) (lib.cartesianProduct {
    unit = units;
    threshold = thresholds;
    step = adjacent monotoneVals;
  });

  # Idempotence is the one relation the generator cannot express alone: the
  # second body is the first run's output. The runner composes it.
  familyIdempotent = lib.imap0 (i: c:
    mkInstance {
      name = "idempotent-${toString i}-${c.unit}";
      pairId = "idempotent-${toString i}-${c.unit}";
      feedback = "x";
      provider = singleProvider {
        inherit (c) unit;
        threshold = ascending;
      };
      body = jsonX c.value;
      expect = {
        pair = "norm-idempotent";
        metric = "x";
      };
    }) (lib.cartesianProduct {
    unit = units;
    value = [(-1) 0.4 0.5 79.9 100.1 155.984825867];
  });

  instances =
    familyA
    ++ familyStale
    ++ familyB
    ++ familyC
    ++ familyBoundary
    ++ familyRatio
    ++ familyExpression
    ++ pairDeterminism
    ++ pairPermutation
    ++ pairInclusion
    ++ pairMonotone
    ++ familyIdempotent;

  instancesFile =
    builtins.toFile "ai-usage-law-instances.json" (builtins.toJSON instances);
in
  runCommand "check-ai-usage-laws" {
    nativeBuildInputs = [jq];
  } ''
    mkdir -p out
    count=$(jq 'length' ${instancesFile})
    echo "laws: executing $count generated instances" >&2

    seq 0 $((count - 1)) \
      | xargs -P "$NIX_BUILD_CORES" -I{} \
        sh ${./run-instance.sh} ${instancesFile} {} out ${jqProgram}

    # Concatenated in index order, so the verifier sees a byte-identical result
    # set no matter how the parallel stage interleaved.
    i=0
    while [ "$i" -lt "$count" ]; do
      cat "out/$i.json" >>results.jsonl
      if [ -f "out/$i.feedback.json" ]; then
        cat "out/$i.feedback.json" >>results.jsonl
      fi
      i=$((i + 1))
    done

    runs=$(wc -l <results.jsonl)
    jq -s -f ${./laws.jq} results.jsonl >violations.json

    violations=$(jq 'length' violations.json)
    if [ "$violations" != 0 ]; then
      echo "LAW VIOLATIONS ($violations):" >&2
      jq '.' violations.json >&2
      exit 1
    fi

    echo "laws: $count instances, $runs core runs, 0 violations" >&2
    touch $out
  ''
