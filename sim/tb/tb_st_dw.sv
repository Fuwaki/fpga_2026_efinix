// tb_st_dw.sv -- one st_dw configuration against tools/st_dw_vectors.py.
//
// The case directory ($CASE_DIR) holds cfg.txt (name value lines), in.hex and
// out.hex, one beat per line as "data last eol sof".  An input beat's data is
// 10 hex digits (four 10-bit lanes); an output beat's is 32 hex digits, the
// 128-bit out_wide word, of which DW and BYPASS fill the low 40 bits and
// IM2COL all 128.  The driver streams in.hex with random valid gaps, the sink
// takes out.hex's rate with random ready gaps (30% low), and the checker
// compares every output beat and its three flags, in order, against out.hex:
// a dropped, duplicated or reordered beat fails.
//
// DW cases with a synthetic network also carry dw.hex and rq.hex, which are
// loaded over the ROM instances' images; the real cases use the committed
// generated hex the ROMs read at elaboration.
//
// Output:
//   tb_st_dw <case> PASS <n> beats, <cycles> cycles, <cpi> cycles/input beat
//   tb_st_dw <case> PASS <n> beats, <cycles> cycles, <cpi> cycles/input beat
//     (clean: no input gaps and ready always high)
// followed by the clean run's throughput, so the Makefile can print it.
//
//   +CASE_DIR=<dir>   the case directory
//   +CLEAN=1          no input valid gaps, out_ready always high
//   +MAX_CYCLES=<n>   watchdog in cycles (default 40x the input beats)
module tb_st_dw;
    localparam int MAXB = 1 << 21;      // beats the testbench can hold

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ------------------------------------------------------- configuration
    logic        start = 0;
    logic        busy;
    logic [1:0]  cfg_mode = 0;
    logic [9:0]  cfg_w = 0, cfg_h = 0;
    logic [4:0]  cfg_g = 1;
    logic [1:0]  cfg_stride = 1;
    logic [9:0]  cfg_dw_base = 0;
    logic [10:0] cfg_rq_base = 0;
    logic signed [9:0] cfg_lo = 0, cfg_hi = 127;

    // ------------------------------------------------------------- streams
    logic        in_valid = 0;
    logic        in_ready;
    logic [39:0] in_data = 0;
    logic        in_last = 0, in_eol = 0, in_sof = 0;

    logic         out_valid;
    logic         out_ready = 0;
    logic  [39:0] out_data;
    logic [127:0] out_wide;
    logic         out_last, out_eol, out_sof;

    st_dw dut (
        .clk (clk), .rst_n (rst_n),
        .start (start), .busy (busy),
        .cfg_mode (cfg_mode), .cfg_w (cfg_w), .cfg_h (cfg_h), .cfg_g (cfg_g),
        .cfg_stride (cfg_stride), .cfg_dw_base (cfg_dw_base),
        .cfg_rq_base (cfg_rq_base), .cfg_lo (cfg_lo), .cfg_hi (cfg_hi),
        .in_valid (in_valid), .in_ready (in_ready), .in_data (in_data),
        .in_last (in_last), .in_eol (in_eol), .in_sof (in_sof),
        .out_valid (out_valid), .out_ready (out_ready), .out_data (out_data),
        .out_wide (out_wide),
        .out_last (out_last), .out_eol (out_eol), .out_sof (out_sof)
    );

    // ------------------------------------------------------------- vectors
    logic [39:0] vin_data [MAXB];
    logic        vin_last [MAXB], vin_eol [MAXB], vin_sof [MAXB];
    logic [127:0] vout_data [MAXB];
    logic        vout_last [MAXB], vout_eol [MAXB], vout_sof [MAXB];
    int  nin  = 0;
    int  nout = 0;

    string case_dir = "";
    string case_name = "";
    bit    clean = 0;
    longint max_cycles = 0;

    // both files are read into one 128-bit word: an input beat's 40-bit data
    // only fills the low bits, which is what the driver presents
    function automatic int load_hex(input string path, input bit is_out);
        int fd, k;
        logic [127:0] d;
        logic la, e, s;
        k = 0;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "tb_st_dw: cannot open %s", path);
        while (k < MAXB && $fscanf(fd, "%h %b %b %b\n", d, la, e, s) == 4) begin
            if (is_out) begin
                vout_data[k] = d;
                vout_last[k] = la;
                vout_eol[k]  = e;
                vout_sof[k]  = s;
            end else begin
                vin_data[k] = d[39:0];
                vin_last[k] = la;
                vin_eol[k]  = e;
                vin_sof[k]  = s;
            end
            k++;
        end
        $fclose(fd);
        return k;
    endfunction

    initial begin
        int fd, got;
        string line, key, val;
        bit is_out;

        if (!$value$plusargs("CASE_DIR=%s", case_dir))
            $fatal(1, "tb_st_dw: +CASE_DIR=<dir> is required");
        if ($value$plusargs("CLEAN=%d", got)) clean = (got != 0);
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles))
            max_cycles = 0;

        fd = $fopen({case_dir, "/cfg.txt"}, "r");
        if (fd == 0) $fatal(1, "tb_st_dw: cannot open %s/cfg.txt", case_dir);
        while ($fgets(line, fd) > 0) begin
            if ($sscanf(line, "%s %d", key, got) != 2) continue;
            case (key)
                "mode":      cfg_mode    = 2'(got);
                "w":         cfg_w       = 10'(got);
                "h":         cfg_h       = 10'(got);
                "g":         cfg_g       = 5'(got);
                "stride":    cfg_stride  = 2'(got);
                "dw_base":   cfg_dw_base = 10'(got);
                "rq_base":   cfg_rq_base = 11'(got);
                "lo":        cfg_lo      = 10'(got);
                "hi":        cfg_hi      = 10'(got);
                default: $fatal(1, "tb_st_dw: unknown cfg key %s", key);
            endcase
        end
        $fclose(fd);

        case_name = case_dir;
        for (int i = case_dir.len() - 1; i >= 0; i--)
            if (case_dir[i] == "/") begin
                case_name = case_dir.substr(i + 1, case_dir.len() - 1);
                break;
            end

        // Per-case ROM images, if the case carries them.  The ROMs' own
        // initial blocks run at time 0 after this one, so the load has to
        // happen after them: #1 puts it in the same slot as the reset
        // sequence, and each load() is a plain procedural task.
        #1;
        fd = $fopen({case_dir, "/dw.hex"}, "r");
        if (fd != 0) begin
            $fclose(fd);
            dut.u_dw_rom.load({case_dir, "/dw.hex"});
        end
        fd = $fopen({case_dir, "/rq.hex"}, "r");
        if (fd != 0) begin
            $fclose(fd);
            dut.u_rq_rom.load({case_dir, "/rq.hex"});
        end

        is_out = 1'b0;
        nin    = load_hex({case_dir, "/in.hex"}, is_out);
        is_out = 1'b1;
        nout   = load_hex({case_dir, "/out.hex"}, is_out);
        if (nin == 0 || nout == 0)
            $fatal(1, "tb_st_dw: %d input and %d expected beats", nin, nout);
        if (max_cycles == 0) max_cycles = 40 * longint'(nin) + 4096;
        $display("tb_st_dw %s: mode %0d, %0dx%0d, g %0d, stride %0d, %0d in, %0d out%s",
                 case_name, cfg_mode, cfg_w, cfg_h, cfg_g, cfg_stride,
                 nin, nout, clean ? ", clean" : "");
        if (cfg_mode == 2 && nin != nout)
            $fatal(1, "tb_st_dw: bypass must not change the beat count");
        if (cfg_mode == 1 && nout != 2 * nin)
            $fatal(1, "tb_st_dw: im2col must emit two beats per input beat");
    end

    // -------------------------------------------------------------- driver
    // idx is the beat presented now.  A handshake is sampled at the posedge
    // (that is where the DUT takes it); the negedge then either sets up the
    // next beat, or holds the line idle for a random gap.  in_valid and the
    // payload only change at a negedge, so a beat is never presented twice.
    int idx = 0;
    int gap = 0;
    bit taken = 0;

    task automatic present(input int k);
        in_valid <= 1'b1;
        in_data  <= vin_data[k];
        in_last  <= vin_last[k];
        in_eol   <= vin_eol[k];
        in_sof   <= vin_sof[k];
    endtask

    always @(posedge clk)
        taken <= rst_n && in_valid && in_ready;

    always @(posedge clk)
        if (rst_n && in_valid && in_ready)
            idx <= idx + 1;

    always @(negedge clk) begin
        if (!rst_n) begin
            in_valid <= 1'b0;
            in_data  <= 'x;
            in_last  <= 1'bx;
            in_eol   <= 1'bx;
            in_sof   <= 1'bx;
            gap      <= 0;
        end else if (gap != 0) begin
            gap      <= gap - 1;
            in_valid <= 1'b0;
        end else if (taken) begin
            if (!clean && $urandom_range(99) < 30) begin
                gap      <= $urandom_range(1, 3);
                in_valid <= 1'b0;
            end else if (idx < nin) begin
                present(idx);
            end else begin
                in_valid <= 1'b0;
            end
        end else if (!in_valid && idx < nin) begin
            present(idx);
        end
    end

    // --------------------------------------------------------------- sink
    int oidx = 0;
    int errs = 0;

    always @(negedge clk) begin
        if (!rst_n)
            out_ready <= 1'b0;
        else
            out_ready <= clean ? 1'b1 : ($urandom_range(99) >= 30);
    end

    function automatic string flags(input bit l, e, s);
        return $sformatf("%b%b%b", l, e, s);
    endfunction

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            if (oidx >= nout) begin
                errs++;
                if (errs <= 10)
                    $display("MISMATCH: unexpected output beat %0d (data %032x flags %s)",
                             oidx, out_wide, flags(out_last, out_eol, out_sof));
            end else begin
                if (out_wide !== vout_data[oidx] ||
                    out_last !== vout_last[oidx] ||
                    out_eol  !== vout_eol[oidx] ||
                    out_sof  !== vout_sof[oidx]) begin
                    errs++;
                    if (errs <= 10)
                        $display("MISMATCH beat %0d: data %032x flags %s, want %032x flags %s",
                                 oidx, out_wide, flags(out_last, out_eol, out_sof),
                                 vout_data[oidx], flags(vout_last[oidx], vout_eol[oidx],
                                                        vout_sof[oidx]));
                end
                // IM2COL is the one mode that does not carry the beat on
                // out_data (it is zero there); the other two mirror the low
                // 40 bits of out_wide
                if (cfg_mode == 2'd1) begin
                    if (out_data !== 40'd0) begin
                        errs++;
                        if (errs <= 10)
                            $display("MISMATCH beat %0d: im2col out_data %010x is not 0",
                                     oidx, out_data);
                    end
                end else if (out_data !== out_wide[39:0]) begin
                    errs++;
                    if (errs <= 10)
                        $display("MISMATCH beat %0d: out_data %010x does not mirror out_wide",
                                 oidx, out_data);
                end
                oidx <= oidx + 1;
            end
        end
    end

    // ------------------------------------------------------- run and report
    longint cyc = 0;
    longint t_first = -1, t_last = -1, t_in_first = -1, t_in_last = -1;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (rst_n) begin
            if (in_valid && in_ready) begin
                if (t_in_first < 0) t_in_first <= cyc;
                t_in_last <= cyc;
            end
            if (out_valid && out_ready) begin
                if (t_first < 0) t_first <= cyc;
                t_last <= cyc;
            end
        end
    end

    initial begin
        real cpi, cpb;
        start = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        while (busy || oidx < nout) begin
            @(posedge clk);
            if (cyc > max_cycles)
                $fatal(1, "tb_st_dw FAIL %s: watchdog after %0d cycles, %0d of %0d beats, %0d errors",
                       case_name, cyc, oidx, nout, errs);
        end
        repeat (4) @(posedge clk);

        cpb = (t_last - t_in_first + 1);
        cpi = cpb / real'(nin);
        if (errs != 0 || oidx != nout)
            $fatal(1, "tb_st_dw FAIL %s: %0d mismatches, %0d of %0d beats out, %0d cycles",
                   case_name, errs, oidx, nout, cyc);
        $display("tb_st_dw %s PASS %0d beats, %0d cycles, %0.3f cycles/input beat%s",
                 case_name, nout, cyc, cpi, clean ? " (clean)" : "");
        $finish;
    end
endmodule
