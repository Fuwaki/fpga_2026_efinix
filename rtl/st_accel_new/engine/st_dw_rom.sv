// st_dw_rom.sv -- the ST DW stage's depthwise weight ROM.
//
// 288-bit words, one per 4-channel group: byte c*9 + ky*3 + kx holds the
// int8 weight of output channel 4g + c for tap (ky, kx), the layout
// tools/st_gen_params.py writes (dw_word).  One registered read port; the
// board image is $readmemh'd from the generated hex.
//
// load() is the one place the image is installed; the initial block calls it
// with HEX and a testbench may call it again with a per-case file.
module st_dw_rom #(
    parameter int    DEPTH = 256,
    parameter string HEX   = "rtl/st_accel_new/gen/tiny_dw/st_dw.hex"
) (
    input  logic                     clk,
    input  logic [$clog2(DEPTH)-1:0] addr,
    output logic [287:0]             dout
);
    logic [287:0] mem [DEPTH];

    task automatic load(input string path);
        for (int i = 0; i < DEPTH; i++)
            mem[i] = '0;
        $readmemh(path, mem);
    endtask

    initial load(HEX);

    always_ff @(posedge clk)
        dout <= mem[addr];
endmodule
