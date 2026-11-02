// tb_st_requant.sv -- one st_requant lane against tools/st_rq_vectors.py.
//
// The vector file holds one line per beat, hex fields
//   x mant k lo hi expected
// (x a 25-bit two's complement accumulator, expected a 10-bit signed result).
// The driver streams them at II = 1 with random valid gaps; the checker
// compares every output beat, in order, against the expected value and its
// tag (the vector index), so a dropped, duplicated or reordered beat fails.
// A mismatch prints the first ten and ends with $fatal(1, ...).
//
//   +VEC=<file>   vector file; default sim/obj/tb_st_requant/vectors.hex,
//                 which is where the Makefile target generates it (run from
//                 the repository root, as the target does).
//
// Also checks the documented fixed latency: the first result leaves
// exactly dut.LAT cycles after its input beat is accepted.
module tb_st_requant;
    localparam int XW   = 25;       // signed accumulator, |x| < 2**24
    localparam int TW   = 18;       // tag carries the vector index
    localparam int MAXV = 400_000;  // vectors the testbench can hold
    localparam int TAIL = 4096;     // extra cycles after the last input

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic                 in_valid;
    logic signed [XW-1:0] in_x;
    logic        [23:0]   in_mant;
    logic        [5:0]    in_k;
    logic signed [9:0]    in_lo, in_hi;
    logic        [TW-1:0] in_tag;

    logic                 out_valid;
    logic signed [9:0]    out_y;
    logic        [TW-1:0] out_tag;

    st_requant #(.XW(XW), .TW(TW)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .in_x      (in_x),
        .in_mant   (in_mant),
        .in_k      (in_k),
        .in_lo     (in_lo),
        .in_hi     (in_hi),
        .in_tag    (in_tag),
        .out_valid (out_valid),
        .out_y     (out_y),
        .out_tag   (out_tag)
    );

    // ------------------------------------------------------------ vectors
    logic [XW-1:0]     vx [MAXV];
    logic [23:0]       vm [MAXV];
    logic [5:0]        vk [MAXV];
    logic signed [9:0] vlo [MAXV], vhi [MAXV];
    logic signed [9:0] ve [MAXV];
    int  n = 0;
    int  fd;

    initial begin
        string path;
        if (!$value$plusargs("VEC=%s", path))
            path = "sim/obj/tb_st_requant/vectors.hex";
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "tb_st_requant: cannot open %s", path);
        while (n < MAXV &&
               $fscanf(fd, "%h %h %h %h %h %h\n", vx[n], vm[n], vk[n], vlo[n], vhi[n], ve[n]) == 6)
            n++;
        $fclose(fd);
        $display("tb_st_requant: %0d vectors from %s", n, path);
        if (n == 0) $fatal(1, "tb_st_requant: no vectors in %s", path);
        for (int i = 0; i < n; i++) begin
            if (vm[i][23] !== 1'b1) $fatal(1, "tb_st_requant: vector %0d: mantissa not normalised", i);
            if (vk[i] < 6'd16 || vk[i] > 6'd47) $fatal(1, "tb_st_requant: vector %0d: k=%0d", i, vk[i]);
            if (vlo[i] > vhi[i]) $fatal(1, "tb_st_requant: vector %0d: lo > hi", i);
        end
        if (n > (1 << TW)) $fatal(1, "tb_st_requant: TW too small for %0d vectors", n);
    end

    // ------------------------------------------------------------- driver
    int     idx  = 0;               // next vector to present
    int     cyc  = 0;               // posedges seen, not counting the current one
    longint t_in0 = -1, t_out0 = -1;
    bit     saw_in0 = 0, saw_out0 = 0;

    // cyc counts posedges; recording it with non-blocking assignments makes
    // every block read the same value at an edge, so the latency measured
    // below is exact.
    always @(posedge clk) cyc <= cyc + 1;

    // The driver only raises in_valid in front of a vector, so the first
    // cycle it is high carries vector 0.
    always @(posedge clk)
        if (rst_n && in_valid && !saw_in0) begin
            saw_in0 <= 1;
            t_in0   <= cyc;
        end

    initial begin
        in_valid = 1'b0;
        in_x = '0; in_mant = '0; in_k = '0; in_lo = '0; in_hi = '0; in_tag = '0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        while (idx < n) begin
            in_valid = 1'b1;
            in_x     = $signed(vx[idx]);
            in_mant  = vm[idx];
            in_k     = vk[idx];
            in_lo    = vlo[idx];
            in_hi    = vhi[idx];
            in_tag   = TW'(idx);
            idx++;
            @(posedge clk);
            @(negedge clk);
            if ($urandom_range(99) < 30) begin          // random valid gap
                in_valid = 1'b0;
                repeat ($urandom_range(1, 3)) begin
                    @(posedge clk);
                    @(negedge clk);
                end
            end
        end
        in_valid = 1'b0;
    end

    // ------------------------------------------------------------ checker
    int oidx = 0;                   // next expected output
    int errs = 0;                   // value or tag mismatches

    // rst_n gates both sides: with --x-initial unique the valid bits are
    // random before the first reset edge, and that must not count.
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (!saw_out0) begin
                saw_out0 <= 1;
                t_out0   <= cyc;
            end
            if (oidx >= n) begin
                errs++;
                if (errs <= 10)
                    $display("MISMATCH: unexpected output %0d (y=%0d tag=%0h)",
                             oidx, out_y, out_tag);
            end else begin
                if (out_y !== ve[oidx] || out_tag !== TW'(oidx)) begin
                    errs++;
                    if (errs <= 10)
                        $display("MISMATCH vector %0d: x=%0h mant=%0h k=%0d lo=%0d hi=%0d: y=%0d want %0d, tag=%0h want %0h",
                                 oidx, vx[oidx], vm[oidx], vk[oidx], vlo[oidx], vhi[oidx],
                                 out_y, ve[oidx], out_tag, TW'(oidx));
                end
                oidx++;
            end
        end
    end

    // --------------------------------------------------------------- run
    initial begin
        longint lat;
        @(posedge rst_n);
        while (oidx < n && cyc < 64 + 8 * n) @(posedge clk);
        repeat (TAIL) @(posedge clk);
        lat = t_out0 - longint'(t_in0);
        if (lat != dut.LAT)
            $display("MISMATCH latency: first result after %0d cycles, LAT says %0d",
                     lat, dut.LAT);
        if (errs != 0 || oidx != n || lat != dut.LAT)
            $fatal(1, "tb_st_requant FAIL %0d errors, %0d of %0d outputs, latency %0d (LAT %0d)",
                   errs, oidx, n, lat, dut.LAT);
        $display("tb_st_requant PASS %0d vectors", n);
        $finish;
    end
endmodule
