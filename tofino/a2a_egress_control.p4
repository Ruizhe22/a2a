control A2AEgress(
    inout a2a_headers_t hdr,
    inout a2a_egress_metadata_t eg_md,
    in egress_intrinsic_metadata_t eg_intr_md,
    in egress_intrinsic_metadata_from_parser_t eg_prsr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
    inout egress_intrinsic_metadata_for_output_port_t eg_oport_md)
{
    DispatchEgress() dispatch_egress;
    CombineEgress() combine_egress;
    
    apply {
        // eg_md.bridge.ing_rank_id     = (bit<32>)hdr.bridge.ing_rank_id;
        // eg_md.bridge.has_reth        = hdr.bridge.has_reth;
        // eg_md.bridge.has_aeth        = hdr.bridge.has_aeth;
        // eg_md.bridge.has_payload     = hdr.bridge.has_payload;
        // eg_md.bridge.conn_phase      = hdr.bridge.conn_phase;
        // eg_md.bridge.conn_semantics  = hdr.bridge.conn_semantics;
        // eg_md.bridge.channel_id      = hdr.bridge.channel_id;
        // eg_md.bridge.bitmap          = hdr.bridge.bitmap;
        // eg_md.bridge.tx_loc_val      = (bit<32>)hdr.bridge.tx_loc_val;
        // eg_md.bridge.tx_offset_val   = (bit<32>)hdr.bridge.tx_offset_val;
        // eg_md.bridge.clear_offset    = (bit<32>)hdr.bridge.clear_offset;
        // eg_md.bridge.is_loopback     = hdr.bridge.is_loopback;
        // eg_md.bridge.root_rank_id    = (bit<32>)hdr.bridge.root_rank_id;
        // eg_md.bridge.next_token_addr = hdr.bridge.next_token_addr;

        eg_md.psn = hdr.bth.psn;

        if (hdr.bridge.conn_phase == CONN_PHASE.CONN_DISPATCH) {
            dispatch_egress.apply(hdr, eg_md, eg_intr_md, eg_dprsr_md);
        } else if (hdr.bridge.conn_phase == CONN_PHASE.CONN_COMBINE) {
            combine_egress.apply(hdr, eg_md, eg_intr_md, eg_dprsr_md);
        }
    }
}

control A2AEgressDeparser(
        packet_out pkt,
        inout a2a_headers_t hdr,
        in a2a_egress_metadata_t eg_md,
        in egress_intrinsic_metadata_for_deparser_t eg_dprsr_md) {
    apply {
        pkt.emit(hdr);
    }
}