//=============================================================================
// layer_seq.veryl -- E4: layer descriptor sequencer (16 layers, layer outer)
//-----------------------------------------------------------------------------
// One instance per dataset drives the whole network on top of the E3 datapath:
//
//   for layer in 0..n_layers-1:                     (16 for ink/vangogh)
//     read the descriptor from the generated ROM (desc_idx -> d_*)
//     latch it, derive h_out/w_out at the RUNTIME resolution img_h/img_w
//     for tile in tiles(TILE) of this layer:
//       pulse cfg_valid (descriptor + tile geometry) to conv_stream/tile_reader
//       if first tile of the layer: sweep the parameters from the off-chip model
//         w: one byte per cycle from c_w_off,  b/m: one word per cycle
//       pulse start, wait for done, drain the output beats to the y arena
//     publish this layer's counters (cyc, bytes, pixels, oc blocks)
//
// Everything that differs between the two datasets and between the 16 layers
// arrives through the descriptor: this module has no layer specific constant.
//
// Off-chip model (all byte addressed, one read port each):
//   w_addr/w_data   weight arena    (conv_stream sees the layer relative 0..w_bytes-1)
//   b_addr/b_data   bias arena      (word aligned, c_b_off + 4*i)
//   m_addr/m_data   M0 arena        (word aligned, c_m_off + 4*i)
//   x_addr/x_data   feature map arena, PACKED pixel words (one MAXC byte word
//                   per input pixel, in_c bytes of it valid); x_addr is the
//                   global pixel index = the running sum of the descriptors'
//                   x_words over the finished layers + tile_reader's index.  The
//                   descriptor's x_off is the same reading in HWC bytes, which
//                   is what the cascade ledger and a byte addressed port use.
//   y_we/y_addr/y_data  output byte writes into the per layer output arena:
//                   CHW at c_y_off + oc*H_out*W_out + oy*W_out + ox
//
// Output beats land in a 2 entry circular FIFO and leave it one byte per cycle
// into the arena.  y_ready is a real backpressure signal (conv_stream holds the
// beat until it is taken), and st_stall counts the cycles that cost.  Measured
// over the two 16 layer runs: sum(st_stall) = 22016 cycles = 0.70% of the frame,
// so for most layers the MAC array is not the limiter -- for the small k layers
// (in_c*k*k+2 < P) the byte serial writer is, which is why at 720p the write
// side has to be widened or kept on chip (E4_ACCOUNTING.md section 5).
//
// Hardware self checks (sticky err): descriptor index out of range, a bad ROM
// slot, the per layer byte counters disagreeing with the descriptor, conv_stream
// w_seq_err / x_hdr_err, output beat loss, and a cycle timeout.
//=============================================================================

