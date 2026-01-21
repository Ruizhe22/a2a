/*******************************************************************************
 * Combine Control for AllToAll Communication - In-Network Aggregation
 * 
 * Aggregate the first 4 bytes of each packet
 * 
 * Connection types:
 * - CONN_CONTROL: query queue pointer (READ)
 * - CONN_BITMAP: rx writes bitmap (WRITE)
 * - CONN_TX: tx writes token for aggregation (WRITE)
 * - CONN_RX: rx reads aggregation result (READ)
 * 
 * Data structures:
 * - tx_epsn[j]: expected PSN from j-th tx
 * - tx_msn[j]: MSN of j-th tx
 * - tx_loc[j]: queue position of current token for j-th tx
 * - tx_packet_offset[j]: packet offset within current token for j-th tx
 * - rx_bitmap_epsn: ePSN for bitmap connection
 * - rx_token_epsn: ePSN for token connection
 * - rx_token_msn: MSN for token connection
 * - bitmap_buffer[loc]: remaining tx bitmap to aggregate
 * - agg_count[loc][packet]: number of tx aggregated
 * - queue_head, queue_tail, queue_incomplete: queue pointers
 ******************************************************************************/

#define NUM_COMBINE_CHANNELS_PER_RX 8
#define COMBINE_QUEUE_LENGTH 64        // number of tokens in the queue 
#define TOKEN_SIZE 7168                // 7K bytes
#define PAYLOAD_LEN 1024               // 1K per packet
#define TOKEN_PACKETS (TOKEN_SIZE / PAYLOAD_LEN) // 7
#define N_AGG_SLOTS 32                 // number of aggregation slots (128 bytes / 4)
#define BYTES_PER_SLOT 4               // each slot 4 bytes, bit<32>
#define BITMAP_PER_PACKET 8            // number of bitmaps per bitmap write packet

// Index calculations
#define COMBINE_CHANNELS_TOTAL (EP_SIZE * NUM_COMBINE_CHANNELS_PER_RX)                    // 64
#define PACKET_NUM_PER_CHANNEL_BUFFER (COMBINE_QUEUE_LENGTH * TOKEN_PACKETS)    // each entry corresponds to an offset position, 448
#define COMBINE_BUFFER_ENTRIES (COMBINE_CHANNELS_TOTAL * PACKET_NUM_PER_CHANNEL_BUFFER)   // 28672, entry->packet
#define COMBINE_TX_ENTRIES (COMBINE_CHANNELS_TOTAL * EP_SIZE)                      // 512
#define COMBINE_BITMAP_ENTRIES (COMBINE_CHANNELS_TOTAL * COMBINE_QUEUE_LENGTH)     // 4096

/*******************************************************************************
 * Queue Pointer Slot - manage queue pointer for each connection
 * channel_id = channel_class * EP_SIZE + _rank_id
 ******************************************************************************/

control QueuePointerSlot(
    inout bit<32> result,
    in COMBINE_QUEUE_POINTER_REG_OP operation,
    in bit<32> channel_class) 
{

    Register<bit<32>, bit<32>>(NUM_COMBINE_CHANNELS_PER_RX) reg_ptr;

    RegisterAction<bit<32>, bit<32>, void>(reg_ptr) ra_init = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_ptr) ra_read = {
        void apply(inout bit<32> value, out bit<32> res) {
            res = value;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_ptr) ra_inc = {
        void apply(inout bit<32> value) {
            if (value == COMBINE_QUEUE_LENGTH - 1) {
                value = 0;
            } else {
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_ptr) ra_read_add = {
        void apply(inout bit<32> value, out bit<32> res) {
            res = value;
            if (value >= COMBINE_QUEUE_LENGTH - 8) {
                value = value + 8 - COMBINE_QUEUE_LENGTH;
            } else {
                value = value + 8;
            }
        }
    };

    // Wrapped actions - write to control's inout result directly
    action do_init(bit<32> idx) {
        ra_init.execute(idx);
    }

    action do_read(bit<32> idx) {
        result = ra_read.execute(idx);
    }

    action do_inc(bit<32> idx) {
        ra_inc.execute(idx);
    }

    action do_read_add(bit<32> idx) {
        result = ra_read_add.execute(idx);
    }

    apply {
        if (operation == COMBINE_QUEUE_POINTER_REG_OP.OP_INIT) {
            do_init(channel_class);
        } else if (operation == COMBINE_QUEUE_POINTER_REG_OP.OP_READ) {
            do_read(channel_class);
        } else if (operation == COMBINE_QUEUE_POINTER_REG_OP.OP_INC) {
            do_inc(channel_class);
        } else if (operation == COMBINE_QUEUE_POINTER_REG_OP.OP_READ_ADD) {
            do_read_add(channel_class);
        }
    }
}

/*******************************************************************************
 * BitmapSlot - Bitmap buffer management for a single RX
 *
 * Each slot manages the bitmaps for all queue positions of one RX
 ******************************************************************************/
control BitmapSlot(
        out bitmap_tofino_t result,
        in bitmap_tofino_t write_val,
        in bitmap_tofino_t clear_mask,
        in COMBINE_BITMAP_REG_OP operation,
        in a2a_ingress_metadata_t ig_md)
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

    // Wrapped actions - write to control's out result directly
    action do_read(bit<32> idx) {
        result = ra_read.execute(idx);
    }

    action do_write(bit<32> idx) {
        ra_write.execute(idx);
    }

    action do_clear_bit(bit<32> idx) {
        result = ra_clear_bit.execute(idx);
    }

    action do_reset(bit<32> idx) {
        ra_reset.execute(idx);
    }

    apply {
        if (operation == COMBINE_BITMAP_REG_OP.OP_READ) {
            do_read(ig_md.slot_index);
        } else if (operation == COMBINE_BITMAP_REG_OP.OP_WRITE) {
            w_val = write_val;
            do_write(ig_md.slot_index);
        } else if (operation == COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT) {
            c_mask = clear_mask;
            do_clear_bit(ig_md.slot_index);
        } else if (operation == COMBINE_BITMAP_REG_OP.OP_RESET) {
            do_reset(ig_md.slot_index);
        }
    }
}


/*******************************************************************************
 * AddrSlot - 1/8 of the Addr Buffer
 *
 * Adjacent tokens are distributed across 8 slots
 * ig_md.token_idx = channel_id * COMBINE_QUEUE_LENGTH + loc
 * slot_id = ig_md.token_idx % 8 = ig_md.token_idx[2:0]
 * ig_md.slot_index = ig_md.token_idx / 8 = ig_md.token_idx >> 3
 ******************************************************************************/
control AddrSlot(
    out addr_tofino_t result,
    in addr_tofino_t write_val,
    in COMBINE_ADDR_REG_OP operation,
    in a2a_ingress_metadata_t ig_md)
{

    // each slot stores COMBINE_BITMAP_ENTRIES / 8 addrs
    Register<addr_half_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) reg_addr_lo;

    // read
    RegisterAction<addr_half_t, bit<32>, addr_half_t>(reg_addr_lo) ra_lo_read = {
        void apply(inout addr_half_t value, out addr_half_t res) {
            res = value;
        }
    };

    // write
    RegisterAction<addr_half_t, bit<32>, void>(reg_addr_lo) ra_lo_write = {
        void apply(inout addr_half_t value) {
            value = write_val[31:0];
        }
    };

    // each slot stores COMBINE_BITMAP_ENTRIES / 8 addrs
    Register<addr_half_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) reg_addr_hi;

    // read
    RegisterAction<addr_half_t, bit<32>, addr_half_t>(reg_addr_hi) ra_hi_read = {
        void apply(inout addr_half_t value, out addr_half_t res) {
            res = value;
        }
    };

    // write
    RegisterAction<addr_half_t, bit<32>, void>(reg_addr_hi) ra_hi_write = {
        void apply(inout addr_half_t value) {
            value = write_val[63:32];
        }
    };

    // Wrapped actions - write to control's out result directly
    action do_lo_read(bit<32> idx) {
        result[31:0] = ra_lo_read.execute(idx);
    }

    action do_hi_read(bit<32> idx) {
        result[63:32] = ra_hi_read.execute(idx);
    }

    action do_lo_write(bit<32> idx) {
        ra_lo_write.execute(idx);
    }

    action do_hi_write(bit<32> idx) {
        ra_hi_write.execute(idx);
    }

    apply {
        if (operation == COMBINE_ADDR_REG_OP.OP_READ) {
            do_lo_read(ig_md.slot_index);
            do_hi_read(ig_md.slot_index);
        } else if (operation == COMBINE_ADDR_REG_OP.OP_WRITE) {
            do_lo_write(ig_md.slot_index);
            do_hi_write(ig_md.slot_index);
        }
    }
}


