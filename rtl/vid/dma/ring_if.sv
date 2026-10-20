// ring_if.sv -- the frame-handoff contract between a frame_ring and its
// producer / consumers.
//
// Every operation is a request held until a one-cycle ack:
//   requester: drive op (and arguments), raise req, keep both stable;
//   ring:      on the ack cycle, results are valid; the requester drops req
//              (or issues the next operation) on the following cycle.
// Operations are rare (a few per frame) so the ring serves one per cycle.
//
// Producer:   ACQ  -> ok, slot     (ok = 0: no free slot, skip this frame)
//             COMMIT(src_seq)       the slot becomes the latest frame
//             ABORT                 the slot is discarded
// Consumer:   ACQ(policy) -> ok, token
//             REL                   done with the held frame
//
// Rules (asserted in frame_ring_core):
//   * a producer commits or aborts only while it holds a slot, and holds at
//     most one;
//   * a consumer releases only while it holds a frame, and holds at most one;
//   * a slot is never handed to the producer while any consumer holds it or
//     while it is the latest frame.

interface ring_prod_if;
    import vid_pkg::*;
    logic                   req;
    ring_p_op_e             op;
    logic [SEQ_W-1:0]       src_seq;
    logic                   ack;
    logic                   ok;
    logic [RING_SLOT_W-1:0] slot;

    modport user (output req, op, src_seq, input ack, ok, slot);
    modport ring (input req, op, src_seq, output ack, ok, slot);
endinterface

interface ring_cons_if;
    import vid_pkg::*;
    logic         req;
    ring_c_op_e   op;
    acq_policy_e  policy;
    logic         ack;
    logic         ok;
    frame_token_t token;

    modport user (output req, op, policy, input ack, ok, token);
    modport ring (input req, op, policy, output ack, ok, token);
endinterface
