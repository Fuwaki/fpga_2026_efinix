// tb_proc.sv -- proc_stub Sobel under back-pressure: random input gaps and
// random output ready.  The output stream hash must equal that of a run with
// no stalls at all (the Makefile runs both and compares).
module tb_proc #(parameter bit RND = 0);
    import vid_pkg::*;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    vstream_if #(.T(rgb565_t), .PPC(2)) a (.clk(clk), .rst_n(rst_n));
    vstream_if #(.T(rgb565_t), .PPC(2)) b (.clk(clk), .rst_n(rst_n));
    proc_stub #(.MODE(PROC_SOBEL)) dut (.i(a), .o(b));
    always @(posedge clk) b.ready <= RND ? ($urandom_range(99) < 40) : 1'b1;
    longint unsigned h = 0;
    always @(posedge clk) if (b.valid && b.ready) h = h * 1000003 + {b.sof, b.eol, b.data};
    function automatic rgb565_t px(int x, int y); return rgb565_t'(16'((x * 7919 + y * 104729) ^ (x * y))); endfunction
    int ox = 0, oy = 0;
    always @(posedge clk) if (b.valid && b.ready) begin
        if (0 && oy == 3 && ox >= 424 && ox <= 430) $display("y%0d beat %0d: %h %h", oy, ox, b.data[0], b.data[1]);
        if (b.eol) begin ox = 0; oy++; end else ox++;
    end
    initial begin
        a.valid = 0; a.sof = 0; a.eol = 0;
        repeat (3) @(posedge clk); rst_n = 1;
        for (int y = 0; y < 5; y++) for (int bx = 0; bx < 640; bx++) begin
            @(negedge clk);
            a.valid = 1; a.sof = (y == 0 && bx == 0); a.eol = (bx == 639);
            a.data[0] = px(2*bx, y); a.data[1] = px(2*bx+1, y);
            if ($urandom_range(99) < 30) begin a.valid = 0; @(posedge clk); @(negedge clk); a.valid = 1; end
            @(posedge clk); while (!a.ready) @(posedge clk);
        end
        @(negedge clk); a.valid = 0;
        repeat (4000) @(posedge clk); $display("hash %h", h); $finish;
    end
endmodule
