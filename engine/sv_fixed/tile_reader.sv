//=============================================================================
// tile_reader.veryl -- E3: tile input-window raster reader (halo + reflect)
//-----------------------------------------------------------------------------
// Produces the pixel stream conv_stream eats: one pixel per beat, HWC packed,
// raster order over the tile's INPUT window
//
//     rows: S*tile_y0 - PAD .. S*(tile_y0+tile_h-1) - PAD + K-1   (win_h rows)
//     cols: S*tile_x0 - PAD .. S*(tile_x0+tile_w-1) - PAD + K-1   (win_w cols)
//
// halo rule (architecture.md §5, rule 1 -- the classic tile bug): the global
// input index gi is computed first; if gi is inside [0, img_h/img_w) the real
// neighbour is read, so a tile boundary is seamless.  reflect() is applied
// ONLY when gi falls outside the image.  Reflect semantics are the frozen
// conv_engine ones (edge pixel NOT duplicated): -1 -> 1, n -> n-2.
//
// The map port is a PACKED PIXEL arena: mem_addr is a pixel index
// (gy*img_w + gx) and mem_rdata is that pixel's MAXC-byte HWC word.  Reads are
// registered (address beat, data beat) so the memory is never in a wide
// combinational path; throughput is 1 pixel / 2 cycles, which is 1..2 orders
// of magnitude below the MAC side (see conv_stream.veryl).  E4 replaces the
// arena port with a burst prefetch stage behind the same valid/ready stream.
//=============================================================================

/// Rows of the input window a tile needs: S*(th-1)+K.



