// tb_st_film.sv -- st_film (GAP + FiLM MLP) against tools/st_film_vectors.py.
//
// +DIR holds tap.hex ("<data:10 hex> <last>" per group beat), coef.hex
// ("<idx> <mul:5 hex> <off:6 hex>" per channel) and meta.txt
// ("<nbeat> <npix> <cfg_g>").  The testbench:
//
//   * resets, pulses gap_clear once, then streams the whole plane into the
//     tap with random valid gaps -- a beat is held until tap_ready accepts
//     it, as the engine's stream rules require -- and checks that tap_ready
//     stays high every cycle (the tap must never stall the pack stage);
//   * checks the 40 GAP sums against the sums of the vector file;
//   * pulses mlp_start and checks the 40 coefficient writes: exactly 40, in
//     channel order, every idx/mul/off equal to coef.hex, and mlp_busy high
//     from the start until the last write, then low with no further writes;
//   * prints the MLP cycle count (mlp_start edge to the busy drop) and
//     fails unless it is under the pass budget of 50k cycles.
//
// Any mismatch prints the first ten and ends with $fatal(1, ...).
module tb_st_film;
    localparam int NC    = 40;
    localparam int NBEAT = 576_000;   // 57600 pixels x 10 groups
    localparam int BUDGET = 50_000;   // cycles the MLP may take

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [4:0]  cfg_g = 5'd10;
    logic        gap_clear = 0;
    logic        tap_valid = 0;
    logic        tap_ready;
    logic [39:0] tap_data = '0;
    logic        tap_last = 0;
    logic        mlp_start = 0;
    logic        mlp_busy;
    logic        coef_we;
    logic [6:0]  coef_idx;
    logic [17:0] coef_mul;
    logic [23:0] coef_off;

    st_film dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_g(cfg_g), .gap_clear(gap_clear),
        .tap_valid(tap_valid), .tap_ready(tap_ready),
        .tap_data(tap_data), .tap_last(tap_last),
        .mlp_start(mlp_start), .mlp_busy(mlp_busy),
        .coef_we(coef_we), .coef_idx(coef_idx),
        .coef_mul(coef_mul), .coef_off(coef_off)
    );

    // ------------------------------------------------------------ vectors
    logic [39:0] vdata [NBEAT];
    logic        vlast [NBEAT];
    logic [6:0]  vcidx [NC];
    logic [17:0] vcmul [NC];
    logic [23:0] vcoff [NC];
    int  nbeat = 0, npix = 0, g = 0;
    int  mbeat = 0, mpix = 0, mg = 0;
    int  fd;
    bit  loaded = 0;

    initial begin
        string dir;
        if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "tb_st_film: no +DIR");
        fd = $fopen({dir, "/meta.txt"}, "r");
        if (fd == 0 || $fscanf(fd, "%d %d %d\n", mbeat, mpix, mg) != 3)
            $fatal(1, "tb_st_film: cannot read %s/meta.txt", dir);
        $fclose(fd);
        if (mbeat != NBEAT) $fatal(1, "tb_st_film: %0d beats, expected %0d", mbeat, NBEAT);
        if (mg != 10) $fatal(1, "tb_st_film: cfg_g %0d, expected 10", mg);
        if (mbeat != mpix * mg) $fatal(1, "tb_st_film: %0d beats for %0d pixels", mbeat, mpix);
        nbeat = mbeat;
        npix  = mpix;
        g     = mg;
        fd = $fopen({dir, "/tap.hex"}, "r");
        if (fd == 0) $fatal(1, "tb_st_film: cannot open %s/tap.hex", dir);
        mbeat = 0;
        while (mbeat < NBEAT && $fscanf(fd, "%h %d\n", vdata[mbeat], vlast[mbeat]) == 2)
            mbeat++;
        $fclose(fd);
        if (mbeat != NBEAT) $fatal(1, "tb_st_film: %0d tap beats, expected %0d", mbeat, NBEAT);
        fd = $fopen({dir, "/coef.hex"}, "r");
        if (fd == 0) $fatal(1, "tb_st_film: cannot open %s/coef.hex", dir);
        for (int c = 0; c < NC; c++)
            if ($fscanf(fd, "%d %h %h\n", vcidx[c], vcmul[c], vcoff[c]) != 3)
                $fatal(1, "tb_st_film: coef.hex ends at channel %0d", c);
        $fclose(fd);
        for (int c = 0; c < NC; c++)
            if (vcidx[c] != c) $fatal(1, "tb_st_film: coef %0d has idx %0d", c, vcidx[c]);
        $display("tb_st_film: %0d beats, %0d pixels from %s", nbeat, npix, dir);
        loaded = 1;
    end

    // ------------------------------------------------------------- driver
    int  ii = 0;                    // next beat to present
    int  cyc = 0;                   // posedges seen
    int  gaps = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // The tap is a sniff of the pack stream: valid only when the pack stage
    // really transfers a beat, and a beat is held until tap_ready.  Random
    // gaps model the pack stage's own back-pressure.
    initial begin
        tap_valid = 1'b0;
        wait (loaded);
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        gap_clear = 1'b1;           // zero the sums before the plane
        @(negedge clk);
        gap_clear = 1'b0;
        while (ii < nbeat) begin
            tap_valid = 1'b1;
            tap_data  = vdata[ii];
            tap_last  = vlast[ii];
            @(posedge clk);
            while (!tap_ready) @(posedge clk);
            ii++;
            @(negedge clk);
            if ($urandom_range(99) < 15) begin        // random valid gap
                tap_valid = 1'b0;
                gaps++;
                repeat ($urandom_range(1, 3)) begin
                    @(posedge clk);
                    @(negedge clk);
                end
            end
        end
        tap_valid = 1'b0;
        tap_last  = 1'b0;
    end

    // tap_ready must never fall: the sniff must not stall the pack stage.
    int tap_stalls = 0;
    always @(posedge clk)
        if (rst_n && !tap_ready) tap_stalls++;

    // ------------------------------------------------------- GAP sums check
    logic signed [24:0] want [NC];
    int gap_errs = 0;

    initial begin
        for (int c = 0; c < NC; c++) want[c] = '0;
        for (int i = 0; i < nbeat; i++) begin
            automatic int b = i % g;
            for (int j = 0; j < 4; j++)
                want[4*b + j] += 25'(signed'(vdata[i][10*j +: 10]));
        end
    end

    task automatic check_gap;
        for (int c = 0; c < NC; c++)
            if (dut.gap[c] !== want[c]) begin
                gap_errs++;
                if (gap_errs <= 10)
                    $display("MISMATCH GAP sum %0d: %0d want %0d", c, dut.gap[c], want[c]);
            end
    endtask

    // ------------------------------------------------------ coef checker
    int  oi = 0;                    // writes seen
    int  errs = 0;                  // write mismatches
    int  t_start = -1, t_end = -1;
    bit  busy_seen = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (mlp_start && t_start < 0) t_start = cyc;
            if (mlp_busy) busy_seen = 1;
            if (coef_we) begin
                if (oi >= NC) begin
                    errs++;
                    if (errs <= 10)
                        $display("MISMATCH: write %0d beyond the %0d channels (idx %0d)",
                                 oi, NC, coef_idx);
                end else if (coef_idx !== vcidx[oi] || coef_mul !== vcmul[oi]
                             || coef_off !== vcoff[oi]) begin
                    errs++;
                    if (errs <= 10)
                        $display("MISMATCH coef %0d: idx %0d mul %0d off %0d, want idx %0d mul %0d off %0d",
                                 oi, coef_idx, coef_mul, coef_off,
                                 vcidx[oi], vcmul[oi], vcoff[oi]);
                end
                oi++;
            end
            if (busy_seen && !mlp_busy && t_end < 0) t_end = cyc;
        end
    end

    // --------------------------------------------------------------- run
    initial begin
        int mcyc, t0;
        @(posedge rst_n);
        while (ii < nbeat) @(posedge clk);
        repeat (4) @(posedge clk);
        check_gap();
        @(negedge clk);
        mlp_start = 1'b1;
        @(negedge clk);
        mlp_start = 1'b0;
        t0 = cyc;
        while (t_end < 0 && (cyc - t0) < 2 * BUDGET) @(posedge clk);
        repeat (20) @(posedge clk);
        mcyc = t_end - t_start;
        if (!busy_seen) $fatal(1, "tb_st_film: mlp_busy never went high");
        if (t_end < 0) $fatal(1, "tb_st_film: mlp_busy never dropped");
        if (tap_stalls != 0) $fatal(1, "tb_st_film: tap_ready fell %0d times", tap_stalls);
        if (mcyc > BUDGET) $fatal(1, "tb_st_film: MLP took %0d cycles, budget %0d", mcyc, BUDGET);
        if (gap_errs != 0 || errs != 0 || oi != NC)
            $fatal(1, "tb_st_film FAIL %0d GAP and %0d coef errors, %0d of %0d writes",
                   gap_errs, errs, oi, NC);
        $display("tb_st_film PASS %0d pixels, %0d coef writes, MLP %0d cycles (%0d gaps, %0d tap cycles)",
                 npix, oi, mcyc, gaps, cyc);
        $finish;
    end
endmodule
