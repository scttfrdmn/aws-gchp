#!/usr/bin/env python3
"""Wire the shared-cache pass into upstream's lith-pfreplay.

The scoring itself lives in a new file (pfreplay-global.go -> cmd/lith-pfreplay/global.go).
This script makes the five additive changes in main.go that it needs:

  1. row.key           -- the column exists in the #262 trace format and readTrace never
                          parsed it. Dedup is per object, so it has to.
  2. handleScore.suppressedBlocks
  3. -global flag
  4. the per-trace global pass + accumulation
  5. a second verdict section, and a second CSV, in the shared unit

Every edit asserts it matches exactly once, so a drifted upstream fails loudly here
rather than silently patching the wrong place.
"""
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "cmd/lith-pfreplay/main.go"
src = open(PATH).read()
orig = src


def edit(old, new, label):
    global src
    n = src.count(old)
    assert n == 1, f"{label}: matched {n} times, want 1"
    src = src.replace(old, new)
    print(f"  ok  {label}")


# 1. the key column
edit(
    """	maxWindow   int64 // the mount's SetMax input for this decision; 0 = pre-#267 trace
	fh          uint64
	size        int64 // object size, for the EOF clamp""",
    """	maxWindow   int64 // the mount's SetMax input for this decision; 0 = pre-#267 trace
	fh          uint64
	key         string // the object. Only the shared-cache pass uses it, because only a
	                   // shared cache has to know when two handles fetch the same block.
	size        int64  // object size, for the EOF clamp""",
    "row.key",
)

edit(
    """		if _, ok := col["max_window"]; ok {
			maxWin = atoi("max_window")
		}
		rows = append(rows, row{
			seq: seq, maxWindow: maxWin, fh: fh, size: size, off: atoi("off"), length: atoi("len"), blk: atoi("blk"), gap: atoi("gap"),""",
    """		if _, ok := col["max_window"]; ok {
			maxWin = atoi("max_window")
		}
		var key string
		if _, ok := col["key"]; ok {
			key = rec[col["key"]]
		}
		rows = append(rows, row{
			seq: seq, maxWindow: maxWin, fh: fh, key: key, size: size, off: atoi("off"), length: atoi("len"), blk: atoi("blk"), gap: atoi("gap"),""",
    "readTrace parses key",
)

# 2. per-handle suppression count
edit(
    """	clampedAway        int   // of those, how many fell entirely past the object's end
}""",
    """	clampedAway        int   // of those, how many fell entirely past the object's end
	suppressedBlocks   int   // -global only: dispatches of a block already resident from another handle
}""",
    "handleScore.suppressedBlocks",
)

# 3. the flag
edit(
    """	issued := flag.Int64("issued", 0, "the run's lith_prefetch_issued_total, if you have it: the only fully independent check on the replay's denominator")
	flag.Parse()""",
    """	issued := flag.Int64("issued", 0, "the run's lith_prefetch_issued_total, if you have it: the only fully independent check on the replay's denominator")
	global_ := flag.Bool("global", false, "also score against one SHARED cache per mount: charge each (key, block) fetch once and credit reads by ANY handle on that key (needs the seq and key columns)")
	issuedPer := flag.String("issued-per", "", "per-trace lith_prefetch_issued_total, e.g. `met/a=2939,hemco/a=4632`: with -global, the independent check on which unit reproduces the mount's fetch volume")
	flag.Parse()""",
    "-global flag",
)

# 4. accumulate and run the pass
edit(
    """	var all []handleScore
	var totalDispBytes""",
    """	var all, allGlobal []handleScore
	var totalDispBytes""",
    "allGlobal",
)

edit(
    """		reportColdTax(scores)
		for _, sc := range scores {""",
    """		reportColdTax(scores)
		if *global_ {
			gs, gstats, err := globalScore(scores, cfg, rows, *byteExact)
			if err != nil {
				fmt.Fprintf(os.Stderr, "%s: -global: %v\\n", path, err)
				os.Exit(1)
			}
			var phDisp, phUsed int64
			for _, sc := range scores {
				phDisp += sc.dispatchedBytes
				phUsed += sc.usedBytes
			}
			reportGlobal(gstats, phDisp, phUsed, parseIssuedPer(*issuedPer)[spec], cfg.blockSize)
			allGlobal = append(allGlobal, gs...)
		}
		for _, sc := range scores {""",
    "global pass per trace",
)

# 5. the second verdict, in the shared unit
edit(
    """		fmt.Printf("\\nper-handle scores written to %s\\n", *out)
	}
}""",
    """		fmt.Printf("\\nper-handle scores written to %s\\n", *out)
	}

	// The same handles, the same features, the same fidelity filter — one unit apart.
	// Printed SECOND and separately rather than replacing the per-handle verdict,
	// because which unit is right is itself the open question, and a reader has to be
	// able to see both answers to judge it.
	if *global_ {
		fmt.Printf("\\n########## the same handles scored against a SHARED cache (see global.go) ##########\\n")
		reportDistribution(allGlobal)
		reportSeparation(allGlobal, labels, *minN)
		if *out != "" {
			gp := strings.TrimSuffix(*out, ".csv") + ".global.csv"
			if err := writeCSV(gp, allGlobal); err != nil {
				fmt.Fprintf(os.Stderr, "write %s: %v\\n", gp, err)
				os.Exit(1)
			}
			fmt.Printf("\\nshared-cache scores written to %s\\n", gp)
		}
	}
}""",
    "shared-cache verdict section",
)

# the CSV carries the new column in both units
edit(
    """		"frac_straddle", "obj_size", "cold_first_run_reads", "cold_reentry_reads",
		"cold_net_waste_bytes", "cold_gross_waste_bytes",""",
    """		"frac_straddle", "obj_size", "cold_first_run_reads", "cold_reentry_reads",
		"cold_net_waste_bytes", "cold_gross_waste_bytes", "suppressed_blocks",""",
    "CSV header",
)

edit(
    """			strconv.FormatInt(s.coldNetWasteBytes, 10), strconv.FormatInt(s.coldGrossWasteByte, 10),""",
    """			strconv.FormatInt(s.coldNetWasteBytes, 10), strconv.FormatInt(s.coldGrossWasteByte, 10),
			strconv.Itoa(s.suppressedBlocks),""",
    "CSV row",
)

assert src != orig
open(PATH, "w").write(src)
print(f"wrote {PATH}")
