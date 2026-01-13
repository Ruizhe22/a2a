control CombineIngress(
    inout my_ingress_headers_t hdr,
    inout my_ingress_metadata_t ig_md,
    in ingress_intrinsic_metadata_t ig_intr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md)
{
    /***************************************************************************
     * Registers
     * Combine: 多个rx发送数据到一个tx，需要聚合
     ***************************************************************************/
    
    // rx_epsn: 期望从每个rx收到的PSN
    // Index: tx_id * NUM_CHANNELS * MAX_EP_SIZE + channel_id * MAX_EP_SIZE + rank_id
    Register<bit<32>, bit<32>>(MAX_RX_ENTRIES) reg_rx_epsn;
    
    // rx_msn: 每个rx连接的MSN
    Register<bit<32>, bit<32>>(MAX_RX_ENTRIES) reg_rx_msn;
    
    // tx_next_psn: 发给tx的下一个PSN
    // Index: tx_id * NUM_CHANNELS + channel_id
    Register<bit<32>, bit<32>>(MAX_TX_CHANNELS) reg_tx_next_psn;
    
    // tx_next_addr: 发给tx的下一个地址
    Register<bit<32>, bit<32>>(MAX_TX_CHANNELS) reg_tx_next_addr_hi;
    Register<bit<32>, bit<32>>(MAX_TX_CHANNELS) reg_tx_next_addr_lo;
    
    // 聚合计数器：统计已收到的数据数量
    Register<bit<32>, bit<32>>(MAX_TX_CHANNELS) reg_agg_counter;
    
    /***************************************************************************
     * RegisterActions
     ***************************************************************************/
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_epsn) ra_read_rx_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_epsn) ra_read_inc_rx_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, void>(reg_rx_epsn) ra_write_rx_epsn = {
        void apply(inout bit<32> value) {
            value = ig_md.combine.expected_psn;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, void>(reg_rx_epsn) ra_invalidate_rx_epsn = {
        void apply(inout bit<32> value) {
            value = 0xFFFFFFFF;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_msn) ra_read_rx_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_msn) ra_read_inc_rx_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, void>(reg_rx_msn) ra_reset_rx_msn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_next_psn) ra_read_inc_tx_psn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_next_addr_lo) ra_read_add_tx_addr_lo = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + (bit<32>)ig_md.combine.payload_len;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_next_addr_hi) ra_read_tx_addr_hi = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };
    
    // 聚合计数：返回当前计数并递增
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_agg_counter) ra_inc_agg_counter = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };
    
    // 重置聚合计数
    RegisterAction<bit<32>, bit<32>, void>(reg_agg_counter) ra_reset_agg_counter = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };
    
    /***************************************************************************
     * Tables
     ***************************************************************************/
    
    // Combine转发表：rank_id, channel_id -> tx目的信息
    action set_combine_forward(bit<48> dst_mac, bit<32> dst_ip, bit<24> dst_qp, bit<32> rkey, PortId_t egress_port) {
        hdr.eth.dst_addr = dst_mac;
        hdr.ipv4.dst_addr = dst_ip;
        hdr.bth.dst_qp = dst_qp;
        if (hdr.reth.isValid()) {
            hdr.reth.rkey = rkey;
        }
        ig_tm_md.ucast_egress_port = egress_port;
    }
    
    table tbl_combine_forward {
        key = {
            ig_md.combine.tx_id : exact;
            ig_md.combine.channel_id : exact;
        }
        actions = {
            set_combine_forward;
            NoAction;
        }
        size = 4096;
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
        ig_md.combine.payload_len = len;
    }
    
    /***************************************************************************
     * Apply
     ***************************************************************************/
    
    apply {
        ig_md.combine.pkt_psn = (bit<32>)hdr.bth.psn;
        
        // 计算register索引
        bit<32> rx_reg_idx = ig_md.combine.tx_id * (NUM_DISPATCH_CHANNELS * MAX_EP_SIZE)
                           + ig_md.combine.channel_id * MAX_EP_SIZE
                           + ig_md.combine.rank_id;
        ig_md.combine.reg_idx = rx_reg_idx;
        
        bit<32> tx_reg_idx = ig_md.combine.tx_id * NUM_DISPATCH_CHANNELS 
                           + ig_md.combine.channel_id;
        
        // 处理来自tx的ACK/NAK（combine方向的ACK）
        if (ig_md.combine.conn_type == CONN_RX && hdr.bth.opcode == RDMA_OP_ACK) {
            if (hdr.aeth.syndrome != AETH_ACK) {
                ra_invalidate_rx_epsn.execute(rx_reg_idx);
            }
            ig_dprsr_md.drop_ctl = 1;
            return;
        }
        
        // 处理控制连接
        if (ig_md.combine.conn_type == CONN_CONTROL) {
            ra_reset_rx_msn.execute(rx_reg_idx);
            ig_md.combine.expected_psn = ig_md.combine.pkt_psn + 1;
            ra_write_rx_epsn.execute(rx_reg_idx);
            
            swap_l2_l3_l4();
            set_ack_headers(AETH_ACK, hdr.bth.psn, 0);
            ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            return;
        }
        
        // 处理数据连接
        if (ig_md.combine.conn_type == CONN_DATA) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_FIRST && 
                hdr.bth.opcode != RDMA_OP_WRITE_MIDDLE &&
                hdr.bth.opcode != RDMA_OP_WRITE_LAST &&
                hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }
            
            // PSN验证
            bit<32> expected = ra_read_rx_epsn.execute(rx_reg_idx);
            ig_md.combine.expected_psn = expected;
            
            if (ig_md.combine.pkt_psn == expected) {
                ig_md.combine.psn_status = 0;
            } else if (ig_md.combine.pkt_psn > expected) {
                ig_md.combine.psn_status = 1;
            } else {
                ig_md.combine.psn_status = 2;
            }
            
            // PSN不匹配处理
            if (ig_md.combine.psn_status != 0) {
                ig_md.combine.current_msn = ra_read_rx_msn.execute(rx_reg_idx);
                swap_l2_l3_l4();
                if (ig_md.combine.psn_status == 1) {
                    set_ack_headers(AETH_NAK_PSN_SEQ, (bit<24>)(expected - 1), (bit<24>)ig_md.combine.current_msn);
                } else {
                    set_ack_headers(AETH_ACK, (bit<24>)(expected - 1), (bit<24>)ig_md.combine.current_msn);
                }
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                return;
            }
            
            // PSN匹配
            ra_read_inc_rx_epsn.execute(rx_reg_idx);
            calc_payload_len();
            
            // 更新发给tx的PSN和地址
            bit<32> new_psn = ra_read_inc_tx_psn.execute(tx_reg_idx);
            hdr.bth.psn = (bit<24>)new_psn;
            
            if (hdr.reth.isValid()) {
                bit<32> addr_lo = ra_read_add_tx_addr_lo.execute(tx_reg_idx);
                bit<32> addr_hi = ra_read_tx_addr_hi.execute(tx_reg_idx);
                hdr.reth.vaddr = ((bit<64>)addr_hi << 32) | (bit<64>)addr_lo;
            }
            
            // MSN处理
            if (hdr.bth.opcode == RDMA_OP_WRITE_ONLY || 
                hdr.bth.opcode == RDMA_OP_WRITE_LAST) {
                ig_md.combine.current_msn = ra_read_inc_rx_msn.execute(rx_reg_idx);
            } else {
                ig_md.combine.current_msn = ra_read_rx_msn.execute(rx_reg_idx);
            }
            
            // 转发到tx
            tbl_combine_forward.apply();
            
            // Clone用于ACK返回给rx
            ig_dprsr_md.mirror_type = 2;
        }
    }
}


/*******************************************************************************
 * Combine Egress Control
 ******************************************************************************/

control CombineEgress(
    inout my_egress_headers_t hdr,
    inout my_egress_metadata_t eg_md,
    in egress_intrinsic_metadata_t eg_intr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    apply {
        // Combine的egress处理较简单，因为PSN和地址已在ingress更新
        
        // 处理ACK clone
        if (eg_md.is_ack_clone == 1) {
            bit<48> tmp_mac = hdr.eth.src_addr;
            hdr.eth.src_addr = hdr.eth.dst_addr;
            hdr.eth.dst_addr = tmp_mac;
            
            bit<32> tmp_ip = hdr.ipv4.src_addr;
            hdr.ipv4.src_addr = hdr.ipv4.dst_addr;
            hdr.ipv4.dst_addr = tmp_ip;
            
            hdr.bth.opcode = RDMA_OP_ACK;
            hdr.aeth.setValid();
            hdr.aeth.syndrome = AETH_ACK;
            hdr.reth.setInvalid();
            hdr.payload.setInvalid();
        }
    }
}