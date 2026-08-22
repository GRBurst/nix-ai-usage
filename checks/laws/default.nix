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
    # A pair is still subject to every unary law, `unknown-iff` included, so a
    # pair over an unparsable body has to declare that it degenerates. Both
    # members share the value: a relation is only meaningful between two
    # documents that agree on whether they are documents at all.
    degenerate ? false,
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
          inherit direction degenerate;
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
    # Null rather than true so `filterAttrs` drops it, which keeps every
    # pre-existing family rendering exactly the config it rendered before the
    # flag existed. Absent means truncate, so only `false` needs emitting.
    floor ? null,
  }: {
    name = "laws";
    metrics.x = lib.filterAttrs (_: v: v != null) {
      from = {path = ["x"];};
      inherit unit required nullText floor;
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

  # Family A'' -- `floor = false`, over the same domain. `norm-integral` is
  # deliberately silent here, so the teeth are in `expect.metrics`: every value
  # is pinned to the clamp with no truncation applied. Without a pinned
  # expectation this family would pass against a core that ignored the flag,
  # which is precisely the bug the first implementation had.
  #
  # `raw` is exempt from both clamping and truncation, so its expectation is the
  # input itself -- which also states that the flag cannot start truncating a
  # unit that never truncated.
  clampOnly = unit: v:
    if unit == "percent"
    then
      (
        if v < 0
        then 0
        else if v > 100
        then 100
        else v
      )
    else if unit == "dollars"
    then
      (
        if v < 0
        then 0
        else v
      )
    else v;

  familyUnfloored = lib.imap0 (i: c:
    mkInstance {
      name = "unfloored-${c.unit}-${toString i}";
      provider = singleProvider {
        inherit (c) unit;
        threshold = ascending;
        floor = false;
      };
      body = jsonX c.value;
      expect.metrics = {x = clampOnly c.unit c.value;};
    }) (lib.cartesianProduct {
    unit = units;
    value = numVals;
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

  # Family G -- `from.timestamp` (D-20). A timestamp metric is `raw` and optional,
  # so it must not move `severity`, and it must never make the document degrade.
  timestampProvider = {
    name = "laws";
    metrics.t = {
      from = {timestamp = {path = ["t"];};};
      unit = "raw";
      required = false;
      nullText = "-";
    };
    rules = [];
    format = "t={t}";
    tooltipFormat = "at {t}";
  };

  # Every expectation below was produced by executing the `epoch` definition
  # under jq 1.8.2 and cross-checking with `date -u -d @N`. The plan's original
  # table was one day (86400 s) high on the first two rows.
  timestampCases = [
    # The two shapes the providers actually emit: Anthropic sends fractional
    # seconds with an explicit `+00:00`, OpenRouter sends fractional plus `Z`.
    {
      input = "2026-08-21T23:10:00.029760+00:00";
      expected = 1787353800;
    }
    {
      input = "2026-08-24T20:00:00.029792+00:00";
      expected = 1787601600;
    }
    {
      input = "2027-08-05T12:19:00.001Z";
      expected = 1817468340;
    }
    {
      input = "2026-08-21T23:10:00Z";
      expected = 1787353800;
    }
    # D-21: a non-UTC offset is rejected outright. Accepting it as if it were UTC
    # would silently misplace the reset by hours, which is worse than no value.
    {
      input = "2026-08-21T23:10:00-05:00";
      expected = null;
    }
    {
      input = "2026-08-21T23:10:00+02:00";
      expected = null;
    }
    # No zone at all is not UTC either.
    {
      input = "2026-08-21T23:10:00";
      expected = null;
    }
    {
      input = "";
      expected = null;
    }
    {
      input = "  ";
      expected = null;
    }
    {
      input = "not-a-date";
      expected = null;
    }
    # An epoch that arrived as a string stays rejected: `epoch` parses a format,
    # it does not guess.
    {
      input = "1787440200";
      expected = null;
    }
    # Shape-valid but calendar-nonsense. This is the row that justifies keeping
    # `try`/`catch` behind the regex guard rather than trusting either alone.
    {
      input = "2026-13-45T99:99:99Z";
      expected = null;
    }
    # Non-strings, since a provider may send anything.
    {
      input = null;
      expected = null;
    }
    {
      input = 0;
      expected = null;
    }
    {
      input = [];
      expected = null;
    }
    {
      input = {};
      expected = null;
    }
    {
      input = true;
      expected = null;
    }
  ];

  familyTimestamp =
    lib.imap0 (i: c:
      mkInstance {
        name = "timestamp-${toString i}";
        provider = timestampProvider;
        body = builtins.toJSON {t = c.input;};
        expect = {metrics = {t = c.expected;};};
      })
    timestampCases
    ++ [
      # An absent path is not an error either: `at` yields null and the optional
      # metric simply has no value.
      (mkInstance {
        name = "timestamp-absent";
        provider = timestampProvider;
        body = "{}";
        expect = {metrics = {t = null;};};
      })
    ];

  # Family H -- D-22, the accidental-`unknown` trap, in the shape the shipped
  # Claude provider actually has. A reset timestamp exists to expose more of the
  # payload to an adapter. If it were `required`, an account with a window it has
  # never used -- for which Anthropic sends `resets_at: null` -- would blank the
  # bar instead of showing the utilisation the API did send. `unknown-iff` states
  # that in both directions, so this family generates both polarities: with
  # `required = false` nothing degrades, and flipping the same instances to
  # `required = true` must degrade every one whose timestamp fails to parse.
  claudeShapedProvider = resetsRequired: {
    name = "laws";
    metrics = {
      fiveHour = {
        from = {path = ["five_hour" "utilization"];};
        unit = "percent";
        required = true;
      };
      fiveHourResetsAt = {
        from = {timestamp = {path = ["five_hour" "resets_at"];};};
        unit = "raw";
        required = resetsRequired;
      };
      sevenDay = {
        from = {path = ["seven_day" "utilization"];};
        unit = "percent";
        required = true;
      };
      sevenDayResetsAt = {
        from = {timestamp = {path = ["seven_day" "resets_at"];};};
        unit = "raw";
        required = resetsRequired;
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
    # As in the shipped defaults, neither reset metric appears in either
    # template, so exposing them cannot change a single rendered byte.
    format = "{fiveHour}%·{sevenDay}%";
    tooltipFormat = "5h {fiveHour}% · 7d {sevenDay}%";
  };

  # Utilisations are fixed at the values in the recorded payload: 91 is critical
  # under 80/90, so these instances also witness that a timestamp metric does not
  # perturb a severity that the percent metrics already decided.
  claudeBody = five: seven:
    builtins.toJSON {
      five_hour = {
        utilization = 91;
        resets_at = five;
      };
      seven_day = {
        utilization = 68;
        resets_at = seven;
      };
    };

  claudeResetShapes = [
    {
      id = "present";
      body = claudeBody "2026-08-21T23:10:00.029760+00:00" "2026-08-24T20:00:00.029792+00:00";
      parses = true;
    }
    # The quiet-account case, verbatim from the recorded payload's unused windows.
    {
      id = "null";
      body = claudeBody null null;
      parses = false;
    }
    # One of two is enough to degrade, so the boundary is per-metric and not
    # "all timestamps failed".
    {
      id = "mixed";
      body = claudeBody "2026-08-21T23:10:00Z" null;
      parses = false;
    }
    # A future API that starts sending a human-readable reset must not take the
    # bar down with it.
    {
      id = "unparsable";
      body = claudeBody "soon" "in 3 days";
      parses = false;
    }
    # The field disappearing entirely is the same situation as a null one.
    {
      id = "absent";
      body = builtins.toJSON {
        five_hour = {utilization = 91;};
        seven_day = {utilization = 68;};
      };
      parses = false;
    }
  ];

  familyClaudeResets = map (c: let
    degenerate = c.required && !c.shape.parses;
  in
    mkInstance {
      name = "claude-resets-${c.shape.id}-${
        if c.required
        then "required"
        else "optional"
      }";
      provider = claudeShapedProvider c.required;
      body = c.shape.body;
      expect =
        {
          inherit degenerate;
          severity =
            if degenerate
            then "unknown"
            else "critical";
        }
        // lib.optionalAttrs (c.shape.parses && !c.required) {
          metrics = {
            fiveHour = 91;
            sevenDay = 68;
            fiveHourResetsAt = 1787353800;
            sevenDayResetsAt = 1787601600;
          };
        };
    }) (lib.cartesianProduct {
    shape = claudeResetShapes;
    required = [false true];
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

  # ---- extras non-interference (D-24) ----
  #
  # The strongest law in this file, and the one that justifies restricting an
  # extra to contributing metrics. It quantifies over every subset of every
  # shipped provider's extras, so "enabling a flag is harmless" becomes a
  # property of the mechanism rather than a claim about the groups that happen
  # to ship today.
  #
  # It drives the *real* shipped providers through the *real* pure builder, so
  # it also exercises the shipped `from.expression` filters -- which is why
  # run-instance.sh pre-evaluates them.
  aiLib = import ../../lib {inherit lib;};

  shipped = aiLib.providerDefaults {homeDirectory = "/home/testuser";};

  # An enable assignment, rendered through mkConfig so the merge under test is
  # the one that ships rather than a restatement of it here.
  renderSubset = name: sel:
    (aiLib.mkConfig {
      providers.${name} =
        shipped.${name}
        // {
          extras =
            lib.mapAttrs (n: e: e // {enable = sel.${n};})
            shipped.${name}.extras;
        };
    })
    .providers
    .${
      name
    };

  subsetsOf = name:
    lib.cartesianProduct
    (lib.genAttrs (lib.attrNames shipped.${name}.extras) (_: [false true]));

  # S subset-of S', pointwise on the flags.
  contained = a: b: lib.all (n: !a.${n} || b.${n}) (lib.attrNames a);

  subsetLabel = sel: let
    on = lib.attrNames (lib.filterAttrs (_: v: v) sel);
  in
    if on == []
    then "none"
    else lib.concatStringsSep "-" on;

  # Bodies chosen so the law is checked where the extras' fields are present,
  # absent, ill-typed, and where the document is `unknown` outright.
  claudeExtrasBodies = [
    {
      id = "full";
      body = builtins.toJSON {
        five_hour = {
          utilization = 91.0;
          resets_at = "2026-08-21T23:10:00.029760+00:00";
        };
        seven_day = {
          utilization = 68.0;
          resets_at = "2026-08-24T20:00:00.029792+00:00";
        };
        spend = {
          used = {
            amount_minor = 10000;
            currency = "EUR";
            exponent = 2;
          };
          limit = {
            amount_minor = 0;
            currency = "EUR";
            exponent = 2;
          };
          percent = 0;
        };
      };
    }
    {
      id = "nospend";
      body = builtins.toJSON {
        five_hour = {utilization = 12.0;};
        seven_day = {utilization = 34.0;};
      };
    }
    {
      # A null exponent is the case the shipped filter type-guards: without the
      # guard the division raises and only the orchestrator's collapse saves it.
      id = "badexponent";
      body = builtins.toJSON {
        five_hour = {utilization = 12.0;};
        seven_day = {utilization = 34.0;};
        spend = {
          used = {
            amount_minor = 10000;
            exponent = null;
          };
          limit = null;
          percent = null;
        };
      };
    }
    {
      # Non-interference has to hold where both documents are `unknown` too:
      # that is the case where a bug could let an extra resurrect a metric.
      id = "garbage";
      body = "not json at all";
      degenerate = true;
    }
  ];

  openrouterExtrasBodies = [
    {
      id = "full";
      body = builtins.toJSON {
        data = {
          limit = 200;
          limit_remaining = 44.01517413299999;
          limit_reset = "monthly";
          usage = 155.984825867;
          usage_daily = 0;
          usage_weekly = 11.415461617;
          usage_monthly = 155.984825867;
        };
      };
    }
    {
      id = "nowindows";
      body = builtins.toJSON {
        data = {
          limit = 20;
          limit_remaining = 12.5;
          usage = 7.5;
        };
      };
    }
    {
      id = "garbage";
      body = "not json at all";
      degenerate = true;
    }
  ];

  extrasPairsFor = name: bodies:
    lib.concatMap (
      body:
        lib.concatMap (
          small:
            lib.concatMap (
              large:
                lib.optionals (contained small large) [
                  (mkPair {
                    id = "extras-${name}-${body.id}-${subsetLabel small}-le-${subsetLabel large}";
                    relation = "extras-noninterference";
                    providers = [(renderSubset name small) (renderSubset name large)];
                    bodies = [body.body body.body];
                    # Only the unparsable bodies degenerate. Every other body
                    # supplies each provider's required metrics, and an extra
                    # metric is never required, so no subset can change that.
                    degenerate = body.degenerate or false;
                  })
                ]
            ) (subsetsOf name)
        ) (subsetsOf name)
    )
    bodies;

  familyExtras =
    lib.flatten (extrasPairsFor "claude" claudeExtrasBodies)
    ++ lib.flatten (extrasPairsFor "openrouter" openrouterExtrasBodies);

  instances =
    familyA
    ++ familyUnfloored
    ++ familyStale
    ++ familyB
    ++ familyC
    ++ familyBoundary
    ++ familyRatio
    ++ familyExpression
    ++ familyTimestamp
    ++ familyClaudeResets
    ++ pairDeterminism
    ++ pairPermutation
    ++ pairInclusion
    ++ pairMonotone
    ++ familyIdempotent
    ++ familyExtras;

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
