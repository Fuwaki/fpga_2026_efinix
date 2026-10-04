# E5c: engine_top clock constraint. 10 ns = 100 MHz for the first run.
# Fmax is read from the STA report; the constraint only sets the target.
create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports {clk}]
