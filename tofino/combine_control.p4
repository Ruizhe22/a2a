/*******************************************************************************
 * Combine Control for AllToAll Communication - In-Network Aggregation
 * 
 * 聚合每个 packet 的前 4 bytes
 * 
 * 连接类型：
 * - CONN_CONTROL: 查询队列指针 (READ)
 * - CONN_BITMAP: rx 写入 bitmap (WRITE)
 * - CONN_TX: tx 写入 token 进行聚合 (WRITE)
 * - CONN_RX: rx 读取聚合结果 (READ)
 * 
 * 数据结构：
 * - tx_epsn[j]: 期望从第j个tx收到的PSN
 * - tx_msn[j]: 第j个tx的MSN
 * - tx_loc[j]: 第j个tx当前token的队列位置
 * - tx_packet_offset[j]: 第j个tx当前token内的packet偏移
 * - rx_bitmap_epsn: bitmap连接的ePSN
 * - rx_token_epsn: token连接的ePSN
 * - rx_token_msn: token连接的MSN
 * - bitmap_buffer[loc]: 剩余需要聚合的tx bitmap
 * - agg_count[loc][packet]: 已聚合的tx数量
 * - queue_head, queue_tail, queue_incomplete: 队列指针
 ******************************************************************************/

#define NUM_COMBINE_CHANNELS_PER_RX 8
#define COMBINE_QUEUE_LENGTH 64        // number of tokens in the queue 
#define TOKEN_SIZE 7168                // 7K bytes
#define PAYLOAD_LEN 1024               // 1K per packet
#define TOKEN_PACKETS (TOKEN_SIZE / PAYLOAD_LEN) // 7
#define N_AGG_SLOTS 32                 // 聚合槽位数 (128 bytes / 4)
#define BYTES_PER_SLOT 4               // 每个槽位 4 bytes, bit<32>
#define BITMAP_PER_PACKET 8            // 每个bitmap write packet对应bitmap的个数

// 索引计算
#define COMBINE_CHANNELS_TOTAL (EP_SIZE * NUM_COMBINE_CHANNELS_PER_RX)                    // 64
#define PACKET_NUM_PER_CHANNEL_BUFFER (COMBINE_QUEUE_LENGTH * TOKEN_PACKETS)    // 每个entry对应一个offset位置，448
#define COMBINE_BUFFER_ENTRIES (COMBINE_CHANNELS_TOTAL * PACKET_NUM_PER_CHANNEL_BUFFER)   // 28672, entry->packet
#define COMBINE_TX_ENTRIES (COMBINE_CHANNELS_TOTAL * EP_SIZE)                      // 512
#define COMBINE_BITMAP_ENTRIES (COMBINE_CHANNELS_TOTAL * COMBINE_QUEUE_LENGTH)     // 4096

/*******************************************************************************
 * Queue Pointer Slot - 管理每个连接的队列指针
 * channel_id = channel_class * EP_SIZE + _rank_id
 ******************************************************************************/

