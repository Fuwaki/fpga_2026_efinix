// vid_bind.sv -- attach protocol checkers to every interface instance.
// Compiled into simulation builds only.

bind vstream_if vstream_sva #(.W($bits(data))) u_vstream_sva (
    .clk(clk), .rst_n(rst_n), .valid(valid), .ready(ready),
    .sof(sof), .eol(eol), .data(data));

bind axi4_wr_if axi4_wr_sva #(.AW(AW), .DW(DW), .IW(IW)) u_axi4_wr_sva (
    .clk(clk), .rst_n(rst_n),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready));

bind axi4_rd_if axi4_rd_sva #(.AW(AW), .DW(DW), .IW(IW)) u_axi4_rd_sva (
    .clk(clk), .rst_n(rst_n),
    .arid(arid), .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
    .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready));
