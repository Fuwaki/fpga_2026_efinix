// tb_osd.sv -- menu glyphs painted by the compositor on a 720p60 raster.
//
// Both layer streams are idle, so video is black.  The first active frame is
// FPS 22 / SPLIT (cursor on row 1, yellow) / STY 0.  The second frame is
// FPS 99 / FULL / STY 3 with the cursor on row 2.
module tb_osd;
    import vid_pkg::*;
    import osd_font::*;

    logic clk = 0, rst_n = 0;
    always #6.734 clk = ~clk;   // 74.25 MHz
    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
    end

    vstream_if #(.T(rgb565_t), .PPC(2)) layer0 (.clk(clk), .rst_n(rst_n));
    vstream_if #(.T(rgb565_t), .PPC(2)) layer1 (.clk(clk), .rst_n(rst_n));
    assign layer0.valid = 1'b0;
    assign layer0.sof   = 1'b0;
    assign layer0.eol   = 1'b0;
    assign layer0.data  = '0;
    assign layer1.valid = 1'b0;
    assign layer1.sof   = 1'b0;
    assign layer1.eol   = 1'b0;
    assign layer1.data  = '0;

    // Declaration initializers are dropped if an always block also writes
    // the net, so these are assigned from the initial block below.
    logic       live, osd_en, view_full, single_sel, cursor;
    logic [1:0] style;
    logic [6:0] fps;
    logic [1:0] wb;

    logic [7:0] r, g, b;
    logic       de, hs, vs;
    logic [15:0] st_bad_lines [2];
    logic [15:0] st_resyncs [2];
    logic [31:0] st_frame_sum;
    logic [15:0] st_jumps;
    logic        frame_req;

    compositor u (
        .layer0(layer0), .layer1(layer1), .frame_req(frame_req),
        .r(r), .g(g), .b(b), .de(de), .hs(hs), .vs(vs),
        .st_bad_lines(st_bad_lines), .st_resyncs(st_resyncs),
        .st_frame_sum(st_frame_sum), .st_jumps(st_jumps),
        .live(live), .osd_en(osd_en), .view_full(view_full),
        .single_sel(single_sel), .cursor(cursor), .style(style), .fps(fps),
        .wb(wb));

    localparam logic [4:0] WB_WANT [3][7] = '{
        '{5'd20, 5'd21, 5'd0, 5'd22, 5'd18, 5'd17, 5'd23},   // WB AUTO
        '{5'd20, 5'd21, 5'd0, 5'd24, 5'd22, 5'd15, 5'd0},    // WB CAL
        '{5'd20, 5'd21, 5'd0, 5'd15, 5'd23, 5'd24, 5'd25}};  // WB LOCK

    task automatic expect_row(
        input int row,
        input logic full, input logic cur, input logic [1:0] sty, input logic [6:0] f,
        input logic [4:0] want0, input logic [4:0] want1, input logic [4:0] want2,
        input logic [4:0] want3, input logic [4:0] want4, input logic [4:0] want5
    );
        logic [4:0] want [6];
        want[0] = want0; want[1] = want1; want[2] = want2;
        want[3] = want3; want[4] = want4; want[5] = want5;
        for (int c = 0; c < 6; c++) begin
            if (cell_code(c, row, full, cur, sty, f) !== want[c])
                $fatal(1, "cell r%0dc%0d code %0d want %0d (full %0d cur %0d sty %0d fps %0d)",
                       row, c, cell_code(c, row, full, cur, sty, f), want[c], full, cur, sty, f);
        end
    endtask

    initial begin
        live = 1'b1;
        osd_en = 1'b1;
        view_full = 1'b0;
        single_sel = 1'b1;
        cursor = 1'b0;
        style = 2'd0;
        fps = 7'd22;
        wb = 2'd0;
        // Row 3: WB AUTO / WB CAL / WB LOCK; column 6 is blank on rows 0-2.
        foreach (WB_WANT[k])
            for (int c = 0; c < 7; c++)
                if (cell_code(c, 3, 0, 1, 0, 22, 2'(k)) !== WB_WANT[k][c])
                    $fatal(1, "wb %0d cell %0d code %0d want %0d", k, c,
                           cell_code(c, 3, 0, 1, 0, 22, 2'(k)), WB_WANT[k][c]);
        for (int r = 0; r < 3; r++)
            if (cell_code(6, r, 1, 1, 3, 99, 2'd2) !== 5'd0)
                $fatal(1, "row %0d column 6 must be blank", r);
        if (yellow(13'(OSD_X0), 13'(OSD_Y0 + 3 * OSD_PITCH), 1))
            $fatal(1, "row 3 is never yellow");
        // Frame 1 text: FPS 22, cursor on SPLIT, STY 0.
        expect_row(0, 0, 0, 0, 22, 5'd12, 5'd13, 5'd14, 5'd0, 5'd4, 5'd4);
        expect_row(1, 0, 0, 0, 22, 5'd1,  5'd14, 5'd13, 5'd15, 5'd16, 5'd17);
        expect_row(2, 0, 0, 0, 22, 5'd0,  5'd14, 5'd17, 5'd19, 5'd0,  5'd2);
        // Frame 2 text: digits clamped to 99, FULL, STY 3, cursor on row 2.
        expect_row(0, 1, 1, 3, 100, 5'd12, 5'd13, 5'd14, 5'd0, 5'd11, 5'd11);
        expect_row(1, 1, 1, 3, 100, 5'd0,  5'd12, 5'd18, 5'd15, 5'd15, 5'd0);
        expect_row(2, 1, 1, 3, 100, 5'd1,  5'd14, 5'd17, 5'd19, 5'd0,  5'd5);
        // '>' second source row is 8'h60, drawn on local y 2.  Bit 7 is blank,
        // bit 6 is the first lit pixel.  Cursor 0 puts '>' on row 1.
        if (lit(13'(OSD_X0), 13'(OSD_Y0 + OSD_PITCH + 2), 0, 0, 0, 22))
            $fatal(1, "'>' leftmost pixel of that row must be blank");
        if (!lit(13'(OSD_X0 + 1), 13'(OSD_Y0 + OSD_PITCH + 2), 0, 0, 0, 22))
            $fatal(1, "'>' bit 6 must be the leftmost lit pixel");
        if (yellow(13'(OSD_X0), 13'(OSD_Y0), 0))
            $fatal(1, "row 0 is never yellow");
        if (!yellow(13'(OSD_X0), 13'(OSD_Y0 + OSD_PITCH), 0))
            $fatal(1, "cursor 0 yellows row 1");
        if (yellow(13'(OSD_X0), 13'(OSD_Y0 + 2 * OSD_PITCH), 0))
            $fatal(1, "cursor 0 does not yellow row 2");
        if (yellow(13'(OSD_X0), 13'(OSD_Y0 + OSD_PITCH), 1))
            $fatal(1, "cursor 1 does not yellow row 1");
        if (!yellow(13'(OSD_X0), 13'(OSD_Y0 + 2 * OSD_PITCH), 1))
            $fatal(1, "cursor 1 yellows row 2");
    end

    int  ox, oy, frames_done;
    bit  de_d, vs_d;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ox <= 0; oy <= 0; frames_done <= 0; de_d <= 0; vs_d <= 0;
        end else begin
            de_d <= de;
            vs_d <= vs;
            if (de && frames_done < 2) begin
                logic [23:0] expc;
                expc = lit(13'(ox), 13'(oy), view_full, cursor, style, fps, wb)
                     ? (yellow(13'(ox), 13'(oy), cursor) ? 24'hFFFF00 : 24'hFFFFFF)
                     : 24'h000000;
                if ({r, g, b} !== expc)
                    $fatal(1, "(%0d,%0d) frame %0d got %h want %h", ox, oy, frames_done, {r, g, b}, expc);
                ox <= ox + 1;
            end else if (de_d && frames_done < 2) begin
                if (ox != 1280)
                    $fatal(1, "line %0d has %0d active pixels", oy, ox);
                ox <= 0;
                oy <= oy + 1;
            end
            if (vs && !vs_d && oy != 0) begin
                if (oy != 720)
                    $fatal(1, "frame %0d has %0d active lines", frames_done, oy);
                if (frames_done == 0) begin
                    cursor    <= 1'b1;
                    view_full <= 1'b1;
                    style     <= 2'd3;
                    fps       <= 7'd100;
                    wb        <= 2'd2;
                end else if (frames_done == 1) begin
                    $display("tb_osd PASS");
                    $finish;
                end
                frames_done <= frames_done + 1;
                oy <= 0;
            end
        end
    end

    initial begin
        #80ms $fatal(1, "tb_osd TIMEOUT");
    end
endmodule