/*******************************************************************************
 * CombineIngress - main control logic
 ******************************************************************************/
control CombineIngress(
    inout a2a_headers_t hdr,
    inout a2a_ingress_metadata_t ig_md,
    in ingress_intrinsic_metadata_t ig_intr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md)
{

    /***************************************************************************
     * Variables
     ***************************************************************************/
     
    // Temporary variables for register action results
    bit<32> tmp_result_32;
    bit<32> tmp_result_8;

    /***************************************************************************
     * TX State Registers
     * Index: channel_id * EP_SIZE + ing_rank_id
     ***************************************************************************/
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES, 0) reg_tx_epsn;
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES) reg_tx_msn;
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES) reg_tx_loc;
    Register<bit<32>, bit<32>>(COMBINE_TX_ENTRIES) reg_tx_packet_offset;


    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_epsn) ra_read_cond_inc_tx_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if( ig_md.psn_to_check == value) {
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

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_loc) ra_read_tx_loc = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_loc) ra_write_tx_loc = {
        void apply(inout bit<32> value) {
            value = ig_md.bridge.tx_loc_val;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_tx_packet_offset) ra_read_inc_tx_offset = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            value = value + 1;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_tx_packet_offset) ra_reset_tx_offset = {
            void apply(inout bit<32> value) {
            value = 1;  // reset to 1 (current packet is 0, next is 1)
        }
    };

    // Wrapped actions for TX state registers - write to tmp variables
    action do_read_cond_inc_tx_epsn(bit<32> idx) {
        tmp_result_32 = ra_read_cond_inc_tx_epsn.execute(idx);
    }

    action do_init_tx_epsn(bit<32> idx) {
        ra_init_tx_epsn.execute(idx);
    }

    action do_read_tx_msn(bit<32> idx) {
        tmp_result_32 = ra_read_tx_msn.execute(idx);
    }

    action do_read_inc_tx_msn(bit<32> idx) {
        tmp_result_32 = ra_read_inc_tx_msn.execute(idx);
    }

    action do_init_tx_msn(bit<32> idx) {
        ra_init_tx_msn.execute(idx);
    }

    action do_read_tx_loc(bit<32> idx) {
        tmp_result_8 = ra_read_tx_loc.execute(idx);
    }

    action do_write_tx_loc(bit<32> idx) {
        ra_write_tx_loc.execute(idx);
    }

    action do_read_inc_tx_offset(bit<32> idx) {
        tmp_result_8 = ra_read_inc_tx_offset.execute(idx);
    }

    action do_reset_tx_offset(bit<32> idx) {
        ra_reset_tx_offset.execute(idx);
    }

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
            if (ig_md.psn_to_check == value) {
                // PSN matches: increment value
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_rx_bitmap_epsn) ra_init_rx_bitmap_epsn = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };


    // Read current epsn (do not update)
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_rx_token_epsn) ra_read_rx_token_epsn = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    // Read and add TOKEN_PACKETS
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

    // Wrapped actions for RX state registers
    action do_read_rx_bitmap_epsn(bit<32> idx) {
        tmp_result_32 = ra_read_rx_bitmap_epsn.execute(idx);
    }

    action do_read_cond_inc_rx_bitmap_epsn(bit<32> idx) {
        tmp_result_32 = ra_read_cond_inc_rx_bitmap_epsn.execute(idx);
    }

    action do_init_rx_bitmap_epsn(bit<32> idx) {
        ra_init_rx_bitmap_epsn.execute(idx);
    }

    action do_read_rx_token_epsn(bit<32> idx) {
        tmp_result_32 = ra_read_rx_token_epsn.execute(idx);
    }

    action do_read_add_rx_token_epsn(bit<32> idx) {
        tmp_result_32 = ra_read_add_rx_token_epsn.execute(idx);
    }

    action do_init_rx_token_epsn(bit<32> idx) {
        ra_init_rx_token_epsn.execute(idx);
    }

    action do_read_inc_rx_token_msn(bit<32> idx) {
        tmp_result_32 = ra_read_inc_rx_token_msn.execute(idx);
    }

    /***************************************************************************
     * Queue State Registers
     * Index: rank_id choose which slot and channel_class is the index 
     * Queue Pointer Slots (EP_SIZE = 8)
    * Each RX has its own queue_head and queue_tail
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
     
    Register<bit<32>, bit<32>>(COMBINE_CHANNELS_TOTAL) reg_queue_incomplete;

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_queue_incomplete) ra_read_queue_incomplete = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_queue_incomplete) ra_read_cond_inc_queue_incomplete = {
        void apply(inout bit<32> value, out bit<32> result) {
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

    RegisterAction<bit<32>, bit<32>, void>(reg_queue_incomplete) ra_init_queue_incomplete = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    // Wrapped actions for queue incomplete
    action do_read_queue_incomplete(bit<32> idx) {
        tmp_result_8 = ra_read_queue_incomplete.execute(idx);
    }

    action do_read_cond_inc_queue_incomplete(bit<32> idx) {
        tmp_result_8 = ra_read_cond_inc_queue_incomplete.execute(idx);
    }

    action do_init_queue_incomplete(bit<32> idx) {
        ra_init_queue_incomplete.execute(idx);
    }

    /***************************************************************************
     * Buffer Token State Registers
    * One element per token
    * Index: channel_id * COMBINE_QUEUE_LENGTH + loc  // in bitmap, loc = queue_tail (before inc)
    * Bitmap Slots - each packet corresponds to BITMAP_PER_PACKET (8) bitmap slots for distributed writes
    * Addr Slots - each packet corresponds to 8 addr slots for distributed writes
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

    Register<bit<32>, bit<32>>(COMBINE_BITMAP_ENTRIES) reg_clear_buffer;
    

    // Before calling, set ig_md.bridge.tx_offset_val; a Register can only be read once, so write it this way
    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_clear_buffer) ra_read_set_clear = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
            if(value <= ig_md.bridge.tx_offset_val){ // ideally should be ==
                value = value + 1;
            }
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_clear_buffer) ra_reset_clear = {
        void apply(inout bit<32> value) {
            value = 0;
        }
    };

    // Wrapped actions for clear buffer
    action do_read_set_clear(bit<32> idx) {
        tmp_result_8 = ra_read_set_clear.execute(idx);
    }

    action do_reset_clear(bit<32> idx) {
        ra_reset_clear.execute(idx);
    }

    /***************************************************************************
     * Variables
     ***************************************************************************/
    bit<32> channel_id;
    bit<32> channel_class;
    bit<32> queue_head;
    bit<32> queue_tail;
    bit<32> queue_incomplete;
    bit<32> tx_reg_idx;
    bit<32> buffer_idx;
    
    bit<32> slot_id;

    //bit<32> token_idx;

    /***************************************************************************
     * Utility Actions
     ***************************************************************************/
    bit<32> tmp_mul_256;

    action mul_256(){
        tmp_mul_256 = tmp_mul_256 * 256;
    }

    action set_aeth_msn() {
        ig_md.bridge.has_aeth = true;
        hdr.aeth.setValid();
        hdr.aeth.msn = tmp_mul_256 * 256;
    }

    action set_aeth_syndrome(bit<32> syndrome) {
        hdr.aeth.msn = hdr.aeth.msn + syndrome;
    }

    action set_aeth_psn(bit<32> psn) {
        hdr.bth.psn = psn; // If there's an ack header (e.g., RDMA_OP_ACK or Read response), PSN is determined by the ack, set here

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
        // ACK packet: UDP(8) + BTH(12) + AETH(4) + ICRC(4) = 28
        hdr.udp.length = 28;
        hdr.ipv4.total_len = 48;
        hdr.udp.checksum = 0;
    }

    /*
     * ig_md.bitmap_clear_mask
     */

    action set_bitmap_clear_mask(bitmap_tofino_t m) {
        ig_md.bitmap_clear_mask = m;
    }

    table tbl_rank_to_clear_mask {
        key = {
            ig_md.bridge.ing_rank_id : exact;
        }
        actions = {
            set_bitmap_clear_mask;
        }
        size = 8;
        default_action = set_bitmap_clear_mask((bitmap_tofino_t)0);

        const entries = {
            0 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x01);
            1 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x02);
            2 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x04);
            3 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x08);
            4 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x10);
            5 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x20);
            6 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x40);
            7 : set_bitmap_clear_mask((bitmap_tofino_t)8w0x80);
        }
    }

    /***************************************************************************
    * Index Calculation Actions - 拆分复杂计算
    ***************************************************************************/

    /**
     * 0. devide the calculations into multiple steps    
     */
    action step1_cal_tx_reg_idx() {
        tx_reg_idx =(bit<32>)ig_md.bridge.ing_rank_id; // no use for loop port
    }
    
    bit<32> channel_mul_8;

    action step2_cal_tx_reg_idx() {
        channel_mul_8 = channel_id << 3;  // channel_id * 8
    }
    
    action step3_cal_tx_reg_idx() {
        tx_reg_idx = tx_reg_idx + channel_mul_8;
    }

    // ============================================================
    // 1. ig_md.token_idx = channel_id * COMBINE_QUEUE_LENGTH + (bit<32>)queue_tail
    //    COMBINE_QUEUE_LENGTH = 64 = << 6
    // ============================================================
    bit<32> channel_mul_64;

    action step1_calc_token_idx_from_tail() {
        channel_mul_64 = channel_id << 6;  // channel_id * 64
    }

    action step2_calc_token_idx_from_tail() {
        ig_md.token_idx = (bit<32>)queue_tail;
    }

    action step3_calc_token_idx_from_tail() {
        ig_md.token_idx = ig_md.token_idx + channel_mul_64;
    }

    // 使用方式:
    // step1_calc_token_idx_from_tail();
    // step2_calc_token_idx_from_tail();
    // step3_calc_token_idx_from_tail();


    // ============================================================
    // 2. ig_md.slot_index = ig_md.token_idx >> 3
    //    这个比较简单，可能单独一个action就行
    // ============================================================
    action calc_slot_index_from_token_idx() {
        ig_md.slot_index = ig_md.token_idx >> 3;
    }


    // ============================================================
    // 3. ig_md.slot_index = next_token_idx >> 3
    //    注意：这里是 slot_index 不是 token_idx
    // ============================================================
    bit<32> next_token_idx;  // 需要在外部声明

    action calc_slot_index_from_next_token() {
        ig_md.slot_index = next_token_idx >> 3;
    }


    // ============================================================
    // 4. ig_md.token_idx = channel_id * 64 + (bit<32>)ig_md.bridge.tx_loc_val
    // ============================================================
    action step1_calc_token_idx_from_tx_loc() {
        channel_mul_64 = channel_id << 6;  // channel_id * 64
    }

    action step2_calc_token_idx_from_tx_loc() {
        ig_md.token_idx = (bit<32>)ig_md.bridge.tx_loc_val;
    }

    action step3_calc_token_idx_from_tx_loc() {
        ig_md.token_idx = ig_md.token_idx + channel_mul_64;
    }

    
    bit<32> temp_head_shifted;


    action step1_calc_shift_head() {
        temp_head_shifted = queue_head << 16;
    }

    action step2_calc_combine_tail() {
        ig_md.temp_queue_data = temp_head_shifted | queue_tail;
    }

    action step3_write_payload_data_0() {
        hdr.payload.data00 = ig_md.temp_queue_data;
    }

    action step3_write_payload_data_1() {
        hdr.payload.data01 = ig_md.temp_queue_data;
    }

    action step3_write_payload_data_2() {
        hdr.payload.data02 = ig_md.temp_queue_data;
    }

    action step3_write_payload_data_3() {
        hdr.payload.data03 = ig_md.temp_queue_data;
    }

    action step3_write_payload_data_4() {
        hdr.payload.data04 = ig_md.temp_queue_data;
    }

    action step3_write_payload_data_5() {
        hdr.payload.data05 = ig_md.temp_queue_data;
    }

    action step3_write_payload_data_6() {
        hdr.payload.data06 = ig_md.temp_queue_data;
    }

    action step3_write_payload_data_7() {
        hdr.payload.data07 = ig_md.temp_queue_data;
    }


    action step1_calc_next_token_idx_from_next_loc() {
        channel_mul_64 = channel_id << 6;  // channel_id * 64
    }

    action step2_calc_next_token_idx_from_next_loc() {
        next_token_idx = ig_md.next_loc;
    }

    action step3_calc_next_token_idx_from_next_loc() {
        next_token_idx = next_token_idx + channel_mul_64;
    }


    bitmap_tofino_t bitmap_result;
    bitmap_tofino_t bitmap_write_val;
    addr_tofino_t addr_result;
    addr_tofino_t addr_write_val;

    action step_write_addr_lo() {
        ig_md.bridge.next_token_addr[31:0] = addr_result[31:0];
    }

    action step_write_addr_hi() {
        ig_md.bridge.next_token_addr[63:32] = addr_result[63:32];
    }
    /***************************************************************************
     * Apply
     ***************************************************************************/
    apply {
        channel_id = ig_md.bridge.channel_id;
        channel_class = ig_md.channel_class;
        //tx_reg_idx =(bit<32>)ig_md.bridge.ing_rank_id; // no use for loop port
        step1_cal_tx_reg_idx();
        step2_cal_tx_reg_idx();
        step3_cal_tx_reg_idx();
        //bit<32> channel_multiply_8 = channel_id << 3 ;
        //bit<32> tx_reg_idx_tmp = tx_reg_idx + channel_multiply_8;
        //tx_reg_idx = tx_reg_idx_tmp;

        

        // ================================================================
        // CONN_CONTROL: query queue pointer (READ)
        // ================================================================
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            if (hdr.bth.opcode == RDMA_OP_READ_REQ) {
                // Construct READ_RESPONSE_ONLY
                queue_head_slot_0.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_0.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                step1_calc_shift_head();
                step2_calc_combine_tail();
                step3_write_payload_data_0();
                //hdr.payload.data00 = (queue_head << 16) | queue_tail;

                queue_head_slot_1.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_1.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                //hdr.payload.data01 = (queue_head << 16) | queue_tail;
                step1_calc_shift_head();
                step2_calc_combine_tail();
                step3_write_payload_data_1();

                queue_head_slot_2.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_2.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                //hdr.payload.data02 = (queue_head << 16) | queue_tail;
                step1_calc_shift_head();
                step2_calc_combine_tail();
                step3_write_payload_data_2();

                queue_head_slot_3.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_3.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                //hdr.payload.data03 = (queue_head << 16) | queue_tail;
                step1_calc_shift_head();
                step2_calc_combine_tail();
                step3_write_payload_data_3();

                queue_head_slot_4.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_4.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                //hdr.payload.data04 = (queue_head << 16) | queue_tail;
                step1_calc_shift_head();
                step2_calc_combine_tail();
                step3_write_payload_data_4();

                queue_head_slot_5.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_5.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                //hdr.payload.data05 = (queue_head << 16) | queue_tail;
                step1_calc_shift_head();
                step2_calc_combine_tail();
                step3_write_payload_data_5();

                queue_head_slot_6.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_6.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                //hdr.payload.data06 = (queue_head << 16) | queue_tail;
                step1_calc_shift_head();
                step2_calc_combine_tail();
                step3_write_payload_data_6();

                queue_head_slot_7.apply(queue_head, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                queue_tail_slot_7.apply(queue_tail, COMBINE_QUEUE_POINTER_REG_OP.OP_READ, channel_class);
                //hdr.payload.data07 = (queue_head << 16) | queue_tail;
                step1_calc_shift_head();
                step2_calc_combine_tail();
                step3_write_payload_data_0();

                tmp_mul_256 = ig_md.psn + 32w1;
                mul_256();
                set_aeth_msn();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_psn(ig_md.psn);

                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            }
            return;
        }

        // ================================================================
        // CONN_BITMAP: rx writes bitmap (WRITE_ONLY)
        // ================================================================
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }
            ig_md.psn_to_check = ig_md.psn;
            do_read_cond_inc_rx_bitmap_epsn(channel_id);
            bit<32> expected_psn = tmp_result_32;
            
            if (ig_md.psn == expected_psn) {
                // PSN matches, write bitmap
                // Select corresponding slot by rx_id to read and update queue_tail
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
                
                // Write bitmap and addr

                step1_calc_token_idx_from_tail();
                step2_calc_token_idx_from_tail();
                step3_calc_token_idx_from_tail();
                calc_slot_index_from_token_idx();      // ig_md.token_idx / 8
                
                bitmap_write_val = hdr.payload.data00;
                bitmap_slot_0.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_REG_OP.OP_WRITE, ig_md);
                bitmap_write_val = hdr.payload.data01;
                bitmap_slot_1.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_REG_OP.OP_WRITE, ig_md);
                bitmap_write_val = hdr.payload.data02;
                bitmap_slot_2.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_REG_OP.OP_WRITE, ig_md);
                bitmap_write_val = hdr.payload.data03;
                bitmap_slot_3.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_REG_OP.OP_WRITE, ig_md);
                bitmap_write_val = hdr.payload.data04;
                bitmap_slot_4.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_REG_OP.OP_WRITE, ig_md);
                bitmap_write_val = hdr.payload.data05;
                bitmap_slot_5.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_REG_OP.OP_WRITE, ig_md);
                bitmap_write_val = hdr.payload.data06;
                bitmap_slot_6.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_REG_OP.OP_WRITE, ig_md);
                bitmap_write_val = hdr.payload.data07;
                bitmap_slot_7.apply(bitmap_result, bitmap_write_val, 0, COMBINE_BITMAP_REG_OP.OP_WRITE, ig_md);
                
                addr_write_val[31:0] = hdr.payload.data08;
                addr_write_val[63:32] = hdr.payload.data09;
                addr_slot_0.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, ig_md);
                addr_write_val[31:0] = hdr.payload.data0a;
                addr_write_val[63:32] = hdr.payload.data0b;
                addr_slot_1.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, ig_md);
                addr_write_val[31:0] = hdr.payload.data0c;
                addr_write_val[63:32] = hdr.payload.data0d;
                addr_slot_2.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, ig_md);
                addr_write_val[31:0] = hdr.payload.data0e;
                addr_write_val[63:32] = hdr.payload.data0f;
                addr_slot_3.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, ig_md);
                addr_write_val[31:0] = hdr.payload.data10;
                addr_write_val[63:32] = hdr.payload.data11;
                addr_slot_4.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, ig_md);
                addr_write_val[31:0] = hdr.payload.data12;
                addr_write_val[63:32] = hdr.payload.data13;
                addr_slot_5.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, ig_md);
                addr_write_val[31:0] = hdr.payload.data14;
                addr_write_val[63:32] = hdr.payload.data15;
                addr_slot_6.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, ig_md);
                addr_write_val[31:0] = hdr.payload.data16;
                addr_write_val[63:32] = hdr.payload.data17;
                addr_slot_7.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_WRITE, ig_md);

                // return ACK
                tmp_mul_256 = ig_md.psn + 32w1;
                mul_256();
                set_aeth_msn();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_psn(ig_md.psn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else if (ig_md.psn < expected_psn) {
                // duplicate packet
                //set_aeth_ingress(AETH_ACK_CREDIT_INVALID, expected_psn - 1, expected_psn);
                tmp_mul_256 = expected_psn;
                mul_256();
                set_aeth_msn();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_psn(expected_psn - 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else {
                // packet loss, return NAK
                //set_aeth_ingress(AETH_NAK_SEQ_ERR, (expected_psn - 1), expected_psn);
                tmp_mul_256 = expected_psn;
                mul_256();
                set_aeth_msn();
                set_aeth_syndrome(AETH_NAK_SEQ_ERR);
                set_aeth_psn(expected_psn - 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            }
            return;
        }

        // ================================================================
        // CONN_TX: tx writes token (WRITE) - aggregation
        // Bitmap storage must be in ingress to determine if token aggregation is complete and then broadcast
        // Token buffer must be in egress because broadcast needs to read packets at different offsets
        // ================================================================
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_TX && ig_intr_md.ingress_port != LOOPBACK_PORT) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_FIRST && 
                hdr.bth.opcode != RDMA_OP_WRITE_MIDDLE &&
                hdr.bth.opcode != RDMA_OP_WRITE_LAST &&
                hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }

            ig_md.psn_to_check = ig_md.psn;
            do_read_cond_inc_tx_epsn(tx_reg_idx);
            bit<32> expected_psn = tmp_result_32;
            do_read_tx_msn(tx_reg_idx);
            bit<32> current_msn = tmp_result_32;
            
            if (ig_md.psn == expected_psn) {
                // PSN matches
                // Get loc and packet_offset
                if (hdr.bth.opcode == RDMA_OP_WRITE_FIRST || 
                    hdr.bth.opcode == RDMA_OP_WRITE_ONLY) {
                    // Get loc from reth.addr
                    ig_md.bridge.tx_loc_val = hdr.reth.addr[63:32];
                    ig_md.bridge.tx_offset_val = 0;
                    do_write_tx_loc(tx_reg_idx);
                    do_reset_tx_offset(tx_reg_idx);
                } else {
                    // Get from registers
                    do_read_tx_loc(tx_reg_idx);
                    ig_md.bridge.tx_loc_val = tmp_result_8;
                    do_read_inc_tx_offset(tx_reg_idx);
                    ig_md.bridge.tx_offset_val = tmp_result_8;
                }
                
                //ig_md.token_idx = channel_id * COMBINE_QUEUE_LENGTH + (bit<32>)ig_md.bridge.tx_loc_val;
                step1_calc_token_idx_from_tx_loc();
                step2_calc_token_idx_from_tx_loc();
                step3_calc_token_idx_from_tx_loc();
                slot_id = ig_md.token_idx;
                // Check whether this is the first tx to arrive
                do_read_set_clear(ig_md.token_idx);
                ig_md.bridge.clear_offset = tmp_result_8;
                
                // If WRITE_LAST/ONLY: clear tx bit in bitmap and update MSN
                if (hdr.bth.opcode == RDMA_OP_WRITE_ONLY || 
                    hdr.bth.opcode == RDMA_OP_WRITE_LAST) {
                    
                    calc_slot_index_from_token_idx();     // ig_md.token_idx / 8
                    //ig_md.slot_index = (bit<32>)ig_md.bridge.channel_id + 1;      // ig_md.token_idx / 8
                    //ig_md.bitmap_clear_mask = (bitmap_tofino_t)1 << ig_md.bridge.ing_rank_id;
                    tbl_rank_to_clear_mask.apply();
                    //bitmap_tofino_t bitmap_after_clear = ra_clear_bit_bitmap.execute(ig_md.token_idx);
                    if (slot_id == 0) {
                        bitmap_slot_0.apply(bitmap_result, bitmap_write_val, ig_md.bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, ig_md);
                        addr_slot_0.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                    } else if (slot_id == 1) {
                        bitmap_slot_1.apply(bitmap_result, bitmap_write_val, ig_md.bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, ig_md);
                        addr_slot_1.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                    } else if (slot_id == 2) {
                        bitmap_slot_2.apply(bitmap_result, bitmap_write_val, ig_md.bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, ig_md);
                        addr_slot_2.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                    } else if (slot_id == 3) {
                        bitmap_slot_3.apply(bitmap_result, bitmap_write_val, ig_md.bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, ig_md);
                        addr_slot_3.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                    } else if (slot_id == 4) {
                        bitmap_slot_4.apply(bitmap_result, bitmap_write_val, ig_md.bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, ig_md);
                        addr_slot_4.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                    } else if (slot_id == 5) {
                        bitmap_slot_5.apply(bitmap_result, bitmap_write_val, ig_md.bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, ig_md);
                        addr_slot_5.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                    } else if (slot_id == 6) {
                        bitmap_slot_6.apply(bitmap_result, bitmap_write_val, ig_md.bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, ig_md);
                        addr_slot_6.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                    } else {  // slot_id == 7
                        bitmap_slot_7.apply(bitmap_result, bitmap_write_val, ig_md.bitmap_clear_mask, COMBINE_BITMAP_REG_OP.OP_CLEAR_BIT, ig_md);
                        addr_slot_7.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                    }

                    do_read_inc_tx_msn(tx_reg_idx);
                    current_msn = tmp_result_32;
                    if (bitmap_result == 0) {
                        do_read_cond_inc_queue_incomplete(channel_id);
                        queue_incomplete = tmp_result_8;
                        if( queue_incomplete == ig_md.bridge.tx_loc_val) {
                            // Update queue_head to match queue_incomplete
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
                            
                            // Convert packet to WRITE_FIRST; length and other fields are not set.
                            // On the first loop startup the incoming packet may have no RETH and may not fit.
                            //ig_md.bridge.next_token_addr = addr_result;
                            //ig_md.bridge.next_token_addr[31:0] = addr_result[31:0];
                            //ig_md.bridge.next_token_addr[63:32] = addr_result[63:32];
                            step_write_addr_lo();
                            step_write_addr_hi();

                        }
                    }
                }

                // return ACK
                //set_aeth_ingress(AETH_ACK_CREDIT_INVALID, expected_psn, current_msn);
                tmp_mul_256 = current_msn;
                mul_256();
                set_aeth_msn();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_psn(expected_psn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else if (ig_md.psn < expected_psn) {
                // duplicate packet
                //set_aeth_ingress(AETH_ACK_CREDIT_INVALID, (expected_psn - 1), current_msn);
                tmp_mul_256 = current_msn;
                mul_256();
                set_aeth_msn();
                set_aeth_syndrome(AETH_ACK_CREDIT_INVALID);
                set_aeth_psn(expected_psn - 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else {
                // packet loss
                //set_aeth_ingress(AETH_NAK_SEQ_ERR, (expected_psn - 1), current_msn);
                tmp_mul_256 = current_msn;
                mul_256();
                set_aeth_msn();
                set_aeth_syndrome(AETH_NAK_SEQ_ERR);
                set_aeth_psn(expected_psn - 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
            }
            return;
        }

        // ================================================================
        // loopback port; LOOPBACK_PORT not defined yet
        // This packet is guaranteed to be a WRITE_FIRST
        // reth
        //  data00: during ingress it's the token's bcast loc; during egress it's the next token's bcast loc
        // addr for this token remains unchanged during reception; during egress the loopback port will be set to the next token address stored in bridge during ingress
        // Fields of this packet are mostly set by the previous egress, except PSN, opcode, and payload which vary per packet.
        // ================================================================
        if (ig_intr_md.ingress_port == LOOPBACK_PORT && 
            hdr.bth.opcode == RDMA_OP_WRITE_FIRST) {
            
            // Get current loc from payload
            //bit<32> current_loc = hdr.payload.data00;
            ig_md.bridge.tx_loc_val = hdr.payload.data00;
            ig_md.bridge.is_loopback = true;
            
            // Set multicast to rx (TOKEN_PACKETS packets)
            bit<32> group = 100 + ig_md.bridge.root_rank_id;
            ig_tm_md.mcast_grp_a = (bit<16>)group;
            
            do_read_add_rx_token_epsn(channel_id);
            hdr.bth.psn = tmp_result_32;

            // Compute next loc (circular queue)
            if (hdr.payload.data00 >= COMBINE_QUEUE_LENGTH - 1) {
                ig_md.next_loc = 0;
            } else {
                ig_md.next_loc = hdr.payload.data00 + 1;
            }
            
            // Read queue_tail to check if tail is reached
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
            
            // If ig_md.next_loc == queue_tail, all tokens are processed; stop loopback
            if (ig_md.next_loc != queue_tail) {
                // Check if bitmap of next loc is zero
                //next_token_idx = channel_id * COMBINE_QUEUE_LENGTH + ig_md.next_loc;
                step1_calc_next_token_idx_from_next_loc();
                step2_calc_next_token_idx_from_next_loc();
                step3_calc_next_token_idx_from_next_loc();

                bit<32> next_slot_id = next_token_idx;
                calc_slot_index_from_next_token();
                
                bitmap_tofino_t next_bitmap_result;
                
                if (next_slot_id == 0) {
                    bitmap_slot_0.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, ig_md);
                    addr_slot_0.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                } else if (next_slot_id == 1) {
                    bitmap_slot_1.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, ig_md);
                    addr_slot_1.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                } else if (next_slot_id == 2) {
                    bitmap_slot_2.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, ig_md);
                    addr_slot_2.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                } else if (next_slot_id == 3) {
                    bitmap_slot_3.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, ig_md);
                    addr_slot_3.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                } else if (next_slot_id == 4) {
                    bitmap_slot_4.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, ig_md);
                    addr_slot_4.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                } else if (next_slot_id == 5) {
                    bitmap_slot_5.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, ig_md);
                    addr_slot_5.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                } else if (next_slot_id == 6) {
                    bitmap_slot_6.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, ig_md);
                    addr_slot_6.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                } else {
                    bitmap_slot_7.apply(next_bitmap_result, 0, 0, COMBINE_BITMAP_REG_OP.OP_READ, ig_md);
                    addr_slot_7.apply(addr_result, addr_write_val, COMBINE_ADDR_REG_OP.OP_READ, ig_md);
                }
                
                // Check queue_incomplete
                //bit<32> queue_incomplete_val = ra_read_queue_incomplete.execute(channel_id);
                
                // If next token is ready, continue loopback
                if (next_bitmap_result == 0 ) { //&& ig_md.next_loc == queue_incomplete_val
                    // Update queue_incomplete and queue_head
                    ig_md.bridge.tx_loc_val = ig_md.next_loc;
                    do_read_cond_inc_queue_incomplete(channel_id);
                    queue_incomplete = tmp_result_8;
                    // Restore current loc for egress
                    ig_md.bridge.tx_loc_val = hdr.payload.data00;
                    
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
                    
                    // Set loopback to continue and update payload.data00 to ig_md.next_loc
                    ig_tm_md.mcast_grp_b = LOOPBACK_MCAST_GRP;
                    hdr.payload.data00 = ig_md.next_loc;
                    //ig_md.bridge.next_token_addr[31:0] = addr_result[31:0];
                    //ig_md.bridge.next_token_addr[63:32] = addr_result[63:32];
                    step_write_addr_lo();
                    step_write_addr_hi();
                }
            }
            
            
            
            return;
        }

    }
}


