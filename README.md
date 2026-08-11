# CNN Convolution Accelerator

> A three-channel 5×5 stride-3 convolver taken from RTL all the way to GDS.

The design goes through synthesis, placement, clock tree and routing to a finished
physical implementation. It is scored by a formula that ranks it against a reference
design — and measuring that reference showed almost all of the score lives in power.
Restructuring the buffers cut the **scored area from 295,842 µm² to 106,234 µm², a 2.8×
reduction**, with all three verification filters matching 1024/1024.

[한국어](README.ko.md)

---

## Background

```
Score = Δpower + Δarea + 2 × Δtiming        (lower is better)
Δ = (my design − reference) / reference
```

Cycle count is not part of the score. It is a **gate**. All three filters must match
100%, the average cycle count must stay under 450,000, and routing must succeed. Miss any
one and the score is zero.

That inverts the usual intuition. Past the gate there is no reward for being faster, so
the winning design is **the smallest, lowest-power one that still clears the gate**. The
reference design has no buffers at all, so any buffered design starts with an area deficit
it has to earn back.

Reading the formula was not enough. Measuring the reference design showed where the score
actually was.

| Term | Reference | Effect |
|---|---|---|
| Area | 5,760 µm² | Δarea ≈ 17.6 |
| **Power** | **0.0070 W** | **Δpower ≈ 15.4 — dividing by 0.007 makes 1 mW worth 0.14 points** |
| Timing | 1.0 ns | 2 × Δtiming ≈ 0.04 |

Timing carries a weight of 2 and still contributes almost nothing. Power decides the
ranking. Chasing timing because its visible weight was highest would have been the wrong
direction entirely.

## System

| | |
|---|---|
| Operation | three channels, 5×5 kernel, stride 3 |
| Output | 32×32 feature map, three filters |
| Memory | external RAM, 10-cycle read latency, not pipelineable |
| Internal buffer | 495 B, five banks by row slot |
| Process | Nangate45 |
| Toolchain | OpenROAD Flow Scripts (Yosys → place → CTS → route); functional simulation in Cadence NCverilog |

## Design

A memory read takes 10 cycles and cannot be pipelined, so without buffering data for reuse
there is no way to reach the cycle gate.

### Channel serialisation with partial sums in external RAM

Buffering all three channels needs 1,470 bytes, and that dominated the area. Processing one
channel at a time and accumulating partial sums into the feature RAM — write on the first
pass, read-add-write afterwards — cuts the buffer to 495 bytes and removes the partial-sum
registers entirely.

| Version | Structure | Scored area |
|---|---|---:|
| v11 | all three channels buffered (1,470 B) | 295,842 µm² |
| **v12** | **serial channels + accumulation in external RAM (495 B)** | **106,234 µm²** |

The read count is unchanged, so cycles are unchanged. Row-wise rolling reuse means only 3
of 5 rows are freshly read when the output row advances by one.

### Banked line buffer

Declaring 1,470 bytes as a single array meant the synthesiser did not infer memory. It
unrolled it into a 1470:1 multiplexer and 11,760 flip-flops, producing 13,224 routing
violations. Splitting it into five banks by row slot (99 bytes each) put every bank under
the 512-byte inference limit, shrank the read mux from 495:1 to 5:1, and removed the
multiply from the index calculation. Routing then completed with zero DRC violations.

### Disproving the diagnosis

One of the three filters kept failing from a particular index onwards. The standing
explanation was "a testbench race condition that RTL cannot fix", and code had accumulated
on top of that assumption.

Recomputing the convolution in Python straight from the original binaries settled it.

```
Σ over ch,dr,dc:  ifmap[ch][3R+dr][3C+dc] × filter[ch][dr][dc]
    → 1024 / 1024 match against the golden file
```

There was no race and no special rule. Both real causes were on my side.

1. The memory latches the previous cycle's address, so reads need a `col = 3C+dc+1`
   correction.
2. Output column 31 needs input column 97, which after the correction lands at buffer
   position 98 — one slot outside a 98-entry buffer, so it was reading the next row's value.

The other two filters passed only because the weight at that position happened to be zero.
Widening the buffer from 98 to 99 made all three pass, and all the workaround code that had
piled up came back out.

### Chasing the endpoint of the critical path

The grading `constraint.sdc` pins the clock period at **1.0 ns (1 GHz)** — ten times faster
than the 100 MHz in the specification, and no design that carries a buffer can satisfy it
outright. So the goal became **closing every path I wrote and showing from the reports that
what remained was untouchable.**

Rather than guessing where the bottleneck was, each round read the **endpoint** the physical
report named and cut only that path. The bottleneck moved four times.

| Version | Critical-path endpoint | Path | Slack (WNS) |
|---|---|---|---:|
| v8 | 1470:1 random read mux | **routing failed** — 13,224 violations | −1.025 ns |
| v12 | channel-serial core | — | −0.45 ns |
| v13 | MAC input buffer | counter → 495:1 buffer mux → MAC input (**half a clock**) | −0.27 ns |
| v14 | partial-sum register | partial-sum adder → select mux → register (**one clock**) | −0.01 ns |
| **v15** | **accumulator inside MAC** | 8×8 multiply + 16-bit accumulate (**unmodifiable module**) | **−0.02 ns** |

v14 registers the output of the large read mux before handing it to the MAC, turning a
half-clock path into a full one. The extra cycle of latency is absorbed by disabling
accumulation during fill and adding one drain cycle at the end.

v15 removes the remaining partial-sum output mux. Choosing a reset value that keeps
`feat_old` at zero through the first pass (the first pass never enters the read state) makes
the conditional unnecessary, so the path is **always `feat_old + mac_result`**. Dropping the
mux also cut area and power.

