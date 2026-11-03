// isp_top.sv -- the camera ISP: raw Bayer in, display-ready RGB565 out, both
// 2 pixels per clock in the core clock.
//
//   isp_blc_wb -> isp_demosaic -> isp_gamma -> isp_sat -> isp_dither565
//
// Every stage is a fixed-latency vpush_if stage; the framing (sof/eol) travels
// with the data, so stages can be added or reordered without retiming the
// others.  cfg.bypass_all sends raw[9:2] as gray straight to the output, for
// bit-exact checks of everything around the ISP.  The arithmetic is specified
// by sim/ref/isp_ref.py.
module isp_top
    import vid_pkg::*;
#(
    parameter string GAMMA_CURVE = "./rtl/gamma_conrrection/SRGB_ENC.mem"
) (
    vpush_if.snk          i,         // raw10_t x 2
    vpush_if.src          o,         // rgb565_t x 2
    input isp_cfg_t       cfg,
    input isp_gain_t      gain,      // per-colour BLC/WB gain, taken at sof
    output logic [3:0][31:0] st_sum,
    output logic [31:0]   st_clip,
    output logic [31:0]   st_dark,
    output logic [7:0]    st_frames
);
    wire clk = i.clk, rst_n = i.rst_n;

    vpush_if #(.T(raw10_t),  .PPC(2)) s_wb  (.clk(clk), .rst_n(rst_n));
    vpush_if #(.T(rgb10_t),  .PPC(2)) s_dm  (.clk(clk), .rst_n(rst_n));
    vpush_if #(.T(rgb888_t), .PPC(2)) s_gm  (.clk(clk), .rst_n(rst_n));
    vpush_if #(.T(rgb888_t), .PPC(2)) s_sat (.clk(clk), .rst_n(rst_n));
    vpush_if #(.T(rgb565_t), .PPC(2)) s_out (.clk(clk), .rst_n(rst_n));

    isp_stats     u_stats (.i(i), .st_sum(st_sum), .st_clip(st_clip), .st_dark(st_dark),
                           .st_frames(st_frames));
    isp_blc_wb    u_wb    (.i(i),     .o(s_wb),  .cfg(cfg), .gain(gain));
    isp_demosaic  u_dm    (.i(s_wb),  .o(s_dm),  .cfg(cfg));
    isp_gamma #(.CURVE(GAMMA_CURVE)) u_gm (.i(s_dm), .o(s_gm), .cfg(cfg));
    isp_sat       u_sat   (.i(s_gm),  .o(s_sat), .cfg(cfg));
    isp_dither565 u_dith  (.i(s_sat), .o(s_out), .cfg(cfg));

    // Bypass: gray from the raw value, plain truncation.
    function automatic rgb565_t gray565(input raw10_t v);
        return pack565('{r: v[9:2], g: v[9:2], b: v[9:2]});
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o.valid <= 1'b0;
            o.sof   <= 1'b0;
            o.eol   <= 1'b0;
            o.data  <= '0;
        end else if (cfg.bypass_all) begin
            o.valid   <= i.valid;
            o.sof     <= i.valid && i.sof;
            o.eol     <= i.valid && i.eol;
            o.data[0] <= gray565(i.data[0]);
            o.data[1] <= gray565(i.data[1]);
        end else begin
            o.valid <= s_out.valid;
            o.sof   <= s_out.sof;
            o.eol   <= s_out.eol;
            o.data  <= s_out.data;
        end
    end

endmodule