/*******************************************************************************
 * CombineEgress
 * Processing:
 * 1. Loopback port output - construct WRITE_FIRST to continue loop
 * 2. Broadcast to rx - set opcode by rid, read aggregation result
 * 3. CONN_TX - aggregate and return ACK
 * 4. Other ACK packets
 ******************************************************************************/
control CombineEgress(
    inout a2a_headers_t hdr,
    inout a2a_egress_metadata_t eg_md,
    in egress_intrinsic_metadata_t eg_intr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    /***************************************************************************
     * Aggregator
     * Index: channel_id * PACKET_NUM_PER_CHANNEL_BUFFER + loc * TOKEN_PACKETS + packet_offset 
     ***************************************************************************/
    bit<32> agg_val;
    bit<32> buffer_idx;
    bit<32> channel_id;
    
    // Temporary variable for register action results
    bit<32> tmp_agg_result;
    
    Register<bit<32>, bit<32>>(COMBINE_BUFFER_ENTRIES) reg_agg;
    
    RegisterAction<bit<32>, bit<32>, void>(reg_agg) ra_store = {
        void apply(inout bit<32> value) {
            value = agg_val;
        }
    };

    RegisterAction<bit<32>, bit<32>, void>(reg_agg) ra_aggregate = {
        void apply(inout bit<32> value) {
            value = value + agg_val;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(reg_agg) ra_read_agg = {
        void apply(inout bit<32> value, out bit<32> res) {
            res = value;
        }
    };

    // Wrapped actions for aggregator - write to tmp variable
    action do_store(bit<32> idx) {
        ra_store.execute(idx);
    }

    action do_aggregate(bit<32> idx) {
        ra_aggregate.execute(idx);
    }

    action do_read_agg(bit<32> idx) {
        tmp_agg_result = ra_read_agg.execute(idx);
    }

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
     * RX info table - used to construct WRITE_FIRST for loopback
     ***************************************************************************/
    action set_rx_info(bit<48> dst_mac, bit<32> dst_ip, bit<32> dst_qp, bit<32> rkey) {
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

        // ============================================================
    // 5. buffer_idx = channel_id * (64 * (7168 / 1024)) = channel_id * 448
    //    448 = 512 - 64 = (1 << 9) - (1 << 6)
    //    
    //    完整公式: buffer_idx = channel_id * 448 + loc * 7 + offset
    //    7 = 8 - 1 = (1 << 3) - 1
    // ============================================================

    // 中间变量声明
    bit<32> channel_mul_512;
    bit<32> channel_mul_64;
    bit<32> channel_mul_448;
    bit<32> tmp_loc;         // 存储 loc 值
    bit<32> loc_mul_8;
    bit<32> loc_mul_7;
    bit<32> tmp_offset;      // 存储 offset 值

    // ============================================================
    // buffer_idx = channel_id * 448 + loc * 7 + offset
    // 448 = 512 - 64
    // 7 = 8 - 1
    // ============================================================

    // Step 1: channel_id * 512
    action step1_calc_buffer_idx() {
        channel_mul_512 = channel_id << 9;
    }

    // Step 2: channel_id * 64
    action step2_calc_buffer_idx() {
        channel_mul_64 = channel_id << 6;
    }

    // Step 3: channel_id * 448 = 512 - 64
    action step3_calc_buffer_idx() {
        channel_mul_448 = channel_mul_512 - channel_mul_64;
    }

    // Step 4a: 设置 tmp_loc (用于存储 loc 的值)
    action step4a_set_loc_from_tx_loc() {
        tmp_loc = (bit<32>)eg_md.bridge.tx_loc_val;
    }

    // Step 4b: loc * 8
    action step4b_calc_loc_mul_8() {
        loc_mul_8 = tmp_loc << 3;
    }

    // Step 5: loc * 7 = loc * 8 - loc
    action step5_calc_loc_mul_7() {
        loc_mul_7 = loc_mul_8 - tmp_loc;
    }

    // Step 6: buffer_idx = channel_mul_448 + loc_mul_7
    action step6_calc_buffer_idx() {
        buffer_idx = channel_mul_448 + loc_mul_7;
    }

    // Step 7a: 设置 tmp_offset
    action step7a_set_offset_from_tx_offset() {
        tmp_offset = (bit<32>)eg_md.bridge.tx_offset_val;
    }

    action step7a_set_offset_from_rid() {
        tmp_offset = (bit<32>)eg_intr_md.egress_rid;
    }

    action step7a_set_offset_from_eg() {
        tmp_offset = (bit<32>)eg_md.bridge.tx_offset_val;
    }
    // Step 7b: buffer_idx = buffer_idx + offset
    action step7b_add_offset() {
        buffer_idx = buffer_idx + tmp_offset;
    }

    // 使用方式 (在 egress):
    // step1_calc_buffer_idx();
    // step2_calc_buffer_idx();
    // step3_calc_buffer_idx();
    // step4_calc_buffer_idx((bit<32>)eg_md.bridge.tx_loc_val);
    // step5_calc_buffer_idx((bit<32>)eg_md.bridge.tx_loc_val);
    // step6_calc_buffer_idx();
    // step7_calc_buffer_idx((bit<32>)pkt_offset);

    bit<32> pkt_offset;

    action step1_prep_offset() {
        pkt_offset = (bit<32>)eg_intr_md.egress_rid;
    }


    action step2_calc_psn_add() {
        eg_md.psn = eg_md.psn + pkt_offset;
    }

    action step3_write_bth_psn() {
        hdr.bth.psn = eg_md.psn;
    }
    /***************************************************************************
     * Apply
     ***************************************************************************/
    apply {
        
        channel_id = (bit<32>)eg_md.bridge.channel_id;
        
        // ================================================================
        // 1. Loopback port output - construct WRITE_FIRST to send to loopback for continued processing
        // ================================================================
        if (eg_intr_md.egress_port == LOOPBACK_PORT) {
            // Construct full WRITE_FIRST
            hdr.bth.opcode = RDMA_OP_WRITE_FIRST;
            
            // Set RETH
            hdr.reth.setValid();
            hdr.reth.addr = eg_md.bridge.next_token_addr;

            hdr.reth.len = TOKEN_SIZE;
            
            // Set payload.data00 to store loc
            hdr.payload.setValid();
            if (!eg_md.bridge.is_loopback) {
                // From CONN_TX: first time starting loop, set current loc
                hdr.payload.data00 = eg_md.bridge.tx_loc_val;
            }
            // If is_loopback, payload.data00 was already set to ig_md.next_loc in ingress
            
            // Lookup table to set rx info (dst_mac, dst_ip, dst_qp, rkey)
            tbl_rx_info.apply();
            
            // Set packet length
            set_write_first_len();
            
            // AETH invalid
            hdr.aeth.setInvalid();
            
            return;
        }
        
        // ================================================================
        // 2. is_loopback broadcast packets - send TOKEN_PACKETS packets to rx
        // ================================================================
        if (eg_intr_md.egress_port != LOOPBACK_PORT && eg_md.bridge.is_loopback) {
            // Determine which packet based on egress_rid (0 to TOKEN_PACKETS-1)
            step1_prep_offset();
            step2_calc_psn_add();
            step3_write_bth_psn();
            
            // Compute buffer index and read aggregation result
            step1_calc_buffer_idx();           // channel * 512
            step2_calc_buffer_idx();           // channel * 64
            step3_calc_buffer_idx();           // channel * 448
            step4a_set_loc_from_tx_loc();      // tmp_loc = tx_loc_val
            step4b_calc_loc_mul_8();           // loc * 8
            step5_calc_loc_mul_7();            // loc * 7
            step6_calc_buffer_idx();           // channel*448 + loc*7
            step7a_set_offset_from_rid();      // tmp_offset = egress_rid
            step7b_add_offset();               // + offset
            
            do_read_agg(buffer_idx);
            bit<32> agg_result = tmp_agg_result;
            
            // Set payload
            hdr.payload.setValid();
            hdr.payload.data00 = agg_result;
            
            // Set opcode and header based on pkt_offset
            if (pkt_offset == 0) {
                // First packet: WRITE_FIRST
                hdr.bth.opcode = RDMA_OP_WRITE_FIRST;
                // RETH address preserved from original packet during ingress
                hdr.reth.setValid();
                hdr.reth.len = TOKEN_SIZE;
                set_write_first_len();
            } else if (pkt_offset == TOKEN_PACKETS - 1) {
                // Last packet: WRITE_LAST
                hdr.bth.opcode = RDMA_OP_WRITE_LAST;
                hdr.reth.setInvalid();
                set_write_middle_len();
            } else {
                // Middle packet: WRITE_MIDDLE
                hdr.bth.opcode = RDMA_OP_WRITE_MIDDLE;
                hdr.reth.setInvalid();
                set_write_middle_len();
            }
            
            // AETH invalid (WRITE packets do not have AETH)
            hdr.aeth.setInvalid();
            
            return;
        }
        
        // ================================================================
        // 3. CONN_TX - aggregate data and return ACK
        // ================================================================
        if (eg_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_TX && 
            eg_intr_md.egress_port != LOOPBACK_PORT) {
            // Compute buffer index
            // buffer_idx = channel_id * PACKET_NUM_PER_CHANNEL_BUFFER 
            //            + (bit<32>)eg_md.bridge.tx_loc_val * TOKEN_PACKETS 
            //            + (bit<32>)eg_md.bridge.tx_offset_val;
            step1_calc_buffer_idx();           // channel * 512
            step2_calc_buffer_idx();           // channel * 64
            step3_calc_buffer_idx();           // channel * 448
            step4a_set_loc_from_tx_loc();      // tmp_loc = tx_loc_val
            step4b_calc_loc_mul_8();           // loc * 8
            step5_calc_loc_mul_7();            // loc * 7
            step6_calc_buffer_idx();           // channel*448 + loc*7
            step7a_set_offset_from_eg();      // tmp_offset = tx_offset_val
            step7b_add_offset();               // + offset
        
            agg_val = hdr.payload.data00; // only data00 is used for aggregation

            // Aggregate or store
            if (eg_md.bridge.clear_offset <= eg_md.bridge.tx_offset_val) {
                do_store(buffer_idx);
            } else {
                do_aggregate(buffer_idx);
            }
            
            // Set ACK packet
            swap_l2_l3_l4();
            set_ack_len();
            
            // Set header valid/invalid
            // AETH syndrome/psn/msn already set in ingress
            hdr.aeth.setValid();
            hdr.bth.opcode = RDMA_OP_ACK;
            hdr.reth.setInvalid();
            hdr.payload.setInvalid();
            
            return;
        }
        
        // ================================================================
        // 4. CONN_CONTROL READ_RESPONSE (completed in ingress, only need to set)
        // ================================================================
        if (eg_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            // Set packet length: UDP: BTH(12) + AETH(4) + Payload(128) + ICRC(4) = 148, + UDP header(8) = 156; IP: UDP(156) + IP header(20) = 176
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
        // 5. Other ACK packets (CONN_BITMAP)
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