The final endpoint sits **inside `MAC.v`, which the assignment forbids modifying** — a
structural limit of single-cycle multiply-accumulate at 1 GHz. That made it possible to show
from the report's critical-path endpoint that **no path I wrote was left to cut.** The
difference between v14's −0.01 and v15's −0.02 is within placement noise (±0.05); both bottom
out on the same MAC multiply-accumulate.

### A two-dimensional sweep of the physical parameters

Part 2 freezes the RTL and tunes parameters only. Scored area is `design area / placement
density`, so density was the axis to push.

**Placement density (clock fixed at 1.0)** — a U-curve.

| Density | Scored area | Power | Slack | Score |
|---:|---:|---:|---:|---:|
| 40 (reference) | 5,760 | 0.00700 | 0 | 0 |
| 60 | 3,850 | 0.00644 | 0 | −0.412 |
| **80** | **2,851** | **0.00630** | 0 | **−0.605** |
| 85 | 2,721 | 0.00732 ↑ | −0.05 ↓ | −0.382 (worse) |
| 90 | — | — | — | **placement failed** |

Past 85, congestion costs more in power and timing than the area saves. 80 is the minimum and
sits close to the cell-area floor of about 2,452 µm².

**Clock period (density fixed at 80)**

| Period | Timing (= period − slack) | Power | Score |
|---:|---:|---:|---:|
| 0.9 | 1.0 | 0.00935 | −0.166 |
| **1.0** | **1.0** | **0.00630** | **−0.605** |
| 1.2 | 1.2 | 0.00476 | −0.423 |

Both directions lose. **Tighten** and the MAC is already at its delay limit, so timing stays
pinned at 1.0 while the cells grow — 48% of the power wasted for nothing. **Loosen** and slack
stops at zero, so timing becomes the clock period itself and rises to 1.2; power drops 32% but
the weight-2 penalty outweighs it.

The minimum achievable timing is the real path delay (≈1.0), and **the cheapest way to reach it
is the clock period where slack is exactly zero**.

Power recovery, clock-tree and cell-restriction options were swept too, but **73% of the power
comes from the unmodifiable MAC multiplier**, leaving nothing to recover (power-recovery
options changed the result by zero). With density and clock the only effective levers, the
sweep ended there.

### Timing fully closed at 1 GHz

The Part 2 submission leaves nothing on the table.

| | |
|---|---|
| WNS / TNS | **0.00 / 0.00** |
| Worst slack | **+0.10 ns** |
| Setup / hold violations | **0 / 0** |
| Max slew, fanout, capacitance violations | **0 each** |
| DRC violations | **0** |
| Minimum clock period / fmax | 1.09 ns / **919.77 MHz** |

WNS stays at zero all the way to density 80 and first goes negative (−0.05) at 85. **The
optimum is the point that halves the area without giving up any timing at all.**

### Why verification was split into four stages

| Stage | Method | What it settles |
|---|---|---|
| 1. Define correctness | Python back-solve (`reverse.py`) | is the golden file a standard convolution — 1024/1024 |
| 2. Architecture | Python model (`verify_b1.py`) | does channel-serial + 16-bit modular accumulation match — **before any RTL** |
| 3. Function | NCverilog | all 1,024 outputs for each of three filters, plus cycle count |
| 4. Physical | OpenROAD | synthesis → placement → routing, zero DRC, area/power/timing extracted |

Stage 2 earned its place. Confirming **before writing RTL** that splitting channels and
accumulating in 16 bits still matches the golden data meant that when values went wrong after
the restructure, the cause was an implementation slip and nothing else.

## Repository structure

```
part1_rtl/Convolver.v         the submitted design
part1_rtl/MAC.v               distributed, must not be modified, required in the submission
part2_physical/config.mk      placement density 40 → 80
part2_physical/constraint.sdc clock period 1.0 ns (kept — the sweep found it optimal)
verification/                 Python golden model used to define and check correctness
```

## Results

| | |
|---|---|
| Function | **1024 / 1024 for each of the three filters** |
| Cycles | **435,778** (gate is 450,000) |
| Routing | passed, **zero DRC violations** |
| Scored area | 107,341 µm² |
| Power | 0.115 W |
| Part 1 timing | −0.02 ns — every path I wrote is closed; what remains is inside `MAC.v` |
| **Part 2 timing** | **WNS and TNS 0.00, zero setup and hold violations — 1 GHz fully met** |
| Part 1 score | **33.1** (from 41.3) |
| Part 2 score | **−0.605** against the reference (−50% area, −10% power) |

The Part 1 improvement came almost entirely from power (0.170 → 0.115 W), not timing.

Part 2 froze the RTL and tuned only physical parameters. Sweeping placement density against
clock period in two dimensions put the bottom of the U-curve at density 80 with a 1.0 ns
clock. Lower density grows the die; higher density costs more in congestion-driven power and
timing than it saves in area.

## Build and run

**Prerequisites** — OpenROAD Flow Scripts, the Nangate45 PDK, NCverilog for functional
simulation.

```bash
# functional simulation
ncverilog part1_rtl/Convolver.v part1_rtl/MAC.v <testbench>

# physical implementation — place config.mk and constraint.sdc in the flow directory
make DESIGN_CONFIG=./config.mk
```

The Python golden model in `verification/` regenerates the reference files so RTL output can
be compared against them.

## Notes

**Distributed material** — `part1_rtl/MAC.v` was provided by the course and carries a
no-modification condition. It is bundled as-is so the design builds. Everything else here is
my own work.

**Not included** — the testbench (`tb_Convolver.v`) and the physical-flow platform settings
are also distributed material and are left out. The testbench is what the `<testbench>`
placeholder in the simulation command above refers to.
