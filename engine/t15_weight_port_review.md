# t15 review pack: `conv_stream` weight write port (whole-word write)

Author: architect (t15 attempt 1). **This is evidence for an independent review, not
an approval** - the author must not pass their own change, and `conv_stream` is a
verified module, so it should not become the baseline on my word alone.

## 0. What was changed, exactly

| item | value |
|---|---|
| file | `fpga_rtl_lab/src/conv_stream.veryl` |
| source sha256 | `41fd073dd8ed8d957a024b19a02fb4c7884f5fc592c9b86344854dd65cfc6382` (before: `4a62ea85b4e4dde5e4cacd927ddeaebd6ee7dff03490d667b0d690ca4815ac55`) |
| diff size | +41 / -9 lines (one file); `git diff src/conv_stream.veryl` |
| new state | `wr_sh` (8*P-bit shadow register), `wr_nx` (merged word), `ld_word_c` / `ld_lane_c` (write-side helpers) |
| new write port | `wr_sh = wr_nx;` and `if w_we { wr[ld_word_c[WW-1:0]] = wr_nx; }` |
| generated SV | `target/conv_stream.sv` lines 388-390; `grep -nE 'wr\[[^]]*\]\[[^]]*\+:' target/conv_stream.sv` is **empty** |
| pinned netlist | `fpga_src/engine/sv_fixed/SHA256SUMS` (conv_stream.sv `28a3ccd7...`) |

Removed line: `wr[...][8 * (ld_oc % P)+:8] = w_data;` (a byte-lane write into a wide
RAM word) - the shape that makes Efinity's Titanium mapper abort; see `README.md`
sections 2 and 3 for the abort evidence and the five-file reproducer.

## 1. The two assumptions a reviewer should attack

**A1 - "`ld_lane_c == 0` starts a fresh shadow" is correct.**
The load port is sequential by contract: the host streams the layer's weight bytes
at addresses 0,1,2,... in the layout `((ic*K+ky)*K+kx)*OUT_C+oc`, and `w_addr` is
compared against the internal counter (mismatch sets the sticky `w_seq_err`).
`src/conv_stream.veryl:499-511` implements it as:

```
if w_we {
    if w_addr != ld_addr { w_err = 1 }
    if cfg_out_c == 0     { w_err = 1 }
    ld_addr = ld_addr + 1;
    if ld_oc == (cfg_out_c - 1) { ld_oc = 0; ld_t = ld_t + 1 }
    else                        { ld_oc = ld_oc + 1 }
}
```

So within one tap `ld_oc` walks 0,1,...,out_c-1 with no gaps and no repeats, and the
word/lane pair is `(ld_t*NPASS + ld_oc/P, ld_oc%P)`. Since `ld_oc` starts each tap at
0 and is contiguous, the *first* write of every packed word happens at lane 0 -
e.g. out_c = 48, P = 32: word 0 gets lanes 0..31, word 1 gets its lane 0 at
`ld_oc = 32` because `32 % 32 == 0`. Both reset points put the counters back to
`(ld_t, ld_oc) = (0, 0)` before a sweep (`:438-440` and `:521-523`), so a re-load
also starts on a lane 0. Clearing the shadow on lane 0 is therefore exactly
"a word is assembled from its own bytes" - a stale-byte merge is impossible.

**A2 - "the lanes a final partial block never fills cannot affect the output".**
`rq_pe_c = min(P, out_c - oc_base)` (`:338-342`), `y_cnt = rq_pe_c` (`:373`), and the
drain pair indices are clamped to `< P` (`:348-357`), so only lanes `< rq_pe_c` reach
requant and emit. Note the *old* code left those lanes at whatever the RAM word
held (0 in Verilator, undefined in silicon), so if A2 were false the old code was
equally exposed - the change replaces "undefined" with "deterministic 0".

## 2. Direct evidence that the partial-block path is exercised (not just argued)

Channel counts measured from the frozen per-layer dumps (`bytes / 256 px` at 16x16,
identical for both styles):

| layer | out_c | out_c % 32 | regime |
|---|---|---|---|
| `enc.1`, `enc.2`, `up1.1`, `up3.1` | 48 | **16** | one full block + **one partial block** |
| `head` | 9 | **9** | **one partial block only** |
| `enc.0`, `up1.0`, `up3.0`, `res.*` | 96 / 192 | 0 | full blocks |

i.e. **5 of the 16 layers per style take the partial-last-block path**, and the A/B
below compares outputs byte-for-byte on all of them.

