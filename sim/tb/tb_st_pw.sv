// tb_st_pw.sv -- the PW stage against tools/st_pw_vectors.py.
//
// CASE_DIR (plusarg) holds cfg.txt, in.hex (the input beats to drive),
// out.hex (the expected output beats) and, for every case, pw.hex / rq.hex
// (the case's own weight and requant ROM images, loaded over the ROMs'
// instances).  Every case runs twice:
//
//   phase 0  random input valid gaps and random out_ready (30% low), both
//            from $urandom: the functional check;
//   phase 1  no input gaps, out_ready always high: the same beats again, and
//            the cycles from the start pulse to the last accepted output beat
//            are divided by the pixel count (the clean cycles per pixel).
//
// cfg.txt is "<npix> <nin> <nout> <nlay> <wide>" followed by one
// "<cin> <cout> <pw_base> <rq_base> <lo> <hi>" line per layer.  A wide case
// (wide = 1) drives in_wide[127:0], 16 int8 values per beat; a narrow case
// drives in_data, four 10-bit lanes.  in.hex lines are
// "<128-bit hex> <last> <eol> <sof>"; out.hex lines are
// "<40-bit hex> <last> <eol> <sof>".
//
// The checker compares every output beat in order -- data and the last, eol
// and sof flags -- against out.hex, so a dropped, duplicated or reordered
// beat fails.  A mismatch prints the first ten and the run ends with
// $fatal(1, ...).
module tb_st_pw #(
    parameter int TILE_DEPTH = 8,
    parameter int OUT_DEPTH  = 64,
    parameter int PW_DEPTH   = 256,
    parameter int RQ_DEPTH   = 512
);
    localparam int MAXB    = 1 << 19;    // beats a case may hold
    localparam int TIMEOUT = 20_000_000; // cycles a run may take

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------- the DUT
    logic         in_valid, in_ready;
    logic [39:0]  in_data;
    logic [127:0] in_wide;
    logic         in_last, in_eol, in_sof;
    logic         out_valid, out_ready;
    logic [39:0]  out_data;
    logic         out_last, out_eol, out_sof;
    logic         start, busy;
    logic [17:0]  cfg_npix;
    logic         cfg_wide;
    logic [1:0]   cfg_n;
    logic [6:0]   cfg_cin0, cfg_cin1, cfg_cout0, cfg_cout1;
    logic [9:0]   cfg_pw_base0, cfg_pw_base1;
    logic [10:0]  cfg_rq_base0, cfg_rq_base1;
    logic signed [9:0] cfg_lo0, cfg_lo1, cfg_hi0, cfg_hi1;

    st_pw #(.TILE_DEPTH(TILE_DEPTH), .OUT_DEPTH(OUT_DEPTH),
            .PW_DEPTH(PW_DEPTH), .RQ_DEPTH(RQ_DEPTH)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_valid     (in_valid),
        .in_ready     (in_ready),
        .in_data      (in_data),
        .in_wide      (in_wide),
        .in_last      (in_last),
        .in_eol       (in_eol),
        .in_sof       (in_sof),
        .out_valid    (out_valid),
        .out_ready    (out_ready),
        .out_data     (out_data),
        .out_last     (out_last),
        .out_eol      (out_eol),
        .out_sof      (out_sof),
        .start        (start),
        .busy         (busy),
        .cfg_npix     (cfg_npix),
        .cfg_wide     (cfg_wide),
        .cfg_n         (cfg_n),
        .cfg_cin0     (cfg_cin0),
        .cfg_cin1     (cfg_cin1),
        .cfg_cout0    (cfg_cout0),
        .cfg_cout1    (cfg_cout1),
        .cfg_pw_base0 (cfg_pw_base0),
        .cfg_pw_base1 (cfg_pw_base1),
        .cfg_rq_base0 (cfg_rq_base0),
        .cfg_rq_base1 (cfg_rq_base1),
        .cfg_lo0      (cfg_lo0),
        .cfg_lo1      (cfg_lo1),
        .cfg_hi0      (cfg_hi0),
        .cfg_hi1      (cfg_hi1)
    );

    // ------------------------------------------------------------ vectors
    logic [127:0] idat [MAXB];
    logic         ilst [MAXB], iel [MAXB], isf [MAXB];
    logic [39:0]  odat [MAXB];
    logic         olst [MAXB], oel [MAXB], osf [MAXB];

    int npix = 0, nin = 0, nout = 0, nlay = 1, wide = 0;
    int cin_v [2], cout_v [2], pw_v [2], rq_v [2];
    int lo_v [2], hi_v [2];
    string case_dir, case_name;

    initial begin
        int fd, r;
        if (!$value$plusargs("CASE_DIR=%s", case_dir))
            $fatal(1, "tb_st_pw: +CASE_DIR= is required");
        // the case name is the last path component of CASE_DIR
        case_name = case_dir;
        for (int i = 0; i < case_dir.len(); i++)
            if (case_dir[i] == "/") case_name = case_dir.substr(i + 1, case_dir.len() - 1);
        fd = $fopen({case_dir, "/cfg.txt"}, "r");
        if (fd == 0) $fatal(1, "tb_st_pw: cannot open %s/cfg.txt", case_dir);
        r = $fscanf(fd, "%d %d %d %d %d\n", npix, nin, nout, nlay, wide);
        if (r != 5) $fatal(1, "tb_st_pw: bad cfg.txt header");
        for (int k = 0; k < 2; k++) begin
            r = $fscanf(fd, "%d %d %d %d %d %d\n", cin_v[k], cout_v[k], pw_v[k],
                        rq_v[k], lo_v[k], hi_v[k]);
            if (r != 6) $fatal(1, "tb_st_pw: bad cfg.txt layer %0d", k);
        end
        $fclose(fd);
        if (npix <= 0 || nin <= 0 || nout <= 0 || nlay < 1 || nlay > 2)
            $fatal(1, "tb_st_pw: bad cfg %0d %0d %0d %0d", npix, nin, nout, nlay);
        if (nin > MAXB || nout > MAXB) $fatal(1, "tb_st_pw: vectors exceed MAXB");

        fd = $fopen({case_dir, "/in.hex"}, "r");
        if (fd == 0) $fatal(1, "tb_st_pw: cannot open %s/in.hex", case_dir);
        for (int i = 0; i < nin; i++)
            if ($fscanf(fd, "%h %d %d %d\n", idat[i], ilst[i], iel[i], isf[i]) != 4)
                $fatal(1, "tb_st_pw: in.hex ends at beat %0d of %0d", i, nin);
        $fclose(fd);

        fd = $fopen({case_dir, "/out.hex"}, "r");
        if (fd == 0) $fatal(1, "tb_st_pw: cannot open %s/out.hex", case_dir);
        for (int i = 0; i < nout; i++)
            if ($fscanf(fd, "%h %d %d %d\n", odat[i], olst[i], oel[i], osf[i]) != 4)
                $fatal(1, "tb_st_pw: out.hex ends at beat %0d of %0d", i, nout);
        $fclose(fd);

        // Per-case ROM images.  The ROMs' own initial blocks run at time 0
        // after this one, so the load has to happen after them: #1 puts it in
        // the same slot as the reset sequence (tb_st_dw does the same).
        // Both files are required: the case's weights are its own, and a
        // stale image would only show up as a data mismatch.
        #1;
        fd = $fopen({case_dir, "/pw.hex"}, "r");
        if (fd == 0) $fatal(1, "tb_st_pw: cannot open %s/pw.hex", case_dir);
        $fclose(fd);
        dut.u_pw_rom.load({case_dir, "/pw.hex"});
        fd = $fopen({case_dir, "/rq.hex"}, "r");
        if (fd == 0) $fatal(1, "tb_st_pw: cannot open %s/rq.hex", case_dir);
        $fclose(fd);
        dut.u_rq_rom.load({case_dir, "/rq.hex"});

        $display("tb_st_pw: %s: %0d pixels, %0d in beats, %0d out beats, %0d layer(s), %s",
                 case_name, npix, nin, nout, nlay, wide ? "wide" : "narrow");
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
        in_data  = 40'(idat[i]);
        in_wide  = idat[i];
        in_last  = ilst[i];
        in_eol   = iel[i];
        in_sof   = isf[i];
    endtask

    task automatic idle_in();
        in_valid = 1'b0;
        in_data  = '0;
        in_wide  = '0;
        in_last  = 1'b0;
        in_eol   = 1'b0;
        in_sof   = 1'b0;
    endtask

    task automatic pulse_start();
        @(negedge clk);
        cfg_n        = 2'(nlay);
        cfg_wide     = (wide != 0);
        cfg_cin0     = 7'(cin_v[0]);
        cfg_cin1     = 7'(cin_v[1]);
        cfg_cout0    = 7'(cout_v[0]);
        cfg_cout1    = 7'(cout_v[1]);
        cfg_pw_base0 = 10'(pw_v[0]);
        cfg_pw_base1 = 10'(pw_v[1]);
        cfg_rq_base0 = 11'(rq_v[0]);
        cfg_rq_base1 = 11'(rq_v[1]);
        cfg_lo0      = 10'(lo_v[0]);
        cfg_hi0      = 10'(hi_v[0]);
        cfg_lo1      = 10'(lo_v[1]);
        cfg_hi1      = 10'(hi_v[1]);
        cfg_npix     = 18'(npix);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    endtask

    task automatic drive_all(input bit gaps);
        int i = 1;
        idle_in();
        @(negedge clk);
        present(0);
        while (i < nin) begin
            @(negedge clk);
            if (in_taken) begin
                if (gaps && (i % 4096 == 2048)) begin
                    // now and then a stall longer than any pipeline: the
                    // stage must not take it for the end of the pass
                    idle_in();
                    repeat (300) @(negedge clk);
                end else if (gaps && ($urandom_range(99) < 30)) begin
                    idle_in();
                    repeat ($urandom_range(1, 3)) @(negedge clk);
                end
                present(i);
                i++;
            end
        end
        do @(negedge clk); while (!in_taken);     // the last beat
        idle_in();
    endtask

    // ------------------------------------------------------------------ run
    int ph;

    initial begin
        idle_in();
        start    = 1'b0;
        cfg_npix = 18'd0;
        cfg_wide = 1'b0;
        cfg_n = 2'd1;
        cfg_cin0 = 7'd1; cfg_cin1 = 7'd1;
        cfg_cout0 = 7'd1; cfg_cout1 = 7'd1;
        cfg_pw_base0 = 10'd0; cfg_pw_base1 = 10'd0;
        cfg_rq_base0 = 11'd0; cfg_rq_base1 = 11'd0;
        cfg_lo0 = 10'sd0; cfg_hi0 = 10'sd127;
        cfg_lo1 = 10'sd0; cfg_hi1 = 10'sd127;

        repeat (3) @(posedge clk);
        rst_n = 1;
        @(negedge clk);

        for (ph = 0; ph < 2; ph++) begin
            while (busy) @(negedge clk);
            checking = 1'b0;
            rnd_out  = (ph == 0);
            oidx     = 0;
            @(negedge clk);
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
                $fatal(1, "tb_st_pw FAIL %s phase %0d: %0d of %0d output beats",
                       case_name, ph, oidx, nout);
        end

        if (errs != 0 || n_beat[0] != nout || n_beat[1] != nout)
            $fatal(1, "tb_st_pw FAIL %s: %0d errors, %0d + %0d of %0d beats",
                   case_name, errs, n_beat[0], n_beat[1], nout);
        $display("tb_st_pw %s: %0.3f clean cycles/pixel", case_name,
                 real'(n_cyc[1]) / real'(npix));
        $display("tb_st_pw %s PASS %0d beats, %0d cycles",
                 case_name, n_beat[1], n_cyc[1]);
        $finish;
    end

    // A case that never drains must not hang the run.
    initial begin
        #1;
        #(TIMEOUT * 10);
        $fatal(1, "tb_st_pw FAIL %s: timeout", case_name);
    end

endmodule
