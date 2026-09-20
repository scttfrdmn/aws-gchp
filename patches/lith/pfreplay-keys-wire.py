#!/usr/bin/env python3
"""Wire keys.go into lith-pfreplay: the #256 rule at the KEY level.

Additive, behind -keys. Every edit is asserted to match exactly once, so the script
fails loudly rather than silently patching the wrong place or patching twice.

globalScore gains a fourth return value: the per-key shared-cache aggregates. That is
deliberately NOT a second implementation of the dedup, the EOF clamp or the first-run
cold rule — the key-level numbers come out of the same loops that produce the mount-level
ones, so the two can never drift apart.

Usage: pfreplay-keys-wire.py /path/to/lith-src
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
gp = root / "cmd/lith-pfreplay/global.go"
mp = root / "cmd/lith-pfreplay/main.go"

EDITS = []


def edit(path, old, new, why):
    EDITS.append((path, old, new, why))


# ---- global.go: accumulate per key while the shared cache is being replayed -------------
edit(gp,
     "func globalScore(perHandle []handleScore, cfg traceConfig, rows []row, byteExact int64) ([]handleScore, globalStats, error) {\n"
     "\tvar stats globalStats\n"
     "\tif len(rows) == 0 {\n"
     "\t\treturn nil, stats, fmt.Errorf(\"no rows\")\n"
     "\t}",
     "func globalScore(perHandle []handleScore, cfg traceConfig, rows []row, byteExact int64) ([]handleScore, globalStats, map[string]*keyAgg, error) {\n"
     "\tvar stats globalStats\n"
     "\t// Per-OBJECT aggregates of the very same accounting, for the key-level fit (keys.go).\n"
     "\t// Filled here rather than recomputed there so that the dedup, the EOF clamp and the\n"
     "\t// first-run cold rule cannot drift between the two units.\n"
     "\tkeyAggs := map[string]*keyAgg{}\n"
     "\tka := func(k string) *keyAgg {\n"
     "\t\ta, ok := keyAggs[k]\n"
     "\t\tif !ok {\n"
     "\t\t\ta = &keyAgg{}\n"
     "\t\t\tkeyAggs[k] = a\n"
     "\t\t}\n"
     "\t\treturn a\n"
     "\t}\n"
     "\tif len(rows) == 0 {\n"
     "\t\treturn nil, stats, nil, fmt.Errorf(\"no rows\")\n"
     "\t}",
     "globalScore returns per-key aggregates")

edit(gp,
     "\t\t\treturn nil, stats, fmt.Errorf(\"trace has no `seq` column",
     "\t\t\treturn nil, stats, nil, fmt.Errorf(\"trace has no `seq` column",
     "seq refusal, new arity")

edit(gp,
     "\t\t\treturn nil, stats, fmt.Errorf(\"trace has no `key` column",
     "\t\t\treturn nil, stats, nil, fmt.Errorf(\"trace has no `key` column",
     "key refusal, new arity")

edit(gp,
     "\t\tstats.claimedBlocks++\n"
     "\t\tstats.dispatchedBytes += hi - lo\n"
     "\t\tgDisp[d.fh] += hi - lo\n",
     "\t\tstats.claimedBlocks++\n"
     "\t\tstats.dispatchedBytes += hi - lo\n"
     "\t\tgDisp[d.fh] += hi - lo\n"
     "\t\tka(d.key).dispatchedBytes += hi - lo\n",
     "per-key dispatched bytes")

edit(gp,
     "\t\tif claimed[d.key][d.block] {\n"
     "\t\t\tstats.suppressedBlocks++\n"
     "\t\t\tsuppressed[d.fh]++\n"
     "\t\t\tcontinue\n"
     "\t\t}",
     "\t\tif claimed[d.key][d.block] {\n"
     "\t\t\tstats.suppressedBlocks++\n"
     "\t\t\tsuppressed[d.fh]++\n"
     "\t\t\tka(d.key).suppressedBlocks++\n"
     "\t\t\tcontinue\n"
     "\t\t}",
     "per-key suppressed blocks")

edit(gp,
     "\t\tused := coveredBytes(later, lo, hi)\n"
     "\t\tgUsed[d.fh] += used\n"
     "\t\tstats.usedBytes += used\n",
     "\t\tused := coveredBytes(later, lo, hi)\n"
     "\t\tgUsed[d.fh] += used\n"
     "\t\tstats.usedBytes += used\n"
     "\t\tka(d.key).usedBytes += used\n",
     "per-key redeemed bytes")

edit(gp,
     "\t\ts := coveredBytes(same, lo, hi)\n"
     "\t\tstats.sameHandleBytes += s\n"
     "\t\tstats.crossHandleBytes += used - s\n",
     "\t\ts := coveredBytes(same, lo, hi)\n"
     "\t\tstats.sameHandleBytes += s\n"
     "\t\tstats.crossHandleBytes += used - s\n"
     "\t\tka(d.key).crossHandleBytes += used - s\n",
     "per-key cross-handle bytes")

edit(gp,
     "\t\tcFirst[r.fh]++\n"
     "\t\tstats.coldFirstRunReads++\n",
     "\t\tcFirst[r.fh]++\n"
     "\t\tstats.coldFirstRunReads++\n"
     "\t\tka(r.key).coldFirstRunReads++\n",
     "per-key cold first-run reads")

edit(gp,
     "\t\tif coldSeen[r.key][ci] {\n"
     "\t\t\tstats.coldSuppressed++\n",
     "\t\tif coldSeen[r.key][ci] {\n"
     "\t\t\tstats.coldSuppressed++\n"
     "\t\t\tka(r.key).coldSuppressed++\n",
     "per-key cold suppressions")

edit(gp,
     "\t\tcGross[r.fh] += g\n"
     "\t\tcNet[r.fh] += n\n"
     "\t\tstats.coldGrossWaste += g\n"
     "\t\tstats.coldNetWaste += n\n",
     "\t\tcGross[r.fh] += g\n"
     "\t\tcNet[r.fh] += n\n"
     "\t\tstats.coldGrossWaste += g\n"
     "\t\tstats.coldNetWaste += n\n"
     "\t\tka(r.key).coldGrossWaste += g\n"
     "\t\tka(r.key).coldNetWaste += n\n",
     "per-key cold waste")

edit(gp,
     "\tstats.keys = len(byKey)\n",
     "\t// The clamped size, so the key-level features divide by the same denominator the\n"
     "\t// byte accounting used rather than re-deriving it.\n"
     "\tfor k, sz := range sizeOf {\n"
     "\t\tka(k).size = sz\n"
     "\t}\n"
     "\tstats.keys = len(byKey)\n",
     "per-key object size")

edit(gp,
     "\tstats.handles = len(out)\n"
     "\treturn out, stats, nil\n}",
     "\tstats.handles = len(out)\n"
     "\treturn out, stats, keyAggs, nil\n}",
     "final return, new arity")

# ---- main.go: the flag, the per-trace pass, the verdict --------------------------------
edit(mp,
     '\tglobal_ := flag.Bool("global", false,',
     '\tkeys_ := flag.Bool("keys", false, "also fit the rule at the KEY (object) level and score it against the cold-start tax as well as follow-through; implies -global, since the accounting is the shared one (see keys.go)")\n'
     '\tkeysOut := flag.String("keys-out", "", "write per-key scores and features to this CSV")\n'
     '\tglobal_ := flag.Bool("global", false,',
     "-keys and -keys-out flags")

edit(mp,
     "\tvar all, allGlobal []handleScore\n",
     "\tvar all, allGlobal []handleScore\n"
     "\tvar allKeys []keyScore\n"
     "\t// The key-level pass reuses the shared-cache accounting wholesale, so asking for one\n"
     "\t// without the other would silently score objects against a per-handle denominator.\n"
     "\tif *keys_ {\n"
     "\t\t*global_ = true\n"
     "\t}\n",
     "allKeys accumulator; -keys implies -global")

edit(mp,
     "\t\t\tgs, gstats, err := globalScore(scores, cfg, rows, *byteExact)\n",
     "\t\t\tgs, gstats, kaggs, err := globalScore(scores, cfg, rows, *byteExact)\n",
     "call site, new arity")

edit(mp,
     "\t\t\treportGlobal(gstats, phDisp, phUsed, parseIssuedPer(*issuedPer)[spec], cfg.blockSize)\n"
     "\t\t\tallGlobal = append(allGlobal, gs...)\n",
     "\t\t\treportGlobal(gstats, phDisp, phUsed, parseIssuedPer(*issuedPer)[spec], cfg.blockSize)\n"
     "\t\t\tallGlobal = append(allGlobal, gs...)\n"
     "\t\t\tif *keys_ {\n"
     "\t\t\t\tks := scoreKeys(label, arm, cfg, rows, scores, kaggs, *k, *byteExact)\n"
     "\t\t\t\treportKeys(ks, cfg.blockSize)\n"
     "\t\t\t\tallKeys = append(allKeys, ks...)\n"
     "\t\t\t}\n",
     "per-trace key pass")

edit(mp,
     '\t\t\tfmt.Printf("\\nshared-cache scores written to %s\\n", gp)\n'
     "\t\t}\n"
     "\t}\n"
     "}",
     '\t\t\tfmt.Printf("\\nshared-cache scores written to %s\\n", gp)\n'
     "\t\t}\n"
     "\t}\n"
     "\n"
     "\t// And the same rule one level up. Printed THIRD, after both handle-level verdicts,\n"
     "\t// for the same reason they are both printed: which unit the rule belongs in is the\n"
     "\t// open question, and a reader has to be able to see every answer to judge it.\n"
     "\tif *keys_ {\n"
     '\t\tfmt.Printf("\\n########## the rule at the KEY level, against two targets (see keys.go) ##########\\n")\n'
     "\t\treportKeyVerdict(allKeys, labels, *minN, *k)\n"
     '\t\tif *keysOut != "" {\n'
     "\t\t\tif err := writeKeyCSV(*keysOut, allKeys); err != nil {\n"
     '\t\t\t\tfmt.Fprintf(os.Stderr, "write %s: %v\\n", *keysOut, err)\n'
     "\t\t\t\tos.Exit(1)\n"
     "\t\t\t}\n"
     '\t\t\tfmt.Printf("\\nper-key scores written to %s\\n", *keysOut)\n'
     "\t\t}\n"
     "\t}\n"
     "}",
     "key-level verdict section")

for path, old, new, why in EDITS:
    src = path.read_text()
    n = src.count(old)
    assert n == 1, f"{path.name}: {why!r} matched {n} times, expected 1"
    path.write_text(src.replace(old, new, 1))
    print(f"ok  {path.name}: {why}")
print(f"{len(EDITS)} edits applied")
