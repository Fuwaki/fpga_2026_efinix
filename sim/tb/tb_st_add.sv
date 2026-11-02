// tb_st_add.sv -- st_add against tools/st_io_vectors.py: trunk and aux are
// golden activations, the expected sum is st_golden's add.  +DIR holds
// t.hex / a.hex / out.hex, the factor comes as +MANT / +K.  The two inputs
// get independent random gaps, the output random back-pressure.
module tb_st_add;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    string dir;
    logic [23:0] mant;
    logic [5:0]  k;

    logic [42:0] vt [$], va [$], vo [$];

    function automatic void load(input string path, ref logic [42:0] q [$]);
        int fd, a, b, d;
        logic [39:0] v;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "tb_st_add: cannot open %s", path);
        while ($fscanf(fd, "%h %d %d %d\n", v, a, b, d) == 4) q.push_back({v, 1'(a), 1'(b), 1'(d)});
        $fclose(fd);
    endfunction

    logic        t_valid = 0, a_valid = 0, o_ready = 0;
    logic [42:0] tc, ac;
    logic        t_ready, a_ready, ov;
    logic [39:0] od;
    logic        ol, oe, os;

    st_add dut (
        .clk(clk), .rst_n(rst_n), .cfg_mant(mant), .cfg_k(k),
        .t_valid(t_valid), .t_ready(t_ready), .t_data(tc[42:3]),
        .t_last(tc[2]), .t_eol(tc[1]), .t_sof(tc[0]),
        .a_valid(a_valid), .a_ready(a_ready), .a_data(ac[42:3]),
        .a_last(ac[2]), .a_eol(ac[1]), .a_sof(ac[0]),
        .out_valid(ov), .out_ready(o_ready), .out_data(od),
        .out_last(ol), .out_eol(oe), .out_sof(os));

    int ti = 0, ai = 0, oi = 0, errs = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            automatic int tn = ti + (t_valid && t_ready ? 1 : 0);
            automatic int an = ai + (a_valid && a_ready ? 1 : 0);
            if (t_valid && t_ready) t_valid <= 1'b0;
            if (a_valid && a_ready) a_valid <= 1'b0;
            ti = tn;
            ai = an;
            if ((!t_valid || t_ready) && tn < vt.size() && $urandom_range(99) < 85) begin
                tc <= vt[tn];
                t_valid <= 1'b1;
            end
            if ((!a_valid || a_ready) && an < va.size() && $urandom_range(99) < 85) begin
                ac <= va[an];
                a_valid <= 1'b1;
            end
        end
        o_ready <= $urandom_range(99) < 75;
    end

    always @(posedge clk)
        if (rst_n && ov && o_ready) begin
            if (oi >= vo.size() || {od, ol, oe, os} !== vo[oi]) begin
                errs++;
                if (errs <= 10)
                    $display("MISMATCH out %0d: got %h %b%b%b want %h", oi, od, ol, oe, os,
                             oi < vo.size() ? vo[oi] : 'x);
            end
            oi++;
        end

    initial begin
        if (!$value$plusargs("DIR=%s", dir) || !$value$plusargs("MANT=%h", mant)
            || !$value$plusargs("K=%d", k))
            $fatal(1, "tb_st_add: missing plusargs");
        load({dir, "/t.hex"}, vt);
        load({dir, "/a.hex"}, va);
        load({dir, "/out.hex"}, vo);
        repeat (5) @(posedge clk);
        rst_n = 1;
        wait (oi == vo.size());
        repeat (50) @(posedge clk);
        if (errs != 0 || oi != vo.size())
            $fatal(1, "tb_st_add %s FAIL %0d errors, %0d of %0d outputs", dir, errs, oi, vo.size());
        $display("tb_st_add %s PASS %0d outputs", dir, oi);
        $finish;
    end
endmodule
