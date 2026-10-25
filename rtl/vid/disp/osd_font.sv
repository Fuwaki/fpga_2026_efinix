// osd_font.sv -- 8x16 menu glyphs for the compositor.
//
// Drawn as combinational functions.  There is no array and no memory
// attribute: a function of constants maps to LUTs, not a RAM10.
// Glyphs are 8x8 source rows, each row painted twice (local_y[3:1]).
// Bit 7 of a row byte is the leftmost pixel.  Cells are OSD_GW pixels wide
// and OSD_PITCH pixels tall; the source is 16 pixels tall, so the last 4
// pixels of every cell are a transparent gap.
package osd_font;
    localparam int OSD_X0    = 16;
    localparam int OSD_Y0    = 16;
    localparam int OSD_COLS  = 6;
    localparam int OSD_ROWS  = 3;
    localparam int OSD_GW    = 8;
    localparam int OSD_GH    = 16;
    localparam int OSD_PITCH = 20;

    function automatic logic [3:0] fps_tens(input logic [6:0] v);
        fps_tens = 4'd0;
        if (v >= 7'd10) fps_tens = 4'd1;
        if (v >= 7'd20) fps_tens = 4'd2;
        if (v >= 7'd30) fps_tens = 4'd3;
        if (v >= 7'd40) fps_tens = 4'd4;
        if (v >= 7'd50) fps_tens = 4'd5;
        if (v >= 7'd60) fps_tens = 4'd6;
        if (v >= 7'd70) fps_tens = 4'd7;
        if (v >= 7'd80) fps_tens = 4'd8;
        if (v >= 7'd90) fps_tens = 4'd9;
    endfunction

    function automatic logic [3:0] fps_ones(input logic [6:0] v);
        logic [3:0] t;
        logic [6:0] base;
        t = fps_tens(v);
        base = {t, 3'b000} + {2'b00, t, 1'b0};
        fps_ones = 4'(v - base);
    endfunction

    function automatic logic [7:0] row8(input logic [4:0] code, input logic [2:0] y);
        row8 = 8'h00;
        case (code)

            5'd1: begin // >
                case (y)
                    3'd0: row8 = 8'h00;
                    3'd1: row8 = 8'h60;
                    3'd2: row8 = 8'h30;
                    3'd3: row8 = 8'h18;
                    3'd4: row8 = 8'h0C;
                    3'd5: row8 = 8'h18;
                    3'd6: row8 = 8'h30;
                    3'd7: row8 = 8'h60;
                    default: row8 = 8'h00;
                endcase
            end
            5'd2: begin // 0
                case (y)
                    3'd0: row8 = 8'h3C;
                    3'd1: row8 = 8'h66;
                    3'd2: row8 = 8'h6E;
                    3'd3: row8 = 8'h76;
                    3'd4: row8 = 8'h66;
                    3'd5: row8 = 8'h66;
                    3'd6: row8 = 8'h3C;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd3: begin // 1
                case (y)
                    3'd0: row8 = 8'h18;
                    3'd1: row8 = 8'h38;
                    3'd2: row8 = 8'h18;
                    3'd3: row8 = 8'h18;
                    3'd4: row8 = 8'h18;
                    3'd5: row8 = 8'h18;
                    3'd6: row8 = 8'h3C;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd4: begin // 2
                case (y)
                    3'd0: row8 = 8'h3C;
                    3'd1: row8 = 8'h66;
                    3'd2: row8 = 8'h06;
                    3'd3: row8 = 8'h0C;
                    3'd4: row8 = 8'h18;
                    3'd5: row8 = 8'h30;
                    3'd6: row8 = 8'h7E;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd5: begin // 3
                case (y)
                    3'd0: row8 = 8'h3C;
                    3'd1: row8 = 8'h66;
                    3'd2: row8 = 8'h06;
                    3'd3: row8 = 8'h1C;
                    3'd4: row8 = 8'h06;
                    3'd5: row8 = 8'h66;
                    3'd6: row8 = 8'h3C;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd6: begin // 4
                case (y)
                    3'd0: row8 = 8'h0C;
                    3'd1: row8 = 8'h1C;
                    3'd2: row8 = 8'h3C;
                    3'd3: row8 = 8'h6C;
                    3'd4: row8 = 8'h7E;
                    3'd5: row8 = 8'h0C;
                    3'd6: row8 = 8'h0C;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd7: begin // 5
                case (y)
                    3'd0: row8 = 8'h7E;
                    3'd1: row8 = 8'h60;
                    3'd2: row8 = 8'h7C;
                    3'd3: row8 = 8'h06;
                    3'd4: row8 = 8'h06;
                    3'd5: row8 = 8'h66;
                    3'd6: row8 = 8'h3C;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd8: begin // 6
                case (y)
                    3'd0: row8 = 8'h1C;
                    3'd1: row8 = 8'h30;
                    3'd2: row8 = 8'h60;
                    3'd3: row8 = 8'h7C;
                    3'd4: row8 = 8'h66;
                    3'd5: row8 = 8'h66;
                    3'd6: row8 = 8'h3C;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd9: begin // 7
                case (y)
                    3'd0: row8 = 8'h7E;
                    3'd1: row8 = 8'h06;
                    3'd2: row8 = 8'h0C;
                    3'd3: row8 = 8'h18;
                    3'd4: row8 = 8'h30;
                    3'd5: row8 = 8'h30;
                    3'd6: row8 = 8'h30;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd10: begin // 8
                case (y)
                    3'd0: row8 = 8'h3C;
                    3'd1: row8 = 8'h66;
                    3'd2: row8 = 8'h66;
                    3'd3: row8 = 8'h3C;
                    3'd4: row8 = 8'h66;
                    3'd5: row8 = 8'h66;
                    3'd6: row8 = 8'h3C;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd11: begin // 9
                case (y)
                    3'd0: row8 = 8'h3C;
                    3'd1: row8 = 8'h66;
                    3'd2: row8 = 8'h66;
                    3'd3: row8 = 8'h3E;
                    3'd4: row8 = 8'h06;
                    3'd5: row8 = 8'h0C;
                    3'd6: row8 = 8'h38;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd12: begin // F
                case (y)
                    3'd0: row8 = 8'h7E;
                    3'd1: row8 = 8'h60;
                    3'd2: row8 = 8'h60;
                    3'd3: row8 = 8'h7C;
                    3'd4: row8 = 8'h60;
                    3'd5: row8 = 8'h60;
                    3'd6: row8 = 8'h60;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd13: begin // P
                case (y)
                    3'd0: row8 = 8'h7C;
                    3'd1: row8 = 8'h66;
                    3'd2: row8 = 8'h66;
                    3'd3: row8 = 8'h7C;
                    3'd4: row8 = 8'h60;
                    3'd5: row8 = 8'h60;
                    3'd6: row8 = 8'h60;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd14: begin // S
                case (y)
                    3'd0: row8 = 8'h3C;
                    3'd1: row8 = 8'h66;
                    3'd2: row8 = 8'h60;
                    3'd3: row8 = 8'h3C;
                    3'd4: row8 = 8'h06;
                    3'd5: row8 = 8'h66;
                    3'd6: row8 = 8'h3C;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd15: begin // L
                case (y)
                    3'd0: row8 = 8'h60;
                    3'd1: row8 = 8'h60;
                    3'd2: row8 = 8'h60;
                    3'd3: row8 = 8'h60;
                    3'd4: row8 = 8'h60;
                    3'd5: row8 = 8'h60;
                    3'd6: row8 = 8'h7E;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd16: begin // I
                case (y)
                    3'd0: row8 = 8'h3C;
                    3'd1: row8 = 8'h18;
                    3'd2: row8 = 8'h18;
                    3'd3: row8 = 8'h18;
                    3'd4: row8 = 8'h18;
                    3'd5: row8 = 8'h18;
                    3'd6: row8 = 8'h3C;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd17: begin // T
                case (y)
                    3'd0: row8 = 8'h7E;
                    3'd1: row8 = 8'h18;
                    3'd2: row8 = 8'h18;
                    3'd3: row8 = 8'h18;
                    3'd4: row8 = 8'h18;
                    3'd5: row8 = 8'h18;
                    3'd6: row8 = 8'h18;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd18: begin // U
                case (y)
                    3'd0: row8 = 8'h66;
                    3'd1: row8 = 8'h66;
                    3'd2: row8 = 8'h66;
                    3'd3: row8 = 8'h66;
                    3'd4: row8 = 8'h66;
                    3'd5: row8 = 8'h66;
                    3'd6: row8 = 8'h3C;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            5'd19: begin // Y
                case (y)
                    3'd0: row8 = 8'h66;
                    3'd1: row8 = 8'h66;
                    3'd2: row8 = 8'h66;
                    3'd3: row8 = 8'h3C;
                    3'd4: row8 = 8'h18;
                    3'd5: row8 = 8'h18;
                    3'd6: row8 = 8'h18;
                    3'd7: row8 = 8'h00;
                    default: row8 = 8'h00;
                endcase
            end
            default: row8 = 8'h00;
        endcase
    endfunction

    // Six columns.  Digits are codes 2..11.  fps above 99 is shown as 99.
    function automatic logic [4:0] cell_code(
        input int          col,
        input int          row,
        input logic        view_full,
        input logic        cursor,
        input logic [1:0]  style,
        input logic [6:0]  fps
    );
        logic [6:0] f;
        logic [3:0] tens, ones;
        cell_code = 5'd0;
        f = (fps > 7'd99) ? 7'd99 : fps;
        tens = fps_tens(f);
        ones = fps_ones(f);
        if (col < 0 || col >= OSD_COLS || row < 0 || row >= OSD_ROWS)
            cell_code = 5'd0;
        else if (row == 0) begin
            case (col)
                0: cell_code = 5'd12;                 // F
                1: cell_code = 5'd13;                 // P
                2: cell_code = 5'd14;                 // S
                3: cell_code = 5'd0;
                4: cell_code = 5'(5'd2 + tens);
                5: cell_code = 5'(5'd2 + ones);
                default: cell_code = 5'd0;
            endcase
        end else if (row == 1) begin
            if (col == 0)
                cell_code = (cursor == 1'b0) ? 5'd1 : 5'd0;
            else if (!view_full) begin
                case (col)
                    1: cell_code = 5'd14;             // S
                    2: cell_code = 5'd13;             // P
                    3: cell_code = 5'd15;             // L
                    4: cell_code = 5'd16;             // I
                    5: cell_code = 5'd17;             // T
                    default: cell_code = 5'd0;
                endcase
            end else begin
                case (col)
                    1: cell_code = 5'd12;             // F
                    2: cell_code = 5'd18;             // U
                    3: cell_code = 5'd15;             // L
                    4: cell_code = 5'd15;             // L
                    5: cell_code = 5'd0;
                    default: cell_code = 5'd0;
                endcase
            end
        end else begin
            case (col)
                0: cell_code = (cursor == 1'b1) ? 5'd1 : 5'd0;
                1: cell_code = 5'd14;                 // S
                2: cell_code = 5'd17;                 // T
                3: cell_code = 5'd19;                 // Y
                4: cell_code = 5'd0;
                5: cell_code = 5'(5'd2 + style);
                default: cell_code = 5'd0;
            endcase
        end
    endfunction

    function automatic logic in_cell(
        input  logic [12:0] x,
        input  logic [12:0] y,
        output logic [2:0]  col,
        output logic [1:0]  row,
        output logic [2:0]  gx,
        output logic [4:0]  gy
    );
        logic [12:0] dx, dy;
        in_cell = 1'b0;
        col = '0;
        row = '0;
        gx  = '0;
        gy  = '0;
        if (x >= 13'(OSD_X0) && y >= 13'(OSD_Y0)) begin
            dx = x - 13'(OSD_X0);
            dy = y - 13'(OSD_Y0);
            if (dx < 13'(OSD_COLS * OSD_GW) && dy < 13'(OSD_ROWS * OSD_PITCH)) begin
                in_cell = 1'b1;
                col = dx[5:3];
                gx  = dx[2:0];
                if (dy < 13'(OSD_PITCH)) begin
                    row = 2'd0;
                    gy  = dy[4:0];
                end else if (dy < 13'(2 * OSD_PITCH)) begin
                    row = 2'd1;
                    gy  = 5'(dy - 13'(OSD_PITCH));
                end else begin
                    row = 2'd2;
                    gy  = 5'(dy - 13'(2 * OSD_PITCH));
                end
            end
        end
    endfunction

    function automatic logic lit(
        input logic [12:0] x,
        input logic [12:0] y,
        input logic        view_full,
        input logic        cursor,
        input logic [1:0]  style,
        input logic [6:0]  fps
    );
        logic [2:0] col;
        logic [1:0] row;
        logic [2:0] gx;
        logic [4:0] gy;
        logic [7:0] bits;
        lit = 1'b0;
        if (in_cell(x, y, col, row, gx, gy) && gy < 5'(OSD_GH)) begin
            bits = row8(cell_code(int'(col), int'(row), view_full, cursor, style, fps), gy[3:1]);
            lit  = bits[~gx];
        end
    endfunction

    // Row 0 is never yellow.  Row 1 is yellow while it is selected (cursor 0),
    // row 2 while cursor is 1.  Gaps stay unlit, so this only colours ink.
    function automatic logic yellow(
        input logic [12:0] x,
        input logic [12:0] y,
        input logic        cursor
    );
        logic [12:0] dx, dy;
        logic [1:0]  row;
        yellow = 1'b0;
        row = '0;
        if (x >= 13'(OSD_X0) && y >= 13'(OSD_Y0)) begin
            dx = x - 13'(OSD_X0);
            dy = y - 13'(OSD_Y0);
            if (dx < 13'(OSD_COLS * OSD_GW) && dy < 13'(OSD_ROWS * OSD_PITCH)) begin
                if (dy < 13'(OSD_PITCH))
                    row = 2'd0;
                else if (dy < 13'(2 * OSD_PITCH))
                    row = 2'd1;
                else
                    row = 2'd2;
                if (row == 2'd1 && cursor == 1'b0)
                    yellow = 1'b1;
                else if (row == 2'd2 && cursor == 1'b1)
                    yellow = 1'b1;
            end
        end
    endfunction
endpackage