module layer_seq #(
    parameter int unsigned P       = 32     , // MAC lanes == oc block size (34 DSP at P=32)
    parameter int unsigned MAXC    = 64     , // largest channel count this instance supports
    parameter int unsigned TW      = 64     , // largest tile width of the inner datapath
    parameter int unsigned TILE    = 64     , // tile edge this sequencer walks (output pixels)
    parameter int unsigned MAXL    = 16     , // layers this instance can run
    parameter int unsigned CASCADE = 0      , // 0: layer level golden (H/W fixed), 1: cascade
    parameter int unsigned TO_CYC  = 4000000 // per layer timeout, in cycles
) (
    input var logic clk  ,
    input var logic rst_n,

    // ---- runtime job ------------------------------------------------------
    input  var logic [16-1:0] img_h     , // input image height (input pixels)
    input  var logic [16-1:0] img_w     , // input image width
    input  var logic [8-1:0]  n_layers  , // layers to run, <= MAXL
    input  var logic [8-1:0]  desc_start, // descriptor index of the first layer
    input  var logic          start     ,
    output var logic          busy      ,
    output var logic          done      ,

    // ---- descriptor ROM (generated, one instance per dataset) -------------
    output var logic        [8-1:0]  desc_idx   ,
    input  var logic                 d_valid    ,
    input  var logic        [4-1:0]  d_layer_id ,
    input  var logic        [8-1:0]  d_in_c     ,
    input  var logic        [8-1:0]  d_out_c    ,
    input  var logic        [2-1:0]  d_k        ,
    input  var logic        [2-1:0]  d_stride   ,
    input  var logic        [2-1:0]  d_pad      ,
    input  var logic                 d_relu     ,
    input  var logic        [6-1:0]  d_shift    ,
    input  var logic                 d_up2x_in  ,
    input  var logic                 d_res_en   ,
    input  var logic        [4-1:0]  d_res_pt   ,
    input  var logic                 d_res_sat  ,
    input  var logic signed [18-1:0] d_res_m0   ,
    input  var logic        [6-1:0]  d_res_shift,
    input  var logic        [4-1:0]  d_out_pt   ,
    input  var logic                 d_keep     ,
    input  var logic                 d_unsigned ,
    input  var logic        [24-1:0] d_w_off    ,
    input  var logic        [24-1:0] d_w_bytes  ,
    input  var logic        [24-1:0] d_b_off    ,
    input  var logic        [24-1:0] d_m_off    ,
    input  var logic        [24-1:0] d_x_off    ,
    input  var logic        [24-1:0] d_y_off    ,
    input  var logic        [24-1:0] d_x_words  ,
    input  var logic        [24-1:0] d_y_bytes  ,

    // ---- off-chip model: weight / bias / M0 read ports --------------------
    output var logic        [24-1:0] w_addr,
    input  var logic        [8-1:0]  w_data,
    output var logic        [24-1:0] b_addr,
    input  var logic signed [32-1:0] b_data,
    output var logic        [24-1:0] m_addr,
    input  var logic signed [18-1:0] m_data,

    // ---- off-chip model: packed feature map read + byte write -------------
    output var logic [32-1:0]         x_addr,
    input  var logic [(8 * MAXC)-1:0] x_data,
    output var logic                  y_we  ,
    output var logic [24-1:0]         y_addr,
    output var logic [8-1:0]          y_data,

    // ---- per layer evidence ----------------------------------------------
    output var logic          st_we      ,
    output var logic [8-1:0]  st_idx     ,
    output var logic [4-1:0]  st_layer_id,
    output var logic [32-1:0] st_cyc     ,
    output var logic [32-1:0] st_w_bytes ,
    output var logic [8-1:0]  st_b_words ,
    output var logic [8-1:0]  st_m_words ,
    output var logic [32-1:0] st_x_px    ,
    output var logic [32-1:0] st_y_bytes ,
    output var logic [8-1:0]  st_blocks  ,
    output var logic [8-1:0]  st_tiles   ,
    output var logic [32-1:0] st_stall   ,

    // ---- frame totals -----------------------------------------------------
    output var logic [48-1:0] tot_cyc    ,
    output var logic [48-1:0] tot_w_bytes,
    output var logic [48-1:0] tot_x_px   ,
    output var logic [48-1:0] tot_y_bytes,
    output var logic          err    
);
    // ---- inner datapath ---------------------------------------------------
    logic                  cfg_valid_v;
    logic                  cfg_ready_c;
    logic                  cfg_ready_r;
    logic [2-1:0]          i_k        ;
    logic [2-1:0]          i_stride   ;
    logic [2-1:0]          i_pad      ;
    logic                  i_relu     ;
    logic [6-1:0]          i_shift    ;
    logic [8-1:0]          i_in_c     ;
    logic [8-1:0]          i_out_c    ;
    logic [16-1:0]         i_ty0      ;
    logic [16-1:0]         i_tx0      ;
    logic [16-1:0]         i_t_h      ;
    logic [16-1:0]         i_t_w      ;
    logic                  i_start    ;
    logic                  i_busy     ;
    logic                  i_done     ;
    logic                  i_w_we     ;
    logic [16-1:0]         i_w_addr   ;
    logic                  i_b_we     ;
    logic [6-1:0]          i_b_addr   ;
    logic                  i_m_we     ;
    logic [6-1:0]          i_m_addr   ;
    logic                  i_w_seq_err;
    logic                  i_x_hdr_err;
    logic                  i_x_valid  ;
    logic                  i_x_ready  ;
    logic [(8 * MAXC)-1:0] i_x_pixel  ;
    logic                  i_x_sof    ;
    logic                  i_x_eol    ;
    logic                  i_y_valid  ;
    logic                  i_y_ready  ;
    logic [(8 * P)-1:0]    i_y_data   ;
    logic [8-1:0]          i_y_oc_base;
    logic [8-1:0]          i_y_cnt    ;
    logic [16-1:0]         i_y_oy     ;
    logic [16-1:0]         i_y_ox     ;
    logic                  i_rd_busy  ;
    logic                  i_rd_done  ;
    logic [32-1:0]         i_rd_addr  ;
    logic [(8 * MAXC)-1:0] i_rd_rdata ;

    conv_stream #(
        .P    (P   ),
        .MAXC (MAXC),
        .TW   (TW  )
    ) dut (
        .clk        (clk        ),
        .rst_n      (rst_n      ),
        .cfg_valid  (cfg_valid_v),
        .cfg_ready  (cfg_ready_c),
        .cfg_in_c   (i_in_c     ),
        .cfg_out_c  (i_out_c    ),
        .cfg_k      (i_k        ),
        .cfg_stride (i_stride   ),
        .cfg_relu   (i_relu     ),
        .cfg_shift  (i_shift    ),
        .tile_y0    (i_ty0      ),
        .tile_x0    (i_tx0      ),
        .tile_h     (i_t_h      ),
        .tile_w     (i_t_w      ),
        .start      (i_start    ),
        .busy       (i_busy     ),
        .done       (i_done     ),
        .w_we       (i_w_we     ),
        .w_addr     (i_w_addr   ),
        .w_data     (w_data     ),
        .w_seq_err  (i_w_seq_err),
        .b_we       (i_b_we     ),
        .b_addr     (i_b_addr   ),
        .b_data     (b_data     ),
        .m_we       (i_m_we     ),
        .m_addr     (i_m_addr   ),
        .m_data     (m_data     ),
        .x_valid    (i_x_valid  ),
        .x_ready    (i_x_ready  ),
        .x_pixel    (i_x_pixel  ),
        .x_sof      (i_x_sof    ),
        .x_eol      (i_x_eol    ),
        .x_hdr_err  (i_x_hdr_err),
        .y_valid    (i_y_valid  ),
        .y_ready    (i_y_ready  ),
        .y_data     (i_y_data   ),
        .y_oc_base  (i_y_oc_base),
        .y_cnt      (i_y_cnt    ),
        .y_oy       (i_y_oy     ),
        .y_ox       (i_y_ox     )
    );

    tile_reader #(
        .MAXC (MAXC)
    ) rd (
        .clk        (clk        ),
        .rst_n      (rst_n      ),
        .cfg_valid  (cfg_valid_v),
        .cfg_ready  (cfg_ready_r),
        .cfg_k      (i_k        ),
        .cfg_stride (i_stride   ),
        .cfg_pad    (i_pad      ),
        .img_h      (img_h      ),
        .img_w      (img_w      ),
        .tile_y0    (i_ty0      ),
        .tile_x0    (i_tx0      ),
        .tile_h     (i_t_h      ),
        .tile_w     (i_t_w      ),
        .start      (i_start    ),
        .busy       (i_rd_busy  ),
        .done       (i_rd_done  ),
        .mem_addr   (i_rd_addr  ),
        .mem_rdata  (i_rd_rdata ),
        .x_valid    (i_x_valid  ),
        .x_ready    (i_x_ready  ),
        .x_pixel    (i_x_pixel  ),
        .x_sof      (i_x_sof    ),
        .x_eol      (i_x_eol    )
    );

    // ---- off-chip model wiring --------------------------------------------
    // The packed pixel arena is indexed by the global pixel index: the per layer
    // packed base (sum of the earlier layers' x_words) plus tile_reader's index.
    logic [32-1:0] pk_base_r;
    logic [32-1:0] x_addr_r ;

    always_comb begin
        i_rd_rdata = x_data;
        x_addr_r   = pk_base_r + i_rd_addr;
        x_addr     = x_addr_r;
    end

    // ---- FSM --------------------------------------------------------------
    localparam logic [4-1:0] S_IDLE  = 0;
    localparam logic [4-1:0] S_DESC  = 1;
    localparam logic [4-1:0] S_LATCH = 2;
    localparam logic [4-1:0] S_CFG0  = 3;
    localparam logic [4-1:0] S_W     = 4;
    localparam logic [4-1:0] S_B     = 5;
    localparam logic [4-1:0] S_M     = 6;
    localparam logic [4-1:0] S_CFG   = 7;
    localparam logic [4-1:0] S_GO    = 8;
    localparam logic [4-1:0] S_RUN   = 9;
    localparam logic [4-1:0] S_STAT  = 10;
    localparam logic [4-1:0] S_DONE  = 11;
    localparam logic [4-1:0] S_GEOM  = 12;
    localparam logic [4-1:0] S_FLUSH = 13;

    logic [4-1:0]  st ;
    logic [8-1:0]  li ;
    logic [16-1:0] ty ;
    logic [16-1:0] tx ;
    logic [16-1:0] nty;
    logic [16-1:0] ntx;

    // descriptor latches
    logic        [4-1:0]  c_layer ;
    logic        [8-1:0]  c_in_c  ;
    logic        [8-1:0]  c_out_c ;
    logic        [2-1:0]  c_k     ;
    logic        [2-1:0]  c_stride;
    logic        [2-1:0]  c_pad   ;
    logic                 c_relu  ;
    logic        [6-1:0]  c_shift ;
    logic                 c_up2x  ;
    logic                 c_res_en;
    logic signed [18-1:0] c_res_m0;
    logic        [6-1:0]  c_res_sh;
    logic        [24-1:0] c_w_off ;
    logic        [24-1:0] c_w_byt ;
    logic        [24-1:0] c_b_off ;
    logic        [24-1:0] c_m_off ;
    logic        [24-1:0] c_x_off ;
    logic        [24-1:0] c_y_off ;
    logic        [24-1:0] c_x_wrd ;
    logic        [24-1:0] c_y_byt ;
    logic        [8-1:0]  c_blocks;

    // geometry
    logic [16-1:0] h_in_r ;
    logic [16-1:0] w_in_r ;
    logic [16-1:0] h_out_r;
    logic [16-1:0] w_out_r;
    logic [32-1:0] npx_r  ;
    logic [16-1:0] h_ev_r ;
    logic [16-1:0] w_ev_r ;

    // geometry derivation (combinational: always_ff assignments are nonblocking,
    // so the derived size can never be computed from a value latched in the same
    // cycle -- it is computed here from the registered descriptor instead)
    logic [32-1:0] gh  ;
    logic [32-1:0] gw  ;
    logic [32-1:0] gho ;
    logic [32-1:0] gwo ;
    logic [32-1:0] gnpx;
    logic [16-1:0] gnty;
    logic [16-1:0] gntx;

    always_comb begin
        gh = 32'(img_h);
        gw = 32'(img_w);
        if ((CASCADE == 1)) begin
            gh = 32'(h_ev_r);
            gw = 32'(w_ev_r);
            if ((c_up2x)) begin
                gh = (32'(h_ev_r)) * 2;
                gw = (32'(w_ev_r)) * 2;
            end
        end
        gho  = seq_h_out(gh, unsigned'(int'(c_pad)), unsigned'(int'(c_k)), unsigned'(int'(c_stride)));
        gwo  = seq_h_out(gw, unsigned'(int'(c_pad)), unsigned'(int'(c_k)), unsigned'(int'(c_stride)));
        gnpx = gho * gwo;
        gnty = 16'(((gho + TILE - 1) / TILE));
        gntx = 16'(((gwo + TILE - 1) / TILE));
    end

    // load sweep
    logic [24-1:0] ld_off;

    // counters
    logic [32-1:0] cyc_r ;
    logic [32-1:0] to_r  ;
    logic [32-1:0] wb_r  ;
    logic [16-1:0] bb_r  ;
    logic [16-1:0] mb_r  ;
    logic [32-1:0] xp_r  ;
    logic [32-1:0] yb_r  ;
    logic [16-1:0] tl_r  ;
    logic [32-1:0] stl_r ;
    logic [48-1:0] tcyc_r;
    logic [48-1:0] twb_r ;
    logic [48-1:0] txp_r ;
    logic [48-1:0] tyb_r ;
    logic          e_r   ;
    // beats accepted for the current tile, and how many this tile must produce
    logic [16-1:0] tb_r ;
    logic [16-1:0] exp_b;

    // ---- output beat FIFO (2 entries x P bytes) + arena byte writer -------
    // A real two entry circular FIFO: the entry order is kept, a pop frees a
    // slot in the same cycle (so a beat is accepted while the previous one is
    // still draining) and y_ready is a genuine backpressure signal that
    // conv_stream honours (E3 contract: y_valid is held until y_ready).
    logic [8-1:0]  sk_buf  [2 * P];
    logic [8-1:0]  sk_oc   [2]    ;
    logic [16-1:0] sk_oy   [2]    ;
    logic [16-1:0] sk_ox   [2]    ;
    logic [8-1:0]  sk_cnts [2]    ;
    logic [2-1:0]  sk_wr          ;
    logic [2-1:0]  sk_rd          ;
    logic [2-1:0]  sk_n           ;
    logic          sk_pop         ;
    logic [8-1:0]  sk_cur         ;
    logic [8-1:0]  sk_oc_r        ;
    logic [16-1:0] sk_oy_r        ;
    logic [16-1:0] sk_ox_r        ;
    logic [32-1:0] wbase          ;
    logic [32-1:0] rbase          ;
    logic [8-1:0]  dj             ;

    // The geometry side of the descriptor is pure combinational logic from the
    // latches; the handshake side (w_we/b_we/m_we/start/cfg_valid) is driven
    // inside the FSM only, so no signal has two drivers.
    always_comb begin
        i_in_c   = c_in_c;
        i_out_c  = c_out_c;
        i_k      = c_k;
        i_stride = c_stride;
        i_pad    = c_pad;
        i_relu   = c_relu;
        i_shift  = c_shift;
        i_ty0    = (16'(ty)) * (16'(TILE));
        i_tx0    = (16'(tx)) * (16'(TILE));
        i_t_h    = 16'(TILE);
        i_t_w    = 16'(TILE);
        if ((h_out_r < ((16'(ty)) * (16'(TILE)) + (16'(TILE))))) begin
            i_t_h = h_out_r - (16'(ty)) * (16'(TILE));
        end
        if ((w_out_r < ((16'(tx)) * (16'(TILE)) + (16'(TILE))))) begin
            i_t_w = w_out_r - (16'(tx)) * (16'(TILE));
        end
    end

    // pointer bases and the head entry's byte count, all combinational from the
    // FIFO registers, so the clocked block below never reads a stale value back.
    always_comb begin
        wbase   = (32'(sk_wr)) * P;
        rbase   = (32'(sk_rd)) * P;
        sk_cur  = sk_cnts[0];
        sk_oc_r = sk_oc[0];
        sk_oy_r = sk_oy[0];
        sk_ox_r = sk_ox[0];
        if ((sk_rd == 1)) begin
            sk_cur  = sk_cnts[1];
            sk_oc_r = sk_oc[1];
            sk_oy_r = sk_oy[1];
            sk_ox_r = sk_ox[1];
        end
        // the head entry retires on the cycle its last byte is presented
        sk_pop = 0;
        if ((sk_n > 0)) begin
            if (((dj + 1) == sk_cur)) begin
                sk_pop = 1;
            end
        end
    end

    // One output byte per cycle, CHW inside the layer's arena region:
    //   y_off + (oc)*H_out*W_out + oy*W_out + ox
    // conv_stream already reports y_oy/y_ox in image coordinates
    // (b_oy[u] = c_ty0 + oy), so the tile origin is not added here.
    always_comb begin
        i_y_ready = 0;
        if ((sk_n < 2)) begin
            i_y_ready = 1;
        end
        if ((sk_pop)) begin
            i_y_ready = 1;
        end
        y_we   = 0;
        y_data = 0;
        y_addr = 0;
        if ((sk_n > 0)) begin
            y_we   = 1;
            y_data = sk_buf[rbase + (unsigned'(int'(dj)))];
            y_addr = c_y_off + (32'((sk_oc_r + dj))) * (32'(npx_r)) + (32'(sk_oy_r)) * (32'(w_out_r)) + (32'(sk_ox_r));
        end
    end

    // push / pop pointer updates

    always_ff @ (posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            sk_wr <= 0;
            sk_rd <= 0;
            sk_n  <= 0;
            dj    <= 0;
            stl_r <= 0;
        end else begin
            // advance the byte pointer / retire the head entry
            if ((sk_n > 0)) begin
                if ((sk_pop)) begin
                    if ((sk_rd == 0)) begin
                        sk_rd <= 1;
                    end else begin
                        sk_rd <= 0;
                    end
                    dj <= 0;
                end else begin
                    dj <= dj + 1;
                end
            end else begin
                dj <= 0;
            end
            // capture a beat at the write pointer
            if ((i_y_valid && i_y_ready)) begin
                for (int _j = 0; _j < P; _j++) begin
                    if ((unsigned'(int'(_j))) < (unsigned'(int'(i_y_cnt)))) begin
                        sk_buf[wbase + _j] <= i_y_data[8 * _j+:8];
                    end
                end
                if ((sk_wr == 0)) begin
                    sk_oc[0]   <= i_y_oc_base;
                    sk_oy[0]   <= i_y_oy;
                    sk_ox[0]   <= i_y_ox;
                    sk_cnts[0] <= i_y_cnt;
                    sk_wr      <= 1;
                end else begin
                    sk_oc[1]   <= i_y_oc_base;
                    sk_oy[1]   <= i_y_oy;
                    sk_ox[1]   <= i_y_ox;
                    sk_cnts[1] <= i_y_cnt;
                    sk_wr      <= 0;
                end
                if ((!sk_pop)) begin
                    sk_n <= sk_n + 1;
                end

            end else begin
                if ((sk_pop)) begin
                    sk_n <= sk_n - 1;
                end
            end
            if ((i_y_valid && (i_y_ready == 0))) begin
                stl_r <= stl_r + 1;
            end
        end
    end

    always_ff @ (posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            st          <= S_IDLE;
            li          <= 0;
            ty          <= 0;
            tx          <= 0;
            nty         <= 0;
            ntx         <= 0;
            c_layer     <= 0;
            c_in_c      <= 0;
            c_out_c     <= 0;
            c_k         <= 0;
            c_stride    <= 0;
            c_pad       <= 0;
            c_relu      <= 0;
            c_shift     <= 0;
            c_up2x      <= 0;
            c_res_en    <= 0;
            c_res_m0    <= 0;
            c_res_sh    <= 0;
            c_w_off     <= 0;
            c_w_byt     <= 0;
            c_b_off     <= 0;
            c_m_off     <= 0;
            c_x_off     <= 0;
            c_y_off     <= 0;
            c_x_wrd     <= 0;
            c_y_byt     <= 0;
            c_blocks    <= 0;
            h_in_r      <= 0;
            w_in_r      <= 0;
            h_out_r     <= 0;
            w_out_r     <= 0;
            npx_r       <= 0;
            h_ev_r      <= 0;
            w_ev_r      <= 0;
            ld_off      <= 0;
            cyc_r       <= 0;
            to_r        <= 0;
            wb_r        <= 0;
            bb_r        <= 0;
            mb_r        <= 0;
            xp_r        <= 0;
            yb_r        <= 0;
            tl_r        <= 0;
            tcyc_r      <= 0;
            twb_r       <= 0;
            txp_r       <= 0;
            tyb_r       <= 0;
            pk_base_r   <= 0;
            e_r         <= 0;
            busy        <= 0;
            done        <= 0;
            desc_idx    <= 0;
            w_addr      <= 0;
            b_addr      <= 0;
            m_addr      <= 0;
            st_we       <= 0;
            st_idx      <= 0;
            st_layer_id <= 0;
            st_cyc      <= 0;
            st_w_bytes  <= 0;
            st_b_words  <= 0;
            st_m_words  <= 0;
            st_x_px     <= 0;
            st_y_bytes  <= 0;
            st_blocks   <= 0;
            st_tiles    <= 0;
            st_stall    <= 0;
            tot_cyc     <= 0;
            tot_w_bytes <= 0;
            tot_x_px    <= 0;
            tot_y_bytes <= 0;
            err         <= 0;
        end else begin
            // ---- per cycle defaults ---------------------------------------
            st_we       <= 0;
            st_idx      <= li;
            done        <= 0;
            i_w_we      <= 0;
            i_b_we      <= 0;
            i_m_we      <= 0;
            i_start     <= 0;
            cfg_valid_v <= 0;
            if ((e_r)) begin
                err <= 1;
            end
            if (((i_w_seq_err == 1) || (i_x_hdr_err == 1))) begin
                e_r <= 1;
            end
            if ((st != S_IDLE)) begin
                cyc_r <= cyc_r + 1;
                to_r  <= to_r + 1;
                busy  <= 1;
            end
            // evidence counters: pixels pulled from the arena, bytes written
            if ((i_x_valid && i_x_ready)) begin
                xp_r <= xp_r + 1;
            end
            if ((y_we)) begin
                yb_r <= yb_r + 1;
            end
            // beats accepted for the tile currently running
            if ((i_y_valid && i_y_ready)) begin
                tb_r <= tb_r + 1;
            end

            case (st) inside
                S_IDLE: begin
                    busy <= 0;
                    if ((start)) begin
                        if (((n_layers == 0) || ((unsigned'(int'(n_layers))) > MAXL))) begin
                            e_r <= 1;
                            st  <= S_DONE;
                        end else begin
                            li        <= 0;
                            tcyc_r    <= 0;
                            twb_r     <= 0;
                            txp_r     <= 0;
                            tyb_r     <= 0;
                            pk_base_r <= 0;
                            if ((CASCADE == 1)) begin
                                h_ev_r <= img_h;
                                w_ev_r <= img_w;
                            end
                            st <= S_DESC;
                        end
                    end
                end
                S_DESC: begin
                    desc_idx <= li + desc_start;
                    st       <= S_LATCH;
                end
                S_LATCH: begin
                    if ((!d_valid)) begin
                        e_r <= 1;
                        st  <= S_DONE;
                    end else begin
                        c_layer  <= d_layer_id;
                        c_in_c   <= d_in_c;
                        c_out_c  <= d_out_c;
                        c_k      <= d_k;
                        c_stride <= d_stride;
                        c_pad    <= d_pad;
                        c_relu   <= d_relu;
                        c_shift  <= d_shift;
                        c_up2x   <= d_up2x_in;
                        c_res_en <= d_res_en;
                        c_res_m0 <= d_res_m0;
                        c_res_sh <= d_res_shift;
                        c_w_off  <= d_w_off;
                        c_w_byt  <= d_w_bytes;
                        c_b_off  <= d_b_off;
                        c_m_off  <= d_m_off;
                        c_x_off  <= d_x_off;
                        c_y_off  <= d_y_off;
                        c_x_wrd  <= d_x_words;
                        c_y_byt  <= d_y_bytes;
                        c_blocks <= 8'(seq_oc_blocks(unsigned'(int'(d_out_c)), P));
                        st       <= S_GEOM;
                    end
                end
                S_GEOM: begin
                    // the latched descriptor is now visible, so the combinational
                    // geometry block (gh/gw/gho/gwo/gnpx/gnty/gntx) is valid.
                    h_in_r  <= gh[15:0];
                    w_in_r  <= gw[15:0];
                    h_out_r <= gho[15:0];
                    w_out_r <= gwo[15:0];
                    npx_r   <= gnpx;
                    nty     <= gnty;
                    ntx     <= gntx;
                    ty      <= 0;
                    tx      <= 0;
                    ld_off  <= 0;
                    wb_r    <= 0;
                    bb_r    <= 0;
                    mb_r    <= 0;
                    xp_r    <= 0;
                    yb_r    <= 0;
                    tl_r    <= 0;
                    cyc_r   <= 0;
                    to_r    <= 0;
                    tb_r    <= 0;
                    exp_b   <= 0;
                    if ((gnpx == 0)) begin
                        e_r <= 1;
                        st  <= S_DONE;
                    end else begin
                        st <= S_CFG0;
                    end
                end
                S_CFG0: begin
                    // the descriptor must be on the config bus before the first
                    // weight byte (E3 contract), so this pulse comes first.
                    if ((cfg_ready_c && cfg_ready_r)) begin
                        cfg_valid_v <= 1;
                        st          <= S_W;
                    end
                end
                S_W: begin
                    if (((unsigned'(int'(ld_off))) < (unsigned'(int'(c_w_byt))))) begin
                        i_w_we   <= 1;
                        i_w_addr <= ld_off[15:0];
                        w_addr   <= c_w_off + ld_off;
                        wb_r     <= wb_r + 1;
                        ld_off   <= ld_off + 1;
                    end else begin
                        ld_off <= 0;
                        st     <= S_B;
                    end
                end
                S_B: begin
                    if (((unsigned'(int'(ld_off))) < (unsigned'(int'(c_out_c))))) begin
                        i_b_we   <= 1;
                        i_b_addr <= ld_off[5:0];
                        b_addr   <= c_b_off + ld_off * 4;
                        bb_r     <= bb_r + 1;
                        ld_off   <= ld_off + 1;
                    end else begin
                        ld_off <= 0;
                        st     <= S_M;
                    end
                end
                S_M: begin
                    if (((unsigned'(int'(ld_off))) < (unsigned'(int'(c_out_c))))) begin
                        i_m_we   <= 1;
                        i_m_addr <= ld_off[5:0];
                        m_addr   <= c_m_off + ld_off * 4;
                        mb_r     <= mb_r + 1;
                        ld_off   <= ld_off + 1;
                    end else begin
                        ld_off <= 0;
                        st     <= S_CFG;
                    end
                end
                S_CFG: begin
                    if ((cfg_ready_c && cfg_ready_r)) begin
                        cfg_valid_v <= 1;
                        st          <= S_GO;
                    end
                end
                S_GO: begin
                    i_start <= 1;
                    // beats this tile must produce: one per output pixel per
                    // output channel block (ceil(out_c/P)).  conv_stream's done
                    // is a level that stays high until the next start, so the
                    // beat count is what decides that a tile really finished.
                    exp_b <= 16'((((32'(i_t_h)) * (32'(i_t_w))) * (32'(c_blocks))));
                    tb_r  <= 0;
                    st    <= S_RUN;
                end
                S_RUN: begin
                    if ((i_done && i_rd_done && (tb_r == exp_b))) begin
                        if (((unsigned'(int'(to_r))) > TO_CYC)) begin
                            e_r <= 1;
                        end
                        tl_r <= tl_r + 1;
                        if (((unsigned'(int'(tx))) + 1 < (unsigned'(int'(ntx))))) begin
                            tx <= tx + 1;
                            st <= S_CFG;
                        end else begin
                            tx <= 0;
                            if (((unsigned'(int'(ty))) + 1 < (unsigned'(int'(nty))))) begin
                                ty <= ty + 1;
                                st <= S_CFG;
                            end else begin
                                st <= S_FLUSH;
                            end
                        end
                    end else begin
                        if (((unsigned'(int'(to_r))) > TO_CYC)) begin
                            e_r <= 1;
                            st  <= S_DONE;
                        end
                    end
                end
                S_FLUSH: begin
                    // the last output beat has to reach the arena before the next
                    // layer's descriptor overwrites c_y_off/npx_r/w_out_r, and
                    // before this layer's byte count is published.
                    if (((sk_n == 0) && (!i_y_valid))) begin
                        st <= S_STAT;
                    end else begin
                        if (((unsigned'(int'(to_r))) > TO_CYC)) begin
                            e_r <= 1;
                            st  <= S_DONE;
                        end
                    end
                end
                S_STAT: begin
                    st_we       <= 1;
                    st_idx      <= li;
                    st_layer_id <= c_layer;
                    st_cyc      <= cyc_r;
                    st_w_bytes  <= wb_r;
                    st_b_words  <= bb_r[7:0];
                    st_m_words  <= mb_r[7:0];
                    st_x_px     <= xp_r;
                    st_y_bytes  <= yb_r;
                    st_blocks   <= c_blocks;
                    st_tiles    <= tl_r[7:0];
                    st_stall    <= stl_r;
                    tcyc_r      <= tcyc_r + cyc_r;
                    twb_r       <= twb_r + wb_r;
                    txp_r       <= txp_r + xp_r;
                    tyb_r       <= tyb_r + yb_r;
                    // descriptor vs hardware cross check.  The residual scale is
                    // asserted too: a residual layer whose 18 bit multiplier came
                    // back as zero would silently turn the add into a pass through,
                    // which is exactly the kind of thing that must not be silent.
                    if (((c_res_en == 1) && (c_res_m0 == 0))) begin
                        e_r <= 1;
                    end
                    if (((c_res_en == 1) && (c_res_sh == 0))) begin
                        e_r <= 1;
                    end
                    if (((unsigned'(int'(wb_r))) != (unsigned'(int'(c_w_byt))))) begin
                        e_r <= 1;
                    end
                    if (((unsigned'(int'(bb_r))) != (unsigned'(int'(c_out_c))))) begin
                        e_r <= 1;
                    end
                    if (((unsigned'(int'(mb_r))) != (unsigned'(int'(c_out_c))))) begin
                        e_r <= 1;
                    end
                    if ((CASCADE == 0)) begin
                        if (((unsigned'(int'(yb_r))) != (unsigned'(int'(c_y_byt))))) begin
                            e_r <= 1;
                        end
                    end else if (((32'(yb_r)) != ((32'(c_out_c)) * (32'(npx_r))))) begin
                        // in cascade mode the input geometry is runtime, so the
                        // descriptor y_bytes only describes the layer level
                        // ledger; what must still hold is that the layer wrote
                        // exactly out_c * (out pixels) bytes
                        e_r <= 1;
                    end
                    pk_base_r <= pk_base_r + (unsigned'(int'(c_x_wrd)));
                    if ((CASCADE == 1)) begin
                        h_ev_r <= h_out_r;
                        w_ev_r <= w_out_r;
                    end
                    li <= li + 1;
                    if ((li + 1 == n_layers)) begin
                        st <= S_DONE;
                    end else begin
                        st <= S_DESC;
                    end
                end
                S_DONE: begin
                    tot_cyc     <= tcyc_r;
                    tot_w_bytes <= twb_r;
                    tot_x_px    <= txp_r;
                    tot_y_bytes <= tyb_r;
                    busy        <= 0;
                    done        <= 1;
                    st          <= S_IDLE;
                end
                default: begin
                    st <= S_IDLE;
                end
            endcase
        end
    end

    function automatic int unsigned seq_h_out(
        input var int unsigned h     ,
        input var int unsigned pad   ,
        input var int unsigned k     ,
        input var int unsigned stride
    ) ;
        return (h + 2 * pad - k) / stride + 1;
    endfunction

    /// Cycles one layer costs at 16x16-tile granularity: MAC cycles for every
    /// output pixel and every oc block, plus the parameter sweep (1 byte/cycle,
    /// 1 word/cycle) and the tile handshake.  This is the closed form the measured
    /// st_cyc counters are compared against.
    function automatic int unsigned seq_oc_blocks(
        input var int unsigned out_c,
        input var int unsigned p    
    ) ;
        return (out_c + p - 1) / p;
    endfunction

    /// MAC lanes + the two shared requant multipliers.

endmodule
