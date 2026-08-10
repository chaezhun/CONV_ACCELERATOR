# CNN Convolution Accelerator

A 3-channel 5x5 stride-3 convolution accelerator, taken from RTL through synthesis,
placement, clock tree and routing to GDS. Graded by a formula that ranks entries
against a reference design.

System Semiconductor term project (EECE434). Individual work.

[한국어](README.ko.md)

---

## Highlights

| | Before | After |
|---|---|---|
| Scored area | 295,842 µm² | **106,234 µm²** (2.8× smaller) |
| Composite score | 41.3 | **33.1** |
| Timing slack | −0.84 ns | **−0.02 ns** |
| Internal buffer | 1,470 B | **495 B** |

Functional verification **1024/1024** on all three filters.
Final score **−0.605 versus the reference design** (area −50%, power −10%).

## The scoring rule, and why it changed the design

```
Score = dPower + dArea + 2 * dTiming        (lower is better)
d = (mine - baseline) / baseline
```

Cycle count is not scored. It is a **gate**: three filters must match 100 %, the
average must stay under 450,000 cycles, and routing must succeed. Miss any one and
the score is zero.

That inverts the usual instinct. There is no reward for being fast beyond the gate,
so the winning design is **the smallest, lowest-power thing that still clears it**.
The baseline has no buffer at all, so any design that buffers starts at an area
disadvantage and has to earn it back.

Reading the formula was not enough. Measuring the baseline showed where the points
actually were:

| Term | Baseline | Effect |
|---|---|---|
| Area | 5,760 um2 | dArea ~ 17.6 |
| **Power** | **0.0070 W** | **dPower ~ 15.4 — dividing by 0.007 amplifies 1 mW into 0.14 points** |
| Timing | 1.0 ns | 2 x dTiming ~ 0.04 |

Timing carries a weight of 2 and still contributes almost nothing. Power decides
the ranking. Chasing timing because of the visible weight would have been the
wrong move.

## What the design does

Memory reads take 10 cycles and cannot be pipelined, so data has to be buffered and
reused or the cycle gate is unreachable.

**Channel-serial with partial sums in external RAM.** Buffering all three channels
needs 1,470 bytes and that buffer dominated the area. Processing one channel at a
time and accumulating partial sums back into the feature RAM (write on the first
pass, read-add-write afterwards) leaves a buffer of 495 bytes and removes the
partial-sum registers entirely.

| Version | Structure | Scored area |
|---|---|---:|
| v11 | three channels buffered (1,470 B) | 295,842 um2 |
| **v12** | **channel-serial + external accumulation (495 B)** | **106,234 um2** |

Cycle count is unchanged because the number of reads is the same. Row-level rolling
reuse means each output row only fetches three new rows out of five.

**Banked line buffer.** A single 1,470-byte array was not recognised as memory by
the synthesiser, which expanded it into a 1470:1 multiplexer and 11,760 flip-flops
and produced 13,224 routing violations. Splitting it into five banks of 99 bytes,
one per row slot, keeps each bank under the 512-byte inference limit, shrinks the
read multiplexer from 495:1 to 5:1, and removes a multiply from the index
calculation. Routing then completed with zero DRC violations.

## Disproving a diagnosis

One of three filters failed from a fixed index onward. The standing explanation was
a testbench race condition that RTL could not fix, and code had accumulated around
that assumption.

Recomputing the convolution in Python straight from the original binaries settled it:

```
sum over ch,dr,dc of  ifmap[ch][3R+dr][3C+dc] * filter[ch][dr][dc]
    matches the golden file 1024 / 1024
```

No race, no special rule. The real causes were two, both mine:

1. the memory returns the previous cycle's address, so reads need `col = 3C+dc+1`;
2. output column 31 needs input column 97, which after that correction lands at
   buffer position 98 — one past the end of a 98-entry buffer, so it read into the
   next row.

The other two filters passed by luck: the weight at that position happened to be
zero. Widening the buffer from 98 to 99 fixed all three and let every accumulated
workaround be deleted.

## Results

| | |
|---|---|
| Functional | three filters, **1024 / 1024 each** |
| Cycles | **435,778** (gate: 450,000) |
| Routing | passed, **0 DRC violations** |
| Scored area | 107,341 um2 |
| Worst slack | -0.02 ns |
| Power | 0.115 W |
| Part 1 score | **33.1** (from 41.3) |
| Part 2 score | **-0.605** vs baseline |

Part 1 improved almost entirely through power (0.170 W to 0.115 W), not timing.
Part 2 tuned physical parameters on fixed RTL: placement density and clock period
were swept in two dimensions, and density 80 with a 1.0 ns clock sat at the minimum
of a U-shaped curve — below that the die is too large, above it congestion costs
more in power and timing than the area saves.

## Repository structure

```
part1_rtl/Convolver.v        the submitted design
part1_rtl/MAC.v              provided, must not be modified, must be submitted with it
part2_physical/config.mk     placement density 40 -> 80
part2_physical/constraint.sdc clock period 1.0 ns (kept; the sweep confirmed it)
verification/                Python golden models used to define and check correctness
```

## Toolchain

OpenROAD Flow Scripts (Yosys, placement, CTS, routing) on Nangate45, and Cadence
NCverilog for functional simulation.
