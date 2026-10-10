// st_accel_stub.v -- Phase-1 style-transfer hook for fpga_src (Ti60F225)
//
// Goals for this revision (compile-safe, resource-light):
//   * APB3 slave on Sapphire io_apbSlave_0 (base IO_APB_SLAVE_0_INPUT = 0xF810_0000)
//   * Pulse/level IRQ -> userInterruptA
//   * A small bank of signed 8x8 multiply-accumulates that Efinity maps to DSP48
//   * NO AXI master yet (DDR still exclusive to frame_buffer) -- stubs for future
//
// Register map (byte offset, 32-bit words):
//   0x00 VERSION   RO  0x5354_0001 ("ST" + rev)
//   0x04 CTRL      RW  bit0=START (W1P), bit1=IRQ_EN, bit8=SOFT_RST
//   0x08 STATUS    RO  bit0=BUSY, bit1=DONE (sticky, W1C via 0x0C)
//   0x0C STATUS_W1C W  write-1-clear DONE
//   0x10 CYCLES    RO  last run cycle count
//   0x14 MAC_ACC   RO  DSP MAC accumulator (sanity)
//   0x18 IN_ADDR   RW  reserved DDR input base (not used yet)
//   0x1C OUT_ADDR  RW  reserved DDR output base (not used yet)
//   0x20 LENGTH    RW  number of MAC ticks to run (default 256)
//
module st_accel_stub #(
    parameter integer N_DSP = 8  // parallel int8 MACs -> expect ~8 DSP blocks
) (
    input  wire        clk,
    input  wire        rst_n,          // async-ish, treat as sync release

    // APB3 slave
    input  wire [31:0] PADDR,
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire        PWRITE,
    input  wire [31:0] PWDATA,
    output reg  [31:0] PRDATA,
    output wire        PREADY,
    output wire        PSLVERROR,

    // Interrupt to Sapphire userInterruptA (level-high while DONE & IRQ_EN)
    output wire        irq
);
    assign PREADY    = 1'b1;
    assign PSLVERROR = 1'b0;

    // Use only low 8 bits of PADDR (64B window); Sapphire gives 16-bit APB addr.
    wire [7:0]  reg_addr = PADDR[7:0];
    wire        apb_wr   = PSEL & PENABLE &  PWRITE;
    wire        apb_rd   = PSEL & PENABLE & ~PWRITE;

    reg        irq_en;
    reg        busy;
    reg        done;
    reg [31:0] cycles;
    reg [31:0] length;
    reg [31:0] in_addr, out_addr;
    reg        start_pulse;
    reg        soft_rst;

    // ---------------- DSP MAC array (inferred -> EFX DSP48 on Titanium) --------
    // Keep operands registered so the mapper prefers hard DSP over soft mult.
    (* syn_multstyle = "block" *)
    reg signed [7:0]  a_r [0:N_DSP-1];
    (* syn_multstyle = "block" *)
    reg signed [7:0]  b_r [0:N_DSP-1];
    reg signed [31:0] acc;
    reg signed [15:0] prod [0:N_DSP-1];
    integer i;

    // simple LFSR-ish stimulus so the MAC is not constant-folded away
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lfsr <= 16'hACE1;
        else if (busy)
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N_DSP; i = i + 1) begin
                a_r[i]  <= 8'sd0;
                b_r[i]  <= 8'sd0;
                prod[i] <= 16'sd0;
            end
            acc <= 32'sd0;
        end else if (soft_rst) begin
            acc <= 32'sd0;
        end else if (busy) begin
            for (i = 0; i < N_DSP; i = i + 1) begin
                a_r[i]  <= lfsr[7:0] + i[7:0];
                b_r[i]  <= lfsr[15:8] - i[7:0];
                // signed 8x8 -> 16; tool should pack into DSP48
                prod[i] <= $signed(a_r[i]) * $signed(b_r[i]);
            end
            // accumulate first product (keeps fanout small; still references all prod[])
            acc <= acc + {{16{prod[0][15]}}, prod[0]}
                     + {{16{prod[1][15]}}, prod[1]}
                     + {{16{prod[2][15]}}, prod[2]}
                     + {{16{prod[3][15]}}, prod[3]}
                     + {{16{prod[4][15]}}, prod[4]}
                     + {{16{prod[5][15]}}, prod[5]}
                     + {{16{prod[6][15]}}, prod[6]}
                     + {{16{prod[7][15]}}, prod[7]};
        end
    end

    // ---------------- control FSM ---------------------------------------------
    reg [31:0] tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy        <= 1'b0;
            done        <= 1'b0;
            cycles      <= 32'd0;
            tick        <= 32'd0;
            start_pulse <= 1'b0;
            soft_rst    <= 1'b0;
            irq_en      <= 1'b0;
            length      <= 32'd256;
            in_addr     <= 32'd0;
            out_addr    <= 32'd0;
        end else begin
            start_pulse <= 1'b0;
            soft_rst    <= 1'b0;

            if (apb_wr) begin
                case (reg_addr)
                    8'h04: begin
                        if (PWDATA[0]) start_pulse <= 1'b1;
                        irq_en   <= PWDATA[1];
                        if (PWDATA[8]) soft_rst <= 1'b1;
                    end
                    8'h0C: if (PWDATA[1]) done <= 1'b0;
                    8'h18: in_addr  <= PWDATA;
                    8'h1C: out_addr <= PWDATA;
                    8'h20: length   <= (PWDATA == 0) ? 32'd1 : PWDATA;
                    default: ;
                endcase
            end

            if (soft_rst) begin
                busy   <= 1'b0;
                done   <= 1'b0;
                tick   <= 32'd0;
                cycles <= 32'd0;
            end else if (start_pulse && !busy) begin
                busy <= 1'b1;
                done <= 1'b0;
                tick <= 32'd0;
            end else if (busy) begin
                tick <= tick + 1'b1;
                if (tick + 1'b1 >= length) begin
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    cycles <= tick + 1'b1;
                end
            end
        end
    end

    assign irq = done & irq_en;

    // ---------------- APB readback --------------------------------------------
    always @(*) begin
        PRDATA = 32'd0;
        case (reg_addr)
            8'h00: PRDATA = 32'h5354_0001;
            8'h04: PRDATA = {23'd0, soft_rst, 6'd0, irq_en, busy}; // START is W1P
            8'h08: PRDATA = {30'd0, done, busy};
            8'h10: PRDATA = cycles;
            8'h14: PRDATA = acc;
            8'h18: PRDATA = in_addr;
            8'h1C: PRDATA = out_addr;
            8'h20: PRDATA = length;
            default: PRDATA = 32'd0;
        endcase
        // silence unused apb_rd warning in some tools
        if (apb_rd) ;
    end

endmodule
