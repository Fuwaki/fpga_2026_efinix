// tb_st_prepost.sv -- st_pre (FULL / POOL) and st_post against
// tools/st_prepost_vectors.py.
//
// One build, three cases selected with +CASE=<name> (the Makefile runs each
// twice: once with random input gaps and output back-pressure, once clean):
//
//   pre_full  ISP slot RGB565 beats in (160 per line, 720 lines) -> the p0
//             group stream out (640x360 pixels, one beat each).
//   pre_pool  the same input -> the pooled group stream out (320x180).
//   post      the network's head output as group beats (640x360 pixels) ->
//             the whole PROC slot out (160 beats per line, 720 lines, every
//             pixel 2x2).
//   post43    the same input through st_post's other replication,
//             REP_X = 4 / REP_Y = 3 (2560x1080 out, two beats per 64-bit
//             buffer word), which the tiny_dw engine used at W = 320.
//
// The driver offers the input beats with random valid gaps, the checker
// applies random back-pressure (ready low RDY_PCT of the time) and compares
// every output beat and its flags, in order, against the expected file.  The
// first ten mismatches are printed; a mismatch, a missing or extra beat, a
// wrong framing flag, a framing error reported by the DUT or the wrong busy
// behaviour ends in $fatal(1, ...).
//
//   +VEC=<dir>    vector directory (default sim/obj/tb_st_prepost), holding
//                 <case>/in.hex and <case>/exp.hex
//   +CASE=<name>  pre_full (default), pre_pool or post
//   +CLEAN=1      no input gaps, out_ready always high
//
// Output: "tb_st_prepost <case> PASS <n> beats, <cycles> cycles[ (clean)]".
module tb_st_prepost #(
    parameter int MAXB    = 1 << 19,    // beats a file may hold
    parameter int GAP_PCT = 30,         // input valid gaps
    parameter int RDY_PCT = 30,         // output ready low
    parameter int TAIL    = 4096        // cycles to settle before the verdict
);
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------- case
    localparam int C_PRE_FULL = 0, C_PRE_POOL = 1, C_POST = 2, C_POST43 = 3;
    int  csel = C_PRE_FULL;
    bit  is_post;
    bit  clean;
    string case_name;

    // --------------------------------------------------------------- DUT IO
    logic          in_valid = 1'b0, in_ready;
    logic [127:0]  in_data  = '0;
    logic [2:0]    in_fl    = '0;       // {last, sof, eol}
    logic          out_ready = 1'b0;
    logic          start = 1'b0;

    // st_pre
    logic          pre_ready, pre_v, pre_l, pre_e, pre_s, pre_busy, pre_err;
    logic [39:0]   pre_d;
    // st_post, both replications (parameters are elaboration-time)
    logic          po_ready, po_v, po_s, po_e, po_busy, po_err;
    logic [127:0]  po_d;
    logic          q3_ready, q3_v, q3_s, q3_e, q3_busy, q3_err;
    logic [127:0]  q3_d;

    st_pre u_pre (
        .clk(clk), .rst_n(rst_n),
        .start(start), .cfg_pool(csel == C_PRE_POOL), .busy(pre_busy), .err(pre_err),
        .in_valid(in_valid && !is_post), .in_ready(pre_ready), .in_data(in_data),
        .in_sof(in_fl[1]), .in_eol(in_fl[0]),
        .out_valid(pre_v), .out_ready(out_ready), .out_data(pre_d),
        .out_last(pre_l), .out_eol(pre_e), .out_sof(pre_s));

    st_post u_post (                       // the guided net: 2x2
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid && (csel == C_POST)), .in_ready(po_ready),
        .in_data(in_data[39:0]),
        .in_last(in_fl[2]), .in_sof(in_fl[1]), .in_eol(in_fl[0]),
        .out_valid(po_v), .out_ready(out_ready), .out_data(po_d),
        .out_sof(po_s), .out_eol(po_e),
        .start(start), .busy(po_busy), .err(po_err));

    st_post #(.W(640), .H(360), .REP_X(4), .REP_Y(3)) u_post43 (   // tiny_dw's
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid && (csel == C_POST43)), .in_ready(q3_ready),
        .in_data(in_data[39:0]),
        .in_last(in_fl[2]), .in_sof(in_fl[1]), .in_eol(in_fl[0]),
        .out_valid(q3_v), .out_ready(out_ready), .out_data(q3_d),
        .out_sof(q3_s), .out_eol(q3_e),
        .start(start), .busy(q3_busy), .err(q3_err));

    wire sel43 = (csel == C_POST43);

    assign in_ready = sel43 ? q3_ready : is_post ? po_ready : pre_ready;

    wire [127:0] act_data = sel43 ? q3_d : is_post ? po_d : 128'(pre_d);
    wire         act_v    = sel43 ? q3_v : is_post ? po_v : pre_v;
    wire         act_sof  = sel43 ? q3_s : is_post ? po_s : pre_s;
    wire         act_eol  = sel43 ? q3_e : is_post ? po_e : pre_e;
    wire         act_last = (is_post || sel43) ? 1'b1 : pre_l;
    wire         act_busy = sel43 ? q3_busy : is_post ? po_busy : pre_busy;
    wire         act_err  = sel43 ? q3_err : is_post ? po_err : pre_err;

    // ------------------------------------------------------------- vectors
    logic [127:0] vin  [MAXB];
    logic [2:0]   vif  [MAXB];          // input flags {last, sof, eol}
    logic [127:0] vout [MAXB];
    logic [2:0]   vfl  [MAXB];          // expected flags {last, sof, eol}
    int n_in, n_out;

    // $fscanf needs plain variables, not part-selects.
    task automatic load_in(input string path, input bit three_flags);
        int fd, nr;
        logic [127:0] d;
        logic         f2, f1, f0;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "tb_st_prepost: cannot open %s", path);
        n_in = 0;
        forever begin
            if (three_flags) nr = $fscanf(fd, "%h %h %h %h\n", d, f2, f1, f0);
            else             nr = $fscanf(fd, "%h %h %h\n", d, f1, f0);
            if (nr != (three_flags ? 4 : 3)) break;
            if (n_in >= MAXB)
                $fatal(1, "tb_st_prepost: %s is longer than %0d beats", path, MAXB);
            vin[n_in] = d;
            vif[n_in] = three_flags ? {f2, f1, f0} : {1'b1, f1, f0};
            n_in++;
        end
        $fclose(fd);
        if (n_in == 0) $fatal(1, "tb_st_prepost: no beats in %s", path);
    endtask

    task automatic load_out(input string path, input bit three_flags);
        int fd, nr;
        logic [127:0] d;
        logic         f2, f1, f0;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "tb_st_prepost: cannot open %s", path);
        n_out = 0;
        forever begin
            if (three_flags) nr = $fscanf(fd, "%h %h %h %h\n", d, f2, f1, f0);
            else             nr = $fscanf(fd, "%h %h %h\n", d, f1, f0);
            if (nr != (three_flags ? 4 : 3)) break;
            if (n_out >= MAXB)
                $fatal(1, "tb_st_prepost: %s is longer than %0d beats", path, MAXB);
            vout[n_out] = d;
            vfl[n_out]  = three_flags ? {f2, f1, f0} : {1'b1, f1, f0};
            n_out++;
        end
        $fclose(fd);
        if (n_out == 0) $fatal(1, "tb_st_prepost: no beats in %s", path);
    endtask

    // ---------------------------------------------------------------- run
    int  cyc;               // posedges since reset release
    int  out_idx;           // next expected output beat
    int  errs;              // mismatches (data, flags, extra beats)
    int  pend;              // next input beat to present
    int  gap;               // valid gaps left before that beat
    bit  go;                // the frame is running
    bit  busy_seen;         // busy went high after start

    initial begin
        cyc  = 0;
        out_idx = 0;
        errs = 0;
        go   = 0;
        n_in = 0;
        n_out = 0;
        busy_seen = 0;
    end

    always @(posedge clk) if (rst_n) cyc <= cyc + 1;

    // Input driver: present one beat, hold it until accepted, then a random
    // gap before the next.  In the clean run the next beat follows on the very
    // next cycle, so the cycle count is the DUT's own.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_valid <= 1'b0;
            in_data  <= '0;
            in_fl    <= '0;
            pend     <= 0;
            gap      <= 0;
        end else if (!go) begin
            in_valid <= 1'b0;
        end else if (in_valid && in_ready) begin
            pend <= pend + 1;
            if (clean) begin
                in_valid <= 1'b1;
                if (pend + 1 < n_in) begin
                    in_data <= vin[pend + 1];
                    in_fl   <= vif[pend + 1];
                end else begin
                    in_valid <= 1'b0;      // that was the last beat
                end
            end else begin
                in_valid <= 1'b0;
                gap      <= ($urandom_range(99) < GAP_PCT)
                            ? $urandom_range(1, 5) : 0;
            end
        end else if (!in_valid) begin
            if (gap != 0) begin
                gap <= gap - 1;
            end else if (pend < n_in) begin
                in_valid <= 1'b1;
                in_data  <= vin[pend];
                in_fl    <= vif[pend];
            end
        end
    end

    // Output back-pressure.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_ready <= 1'b0;
        else        out_ready <= clean || !($urandom_range(99) < RDY_PCT);
    end

    // Checker: every output beat and its flags, in order; busy high until the
    // last one has been accepted.
    always @(posedge clk) begin
        if (rst_n) begin
            if (act_busy) busy_seen = 1;
            if (act_v && out_ready) begin
                if (out_idx >= n_out) begin
                    errs++;
                    if (errs <= 10)
                        $display("MISMATCH: extra beat %0d (%032h sof=%0b eol=%0b)",
                                 out_idx, act_data, act_sof, act_eol);
                end else if (act_data !== vout[out_idx] ||
                             {act_last, act_sof, act_eol} !== vfl[out_idx]) begin
                    errs++;
                    if (errs <= 10)
                        $display("MISMATCH beat %0d: got %032h last=%0b sof=%0b eol=%0b, want %032h last=%0b sof=%0b eol=%0b",
                                 out_idx, act_data, act_last, act_sof, act_eol,
                                 vout[out_idx], vfl[out_idx][2], vfl[out_idx][1],
                                 vfl[out_idx][0]);
                end
                out_idx++;
            end
            if (busy_seen && !act_busy && go && out_idx < n_out) begin
                errs++;
                if (errs <= 10)
                    $display("MISMATCH: busy fell after %0d of %0d beats", out_idx, n_out);
            end
        end
    end

    // ------------------------------------------------------------- control
    initial begin
        string dir, fin, fexp;
        bit got;

        if (!$value$plusargs("VEC=%s", dir)) dir = "sim/obj/tb_st_prepost";
        if (!$value$plusargs("CASE=%s", case_name)) case_name = "pre_full";
        clean = 0;
        if ($value$plusargs("CLEAN=%d", got)) clean = got;

        if (case_name == "post")          csel = C_POST;
        else if (case_name == "post43")   csel = C_POST43;
        else if (case_name == "pre_pool") csel = C_PRE_POOL;
        else if (case_name == "pre_full") csel = C_PRE_FULL;
        else $fatal(1, "tb_st_prepost: unknown case '%s'", case_name);
        is_post = (csel == C_POST || csel == C_POST43);

        fin  = $sformatf("%s/%s/in.hex",  dir, case_name);
        fexp = $sformatf("%s/%s/exp.hex", dir, case_name);

        load_in(fin, is_post);          // post input carries last, sof, eol
        load_out(fexp, !is_post);       // a group stream carries last as well
        $display("tb_st_prepost %s: %0d input beats, %0d expected beats (%s)%s",
                 case_name, n_in, n_out, dir, clean ? " clean" : "");

        repeat (4) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        if (act_busy) $fatal(1, "tb_st_prepost: busy before start");
        start <= 1'b1;
        go    <= 1'b1;
        @(negedge clk);
        start <= 1'b0;

        // The frame, with room for input gaps and output stalls.
        while (out_idx < n_out && cyc < 40 * n_out + 10 * n_in + 100_000) @(posedge clk);
        repeat (TAIL) @(posedge clk);

        if (out_idx != n_out)
            $fatal(1, "tb_st_prepost FAIL %s: %0d of %0d beats, %0d errors, %0d cycles",
                   case_name, out_idx, n_out, errs, cyc);
        if (errs != 0)
            $fatal(1, "tb_st_prepost FAIL %s: %0d mismatches in %0d beats, %0d cycles",
                   case_name, errs, n_out, cyc);
        if (act_err)
            $fatal(1, "tb_st_prepost FAIL %s: framing error (err is set)", case_name);
        if (!busy_seen || act_busy)
            $fatal(1, "tb_st_prepost FAIL %s: busy never rose or never fell", case_name);
        $display("tb_st_prepost %s PASS %0d beats, %0d cycles%s",
                 case_name, n_out, cyc, clean ? " (clean)" : "");
        $finish;
    end
endmodule
