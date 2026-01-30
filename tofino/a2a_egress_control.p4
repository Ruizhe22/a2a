/**
 * @file a2a_egress_control.p4
 * @brief Egress control logic for A2A packet processing
 *
 * Main egress pipeline that processes packets based on connection phase
 * and dispatches to Dispatch or Combine egress sub-controls.
 */

/* =============================================================================
 * A2A Egress Control
 * ============================================================================= */

control A2AEgress(
    inout a2a_headers_t                            hdr,
    inout a2a_egress_metadata_t                    eg_md,
    in    egress_intrinsic_metadata_t              eg_intr_md,
    in    egress_intrinsic_metadata_from_parser_t  eg_prsr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
    inout egress_intrinsic_metadata_for_output_port_t eg_oport_md)
{
    /* =========================================================================
     * Sub-Control Module Instantiation
     * ========================================================================= */

    DispatchEgress() dispatch_egress;
    CombineEgress()  combine_egress;

    /* =========================================================================
     * Apply Block
     * ========================================================================= */

    apply {
        /* Copy bridge header fields to egress metadata */
        eg_md.ing_rank_id     = hdr.bridge.ing_rank_id;
        eg_md.has_reth        = (bool)hdr.bridge.has_reth;
        eg_md.has_aeth        = (bool)hdr.bridge.has_aeth;
        eg_md.has_payload     = (bool)hdr.bridge.has_payload;
        eg_md.is_loopback     = (bool)hdr.bridge.is_loopback;
        eg_md.conn_phase      = hdr.bridge.conn_phase;
        eg_md.conn_semantics  = hdr.bridge.conn_semantics;
        eg_md.channel_id      = hdr.bridge.channel_id;
        eg_md.bitmap          = hdr.bridge.bitmap;
        eg_md.tx_loc_val      = hdr.bridge.tx_loc_val;
        eg_md.tx_offset_val   = hdr.bridge.tx_offset_val;
        eg_md.root_rank_id    = hdr.bridge.root_rank_id;
        eg_md.next_token_addr = hdr.bridge.next_token_addr;
        eg_md.agg_op          = hdr.bridge.agg_op;

        /* Extract PSN from BTH */
        eg_md.psn = hdr.bth.psn;

        /* Extract egress replication ID */
        eg_md.egress_rid = (bit<32>)eg_intr_md.egress_rid;

        /* Dispatch to appropriate sub-control based on connection phase */
        if (hdr.bridge.conn_phase == CONN_PHASE.CONN_DISPATCH) {
            dispatch_egress.apply(hdr, eg_md, eg_intr_md, eg_dprsr_md);
        } else if (hdr.bridge.conn_phase == CONN_PHASE.CONN_COMBINE) {
            combine_egress.apply(hdr, eg_md, eg_intr_md, eg_dprsr_md);
        }
    }
}

/* =============================================================================
 * A2A Egress Deparser
 * ============================================================================= */

control A2AEgressDeparser(
    packet_out                                     pkt,
    inout a2a_headers_t                            hdr,
    in    a2a_egress_metadata_t                    eg_md,
    in    egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    apply {
        pkt.emit(hdr);
    }
}
