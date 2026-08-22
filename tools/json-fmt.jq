# Reproduce the golden-file style exactly: keys sorted, two-space indent, arrays
# of scalars inlined on one line, arrays of objects expanded.
#
# `jq -S .` does not produce this shape and no formatter in nixpkgs does either,
# so the style lived only in whoever last hand-edited a golden. That is the wrong
# owner for a file `AGENTS.md` says must be regenerated rather than edited, hence
# this program. It round-trips every checked-in golden byte-identically, so a
# regeneration diff shows only what actually changed in the defaults.

def scalarArray: (type == "array") and (all(.[]; type != "object" and type != "array"));

def fmt($ind):
  if type == "object" then
    if length == 0 then "{}"
    else
      "{\n"
      + ([keys[] as $k | ($ind + "  ") + ($k | tojson) + ": " + (.[$k] | fmt($ind + "  "))] | join(",\n"))
      + "\n" + $ind + "}"
    end
  elif type == "array" then
    if length == 0 then "[]"
    elif scalarArray then "[" + ([.[] | tojson] | join(", ")) + "]"
    else
      "[\n"
      + ([.[] | ($ind + "  ") + fmt($ind + "  ")] | join(",\n"))
      + "\n" + $ind + "]"
    end
  else tojson
  end;

fmt("")
