// frame_ring.sv -- interface view of frame_ring_core: one producer port and
// an array of consumer ports.  See ring_if.sv for the contract.
module frame_ring
    import vid_pkg::*;
#(
    parameter int SLOTS = 4,
    parameter int NCONS = 2
) (
    input  logic          clk,
    input  logic          rst_n,
    ring_prod_if.ring     p,
    ring_cons_if.ring     c [NCONS],
    output ring_status_t  status
);
    logic [NCONS-1:0] c_req, c_ack, c_ok;
    ring_c_op_e       c_op     [NCONS];
    acq_policy_e      c_policy [NCONS];
    frame_token_t     c_token  [NCONS];

    for (genvar i = 0; i < NCONS; i++) begin : g_cons
        assign c_req[i]    = c[i].req;
        assign c_op[i]     = c[i].op;
        assign c_policy[i] = c[i].policy;
        assign c[i].ack    = c_ack[i];
        assign c[i].ok     = c_ok[i];
        assign c[i].token  = c_token[i];
    end

    frame_ring_core #(.SLOTS(SLOTS), .NCONS(NCONS)) u_core (
        .clk          (clk),
        .rst_n        (rst_n),
        .p_req        (p.req),
        .p_op         (p.op),
        .p_src_seq    (p.src_seq),
        .p_ack        (p.ack),
        .p_ok         (p.ok),
        .p_slot       (p.slot),
        .c_req        (c_req),
        .c_op         (c_op),
        .c_policy     (c_policy),
        .c_ack        (c_ack),
        .c_ok         (c_ok),
        .c_token      (c_token),
        .st_commits   (status.commits),
        .st_drops     (status.drops),
        .st_aborts    (status.aborts),
        .st_proto_err (status.proto_err)
    );
endmodule
