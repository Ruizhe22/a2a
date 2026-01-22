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
    
    action set_a2a_traffic(CONN_PHASE conn_phase, CONN_SEMANTICS conn_semantics, bit<32> channel_id, bit<32> channel_class, bit<32> ing_rank_id, bit<32> root_rank_id) {
        ig_md.conn_phase = conn_phase;
        ig_md.conn_semantics = conn_semantics;
        ig_md.channel_id = channel_id;
        ig_md.ing_rank_id = ing_rank_id;
        ig_md.root_rank_id = root_rank_id;
        ig_md.channel_class = channel_class;
    }

    action set_unknown_traffic() {
        ig_md.conn_phase = CONN_PHASE.CONN_UNKNOWN;
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

    action set_bridge_ing_rank_id() {
        hdr.bridge.ing_rank_id = ig_md.ing_rank_id;
    }

    action set_bridge_has_reth() {
        hdr.bridge.has_reth = ig_md.has_reth;
    }

    action set_bridge_has_aeth() {
        hdr.bridge.has_aeth = ig_md.has_aeth;
    }

    action set_bridge_has_payload() {
        hdr.bridge.has_payload = ig_md.has_payload;
    }

    action set_bridge_conn_phase() {
        hdr.bridge.conn_phase = ig_md.conn_phase;
    }

    action set_bridge_conn_semantics() {
        hdr.bridge.conn_semantics = ig_md.conn_semantics;
    }

    action set_bridge_channel_id() {
        hdr.bridge.channel_id = ig_md.channel_id;
    }

    action set_bridge_bitmap() {
        hdr.bridge.bitmap = ig_md.bitmap;
    }

    action set_bridge_tx_loc_val() {
        hdr.bridge.tx_loc_val = ig_md.tx_loc_val;
    }

    action set_bridge_tx_offset_val() {
        hdr.bridge.tx_offset_val = ig_md.tx_offset_val;
    }

    action set_bridge_clear_offset() {
        hdr.bridge.clear_offset = ig_md.clear_offset;
    }

    action set_bridge_is_loopback() {
        hdr.bridge.is_loopback = ig_md.is_loopback;
    }

    action set_bridge_root_rank_id_lo() {
        hdr.bridge.root_rank_id[15:0] = ig_md.root_rank_id[15:0];
    }

    action set_bridge_root_rank_id_hi() {
        hdr.bridge.root_rank_id[31:16] = ig_md.root_rank_id[31:16];
    }

    action set_bridge_next_token_addr_hi() {
        hdr.bridge.next_token_addr[63:32] = ig_md.next_token_addr[63:32];
    }

    action set_bridge_next_token_addr_lo() {
        hdr.bridge.next_token_addr[31:0] = ig_md.next_token_addr[31:0];
    }

    
    
    apply {
        // Process only RoCE packets
        if (!ig_md.is_roce) {
            ig_dprsr_md.drop_ctl = 1;
            return;
        }

        ig_md.psn = hdr.bth.psn;
        ig_md.psn[0:0] = 0;
        if(hdr.aeth.isValid()){
            ig_md.msn = hdr.aeth.msn & 32w0xFFFFFF00;
            ig_md.syndrome = hdr.aeth.msn & 32w0x000000FF;
        }
        // Traffic classification
        traffic_classify.apply();
        
        // Invoke corresponding processing logic based on traffic type
        if (ig_md.conn_phase == CONN_PHASE.CONN_DISPATCH) {
            dispatch_ctrl.apply(hdr, ig_md, ig_intr_md, ig_dprsr_md, ig_tm_md);
        } else if (ig_md.conn_phase == CONN_PHASE.CONN_COMBINE) {
            combine_ctrl.apply(hdr, ig_md, ig_intr_md, ig_dprsr_md, ig_tm_md);
        } else {
            // drop unknown traffic
            ig_dprsr_md.drop_ctl = 1;
        }

        hdr.bridge.setValid();
        set_bridge_ing_rank_id();
        set_bridge_has_reth();
        set_bridge_has_aeth();
        set_bridge_has_payload();
        set_bridge_conn_phase();
        set_bridge_conn_semantics();
        set_bridge_channel_id();
        set_bridge_bitmap();
        set_bridge_tx_loc_val();
        set_bridge_tx_offset_val();
        set_bridge_clear_offset();
        set_bridge_is_loopback();
        set_bridge_root_rank_id_hi();
        set_bridge_root_rank_id_lo();
        set_bridge_next_token_addr_hi();
        set_bridge_next_token_addr_lo();
    }
}

control A2AIngressDeparser(
        packet_out pkt,
        inout a2a_headers_t hdr,
        in a2a_ingress_metadata_t ig_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md) {


    apply {
        pkt.emit(hdr);
    }
}