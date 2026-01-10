
#include <core.p4>
#include <tna.p4>

/*******************************************************************************
 * Constants
 ******************************************************************************/

#define MAX_EP_SIZE 64
#define NUM_DISPATCH_CHANNELS 4
#define MAX_TX_CHANNELS (MAX_EP_SIZE * NUM_DISPATCH_CHANNELS)
#define MAX_RX_ENTRIES (MAX_EP_SIZE * NUM_DISPATCH_CHANNELS * MAX_EP_SIZE)


// AETH Syndrome
const bit<8> AETH_ACK         = 0x00;
const bit<8> AETH_NAK_PSN_SEQ = 0x60;

// Traffic Type
const bit<2> TRAFFIC_UNKNOWN  = 0;
const bit<2> TRAFFIC_DISPATCH = 1;
const bit<2> TRAFFIC_COMBINE  = 2;

// Connection Type
const bit<2> CONN_UNKNOWN = 0;
const bit<2> CONN_DATA    = 1;
const bit<2> CONN_CONTROL = 2;
const bit<2> CONN_RX      = 3;

/*******************************************************************************
 * Metadata Structures
 ******************************************************************************/





struct my_egress_metadata_t {
    bit<2>  traffic_type;
    bit<32> tx_id;
    bit<32> channel_id;
    bit<32> rx_id;
    bit<32> reg_idx;
    bit<16> payload_len;
    bit<1>  is_multicast;
    bit<1>  is_ack_clone;
}


/*******************************************************************************
 * Top-Level Ingress Control
 ******************************************************************************/

control MyIngress(
    inout my_ingress_headers_t hdr,
    inout my_ingress_metadata_t ig_md,
    in ingress_intrinsic_metadata_t ig_intr_md,
    in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md)
{
    // 子控制模块实例化
    DispatchIngress() dispatch_ctrl;
    CombineIngress() combine_ctrl;
    
    /***************************************************************************
     * Traffic Classification Table
     * 根据QP、IP等区分dispatch和combine流量
     ***************************************************************************/
    
    // Dispatch连接查找
    action set_dispatch_data(bit<32> tx_id, bit<32> channel_id) {
        ig_md.traffic_type = TRAFFIC_DISPATCH;
        ig_md.dispatch.tx_id = tx_id;
        ig_md.dispatch.channel_id = channel_id;
        ig_md.dispatch.conn_type = CONN_DATA;
        ig_md.dispatch.tx_reg_idx = tx_id * NUM_DISPATCH_CHANNELS + channel_id;
    }
    
    action set_dispatch_control(bit<32> tx_id, bit<32> channel_id) {
        ig_md.traffic_type = TRAFFIC_DISPATCH;
        ig_md.dispatch.tx_id = tx_id;
        ig_md.dispatch.channel_id = channel_id;
        ig_md.dispatch.conn_type = CONN_CONTROL;
        ig_md.dispatch.tx_reg_idx = tx_id * NUM_DISPATCH_CHANNELS + channel_id;
    }
    
    action set_dispatch_rx(bit<32> tx_id, bit<32> channel_id, bit<32> rx_id) {
        ig_md.traffic_type = TRAFFIC_DISPATCH;
        ig_md.dispatch.tx_id = tx_id;
        ig_md.dispatch.channel_id = channel_id;
        ig_md.dispatch.rx_id = rx_id;
        ig_md.dispatch.conn_type = CONN_RX;
        ig_md.dispatch.tx_reg_idx = tx_id * NUM_DISPATCH_CHANNELS + channel_id;
    }
    
    // Combine连接查找
    action set_combine_data(bit<32> rx_id, bit<32> channel_id, bit<32> tx_id) {
        ig_md.traffic_type = TRAFFIC_COMBINE;
        ig_md.combine.rx_id = rx_id;
        ig_md.combine.channel_id = channel_id;
        ig_md.combine.tx_id = tx_id;
        ig_md.combine.conn_type = CONN_DATA;
    }
    
    action set_combine_control(bit<32> rx_id, bit<32> channel_id, bit<32> tx_id) {
        ig_md.traffic_type = TRAFFIC_COMBINE;
        ig_md.combine.rx_id = rx_id;
        ig_md.combine.channel_id = channel_id;
        ig_md.combine.tx_id = tx_id;
        ig_md.combine.conn_type = CONN_CONTROL;
    }
    
    action set_combine_tx_ack(bit<32> rx_id, bit<32> channel_id, bit<32> tx_id) {
        ig_md.traffic_type = TRAFFIC_COMBINE;
        ig_md.combine.rx_id = rx_id;
        ig_md.combine.channel_id = channel_id;
        ig_md.combine.tx_id = tx_id;
        ig_md.combine.conn_type = CONN_RX;
    }
    
    action set_unknown() {
        ig_md.traffic_type = TRAFFIC_UNKNOWN;
    }
    
    // 主分类表：根据QPN区分流量类型和连接信息
    table tbl_traffic_classify {
        key = {
            hdr.bth.dst_qp : exact;
        }
        actions = {
            set_dispatch_data;
            set_dispatch_control;
            set_dispatch_rx;
            set_combine_data;
            set_combine_control;
            set_combine_tx_ack;
            set_unknown;
        }
        size = 32768;
        default_action = set_unknown;
    }
    
    // 备用分类表：可以根据IP地址进一步区分
    table tbl_traffic_classify_by_ip {
        key = {
            hdr.ipv4.src_addr : exact;
            hdr.ipv4.dst_addr : exact;
            hdr.bth.dst_qp : ternary;
        }
        actions = {
            set_dispatch_data;
            set_dispatch_control;
            set_dispatch_rx;
            set_combine_data;
            set_combine_control;
            set_combine_tx_ack;
            set_unknown;
        }
        size = 16384;
        default_action = set_unknown;
    }
    
    /***************************************************************************
     * Main Apply
     ***************************************************************************/
    
    apply {
        // 只处理RoCE包
        if (!hdr.bth.isValid()) {
            return;
        }
        
        // 流量分类
        if (!tbl_traffic_classify.apply().hit) {
            // QPN未匹配，尝试用IP分类
            tbl_traffic_classify_by_ip.apply();
        }
        
        // 根据流量类型调用相应的处理逻辑
        if (ig_md.traffic_type == TRAFFIC_DISPATCH) {
            dispatch_ctrl.apply(hdr, ig_md, ig_intr_md, ig_dprsr_md, ig_tm_md);
        } else if (ig_md.traffic_type == TRAFFIC_COMBINE) {
            combine_ctrl.apply(hdr, ig_md, ig_intr_md, ig_dprsr_md, ig_tm_md);
        } else {
            // 未知流量，丢弃或正常转发
            ig_dprsr_md.drop_ctl = 1;
        }
    }
}