control QueuePointerSlot(
    inout bit<8> result,
    in COMBINE_QUEUE_POINTER_REG_OP operation,
    in bit<32> channel_class) 
{

    Register<bit<8>, bit<32>>(NUM_COMBINE_CHANNELS_PER_RX) reg_ptr;

    RegisterAction<bit<8>, bit<32>, void>(reg_ptr) ra_init = {
        void apply(inout bit<8> value) {
            value = 0;
        }
    };

    RegisterAction<bit<8>, bit<32>, bit<8>>(reg_ptr) ra_read = {
        void apply(inout bit<8> value, out bit<8> res) {
            res = value;
        }
    };

    RegisterAction<bit<8>, bit<32>, void>(reg_ptr) ra_inc = {
        void apply(inout bit<8> value) {
            if (value == COMBINE_QUEUE_LENGTH - 1) {
                value = 0;
            } else {
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<8>, bit<32>, bit<8>>(reg_ptr) ra_read_add = {
        void apply(inout bit<8> value, out bit<8> res) {
            res = value;
            if (value >= COMBINE_QUEUE_LENGTH - 8) {
                value = valiue + 8 - COMBINE_QUEUE_LENGTH;
            } else {
                value = value + 8;
            }
        }
    };

    apply {
        if (operation == COMBINE_QUEUE_POINTER_REG_OP.OP_INIT) {
            ra_init.execute(channel_class);
        } else if (operation == COMBINE_QUEUE_POINTER_REG_OP.OP_READ) {
            result = ra_read.execute(channel_class);
        } else if (operation == COMBINE_QUEUE_POINTER_REG_OP.OP_INC) {
            ra_inc.execute(channel_class);
        } else if (operation == COMBINE_QUEUE_POINTER_REG_OP.OP_READ_ADD) {
            result = ra_read_add.execute(channel_class);
        }
    }
}

/*******************************************************************************
 * BitmapSlot - 单个 RX 的 Bitmap Buffer 管理
 * 
 * 每个 slot 管理一个 rx 的所有 queue 位置的 bitmap
 ******************************************************************************/
control BitmapSlot(
        out bitmap_tofino_t result,
        in bitmap_tofino_t write_val,
        in bitmap_tofino_t clear_mask,
        in COMBINE_BITMAP_REG_OP operation,
        in bit<32> slot_idx)    // channel_class * COMBINE_QUEUE_LENGTH + loc
    {
        bitmap_tofino_t w_val;
        bitmap_tofino_t c_mask;

        Register<bitmap_tofino_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) reg_bitmap;

        RegisterAction<bitmap_tofino_t, bit<32>, bitmap_tofino_t>(reg_bitmap) ra_read = {
            void apply(inout bitmap_tofino_t value, out bitmap_tofino_t res) {
                res = value;
            }
        };

        RegisterAction<bitmap_tofino_t, bit<32>, void>(reg_bitmap) ra_write = {
            void apply(inout bitmap_tofino_t value) {
                value = w_val;
            }
        };

        RegisterAction<bitmap_tofino_t, bit<32>, bitmap_tofino_t>(reg_bitmap) ra_clear_bit = {
            void apply(inout bitmap_tofino_t value, out bitmap_tofino_t res) {
                value = value ^ c_mask;
                res = value;
            }
        };

        RegisterAction<bitmap_tofino_t, bit<32>, void>(reg_bitmap) ra_reset = {
            void apply(inout bitmap_tofino_t value) {
                value = 0;
            }
        };

        apply {
            if (operation == COMBINE_BITMAP_REG_OP.OP_READ) {
                result = ra_read.execute(slot_idx);
            } else if (operation == COMBINE_BITMAP_REG_OP.OP_WRITE) {
                w_val = write_val;
                ra_write.execute(slot_idx);
            } else if (operation == COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT) {
                c_mask = clear_mask;
                result = ra_clear_bit.execute(slot_idx);
            } else if (operation == COMBINE_BITMAP_REG_OP.OP_RESET) {
                ra_reset.execute(slot_idx);
            }
        }
    }


/*******************************************************************************
 * AddrSlot - Addr Buffer 的 1/8
 * 
 * 相邻的 token 分散到 8 个 slot 中
 * token_idx = channel_id * COMBINE_QUEUE_LENGTH + loc
 * slot_id = token_idx % 8 = token_idx[2:0]
 * slot_index = token_idx / 8 = token_idx >> 3
 ******************************************************************************/
control AddrSlot(
    out addr_tofino_t result,
    in addr_tofino_t write_val,
    in COMBINE_ADDR_REG_OP operation,
    in bit<32> slot_index)    // token_idx >> 3
{
    
    addr_tofino_t w_val;

    // 每个 slot 存储 COMBINE_BITMAP_ENTRIES / 8 个 addr
    Register<addr_tofino_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) reg_addr;

    // 读取
    RegisterAction<addr_tofino_t, bit<32>, addr_tofino_t>(reg_addr) ra_read = {
        void apply(inout addr_tofino_t value, out addr_tofino_t res) {
            res = value;
        }
    };

    // 写入
    RegisterAction<addr_tofino_t, bit<32>, void>(reg_addr) ra_write = {
        void apply(inout addr_tofino_t value) {
            value = w_val;
        }
    };

    apply {
        if (operation == COMBINE_ADDR_REG_OP.OP_READ) {
            result = ra_read.execute(slot_index);
        } else if (operation == COMBINE_ADDR_REG_OP.OP_WRITE) {
            w_val = write_val;
            ra_write.execute(slot_index);
        }
    }
}


/*******************************************************************************
 * CombineIngress - 主控制逻辑
 ******************************************************************************/
control CombineIngress(
    inout a2a_ingress_headers_t hdr,
    inout a2a_ingress_metadata_t ig_md,
    in ingress_intrinsic_metadata_t ig_intr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md)
{

    /***************************************************************************
     * TX State Registers
     * Index: channel_id * EP_SIZE + ing_rank_id
     ***************************************************************************/
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES, 0) reg_tx_epsn;
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES) reg_tx_msn;
    Register<bit<8>, bit<32>>(COMBINE_TX_ENTRIES) reg_tx_loc;
    Register<bit<8>, bit<32>>(COMBINE_TX_ENTRIES) reg_tx_packet_offset;


    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_epsn) ra_read_cond_inc_tx_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if( psn_to_check == value) {
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_epsn) ra_init_tx_epsn = {
        void apply(inout bit<32> value) {
            value = 0;
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

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_msn) ra_init_tx_msn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    RegisterAction<bit<8>, bit<32>, bit<8>>(reg_tx_loc) ra_read_tx_loc = {
        void apply(inout bit<8> value, out bit<8> result) {
            result = value;
        }
    };

    RegisterAction<bit<8>, bit<32>, void>(reg_tx_loc) ra_write_tx_loc = {
        void apply(inout bit<8> value) {
            value = ig_md.bridge.tx_loc_val;
        }
    };

    RegisterAction<bit<8>, bit<32>, bit<8>>(reg_tx_packet_offset) ra_read_inc_tx_offset = {
        void apply(inout bit<8> value, out bit<8> result) {
            result = value;
            value = value + 1;
        }
    };

    RegisterAction<bit<8>, bit<32>, void>(reg_tx_packet_offset) ra_reset_tx_offset = {
        void apply(inout bit<8> value) {
            value = 1;  // 重置为 1（当前包是第 0 个，下一个是第 1 个）
        }
    };

    /***************************************************************************
     * RX State Registers
     * Index: channel_id
     ***************************************************************************/
    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL, 0) reg_rx_bitmap_epsn;
    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL, 0) reg_rx_token_epsn;
    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL, 0) reg_rx_token_msn;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_bitmap_epsn) ra_read_rx_bitmap_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_bitmap_epsn) ra_read_cond_inc_rx_bitmap_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if (psn_to_check == value) {
                // PSN 匹配，递增并返回 0
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_rx_bitmap_epsn) ra_init_rx_bitmap_epsn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };


    // 读取当前 epsn（不更新）
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_token_epsn) ra_read_rx_token_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    // 读取并增加 TOKEN_PACKETS
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_token_epsn) ra_read_add_rx_token_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + TOKEN_PACKETS;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_rx_token_epsn) ra_init_rx_token_epsn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_token_msn) ra_read_inc_rx_token_msn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };

    /***************************************************************************
     * Queue State Registers
     * Index: rank_id choose which slot and channel_class is the index 
     * Queue Pointer Slots (EP_SIZE = 8)
     * 每个 rx 有自己的 queue_head, queue_tail
     ***************************************************************************/
    
    // Queue Head Slots
    QueuePointerSlot() queue_head_slot_0;
    QueuePointerSlot() queue_head_slot_1;
    QueuePointerSlot() queue_head_slot_2;
    QueuePointerSlot() queue_head_slot_3;
    QueuePointerSlot() queue_head_slot_4;
    QueuePointerSlot() queue_head_slot_5;
    QueuePointerSlot() queue_head_slot_6;
    QueuePointerSlot() queue_head_slot_7;

    // Queue Tail Slots
    QueuePointerSlot() queue_tail_slot_0;
    QueuePointerSlot() queue_tail_slot_1;
    QueuePointerSlot() queue_tail_slot_2;
    QueuePointerSlot() queue_tail_slot_3;
    QueuePointerSlot() queue_tail_slot_4;
    QueuePointerSlot() queue_tail_slot_5;
    QueuePointerSlot() queue_tail_slot_6;
    QueuePointerSlot() queue_tail_slot_7;

    /***************************************************************************
     * Queue Incomplete Registers
     * Index: channel channel_id
     * Ignore the packet loss, queue queue_head and incomplete pointer are the same 
     ***************************************************************************/
     
    Register<bit<8>, bit<32>>(COMBINE_CHANNELS_TOTAL) reg_queue_incomplete;

    RegisterAction<bit<8>, bit<32>, bit<8>>(reg_queue_incomplete) ra_read_queue_incomplete = {
        void apply(inout bit<8> value, out bit<8> result) {
            result = value;
        }
    };

    RegisterAction<bit<8>, bit<32>, bit<8>>(reg_queue_incomplete) ra_read_cond_inc_queue_incomplete = {
        void apply(inout bit<8> value, out bit<8> result) {
            result = value;
            if(value == ig_md.bridge.tx_loc_val) {
                if (value >= COMBINE_QUEUE_LENGTH - 1) {
                    value = 0;
                } else {
                    value = value + 1;
                }
            }
        }
    };

    RegisterAction<bit<8>, bit<32>, void>(reg_queue_incomplete) ra_init_queue_incomplete = {
        void apply(inout bit<8> value) {
            value = 0;
        }
    };

    /***************************************************************************
     * Buffer Token State Registers
     * 每个token一个元素
     * Index: channel_id * COMBINE_QUEUE_LENGTH + loc / / bitmap中，loc = queue_tail (inc之前)
     * Bitmap Slots - 每个packet对应BITMAP_PER_PACKET（8）个bitmap slots，用于分散写入
     * Addr Slots - 每个packet对应8个addr slots，用于分散写入
     ***************************************************************************/

    BitmapSlot() bitmap_slot_0;
    BitmapSlot() bitmap_slot_1;
    BitmapSlot() bitmap_slot_2;
    BitmapSlot() bitmap_slot_3;
    BitmapSlot() bitmap_slot_4;
    BitmapSlot() bitmap_slot_5;
    BitmapSlot() bitmap_slot_6;
    BitmapSlot() bitmap_slot_7;

    AddrSlot() addr_slot_0;
    AddrSlot() addr_slot_1;
    AddrSlot() addr_slot_2;
    AddrSlot() addr_slot_3;
    AddrSlot() addr_slot_4;
    AddrSlot() addr_slot_5;
    AddrSlot() addr_slot_6;
    AddrSlot() addr_slot_7;

    Register<bit<8>, bit<32>>(COMBINE_BITMAP_ENTRIES) reg_clear_buffer;
    
    addr_tofino_t addr_write_val;
    

    // 在调用前，需要设置 ig_md.bridge.tx_offset_val, 因为一个Register只能被读一次，所以必须这么写
    RegisterAction<bit<8>, bit<32>, bit<8>>(reg_clear_buffer) ra_read_set_clear = {
        void apply(inout bit<8> value, out bit<8> result) {
            result = value;
            if(value <= ig_md.bridge.tx_offset_val){ // 按理说只能 ==
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<8>, bit<32>, void>(reg_clear_buffer) ra_reset_clear = {
        void apply(inout bit<8> value) {
            result = 0;
        }
    };

    /***************************************************************************
     * Local Variables
     ***************************************************************************/
    bit<32> channel_id;
    bit<32> channel_class;
    bit<8> queue_head;
    bit<8> queue_tail;
    bit<8> queue_incomplete;
    bit<32> tx_reg_idx;
    bit<32> buffer_idx;
    bit<32> token_idx;
    bit<32> psn_to_check;

    /***************************************************************************
     * Utility Actions
     ***************************************************************************/
    action set_aeth_ingress(bit<8> syndrome, bit<24> psn, bit<24> msn) {
        ig_md.bridge.has_aeth = true;
        //hdr.bth.opcode = RDMA_OP_ACK;
        hdr.bth.psn = psn; // 如果有ack头，比如RDMA_OP_ACK或者Read response，psn只取决于ack，所以在这里设置
        hdr.aeth.setValid();
        hdr.aeth.syndrome = syndrome;
        hdr.aeth.msn = msn;
        // hdr.reth.setInvalid();
        // hdr.payload.setInvalid();
    }

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

    action set_ack_len() {
        // ACK 包: UDP(8) + BTH(12) + AETH(4) + ICRC(4) = 28
        hdr.udp.length = 28;
        hdr.ipv4.total_len = 48;
        hdr.udp.checksum = 0;
    }

    /***************************************************************************
     * Apply
     ***************************************************************************/
    apply {

        channel_id = (bit<32>)ig_md.bridge.channel_id;
        tx_reg_idx = channel_id * EP_SIZE + (bit<32>)ig_md.bridge.ing_rank_id; // no use for loop port
        channel_class = channel_id >> 3; // EP_SIZE=8

        bitmap_tofino_t bitmap_result;
        bitmap_tofino_t bitmap_write_val;
        bitmap_tofino_t bitmap_clear_mask;
        addr_tofino_t addr_result;
        addr_tofino_t addr_write_val;
        bit<32> token_idx;
        bit<3> slot_id;
        bit<32> slot_index;
        // ================================================================
        // CONN_CONTROL: 查询队列指针 (READ)
        // ================================================================
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            if (hdr.bth.opcode == RDMA_OP_READ_REQ) {
         
                // 构造 READ_RESPONSE_ONLY
                queue_head_slot_0.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_0.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                hdr.payload.data00 = ((bit<32>)queue_head << 16) | (bit<32>)queue_tail;

                queue_head_slot_1.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_1.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                hdr.payload.data01 = ((bit<32>)queue_head << 16) | (bit<32>)queue_tail;

                queue_head_slot_2.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_2.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                hdr.payload.data02 = ((bit<32>)queue_head << 16) | (bit<32>)queue_tail;

                queue_head_slot_3.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_3.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                hdr.payload.data03 = ((bit<32>)queue_head << 16) | (bit<32>)queue_tail;

                queue_head_slot_4.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_4.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                hdr.payload.data04 = ((bit<32>)queue_head << 16) | (bit<32>)queue_tail;

                queue_head_slot_5.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_5.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                hdr.payload.data05 = ((bit<32>)queue_head << 16) | (bit<32>)queue_tail;

                queue_head_slot_6.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_6.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                hdr.payload.data06 = ((bit<32>)queue_head << 16) | (bit<32>)queue_tail;

                queue_head_slot_7.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_7.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                hdr.payload.data07 = ((bit<32>)queue_head << 16) | (bit<32>)queue_tail;

                set_aeth_ingress(AETH_ACK_CREDIT_INVALID, hdr.bth.psn, hdr.bth.psn + 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            }
            return;
        }

        // ================================================================
        // CONN_BITMAP: rx 写入 bitmap (WRITE_ONLY)
        // ================================================================
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }
            psn_to_check = (bit<32>)hdr.bth.psn;
            bit<32> expected_psn = ra_read_cond_inc_rx_bitmap_epsn.execute(channel_id);
            
            if ((bit<32>)hdr.bth.psn == expected_psn) {
                // PSN 匹配，写入 bitmap
                channel_class = channel_id >> 3; // EP_SIZE=8
                // 根据 rx_id 选择对应的 slot 读取 queue_tail 并更新
                if (ig_md.bridge.ing_rank_id == 0) {
                    queue_tail_slot_0.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ_ADD, channel_class);
                } else if (ig_md.bridge.ing_rank_id == 1) {
                    queue_tail_slot_1.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ_ADD, channel_class);
                } else if (ig_md.bridge.ing_rank_id == 2) {
                    queue_tail_slot_2.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ_ADD, channel_class);
                } else if (ig_md.bridge.ing_rank_id == 3) {
                    queue_tail_slot_3.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ_ADD, channel_class);
                } else if (ig_md.bridge.ing_rank_id == 4) {
                    queue_tail_slot_4.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ_ADD, channel_class);
                } else if (ig_md.bridge.ing_rank_id == 5) {
                    queue_tail_slot_5.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ_ADD, channel_class);
                } else if (ig_md.bridge.ing_rank_id == 6) {
                    queue_tail_slot_6.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ_ADD, channel_class);
                } else if (ig_md.bridge.ing_rank_id == 7) {
                    queue_tail_slot_7.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ_ADD, channel_class);
                }
                
                // 写入 bitmap 和 addr

                token_idx = channel_id * COMBINE_QUEUE_LENGTH + (bit<32>)queue_tail;
                slot_index = token_idx >> 3;      // token_idx / 8
                
                bitmap_write_val = hdr.payload.data00;
                bitmap_slot_0.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_OP.OP_WRITE, slot_index);
                bitmap_write_val = hdr.payload.data01;
                bitmap_slot_1.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_OP.OP_WRITE, slot_index);
                bitmap_write_val = hdr.payload.data02;
                bitmap_slot_2.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_OP.OP_WRITE, slot_index);
                bitmap_write_val = hdr.payload.data03;
                bitmap_slot_3.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_OP.OP_WRITE, slot_index);
                bitmap_write_val = hdr.payload.data04;
                bitmap_slot_4.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_OP.OP_WRITE, slot_index);
                bitmap_write_val = hdr.payload.data05;
                bitmap_slot_5.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_OP.OP_WRITE, slot_index);
                bitmap_write_val = hdr.payload.data06;
                bitmap_slot_6.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_OP.OP_WRITE, slot_index);
                bitmap_write_val = hdr.payload.data07;
                bitmap_slot_7.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_OP.OP_WRITE, slot_index);
                
                addr_write_val.lo = hdr.payload.data08;
                addr_write_val.hi = hdr.payload.data09;
                addr_slot_0.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, slot_index);
                addr_write_val.lo = hdr.payload.data0a;
                addr_write_val.hi = hdr.payload.data0b;
                addr_slot_1.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, slot_index);
                addr_write_val.lo = hdr.payload.data0c;
                addr_write_val.hi = hdr.payload.data0d;
                addr_slot_2.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, slot_index);
                addr_write_val.lo = hdr.payload.data0e;
                addr_write_val.hi = hdr.payload.data0f;
                addr_slot_3.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, slot_index);
                addr_write_val.lo = hdr.payload.data10;
                addr_write_val.hi = hdr.payload.data11;
                addr_slot_4.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, slot_index);
                addr_write_val.lo = hdr.payload.data12;
                addr_write_val.hi = hdr.payload.data13;
                addr_slot_5.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, slot_index);
                addr_write_val.lo = hdr.payload.data14;
                addr_write_val.hi = hdr.payload.data15;
                addr_slot_6.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, slot_index);
                addr_write_val.lo = hdr.payload.data16;
                addr_write_val.hi = hdr.payload.data17;
                addr_slot_7.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, slot_index);

                // 返回 ACK
                set_aeth_ingress(AETH_ACK_CREDIT_INVALID, hdr.bth.psn, hdr.bth.psn + 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else if ((bit<32>)hdr.bth.psn < expected_psn) {
                // 重复包
                set_aeth_ingress(AETH_ACK_CREDIT_INVALID, (bit<24>)(expected_psn - 1), (bit<24>)expected_psn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else {
                // 丢包，返回 NAK
                set_aeth_ingress(AETH_NAK_SEQ_ERR, (bit<24>)(expected_psn - 1), (bit<24>)expected_psn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            }
            return;
        }

        // ================================================================
        // CONN_TX: tx 写入 token (WRITE) - 聚合
        // bitmap存储必须在ingress，因为要确定是否token的聚合完成然后广播
        // token buffer必须在egress，因为广播需要读取不同offset的packet
        // ================================================================
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_TX && ig_intr_md.ingress_port != LOOPBACK_PORT) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_FIRST && 
                hdr.bth.opcode != RDMA_OP_WRITE_MIDDLE &&
                hdr.bth.opcode != RDMA_OP_WRITE_LAST &&
                hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }

            bit<32> expected_psn = ra_read_cond_inc_tx_epsn.execute(tx_reg_idx);
            bit<32> current_msn = ra_read_tx_msn.execute(tx_reg_idx);
            
            if ((bit<32>)hdr.bth.psn == expected_psn) {
                // PSN 匹配
                // 获取 loc 和 packet_offset
                if (hdr.bth.opcode == RDMA_OP_WRITE_FIRST || 
                    hdr.bth.opcode == RDMA_OP_WRITE_ONLY) {
                    // 从 reth.addr 获取 loc
                    ig_md.bridge.tx_loc_val = hdr.reth.addr[63:48];
                    ig_md.bridge.tx_offset_val = 0;
                    ra_write_tx_loc.execute(tx_reg_idx);
                    ra_reset_tx_offset.execute(tx_reg_idx);
                } else {
                    // 从寄存器获取
                    ig_md.bridge.tx_loc_val = ra_read_tx_loc.execute(tx_reg_idx);
                    ig_md.bridge.tx_offset_val = ra_read_inc_tx_offset.execute(tx_reg_idx);
                }
                
                token_idx = channel_id * COMBINE_QUEUE_LENGTH + (bit<32>)ig_md.bridge.tx_loc_val;
                slot_id = token_idx[2:0];
                // 检查是否是第一个到达的 tx
                ig_md.bridge.clear_offset = ra_read_set_clear.execute(token_idx);
                
                // 如果是 WRITE_LAST/ONLY，清除 bitmap 中的 tx 位，更新 MSN
                if (hdr.bth.opcode == RDMA_OP_WRITE_ONLY || 
                    hdr.bth.opcode == RDMA_OP_WRITE_LAST) {
                    
                    slot_index = token_idx >> 3;      // token_idx / 8
                    bitmap_clear_mask = (bitmap_tofino_t)1 << ig_md.bridge.ing_rank_id;
                    //bitmap_tofino_t bitmap_after_clear = ra_clear_bit_bitmap.execute(token_idx);
                    if (slot_id == 0) {
                        bitmap_slot_0.apply(bitmap_result, bitmap_write_val, bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, slot_index);
                        addr_slot_0.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, slot_index);
                    } else if (slot_id == 1) {
                        bitmap_slot_1.apply(bitmap_result, bitmap_write_val, bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, slot_index);
                        addr_slot_1.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, slot_index);
                    } else if (slot_id == 2) {
                        bitmap_slot_2.apply(bitmap_result, bitmap_write_val, bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, slot_index);
                        addr_slot_2.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, slot_index);
                    } else if (slot_id == 3) {
                        bitmap_slot_3.apply(bitmap_result, bitmap_write_val, bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, slot_index);
                        addr_slot_3.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, slot_index);
                    } else if (slot_id == 4) {
                        bitmap_slot_4.apply(bitmap_result, bitmap_write_val, bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, slot_index);
                        addr_slot_4.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, slot_index);
                    } else if (slot_id == 5) {
                        bitmap_slot_5.apply(bitmap_result, bitmap_write_val, bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, slot_index);
                        addr_slot_5.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, slot_index);
                    } else if (slot_id == 6) {
                        bitmap_slot_6.apply(bitmap_result, bitmap_write_val, bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, slot_index);
                        addr_slot_6.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, slot_index);
                    } else {  // slot_id == 7
                        bitmap_slot_7.apply(bitmap_result, bitmap_write_val, bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, slot_index);
                        addr_slot_7.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, slot_index);
                    }

                    current_msn = ra_read_inc_tx_msn.execute(tx_reg_idx);
                    if (bitmap_result == 0) {
                        queue_incomplete = ra_read_cond_inc_queue_incomplete.excute(channel_id);
                        if( queue_incomplete == ig_md.bridge.tx_loc_val) {
                            // 更新queue_head，与queue_incomplete保持一致
                            if (ig_md.bridge.ing_rank_id == 0) {
                                queue_head_slot_0.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                            } else if (ig_md.bridge.ing_rank_id == 1) {
                                queue_head_slot_1.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                            } else if (ig_md.bridge.ing_rank_id == 2) {
                                queue_head_slot_2.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                            } else if (ig_md.bridge.ing_rank_id == 3) {
                                queue_head_slot_3.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                            } else if (ig_md.bridge.ing_rank_id == 4) {
                                queue_head_slot_4.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                            } else if (ig_md.bridge.ing_rank_id == 5) {
                                queue_head_slot_5.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                            } else if (ig_md.bridge.ing_rank_id == 6) {
                                queue_head_slot_6.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                            } else if (ig_md.bridge.ing_rank_id == 7) {
                                queue_head_slot_7.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                            }
                            
                            ig_tm_md.mcast_grp_b = 200; // loopback group
                            
                            // 把包改造为write first，没有设置长度和其他字，第一次启动的loop，来的时候没有reth，放不下
                            //hdr.reth.setValid();
                            //hdr.reth.addr[31:0] = addr_result.lo;
                            //hdr.reth.addr[63:32] = addr_result.hi;
                            hdr.bridge.next_token_addr = addr_result;
                        }
                    }
                }

                // 返回 ACK
                set_aeth_ingress(AETH_ACK_CREDIT_INVALID, (bit<24>)expected_psn, (bit<24>)current_msn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else if ((bit<32>)hdr.bth.psn < expected_psn) {
                // 重复包
                set_aeth_ingress(AETH_ACK_CREDIT_INVALID, (bit<24>)(expected_psn - 1), (bit<24>)current_msn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else {
                // 丢包
                set_aeth_ingress(AETH_NAK_SEQ_ERR, (bit<24>)(expected_psn - 1), (bit<24>)current_msn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            }
            return;
        }

        // ================================================================
        // loopback port， LOOPBACK_PORT还未定义
        // 这个包，一定是一个write first
        // reth
        //  data00 在ingress期间是这个token bcsat的loc，egress期间是这个next token bcast的loc
        //  addr这个token的接收，全程保持不变，egress期间 loopback port 再重新设置为下一个 token 地址，该地址在 ingress 存到bridge中
        //  这个包的字段，基本上都是上一次的egress设置了，除了psn，opcode，payload这些每个包不一样的部分。
        // ================================================================
        if (ig_intr_md.ingress_port == LOOPBACK_PORT && 
            hdr.bth.opcode == RDMA_OP_WRITE_FIRST) {
            
            // 从 payload 获取当前 loc
            bit<16> current_loc = hdr.payload.data00[15:0];
            ig_md.bridge.tx_loc_val = current_loc;
            ig_md.bridge.is_loopback = true;
            
            // 设置组播到 rx（TOKEN_PACKETS 个包）
            ig_tm_md.mcast_grp_a = (bit<16>)(100 + ig_md.bridge.root_rank_id);
            
            bit<32> base_psn = ra_read_add_rx_token_epsn.execute(channel_id);
            hdr.bth.psn = (bit<24>)base_psn;

            // 计算下一个 loc（环形队列）
            bit<8> next_loc;
            if (current_loc >= COMBINE_QUEUE_LENGTH - 1) {
                next_loc = 0;
            } else {
                next_loc = current_loc + 1;
            }
            
            // 读取 queue_tail 检查是否到达尾部
            if (ig_md.bridge.root_rank_id == 0) {
                queue_tail_slot_0.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
            } else if (ig_md.bridge.root_rank_id == 1) {
                queue_tail_slot_1.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
            } else if (ig_md.bridge.root_rank_id == 2) {
                queue_tail_slot_2.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
            } else if (ig_md.bridge.root_rank_id == 3) {
                queue_tail_slot_3.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
            } else if (ig_md.bridge.root_rank_id == 4) {
                queue_tail_slot_4.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
            } else if (ig_md.bridge.root_rank_id == 5) {
                queue_tail_slot_5.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
            } else if (ig_md.bridge.root_rank_id == 6) {
                queue_tail_slot_6.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
            } else if (ig_md.bridge.root_rank_id == 7) {
                queue_tail_slot_7.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
            }
            
            // 如果 next_loc == queue_tail，说明已经处理完所有 token，不再 loopback
            if (next_loc != queue_tail) {
                // 检查下一个 loc 的 bitmap 是否为 0
                bit<32> next_token_idx = channel_id * COMBINE_QUEUE_LENGTH + (bit<32>)next_loc;
                bit<3> next_slot_id = next_token_idx[2:0];
                bit<32> next_slot_index = next_token_idx >> 3;
                
                bitmap_tofino_t next_bitmap_result;
                
                if (next_slot_id == 0) {
                    bitmap_slot_0.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, next_slot_index);
                    addr_slot_0.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, next_slot_index);
                } else if (next_slot_id == 1) {
                    bitmap_slot_1.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, next_slot_index);
                    addr_slot_1.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, next_slot_index);
                } else if (next_slot_id == 2) {
                    bitmap_slot_2.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, next_slot_index);
                    addr_slot_2.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, next_slot_index);
                } else if (next_slot_id == 3) {
                    bitmap_slot_3.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, next_slot_index);
                    addr_slot_3.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, next_slot_index);
                } else if (next_slot_id == 4) {
                    bitmap_slot_4.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, next_slot_index);
                    addr_slot_4.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, next_slot_index);
                } else if (next_slot_id == 5) {
                    bitmap_slot_5.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, next_slot_index);
                    addr_slot_5.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, next_slot_index);
                } else if (next_slot_id == 6) {
                    bitmap_slot_6.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, next_slot_index);
                    addr_slot_6.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, next_slot_index);
                } else {
                    bitmap_slot_7.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, next_slot_index);
                    addr_slot_7.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, next_slot_index);
                }
                
                // 检查 queue_incomplete
                //bit<8> queue_incomplete_val = ra_read_queue_incomplete.execute(channel_id);
                
                // 如果下一个 token 准备好了，继续 loopback
                if (next_bitmap_result == 0 ) { //&& next_loc == queue_incomplete_val
                    // 更新 queue_incomplete 和 queue_head
                    ig_md.bridge.tx_loc_val = next_loc;
                    ra_read_cond_inc_queue_incomplete.execute(channel_id);
                    
                    if (ig_md.bridge.root_rank_id == 0) {
                        queue_head_slot_0.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                    } else if (ig_md.bridge.root_rank_id == 1) {
                        queue_head_slot_1.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                    } else if (ig_md.bridge.root_rank_id == 2) {
                        queue_head_slot_2.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                    } else if (ig_md.bridge.root_rank_id == 3) {
                        queue_head_slot_3.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                    } else if (ig_md.bridge.root_rank_id == 4) {
                        queue_head_slot_4.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                    } else if (ig_md.bridge.root_rank_id == 5) {
                        queue_head_slot_5.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                    } else if (ig_md.bridge.root_rank_id == 6) {
                        queue_head_slot_6.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                    } else if (ig_md.bridge.root_rank_id == 7) {
                        queue_head_slot_7.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_INC, channel_class);
                    }
                    
                    // 设置 loopback 继续，同时更新 payload的第一个值 为 next_loc
                    ig_tm_md.mcast_grp_b = LOOPBACK_MCAST_GRP;
                    hdr.payload.data00 = (bit<32>)next_loc;
                    hdr.bridge.next_token_addr = addr_result;
                }
            }
            
            // 恢复当前 loc 用于 egress
            ig_md.bridge.tx_loc_val = current_loc;
            
            return;
        }

    }
}


