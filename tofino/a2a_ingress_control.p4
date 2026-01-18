control A2AIngress(
    inout a2a_headers_t hdr,
    inout a2a_ingress_metadata_t ig_md,
    in ingress_intrinsic_metadata_t ig_intr_md,
    in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md)
{
    // subcontrol modules instantiation
    DispatchIngress() dispatch_ctrl;
    CombineIngress() combine_ctrl;
    
    /*
     * Traffic Classification Table
     * Classify dispatch and combine traffic based on QP, IP, etc.
     */
    
    action set_a2a_traffic(CONN_PHASE conn_phase, CONN_SEMANTICS conn_semantics, bit<32> channel_id, bit<32> channel_class, bit<8> ing_rank_id, bit<8> root_rank_id) {
        ig_md.bridge.conn_phase = conn_phase;
        ig_md.bridge.conn_semantics = conn_semantics;
        ig_md.bridge.channel_id = channel_id;
        ig_md.bridge.ing_rank_id = ing_rank_id;
        ig_md.bridge.root_rank_id = root_rank_id;
        ig_md.channel_class = channel_class;
    }

    action set_unknown_traffic() {
        ig_md.bridge.conn_phase = CONN_PHASE.CONN_UNKNOWN;
    }
    
    // classification table: distinguish traffic type and connection info based on QPN and IPs
    table traffic_classify {
        key = {
            hdr.ipv4.src_addr : exact;
            hdr.ipv4.dst_addr : exact;
            hdr.bth.dst_qp : exact;
        }
        actions = {
            set_a2a_traffic;
            set_unknown_traffic;
        }
        size = 32768;
        default_action = set_unknown_traffic;
    }
    
    apply {
        // Process only RoCE packets
        if (!ig_md.is_roce) {
            ig_dprsr_md.drop_ctl = 1;
            return;
        }

        ig_md.psn = hdr.bth.psn;
        if(hdr.aeth.isValid()){
            ig_md.msn = hdr.aeth.msn & 32w0xFFFFFF00;
            ig_md.syndrome = hdr.aeth.msn & 32w0x000000FF;
        }
        // Traffic classification
        traffic_classify.apply();
        
        // Invoke corresponding processing logic based on traffic type
        if (ig_md.bridge.conn_phase == CONN_PHASE.CONN_DISPATCH) {
            dispatch_ctrl.apply(hdr, ig_md, ig_intr_md, ig_dprsr_md, ig_tm_md);
        } else if (ig_md.bridge.conn_phase == CONN_PHASE.CONN_COMBINE) {
            combine_ctrl.apply(hdr, ig_md, ig_intr_md, ig_dprsr_md, ig_tm_md);
        } else {
            // drop unknown traffic
            ig_dprsr_md.drop_ctl = 1;
        }
    }
}

control A2AIngressDeparser(
        packet_out pkt,
        inout a2a_headers_t hdr,
        in a2a_ingress_metadata_t ig_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md) {

    apply {
        pkt.emit(ig_md.bridge);
        pkt.emit(hdr);
    }
}