/*******************************************************************************
 * Dispatch Egress Control
 ******************************************************************************/

control DispatchEgress(
    inout my_egress_headers_t hdr,
    inout my_egress_metadata_t eg_md,
    in egress_intrinsic_metadata_t eg_intr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    /***************************************************************************
     * Registers
     ***************************************************************************/
    
    Register<bit<32>, bit<32>>(MAX_RX_ENTRIES) reg_rx_next_psn;
    Register<bit<32>, bit<32>>(MAX_RX_ENTRIES) reg_rx_next_addr_hi;
    Register<bit<32>, bit<32>>(MAX_RX_ENTRIES) reg_rx_next_addr_lo;
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_next_psn) ra_read_inc_rx_psn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_next_addr_lo) ra_read_add_rx_addr_lo = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + (bit<32>)eg_md.payload_len;
        }
    };
    
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_next_addr_hi) ra_read_rx_addr_hi = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };
    
    /***************************************************************************
     * Tables
     ***************************************************************************/
    
    action set_rx_info(bit<32> rx_id, bit<48> dst_mac, bit<32> dst_ip, 
                       bit<24> dst_qp, bit<32> rkey) {
        eg_md.rx_id = rx_id;
        hdr.eth.dst_addr = dst_mac;
        hdr.ipv4.dst_addr = dst_ip;
        hdr.bth.dst_qp = dst_qp;
        if (hdr.reth.isValid()) {
            hdr.reth.rkey = rkey;
        }
        eg_md.reg_idx = eg_md.tx_id * (NUM_DISPATCH_CHANNELS * MAX_EP_SIZE)
                      + eg_md.channel_id * MAX_EP_SIZE
                      + rx_id;
    }
    
    table tbl_dispatch_egress_rx {
        key = {
            eg_intr_md.egress_port : exact;
            eg_md.tx_id : exact;
            eg_md.channel_id : exact;
        }
        actions = {
            set_rx_info;
            NoAction;
        }
        size = 16384;
        default_action = NoAction;
    }
    
    /***************************************************************************
     * Apply
     ***************************************************************************/
    
    apply {
        if (eg_md.is_multicast == 1) {
            tbl_dispatch_egress_rx.apply();
            
            // 更新PSN
            bit<32> new_psn = ra_read_inc_rx_psn.execute(eg_md.reg_idx);
            hdr.bth.psn = (bit<24>)new_psn;
            
            // 更新目的地址
            if (hdr.reth.isValid()) {
                bit<32> addr_lo = ra_read_add_rx_addr_lo.execute(eg_md.reg_idx);
                bit<32> addr_hi = ra_read_rx_addr_hi.execute(eg_md.reg_idx);
                hdr.reth.vaddr = ((bit<64>)addr_hi << 32) | (bit<64>)addr_lo;
            }
        }
        
        // 处理ACK clone
        if (eg_md.is_ack_clone == 1) {
            // 构造ACK返回给tx
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

/*******************************************************************************
 * Top-Level Egress Control
 ******************************************************************************/

control MyEgress(
    inout my_egress_headers_t hdr,
    inout my_egress_metadata_t eg_md,
    in egress_intrinsic_metadata_t eg_intr_md,
    in egress_intrinsic_metadata_from_parser_t eg_prsr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
    inout egress_intrinsic_metadata_for_output_port_t eg_oport_md)
{
    DispatchEgress() dispatch_egress;
    CombineEgress() combine_egress;
    
    apply {
        if (!hdr.bth.isValid()) {
            return;
        }
        
        if (eg_md.traffic_type == TRAFFIC_DISPATCH) {
            dispatch_egress.apply(hdr, eg_md, eg_intr_md, eg_dprsr_md);
        } else if (eg_md.traffic_type == TRAFFIC_COMBINE) {
            combine_egress.apply(hdr, eg_md, eg_intr_md, eg_dprsr_md);
        }
    }
}