/*******************************************************************************
 * CombineEgress
 * 处理：
 * 1. Loopback 端口输出 - 构造 WRITE_FIRST 继续 loop
 * 2. 广播到 rx - 根据 rid 设置 opcode，读取聚合结果
 * 3. CONN_TX - 聚合并返回 ACK
 * 4. 其他 ACK 包
 ******************************************************************************/
control CombineEgress(
    inout a2a_headers_t hdr,
    inout a2a_egress_metadata_t eg_md,
    in egress_intrinsic_metadata_t eg_intr_md,
    in egress_intrinsic_metadata_from_parser_t eg_prsr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    /***************************************************************************
     * 聚合器
     * Index: channel_id * PACKET_NUM_PER_CHANNEL_BUFFER + loc * TOKEN_PACKETS + packet_offset 
     ***************************************************************************/
    bit<32> agg_val;
    bit<32> buffer_idx;
    bit<32> channel_id;
    
    Register<bit<32>, bit<32>>(COMBINE_BUFFER_ENTRIES) reg_agg;
    
    RegisterAction<bit<32>, bit<32>, void>(reg_agg) ra_store = {
        void apply(inout bit<32> value) {
            value = agg_val;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_agg) ra_aggregate = {
        void apply(inout bit<32> value) {
            value[7:0] = value[7:0] + agg_val[7:0];
            value[15:8] = value[15:8] + agg_val[15:8];
            value[23:16] = value[23:16] + agg_val[23:16];
            value[31:24] = value[31:24] + agg_val[31:24];
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_agg) ra_read_agg = {
        void apply(inout bit<32> value, out bit<32> res) {
            res = value;
        }
    };

    /***************************************************************************
     * Utility Actions
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

    action set_ack_len() {
        // ACK: UDP(8) + BTH(12) + AETH(4) + ICRC(4) = 28
        hdr.udp.length = 28;
        hdr.ipv4.total_len = 48;
        hdr.udp.checksum = 0;
        //hdr.bth.opcode = RDMA_OP_ACK;
    }

    action set_write_first_len() {
        // WRITE_FIRST: UDP(8) + BTH(12) + RETH(16) + Payload(PAYLOAD_LEN) + ICRC(4)
        hdr.udp.length = 8 + 12 + 16 + PAYLOAD_LEN + 4;
        hdr.ipv4.total_len = 20 + 8 + 12 + 16 + PAYLOAD_LEN + 4;
        hdr.udp.checksum = 0;
    }

    action set_write_middle_len() {
        // WRITE_MIDDLE/LAST: UDP(8) + BTH(12) + Payload(PAYLOAD_LEN) + ICRC(4)
        hdr.udp.length = 8 + 12 + PAYLOAD_LEN + 4;
        hdr.ipv4.total_len = 20 + 8 + 12 + PAYLOAD_LEN + 4;
        hdr.udp.checksum = 0;
    }

    /***************************************************************************
     * RX 信息设置表 - 用于 loopback 构造 WRITE_FIRST
     ***************************************************************************/
    action set_rx_info(bit<48> dst_mac, bit<32> dst_ip, bit<24> dst_qp, bit<32> rkey) {
        hdr.eth.dst_addr = dst_mac;
        hdr.ipv4.dst_addr = dst_ip;
        hdr.bth.dst_qp = dst_qp;
        hdr.reth.rkey = rkey;
    }

    table tbl_rx_info {
        key = {
            eg_md.bridge.channel_id : exact;
            eg_md.bridge.root_rank_id : exact;
        }
        actions = {
            set_rx_info;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }

    /***************************************************************************
     * Apply
     ***************************************************************************/
    apply {
        
        channel_id = (bit<32>)eg_md.bridge.channel_id;
        
        // ================================================================
        // 1. Loopback 端口输出 - 构造 WRITE_FIRST 发往 loopback 继续处理
        // ================================================================
        if (eg_intr_md.egress_port == LOOPBACK_PORT) {
            // 构造完整的 WRITE_FIRST
            hdr.bth.opcode = RDMA_OP_WRITE_FIRST;
            
            // 设置 RETH
            hdr.reth.setValid();
            hdr.reth.addr[31:0] = eg_md.bridge.next_token_addr.lo;
            hdr.reth.addr[63:32] = eg_md.bridge.next_token_addr.hi;
            hdr.reth.length = TOKEN_SIZE;
            
            // 设置 payload.data00 存储 loc
            hdr.payload.setValid();
            if (!eg_md.bridge.is_loopback) {
                // 来自 CONN_TX，第一次启动 loop，设置当前 loc
                hdr.payload.data00 = (bit<32>)eg_md.bridge.tx_loc_val;
            }
            // 如果 is_loopback，payload.data00 已经在 ingress 设置了 next_loc
            
            // 查表设置 rx 信息（dst_mac, dst_ip, dst_qp, rkey）
            tbl_rx_info.apply();
            
            // 设置包长度
            set_write_first_len();
            
            // AETH 无效
            hdr.aeth.setInvalid();
            
            return;
        }
        
        // ================================================================
        // 2. is_loopback 广播包 - 发送到 rx 的 TOKEN_PACKETS 个包
        // ================================================================
        if (eg_intr_md.egress_port != LOOPBACK_PORT && eg_md.bridge.is_loopback) {
            // 根据 egress_rid 确定这是第几个包（0 到 TOKEN_PACKETS-1）
            bit<8> pkt_offset = (bit<8>)eg_intr_md.egress_rid;
            
            // 处理 PSN
            hdr.bth.psn = hdr.bth.psn + (bit<24>)pkt_offset;
            
            // 计算 buffer index 并读取聚合结果
            buffer_idx = channel_id * PACKET_NUM_PER_CHANNEL_BUFFER 
                       + (bit<32>)eg_md.bridge.tx_loc_val * TOKEN_PACKETS 
                       + (bit<32>)pkt_offset;
            
            bit<32> agg_result = ra_read_agg.execute(buffer_idx);
            
            // 设置 payload
            hdr.payload.setValid();
            hdr.payload.data00 = agg_result;
            
            // 根据 pkt_offset 设置 opcode 和 header
            if (pkt_offset == 0) {
                // 第一个包: WRITE_FIRST
                hdr.bth.opcode = RDMA_OP_WRITE_FIRST;
                // reth 地址已在 ingress 从原始包保留
                hdr.reth.setValid();
                hdr.reth.length = TOKEN_SIZE;
                set_write_first_len();
            } else if (pkt_offset == TOKEN_PACKETS - 1) {
                // 最后一个包: WRITE_LAST
                hdr.bth.opcode = RDMA_OP_WRITE_LAST;
                hdr.reth.setInvalid();
                set_write_middle_len();
            } else {
                // 中间的包: WRITE_MIDDLE
                hdr.bth.opcode = RDMA_OP_WRITE_MIDDLE;
                hdr.reth.setInvalid();
                set_write_middle_len();
            }
            
            // AETH 无效（WRITE 包没有 AETH）
            hdr.aeth.setInvalid();
            
            return;
        }
        
        // ================================================================
        // 3. CONN_TX - 聚合数据并返回 ACK
        // ================================================================
        if (eg_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_TX && 
            eg_intr_md.egress_port != LOOPBACK_PORT) {
            // 计算 buffer index
            buffer_idx = channel_id * PACKET_NUM_PER_CHANNEL_BUFFER 
                       + (bit<32>)eg_md.bridge.tx_loc_val * TOKEN_PACKETS 
                       + (bit<32>)eg_md.bridge.tx_offset_val;

            agg_val = hdr.payload.data00;

            // 聚合或存储
            if (eg_md.bridge.clear_offset <= eg_md.bridge.tx_offset_val) {
                ra_store.execute(buffer_idx);
            } else {
                ra_aggregate.execute(buffer_idx);
            }
            
            // 设置 ACK 包
            swap_l2_l3_l4();
            set_ack_len();
            
            // 设置 header valid/invalid
            // AETH 已在 ingress 设置了 syndrome/psn/msn
            hdr.aeth.setValid();
            hdr.bth.opcode = RDMA_OP_ACK;
            hdr.reth.setInvalid();
            hdr.payload.setInvalid();
            
            return;
        }
        
        // ================================================================
        // 4. CONN_CONTROL READ_RESPONSE（已在 ingress 完成，只需要设置）
        // ================================================================
        if (eg_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            // 设置包长度 UDP: BTH(12) + AETH(4) + Payload(128) + ICRC(4) = 148, + UDP header(8) = 156 IP: UDP(156) + IP header(20) = 176
            hdr.udp.length = 156;
            hdr.ipv4.total_len = 176;
            hdr.udp.checksum = 0;
            swap_l2_l3_l4();
            hdr.reth.setInvalid();
            hdr.payload.setValid();
            hdr.bth.opcode = RDMA_OP_READ_RES_ONLY;
            return;
        }

        // ================================================================
        // 5. 其他 ACK 包（CONN_BITMAP）
        // ================================================================
        if (eg_md.bridge.has_aeth) {
            swap_l2_l3_l4();
            set_ack_len();
            hdr.reth.setInvalid();
            hdr.payload.setInvalid();
            hdr.bth.opcode = RDMA_OP_ACK;
            return;
        }
        
        
    }
}