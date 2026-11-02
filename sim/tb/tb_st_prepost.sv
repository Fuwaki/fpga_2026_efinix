// tb_st_prepost.sv -- st_pre and st_post against tools/st_prepost_vectors.py.
//
// One testbench, two cases, selected by the CASE_POST parameter (the Makefile
// target builds and runs both):
//
//   pre   ISP crop RGB565 beats in (120 per line) -> p0 out (one beat per
//         pixel, 320 beats per line, 240 lines).
//   post  head output group beats in (320x240 pixels) -> the PROC slot right
//         half out (80 beats per line, 720 lines).
//
// The driver offers the input beats with random valid gaps, the checker
// applies random back-pressure (ready low RDY_PCT of the time) and compares
// every output beat and its flags, in order, against the expected file.  The
// first ten mismatches are printed; a mismatch, a missing or extra beat, a
// wrong framing flag or the wrong busy behaviour ends in $fatal(1, ...).
//
//   +VEC=<dir>   vector directory (default sim/obj/tb_st_prepost), holding
//                pre_in.hex pre_exp.hex post_in.hex post_exp.hex
module tb_st_prepost #(
    parameter bit CASE_POST = 0,        // 0: pre, 1: post
    parameter int MAXB      = 1 << 17,  // beats a file may hold
    parameter int GAP_PCT   = 30,       // input valid gaps
    parameter int RDY_PCT   = 30,       // output ready low
    parameter int TAIL      = 4096      // cycles to settle before the verdict
);
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    localparam bit  POST = CASE_POST;
    localparam int  DW   = CASE_POST ? 40 : 128;
    localparam int  NF3  = 3;           // flags carried by an input beat

    // --------------------------------------------------------------- DUT IO
    logic           in_valid = 1'b0, in_ready;
    logic [DW-1:0]  in_data  = '0;
    logic [NF3-1:0] in_fl    = '0;      // pre {-, sof, eol}, post {last, sof, eol}
    wire            in_last  = in_fl[2];
    wire            in_sof   = in_fl[1];
    wire            in_eol   = in_fl[0];

    logic           out_valid, out_ready = 1'b0;
    logic [127:0]   out_data;
    logic           out_sof, out_eol;
    logic           start = 1'b0, busy, err;

    generate
        if (CASE_POST) begin : g_post
            st_post dut (
                .clk(clk), .rst_n(rst_n),
                .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
                .in_last(in_last), .in_sof(in_sof), .in_eol(in_eol),
                .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
                .out_sof(out_sof), .out_eol(out_eol),
                .start(start), .busy(busy), .err(err));
        end else begin : g_pre
            st_pre dut (
                .clk(clk), .rst_n(rst_n),
                .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
                .in_sof(in_sof), .in_eol(in_eol),
                .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
                .out_sof(out_sof), .out_eol(out_eol),
                .start(start), .busy(busy), .err(err));
        end
    endgenerate

    // ------------------------------------------------------------- vectors
    logic [DW-1:0]  vin  [MAXB];
    logic [NF3-1:0] vfl  [MAXB];
    logic [127:0]   vout [MAXB];
    logic [1:0]     vof  [MAXB];        // {sof, eol}
    int n_in, n_out;

    // $fscanf needs plain variables, not part-selects.
    task automatic load_in(input string path);
        int fd, nr;
        logic [DW-1:0] d;
        logic          f2, f1, f0;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "tb_st_prepost: cannot open %s", path);
        forever begin
            if (POST) nr = $fscanf(fd, "%h %h %h %h\n", d, f2, f1, f0);
            else      nr = $fscanf(fd, "%h %h %h\n", d, f1, f0);
            if (nr != (POST ? 4 : 3)) break;
            if (n_in >= MAXB) $fatal(1, "tb_st_prepost: %s is longer than %0d beats", path, MAXB);
            vin[n_in] = d;
            vfl[n_in] = POST ? {f2, f1, f0} : {1'b1, f1, f0};
            n_in++;
        end
        $fclose(fd);
        if (n_in == 0) $fatal(1, "tb_st_prepost: no beats in %s", path);
    endtask

    task automatic load_out(input string path);
        int fd;
        logic [127:0] d;
        logic         s, e;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "tb_st_prepost: cannot open %s", path);
        while ($fscanf(fd, "%h %h %h\n", d, s, e) == 3) begin
            if (n_out >= MAXB) $fatal(1, "tb_st_prepost: %s is longer than %0d beats", path, MAXB);
            vout[n_out] = d;
            vof[n_out]  = {s, e};
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

    always @(posedge clk) cyc <= cyc + 1;

    // Input driver: present one beat, hold it until accepted, then a random
    // gap before the next.
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
            in_valid <= 1'b0;
            pend     <= pend + 1;
            gap      <= ($urandom_range(99) < GAP_PCT) ? $urandom_range(1, 5) : 0;
        end else if (!in_valid) begin
            if (gap != 0) begin
                gap <= gap - 1;
            end else if (pend < n_in) begin
                in_valid <= 1'b1;
                in_data  <= vin[pend];
                in_fl    <= vfl[pend];
            end
        end
    end

    // Output back-pressure.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_ready <= 1'b0;
        else        out_ready <= !($urandom_range(99) < RDY_PCT);
    end

    // Checker: every output beat and its flags, in order; busy high until the
    // last one has been accepted.
    always @(posedge clk) begin
        if (rst_n) begin
            if (busy) busy_seen = 1;
            if (out_valid && out_ready) begin
                if (out_idx >= n_out) begin
                    errs++;
                    if (errs <= 10)
                        $display("MISMATCH: extra beat %0d (%032h sof=%0b eol=%0b)",
                                 out_idx, out_data, out_sof, out_eol);
                end else if (out_data !== vout[out_idx] ||
                             {out_sof, out_eol} !== vof[out_idx]) begin
                    errs++;
                    if (errs <= 10)
                        $display("MISMATCH beat %0d: got %032h sof=%0b eol=%0b, want %032h sof=%0b eol=%0b",
                                 out_idx, out_data, out_sof, out_eol,
                                 vout[out_idx], vof[out_idx][1], vof[out_idx][0]);
                end
                out_idx++;
            end
            if (busy_seen && !busy && go && out_idx < n_out) begin
                errs++;
                if (errs <= 10)
                    $display("MISMATCH: busy fell after %0d of %0d beats", out_idx, n_out);
            end
        end
    end

    // ------------------------------------------------------------- control
    initial begin
        string dir, fin, fexp;

        if (!$value$plusargs("VEC=%s", dir)) dir = "sim/obj/tb_st_prepost";
        // Two literals rather than a ternary: Verilator pads a short string
        // operand of %s to the width of the wider branch.
        if (POST) begin
            fin  = $sformatf("%s/post_in.hex",  dir);
            fexp = $sformatf("%s/post_exp.hex", dir);
        end else begin
            fin  = $sformatf("%s/pre_in.hex",  dir);
            fexp = $sformatf("%s/pre_exp.hex", dir);
        end
        load_in(fin);
        load_out(fexp);
        if (POST) $display("tb_st_prepost post: %0d input beats, %0d expected beats (%s)",
                           n_in, n_out, dir);
        else      $display("tb_st_prepost pre: %0d input beats, %0d expected beats (%s)",
                           n_in, n_out, dir);

        repeat (4) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        if (busy) $fatal(1, "tb_st_prepost: busy before start");
        start <= 1'b1;
        go    <= 1'b1;
        @(negedge clk);
        start <= 1'b0;

        // The frame, with room for pipeline stalls at the output.
        while (out_idx < n_out && cyc < 400 * n_out + 100_000) @(posedge clk);
        repeat (TAIL) @(posedge clk);

        if (out_idx != n_out)
            $fatal(1, "tb_st_prepost FAIL: %0d of %0d beats, %0d errors, %0d cycles",
                   out_idx, n_out, errs, cyc);
        if (errs != 0)
            $fatal(1, "tb_st_prepost FAIL: %0d mismatches in %0d beats, %0d cycles",
                   errs, n_out, cyc);
        if (err)
            $fatal(1, "tb_st_prepost FAIL: input framing mismatch (err is set)");
        if (!busy_seen || busy)
            $fatal(1, "tb_st_prepost FAIL: busy never rose or never fell");
        if (POST) $display("tb_st_prepost post PASS %0d beats, %0d cycles", n_out, cyc);
        else      $display("tb_st_prepost pre PASS %0d beats, %0d cycles", n_out, cyc);
        $finish;
    end
endmodule
