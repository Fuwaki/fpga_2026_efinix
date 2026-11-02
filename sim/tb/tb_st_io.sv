// tb_st_io.sv -- st_unpack (+MODE=0) or st_pack (+MODE=1) against
// tools/st_io_vectors.py: real golden activations, DDR beats from
// st_golden.ddr_image.  +DIR holds in.hex / out.hex; geometry comes as
// plusargs.  Random input gaps and output back-pressure; the case runs twice
// back to back to cover the restart.
module tb_st_io;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    int mode, c, elem2, pb, w, h, hrep;
    string dir;

    // stimulus / expected, as wide words: {data, flags}
    logic [130:0] vin  [$];
    logic [130:0] vout [$];

    function automatic void load(input string path, input bit ddr, ref logic [130:0] q [$]);
        int fd, a, b, d;
        logic [127:0] v;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "tb_st_io: cannot open %s", path);
        if (ddr)
            while ($fscanf(fd, "%h %d %d\n", v, a, b) == 3) q.push_back({v, 1'b0, 1'(a), 1'(b)});
        else
            while ($fscanf(fd, "%h %d %d %d\n", v, a, b, d) == 4) q.push_back({v, 1'(a), 1'(b), 1'(d)});
        $fclose(fd);
    endfunction

    logic         start = 0;
    logic         i_valid = 0, o_ready = 0;
    logic [130:0] cur;
    logic         u_busy, p_busy, u_in_ready, p_in_ready;
    logic         u_ov, p_ov;
    logic [39:0]  u_od;
    logic         u_last, u_eol, u_sof;
    logic [127:0] p_od;
    logic         p_sof, p_eol;

    st_unpack u_unpack (
        .clk(clk), .rst_n(rst_n), .start(start && mode == 0),
        .cfg_c(7'(c)), .cfg_elem2(1'(elem2)), .cfg_pb(8'(pb)), .cfg_w(10'(w)),
        .cfg_h(10'(h)), .cfg_hrep(1'(hrep)), .busy(u_busy),
        .in_valid(i_valid && mode == 0), .in_ready(u_in_ready),
        .in_data(cur[130:3]), .in_sof(cur[1]), .in_eol(cur[0]),
        .out_valid(u_ov), .out_ready(o_ready), .out_data(u_od),
        .out_last(u_last), .out_eol(u_eol), .out_sof(u_sof));

    st_pack u_pack (
        .clk(clk), .rst_n(rst_n), .start(start && mode == 1),
        .cfg_c(7'(c)), .cfg_elem2(1'(elem2)), .cfg_h(10'(h)), .busy(p_busy),
        .in_valid(i_valid && mode == 1), .in_ready(p_in_ready),
        .in_data(cur[42:3]), .in_last(cur[2]), .in_eol(cur[1]), .in_sof(cur[0]),
        .out_valid(p_ov), .out_ready(o_ready), .out_data(p_od),
        .out_sof(p_sof), .out_eol(p_eol));

    wire          in_ready = mode == 0 ? u_in_ready : p_in_ready;
    wire          busy     = mode == 0 ? u_busy : p_busy;
    wire          ov       = mode == 0 ? u_ov : p_ov;
    // unpack output in the group format (data in the low 40 bits)
    wire  [130:0] got_w    = mode == 0 ? {88'd0, u_od, u_last, u_eol, u_sof}
                                       : {p_od, 1'b0, p_sof, p_eol};

    int ii = 0, oi = 0, errs = 0, n_in, n_out, rep = 0;
    int cyc = 0, cyc0 = 0, cyc1 = 0, cyc2 = 0;   // cycles: this run, run 1, run 2

    // input driver: random gaps, holds a beat until taken
    always @(posedge clk) begin
        if (rst_n) begin
            if (i_valid && in_ready) begin
                ii++;
                i_valid <= 1'b0;
            end
            if ((!i_valid || in_ready) && ii < n_in * (rep + 1) && busy
                && $urandom_range(99) < 80) begin
                cur     <= vin[ii % n_in];
                i_valid <= 1'b1;
            end
            cyc++;
        end
        o_ready <= $urandom_range(99) < 70;
    end

    always @(posedge clk)
        if (rst_n && ov && o_ready) begin
            automatic logic [130:0] want = vout[oi % n_out];
            if (oi >= n_out * 2 || got_w !== want) begin
                errs++;
                if (errs <= 10)
                    $display("MISMATCH out %0d: got %h want %h", oi, got_w, want);
            end
            oi++;
        end

    task automatic run;
        cyc0 = cyc;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        wait (!busy);
        if (rep == 0) cyc1 = cyc - cyc0;
        else          cyc2 = cyc - cyc0;
    endtask

    initial begin
        if (!$value$plusargs("DIR=%s", dir) || !$value$plusargs("MODE=%d", mode)
            || !$value$plusargs("C=%d", c) || !$value$plusargs("ELEM2=%d", elem2)
            || !$value$plusargs("PB=%d", pb) || !$value$plusargs("W=%d", w)
            || !$value$plusargs("H=%d", h) || !$value$plusargs("HREP=%d", hrep))
            $fatal(1, "tb_st_io: missing plusargs");
        load({dir, "/in.hex"}, mode == 0, vin);
        load({dir, "/out.hex"}, mode == 1, vout);
        n_in  = vin.size();
        n_out = vout.size();
        repeat (5) @(posedge clk);
        rst_n = 1;
        run();
        if (ii != n_in) $fatal(1, "tb_st_io: first run took %0d of %0d inputs", ii, n_in);
        rep = 1;
        run();
        repeat (50) @(posedge clk);
        if (errs != 0 || oi != 2 * n_out || ii != 2 * n_in)
            $fatal(1, "tb_st_io %s FAIL %0d errors, %0d of %0d outputs, %0d of %0d inputs",
                   dir, errs, oi, 2 * n_out, ii, 2 * n_in);
        $display("tb_st_io %s PASS %0d outputs, %0d + %0d cycles", dir, oi, cyc1, cyc2);
        $finish;
    end
endmodule