module tile_reader #(
    parameter int unsigned MAXC = 64
) (
    input  var logic          clk       ,
    input  var logic          rst_n     ,
    input  var logic          cfg_valid ,
    output var logic          cfg_ready ,
    input  var logic [2-1:0]  cfg_k     ,
    input  var logic [2-1:0]  cfg_stride,
    input  var logic [2-1:0]  cfg_pad   ,
    input  var logic [16-1:0] img_h     ,
    input  var logic [16-1:0] img_w     ,
    input  var logic [16-1:0] tile_y0   ,
    input  var logic [16-1:0] tile_x0   ,
    input  var logic [16-1:0] tile_h    ,
    input  var logic [16-1:0] tile_w    ,
    input  var logic          start     ,
    output var logic          busy      ,
    output var logic          done      ,

    output var logic [32-1:0]         mem_addr , // pixel index in the packed arena
    input  var logic [(8 * MAXC)-1:0] mem_rdata,

    output var logic                  x_valid,
    input  var logic                  x_ready,
    output var logic [(8 * MAXC)-1:0] x_pixel,
    output var logic                  x_sof  ,
    output var logic                  x_eol  
);
    localparam logic S_IDLE = 0;
    localparam logic S_RUN  = 1;

    // ---- config registers -------------------------------------------------
    logic [2-1:0]  c_k     ;
    logic [2-1:0]  c_stride;
    logic [2-1:0]  c_pad   ;
    logic [16-1:0] c_ih    ;
    logic [16-1:0] c_iw    ;
    logic [16-1:0] c_ty0   ;
    logic [16-1:0] c_tx0   ;
    logic [16-1:0] c_th    ;
    logic [16-1:0] c_tw    ;

    // ---- raster position ---------------------------------------------------
    logic                  st     ;
    logic [16-1:0]         r      ; // window row
    logic [16-1:0]         c      ; // window column
    logic                  phase  ; // 0 = address beat, 1 = data beat
    logic [(8 * MAXC)-1:0] rd_data;

    // ---- combinational helpers --------------------------------------------
    logic [32-1:0] win_w_c ;
    logic [32-1:0] win_h_c ;
    logic [16-1:0] win_w_m1;
    logic [16-1:0] win_h_16;
    logic [16-1:0] r_next  ;
    logic          c_last  ;
    int            gy_pad  ;
    int            gx_pad  ;
    int            gy      ;
    int            gx      ;
    logic [32-1:0] addr_c  ;
    logic          valid_c ;


    // Reflect the padded index onto the image exactly like the frozen
    // conv_engine.reflect().  This is a deliberate fidelity copy of verified
    // logic (test/tb_tile_reader.veryl cross-checks the emitted address
    // sequence against the independent test/golden.veryl reflect_idx).
    function automatic int reflect(
        input var int v,
        input var int n
    ) ;
        int a     ;
        int period;
        a      = v;
        if (a < 0) begin
            a = -a;
        end
        period = 2 * n - 2;
        if (period > 0) begin
            a = a % period;
            if (a > n - 1) begin
                a = period - a;
            end
        end
        return a;
    endfunction

    always_comb begin
        win_w_c  = (32'(c_stride)) * ((32'(c_tw)) - 1) + (32'(c_k));
        win_h_c  = (32'(c_stride)) * ((32'(c_th)) - 1) + (32'(c_k));
        win_w_m1 = win_w_c[15:0] - 1;
        win_h_16 = win_h_c[15:0];
        r_next   = r + 1;

        // Widen the narrow fields with the "as 32" width cast, which
        // zero-extends.  "x as i32" / "x as u32" on a narrow field SIGN-extends
        // the source bits in this toolchain: 2'd2 (stride 2) would become -2 and
        // silently break S*tile_y0 whenever stride == 2 and the tile origin is
        // non-zero.  The 32-bit result is then reinterpreted as signed.
        gy_pad = int'(((32'(c_ty0)) * (32'(c_stride)) - (32'(c_pad)) + (32'(r))));
        gx_pad = int'(((32'(c_tx0)) * (32'(c_stride)) - (32'(c_pad)) + (32'(c))));
        gy     = reflect(gy_pad, int'((32'(c_ih))));
        gx     = reflect(gx_pad, int'((32'(c_iw))));
        addr_c = (32'(gy)) * (32'(c_iw)) + (32'(gx));

        c_last  = c == win_w_m1;
        valid_c = (r < win_h_16) && (phase != 0);

        mem_addr  = addr_c;
        x_pixel   = rd_data;
        x_sof     = (r == 0) && (c == 0);
        x_eol     = c_last;
        x_valid   = valid_c && (st == S_RUN);
        cfg_ready = (st == S_IDLE) && !busy;
    end

    always_ff @ (posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            r        <= 0;
            c        <= 0;
            phase    <= 0;
            busy     <= 0;
            done     <= 0;
            c_k      <= 0;
            c_stride <= 0;
            c_pad    <= 0;
            c_ih     <= 0;
            c_iw     <= 0;
            c_ty0    <= 0;
            c_tx0    <= 0;
            c_th     <= 0;
            c_tw     <= 0;
        end else begin
            if (cfg_valid && cfg_ready) begin
                c_k      <= cfg_k;
                c_stride <= cfg_stride;
                c_pad    <= cfg_pad;
                c_ih     <= img_h;
                c_iw     <= img_w;
                c_ty0    <= tile_y0;
                c_tx0    <= tile_x0;
                c_th     <= tile_h;
                c_tw     <= tile_w;
            end
            case (st) inside
                S_IDLE: begin
                    busy <= 0;
                    if (start) begin
                        r     <= 0;
                        c     <= 0;
                        phase <= 0;
                        done  <= 0;
                        if ((win_h_16 == 0) || (win_w_c == 0)) begin
                            done <= 1;
                        end else begin
                            busy <= 1;
                            st   <= S_RUN;
                        end
                    end
                end
                S_RUN: begin
                    if (phase == 0) begin
                        // address beat: capture the packed pixel of (r, c)
                        rd_data <= mem_rdata;
                        phase   <= 1;
                    end else begin
                        // data beat: offer it, advance on accept
                        if (x_ready) begin
                            phase <= 0;
                            if (c_last) begin
                                c <= 0;
                                r <= r_next;
                                if (r_next == win_h_16) begin
                                    busy <= 0;
                                    done <= 1;
                                    st   <= S_IDLE;
                                end
                            end else begin
                                c <= c + 1;
                            end
                        end
                    end
                end
                default: begin
                    st <= S_IDLE;
                end
            endcase
        end
    end
endmodule
