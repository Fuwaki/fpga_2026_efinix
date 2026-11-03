// key_debounce.sv -- synchronise an active-low key and debounce it.
//
// pressed becomes 1 only after the synchronised pin has been 0 for
// 2_000_000 clocks (20 ms at 100 MHz, 16 ms at 125 MHz), and 0 after it has been 1 for the
// same count.  pressed resets to 0.
module key_debounce (
    input  logic clk,
    input  logic rst_n,
    input  logic pin,
    output logic pressed
);
    logic [1:0]  sync;
    logic [20:0] cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync    <= 2'b11;
            cnt     <= '0;
            pressed <= 1'b0;
        end else begin
            sync <= {sync[0], pin};
            if (sync[1] == 1'b0) begin
                if (pressed)
                    cnt <= '0;
                else if (cnt == 21'd1_999_999) begin
                    pressed <= 1'b1;
                    cnt     <= '0;
                end else
                    cnt <= cnt + 21'd1;
            end else begin
                if (!pressed)
                    cnt <= '0;
                else if (cnt == 21'd1_999_999) begin
                    pressed <= 1'b0;
                    cnt     <= '0;
                end else
                    cnt <= cnt + 21'd1;
            end
        end
    end
endmodule
