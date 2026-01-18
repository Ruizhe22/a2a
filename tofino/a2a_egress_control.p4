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

        eg_md.psn = hdr.bth.psn;

        if (eg_md.bridge.conn_phase == CONN_PHASE.CONN_DISPATCH) {
            dispatch_egress.apply(hdr, eg_md, eg_intr_md, eg_dprsr_md);
        } else if (eg_md.bridge.conn_phase == CONN_PHASE.CONN_COMBINE) {
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