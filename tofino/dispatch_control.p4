#define NUM_DISPATCH_CHANNELS 8
#define DISPATCH_TX_CHANNELS (EP_SIZE * NUM_DISPATCH_CHANNELS)
#define DISPATCH_RX_ENTRIES (EP_SIZE * NUM_DISPATCH_CHANNELS * EP_SIZE)

control DispatchIngress(
    inout a2a_ingress_headers_t hdr,
    inout a2a_ingress_metadata_t ig_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md)
{
    /* tx_epsn */
    Register<bit<32>, bit<32>>(DISPATCH_TX_CHANNELS) reg_tx_epsn;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_epsn) ra_read_tx_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_epsn) ra_read_inc_tx_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_epsn) ra_write_tx_epsn = {
        void apply(inout bit<32> value) {
            value = ig_md.dispatch.expected_psn;
        }
    };

    /* tx_msn */
    Register<bit<32>, bit<32>>(DISPATCH_TX_CHANNELS) reg_tx_msn;
    
    RegisterAction<bit<32>, bit<32>, void>(reg_tx_epsn) ra_invalidate_tx_epsn = {
        void apply(inout bit<32> value) {
            value = 0xFFFFFFFF;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_msn) ra_read_tx_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_msn) ra_read_inc_tx_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, void>(reg_tx_msn) ra_reset_tx_msn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    /* tx_bitmap */
    Register<bit<64>, bit<32>>(DISPATCH_TX_CHANNELS) reg_tx_bitmap;
    
    RegisterAction<bit<64>, bit<32>, bit<64>>(reg_tx_bitmap) ra_read_tx_bitmap = {
        void apply(inout bit<64> value, out bit<64> result) {
            result = value;
        }
    };
    
    RegisterAction<bit<64>, bit<32>, void>(reg_tx_bitmap) ra_write_tx_bitmap = {
        void apply(inout bit<64> value) {
            value = ig_md.dispatch.bitmap;
        }
    };
    
    /***************************************************************************
     * Tables
     ***************************************************************************/
    
    action set_mcast_group(bit<16> mcast_grp) {
        ig_tm_md.mcast_grp_a = mcast_grp;
    }
    
    table tbl_dispatch_bitmap_to_mcast {
        key = {
            ig_md.dispatch.bitmap : exact;
        }
        actions = {
            set_mcast_group;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }
    
    /***************************************************************************
     * Actions
     ***************************************************************************/
    
    action swap_l2_l3_l4() {
        bit<48> tmp_mac = hdr.eth.src_addr;
        hdr.eth.src_addr = hdr.eth.dst_addr;
        hdr.eth.dst_addr = tmp_mac;
        
        bit<32> tmp_ip = hdr.ipv4.src_addr;
        hdr.ipv4.src_addr = hdr.ipv4.dst_addr;
        hdr.ipv4.dst_addr = tmp_ip;
        
        bit<16> tmp_port = hdr.udp.src_port;
        hdr.udp.src_port = hdr.udp.dst_port;
        hdr.udp.dst_port = tmp_port;
    }
    
    action set_ack_headers(bit<8> syndrome, bit<24> psn, bit<24> msn) {
        hdr.bth.opcode = RDMA_OP_ACK;
        hdr.bth.psn = psn;
        hdr.aeth.setValid();
        hdr.aeth.syndrome = syndrome;
        hdr.aeth.msn = msn;
        hdr.reth.setInvalid();
        hdr.payload.setInvalid();
    }
    
    action calc_payload_len() {
        bit<16> len = hdr.udp.length - 8 - 12 - 4;
        if (hdr.reth.isValid()) {
            len = len - 16;
        }
        if (hdr.aeth.isValid()) {
            len = len - 4;
        }
        ig_md.dispatch.payload_len = len;
    }
    
    /***************************************************************************
     * Apply
     ***************************************************************************/
    
    apply {
        ig_md.dispatch.pkt_psn = (bit<32>)hdr.bth.psn;
        
        // 处理来自rx的ACK/NAK
        if (ig_md.dispatch.conn_type == CONN_RX && hdr.bth.opcode == RDMA_OP_ACK) {
            if (hdr.aeth.syndrome != AETH_ACK) {
                ra_invalidate_tx_epsn.execute(ig_md.dispatch.tx_reg_idx);
            }
            ig_dprsr_md.drop_ctl = 1;
            return;
        }
        
        // 处理控制连接
        if (ig_md.dispatch.conn_type == CONN_CONTROL) {
            ra_reset_tx_msn.execute(ig_md.dispatch.tx_reg_idx);
            ig_md.dispatch.expected_psn = ig_md.dispatch.pkt_psn + 1;
            ra_write_tx_epsn.execute(ig_md.dispatch.tx_reg_idx);
            
            swap_l2_l3_l4();
            set_ack_headers(AETH_ACK, hdr.bth.psn, 0);
            ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            return;
        }
        
        // 处理数据连接
        if (ig_md.dispatch.conn_type == CONN_DATA) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_FIRST && 
                hdr.bth.opcode != RDMA_OP_WRITE_MIDDLE &&
                hdr.bth.opcode != RDMA_OP_WRITE_LAST &&
                hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }
            
            // PSN验证
            bit<32> expected = ra_read_tx_epsn.execute(ig_md.dispatch.tx_reg_idx);
            ig_md.dispatch.expected_psn = expected;
            
            if (ig_md.dispatch.pkt_psn == expected) {
                ig_md.dispatch.psn_status = 0;
            } else if (ig_md.dispatch.pkt_psn > expected) {
                ig_md.dispatch.psn_status = 1;
            } else {
                ig_md.dispatch.psn_status = 2;
            }
            
            // PSN不匹配处理
            if (ig_md.dispatch.psn_status == 1) {
                ig_md.dispatch.current_msn = ra_read_tx_msn.execute(ig_md.dispatch.tx_reg_idx);
                swap_l2_l3_l4();
                set_ack_headers(AETH_NAK_PSN_SEQ, (bit<24>)(expected - 1), (bit<24>)ig_md.dispatch.current_msn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                return;
            }
            
            if (ig_md.dispatch.psn_status == 2) {
                ig_md.dispatch.current_msn = ra_read_tx_msn.execute(ig_md.dispatch.tx_reg_idx);
                swap_l2_l3_l4();
                set_ack_headers(AETH_ACK, (bit<24>)(expected - 1), (bit<24>)ig_md.dispatch.current_msn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                return;
            }
            
            // PSN匹配，继续处理
            ra_read_inc_tx_epsn.execute(ig_md.dispatch.tx_reg_idx);
            
            // 获取bitmap
            if (hdr.bth.opcode == RDMA_OP_WRITE_FIRST || 
                hdr.bth.opcode == RDMA_OP_WRITE_ONLY) {
                ig_md.dispatch.bitmap = hdr.reth.vaddr;
                ig_md.dispatch.is_write_first_or_only = 1;
                ra_write_tx_bitmap.execute(ig_md.dispatch.tx_reg_idx);
            } else {
                ig_md.dispatch.bitmap = ra_read_tx_bitmap.execute(ig_md.dispatch.tx_reg_idx);
                ig_md.dispatch.is_write_first_or_only = 0;
            }
            
            calc_payload_len();
            tbl_dispatch_bitmap_to_mcast.apply();
            
            // MSN处理
            if (hdr.bth.opcode == RDMA_OP_WRITE_ONLY || 
                hdr.bth.opcode == RDMA_OP_WRITE_LAST) {
                ig_md.dispatch.current_msn = ra_read_inc_tx_msn.execute(ig_md.dispatch.tx_reg_idx);
            } else {
                ig_md.dispatch.current_msn = ra_read_tx_msn.execute(ig_md.dispatch.tx_reg_idx);
            }
            
            // Clone用于ACK
            ig_dprsr_md.mirror_type = 1;
        }
    }
}