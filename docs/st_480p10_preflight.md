# 480p/10 fps integration gate

Run the preflight from the repository root:

```sh
python3 tools/st_480p10_preflight.py \
  --json docs/st_480p10_preflight.json
```

The default quantized model and planner config are repo-local:

```text
config/manifest/ink_dw_w8a8/       manifest.json + weights.bin
config/ink_dw_480p10_plan.json     per-layer folding plan
```

The optional NNgen planner is still an external analysis dependency; pass
`--nngen /path/to/nngen` if it is not at `../nngen`.

The command reads the real quantized manifest, runs the NNgen `st_stream`
planner, and writes a machine-readable report. Generated Verilog is placed in
`/tmp` and is discarded. This is intentional: `st_stream` currently produces
a dedicated per-layer accelerator, while the board must use a shared DDR tile
engine. The report therefore sets `board_integration_allowed` to `false` even
when the cycle estimate meets the target.

The current `ink_dw` result reaches the 10 fps cycle budget at 100 MHz, but
needs about 1.08 MB of streaming storage (roughly 106 RAM10 blocks). After
freeing the existing accelerator/video-pipe blocks, the board estimate has
about 88 RAM10 blocks available, so copying its RTL into the project is
rejected by the gate. The 32×32 APB/片上 path remains
the board regression baseline until a shared tile implementation is verified
in simulation and synthesis.
