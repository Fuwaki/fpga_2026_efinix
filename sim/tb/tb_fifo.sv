// tb_fifo.sv -- async FIFO (50 -> 100 MHz) then sync FIFO, random valid and
// ready on both ends, counter payload checked at the sink.
module tb_fifo #(parameter bit MISBEHAVE = 0);
    import vid_pkg::*;

    logic clk_a = 0, clk_b = 0, rst_n = 0;
    always #10 clk_a = ~clk_a;     // 50 MHz
    always #5  clk_b = ~clk_b;     // 100 MHz, unrelated phase below
    initial begin
        #3;
        repeat (20) @(posedge clk_b);
        rst_n = 1;
    end

    localparam int BEATS = 37, LINES = 11, FRAMES = 20;

    vstream_if #(.T(rgb565_t), .PPC(4)) a (.clk(clk_a), .rst_n(rst_n));
    vstream_if #(.T(rgb565_t), .PPC(4)) b (.clk(clk_b), .rst_n(rst_n));
    vstream_if #(.T(rgb565_t), .PPC(4)) c (.clk(clk_b), .rst_n(rst_n));

    logic done;
    vstream_rand_src #(.VALID_PCT(80), .BEATS(BEATS), .LINES(LINES), .FRAMES(FRAMES),
                      .MISBEHAVE(MISBEHAVE)) u_src (.m(a), .done(done));

    logic [4:0] a_lvl, b_lvl;
    vstream_async_fifo #(.DEPTH(16)) u_cdc (.s(a), .m(b), .s_level(a_lvl), .m_level(b_lvl));

    logic [3:0] c_lvl;
    vstream_fifo #(.DEPTH(8)) u_fifo (.s(b), .m(c), .level(c_lvl));

    longint unsigned count;
    int unsigned     errors;
    vstream_check_sink #(.READY_PCT(MISBEHAVE ? 10 : 45), .BEATS(BEATS), .LINES(LINES)) u_snk (.s(c), .count(count), .errors(errors));

    initial begin
        wait (rst_n);
        wait (done && count == BEATS * LINES * FRAMES);
        repeat (10) @(posedge clk_b);
        if (errors != 0 || count != BEATS * LINES * FRAMES)
            $fatal(1, "tb_fifo FAIL: %0d beats, %0d errors", count, errors);
        $display("tb_fifo PASS: %0d beats", count);
        $finish;
    end

    initial begin
        #50ms $fatal(1, "tb_fifo TIMEOUT");
    end
endmodule