## 3. Evidence runs (all reproducible; commands in `README.md` sections 1-2)

| check | result |
|---|---|
| `veryl test` | rc=0, **120 passed / 0 failed** |
| `./sim/run_veryl.sh` | rc=0, every stage PASS: veryl-fmt, veryl-check, veryl-test (120/0), veryl-test-count, veryl-build, layers-ink 16/16, layers-vangogh 16/16, head-clean |
| data-plane A/B: `sim/run_engine.sh` with HEAD then with the patched source | **52 dump files byte-identical** (32 per-layer + 20 cascade), `diff` empty; gate-line `diff` empty; `e2e-rtl-ink-16 mismatch=8322` in both (pre-existing, see `gen/engine/E5_OPEN_ITEMS.md`) |
| layer gate byte volume | `LAYERS ink/vangogh layers=16 pass=16 fail=0 skip=0 vec=172800` each, unchanged |
| Efinity Ti60F225, `sh run_fixed.sh Titanium Ti60F225 I3 ti60` | `map exit=0` + `pnr exit=0` (was `[ASSERT INFO] ram net has invalid dimension` / exit 12) |

## 4. Not proven / open items - for the reviewer to judge

1. **Side effect, not a functional one:** the RAM word is now written on *every*
   load cycle, redundantly re-writing already-filled lanes - an activity/power cost.
2. The frozen `conv_engine` still cannot be synthesised on Titanium *or* Trion
   (SIGSEGV, no byte-lane write in it) - a second, independent blocker this change
   does not touch (`README.md` section 5).
3. Everything above is measured on the committed datasets; a *new* layer shape is not
   covered (e.g. `out_c` > 255 would overflow the 8-bit lane logic) - but it was not
   covered before either, and the descriptor's `out_c` is 8-bit by contract.
4. I am the author of the change. The A/B shows the data plane is unchanged; whether
   that is *sufficient* for a verified module to move is the reviewer's call.

## 5. Audit: why `veryl test` says 120 now and said 121 earlier (asked by the captain)

Answer: the missing unit is **`test_hexdump_probe`**, declared in
`test/tb_hexdump_probe.veryl`. It was a **temporary format probe, never committed**,
and it carried **no assertion**. No committed test was lost - the committed suite
*grew* from 119 to 120 in the same window.

| step | evidence |
|---|---|
| what the two counts are | `build/verify_fulltest.log` (16:40:23): `121 passed, 0 failed`, 121 `Executing test` lines. `build/t14_gate.log` (16:54:00): `121 passed`. My run, `build/veryl-test.log` (17:10:57): `120 passed, 0 failed`, 120 lines. |
| exact name diff of the two full logs | **one** line: `test_hexdump_probe` present at 16:40, absent now; the other 120 names are identical |
| what it was | `/tmp/tb_hexdump_probe.veryl.1789376536` (1222 B, 15:31:53): prints 4 bytes as two nibbles into `build/hexdump_probe.txt` (4 lines: `0d`, `b0`, `e5`, ...) because Veryl 0.21's `%x` has no zero padding; its own header says "the expected text is compared **outside the simulator**". A grep for assert/$error/$fatal/cmp finds only the header word "compared" - **zero in-simulator checks, so zero coverage lost**. |
| never part of any baseline | `git log --all -S test_hexdump_probe` is **empty**; the file is in no commit |
| committed count over time | 119 at `1c4a496`..`f9d8650` (16:33-16:55); **120** from `902802a` (17:02), which *added* `test_e2e_ink_16x16` (the E2E cascade TB) |
| so the 121 reconciles exactly | 119 committed + `test_e2e_ink_16x16` (uncommitted then) + `test_hexdump_probe` (uncommitted, later removed) = 121 at 16:40; today 119 + `test_e2e_ink_16x16` = 120 |
| two name changes are renames, not removals | in the same window `tb_requant`, `tb_sat_add` and 8x `point_add_*` became `test_requant`, `test_sat_add`, `test_point_add_*`; a naive name diff then shows 12 in / 10 out |
| not this author | my whole repository footprint is the two files of commit `679fb2b` (`git show --stat 679fb2b`); `veryl fmt` cannot delete files, and I never ran `rm`/`git clean` on `test/` |

The `veryl-test-count` floor is 41, so 120 vs 121 cannot turn the gate red - which is
exactly why the difference is written out here instead of being left silent.
