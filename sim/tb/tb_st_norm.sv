// tb_st_norm.sv -- the norm stage against tools/st_norm_vectors.py.
//
// CASE_DIR (plusarg) holds cfg.txt ("<mode> <g> <npix>"), in.hex (the group
// beats to drive), out.hex (the expected group beats, from
// tools/st_guided.py) and, for FILM, coef.txt (one "<mul> <off>" per channel,
// written through the coefficient port a group of four channels at a time
// while idle).
//
// Every case runs twice:
//
//   phase 0  random input valid gaps and random out_ready (30% low), both
//            from $urandom: the functional check;
//   phase 1  no input gaps, out_ready always high: the same beats again, and
//            the cycles from the start pulse to the last accepted output beat
//            are divided by the pixel count.
//
// The checker compares every output beat in order -- data and the last, eol
// and sof flags -- against out.hex, so a dropped, duplicated or reordered
// beat fails.  A mismatch prints the first ten and the run ends with
// $fatal(1, ...).
module tb_st_norm #(
    parameter int OUT_DEPTH = 16
);
    localparam int MAXB    = 1 << 20;    // beats a case may hold
    localparam int MAXCH   = 80;         // FiLM channels the port can write
    localparam int TIMEOUT = 20_000_000; // cycles a run may take

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------- the DUT
    logic         in_valid, in_ready;
    logic [39:0]  in_data;
    logic         in_last, in_eol, in_sof;
    logic         out_valid, out_ready;
    logic [39:0]  out_data;
    logic         out_last, out_eol, out_sof;
    logic         start, busy;
    logic [1:0]   cfg_mode;
    logic [4:0]   cfg_g;
    logic [17:0]  cfg_npix;
    logic         coef_we;
    logic [3:0]   coef_grp;
    logic [17:0]  coef_mul [4];
    logic [23:0]  coef_off [4];

    logic [1:0] style = '0;                 // +STYLE: the LN image

    st_norm #(.OUT_DEPTH(OUT_DEPTH)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_ready (in_ready),
        .in_data  (in_data),
        .in_last  (in_last),
        .in_eol   (in_eol),
        .in_sof   (in_sof),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_data (out_data),
        .out_last (out_last),
        .out_eol  (out_eol),
        .out_sof  (out_sof),
        .start    (start),
        .busy     (busy),
        .cfg_mode (cfg_mode),
        .cfg_g    (cfg_g),
        .cfg_npix (cfg_npix),
        .style    (style),
        .coef_we  (coef_we),
        .coef_grp (coef_grp),
        .coef_mul (coef_mul),
        .coef_off (coef_off)
    );

    // ------------------------------------------------------------ vectors
    logic [39:0] idat [MAXB];
    logic        ilst [MAXB], iel [MAXB], isf [MAXB];
    logic [39:0] odat [MAXB];
    logic        olst [MAXB], oel [MAXB], osf [MAXB];
    logic [17:0] cmul [MAXCH];
    logic [23:0] coff [MAXCH];

    int npix = 0, nin = 0, nout = 0, g_v = 0, mode_v = 0, ncoef = 0;
    string case_dir, case_name;

    initial begin
        int fd, r;
        if (!$value$plusargs("CASE_DIR=%s", case_dir))
            $fatal(1, "tb_st_norm: +CASE_DIR= is required");
        if ($value$plusargs("STYLE=%d", r)) style = 2'(r);
        // the case name is the last path component of CASE_DIR
        case_name = case_dir;
        for (int i = 0; i < case_dir.len(); i++)
            if (case_dir[i] == "/") case_name = case_dir.substr(i + 1, case_dir.len() - 1);
        fd = $fopen({case_dir, "/cfg.txt"}, "r");
        if (fd == 0) $fatal(1, "tb_st_norm: cannot open %s/cfg.txt", case_dir);
        r = $fscanf(fd, "%d %d %d\n", mode_v, g_v, npix);
        if (r != 3) $fatal(1, "tb_st_norm: bad cfg.txt header");
        $fclose(fd);
        if (npix <= 0 || g_v < 1 || g_v > 20 || (mode_v != 1 && mode_v != 2))
            $fatal(1, "tb_st_norm: bad cfg mode=%0d g=%0d npix=%0d", mode_v, g_v, npix);

        nin  = npix * g_v;
        nout = nin;
        if (nin > MAXB) $fatal(1, "tb_st_norm: vectors exceed MAXB");

        fd = $fopen({case_dir, "/in.hex"}, "r");
        if (fd == 0) $fatal(1, "tb_st_norm: cannot open %s/in.hex", case_dir);
        for (int i = 0; i < nin; i++)
            if ($fscanf(fd, "%h %d %d %d\n", idat[i], ilst[i], iel[i], isf[i]) != 4)
                $fatal(1, "tb_st_norm: in.hex ends at beat %0d of %0d", i, nin);
        $fclose(fd);

        fd = $fopen({case_dir, "/out.hex"}, "r");
        if (fd == 0) $fatal(1, "tb_st_norm: cannot open %s/out.hex", case_dir);
        for (int i = 0; i < nout; i++)
            if ($fscanf(fd, "%h %d %d %d\n", odat[i], olst[i], oel[i], osf[i]) != 4)
                $fatal(1, "tb_st_norm: out.hex ends at beat %0d of %0d", i, nout);
        $fclose(fd);

        if (mode_v == 2) begin
            fd = $fopen({case_dir, "/coef.txt"}, "r");
            if (fd == 0) $fatal(1, "tb_st_norm: cannot open %s/coef.txt", case_dir);
            for (int c = 0; c < MAXCH; c++) begin
                cmul[c] = 18'd0;
                coff[c] = 24'd0;
            end
            for (int c = 0; c < MAXCH; c++) begin
                r = $fscanf(fd, "%d %d\n", cmul[c], coff[c]);
                if (r != 2) begin
                    if (c == 0) $fatal(1, "tb_st_norm: coef.txt is empty");
                    break;
                end
                ncoef = c + 1;
            end
            $fclose(fd);
            if (ncoef != g_v * 4)
                $fatal(1, "tb_st_norm: %0d coefficients for %0d groups", ncoef, g_v);
        end

        $display("tb_st_norm: %s: mode %0d, %0d pixels x %0d groups, %0d beats",
                 case_name, mode_v, npix, g_v, nin);
    end

    // ------------------------------------------------------------- clocks
    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ------------------------------------------------------------- checker
    int  oidx = 0;              // next expected output beat, per phase
    int  errs = 0;              // mismatches over the whole run
    bit  checking = 0;
    bit  rnd_out  = 1;
    longint t_start = 0, t_end = 0;

    int  n_beat  [2];           // accepted beats per phase
    longint n_cyc [2];          // start pulse to last output beat, per phase

    // out_ready is a register, so the DUT and the checker never disagree about
    // the handshake of a cycle: both see the pre-edge value.
    always @(posedge clk) begin
        if (!rst_n) out_ready <= 1'b0;
        else        out_ready <= rnd_out ? ($urandom_range(99) >= 30) : 1'b1;
    end

    // The input side: one register tells the driver at the following negedge
    // whether the beat it presented was taken, so beats run back to back and
    // the checker's view of the handshake is the DUT's.
    bit in_taken;

    always @(posedge clk) begin
        if (!rst_n) in_taken <= 1'b0;
        else        in_taken <= in_valid && in_ready;
    end

    always @(posedge clk) begin
        if (rst_n && checking && out_valid && out_ready) begin
            if (oidx >= nout) begin
                errs++;
                if (errs <= 10)
                    $display("MISMATCH: unexpected output beat %0d (data=%010x last=%0d eol=%0d sof=%0d)",
                             oidx, out_data, out_last, out_eol, out_sof);
            end else if (out_data !== odat[oidx] || out_last !== olst[oidx]
                      || out_eol !== oel[oidx] || out_sof !== osf[oidx]) begin
                errs++;
                if (errs <= 10)
                    $display("MISMATCH beat %0d: data=%010x last=%0d eol=%0d sof=%0d, want %010x %0d %0d %0d",
                             oidx, out_data, out_last, out_eol, out_sof,
                             odat[oidx], olst[oidx], oel[oidx], osf[oidx]);
            end
            oidx++;
            if (oidx == nout) t_end = cyc;
        end
    end

    // -------------------------------------------------------------- driver
    task automatic present(input int i);
        in_valid = 1'b1;
        in_data  = idat[i];
        in_last  = ilst[i];
        in_eol   = iel[i];
        in_sof   = isf[i];
    endtask

    task automatic write_coefs();
        coef_we = 1'b1;
        for (int g = 0; g < ncoef / 4; g++) begin
            coef_grp = 4'(g);
            for (int j = 0; j < 4; j++) begin
                coef_mul[j] = cmul[4 * g + j];
                coef_off[j] = coff[4 * g + j];
            end
            @(negedge clk);
        end
        coef_we = 1'b0;
        coef_grp = 4'd0;
        for (int j = 0; j < 4; j++) begin
            coef_mul[j] = 18'd0;
            coef_off[j] = 24'd0;
        end
    endtask

    task automatic pulse_start();
        @(negedge clk);
        cfg_mode = 2'(mode_v);
        cfg_g    = 5'(g_v);
        cfg_npix = 18'(npix);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    endtask

    task automatic drive_all(input bit gaps);
        int i = 1;
        in_valid = 1'b0;
        @(negedge clk);
        present(0);
        while (i < nin) begin
            @(negedge clk);
            if (in_taken) begin
                if (gaps && (i % 4096 == 2048)) begin
                    // now and then a stall longer than any pipeline: the
                    // stage must not take it for the end of the pass
                    in_valid = 1'b0;
                    repeat (300) @(negedge clk);
                end else if (gaps && ($urandom_range(99) < 30)) begin
                    in_valid = 1'b0;
                    repeat ($urandom_range(1, 3)) @(negedge clk);
                end
                present(i);
                i++;
            end
        end
        do @(negedge clk); while (!in_taken);     // the last beat
        in_valid = 1'b0;
        in_data  = '0;
        in_last  = 1'b0;
        in_eol   = 1'b0;
        in_sof   = 1'b0;
    endtask

    // ------------------------------------------------------------------ run
    int ph;

    initial begin
        in_valid = 1'b0;
        in_data  = '0;
        in_last  = 1'b0;
        in_eol   = 1'b0;
        in_sof   = 1'b0;
        start    = 1'b0;
        cfg_mode = 2'd1;
        cfg_g    = 5'd20;
        cfg_npix = 18'd0;
        coef_we  = 1'b0;
        coef_grp = 4'd0;
        for (int j = 0; j < 4; j++) begin
            coef_mul[j] = 18'd0;
            coef_off[j] = 24'd0;
        end

        repeat (3) @(posedge clk);
        rst_n = 1;
        @(negedge clk);

        for (ph = 0; ph < 2; ph++) begin
            while (busy) @(negedge clk);
            checking = 1'b0;
            rnd_out  = (ph == 0);
            oidx     = 0;
            @(negedge clk);
            if (mode_v == 2) write_coefs();
            pulse_start();
            t_start = cyc;
            checking = 1'b1;
            drive_all(ph == 0);
            // the stage ends a pass after cfg_npix pixels and a drained pipeline
            while (busy) @(negedge clk);
            repeat (4) @(negedge clk);
            checking = 1'b0;
            n_beat[ph] = oidx;
            n_cyc[ph]  = t_end - t_start;
            if (oidx != nout)
                $fatal(1, "tb_st_norm FAIL %s phase %0d: %0d of %0d output beats",
                       case_name, ph, oidx, nout);
        end

        if (errs != 0 || n_beat[0] != nout || n_beat[1] != nout)
            $fatal(1, "tb_st_norm FAIL %s: %0d errors, %0d + %0d of %0d beats",
                   case_name, errs, n_beat[0], n_beat[1], nout);
        $display("tb_st_norm %s: %0.2f cycles/pixel", case_name,
                 real'(n_cyc[1]) / real'(npix));
        $display("tb_st_norm %s PASS %0d beats, %0d cycles",
                 case_name, n_beat[1], n_cyc[1]);
        $finish;
    end

    // A case that never drains must not hang the run.
    initial begin
        #1;
        #(TIMEOUT * 10);
        $fatal(1, "tb_st_norm FAIL %s: timeout", case_name);
    end

endmodule
