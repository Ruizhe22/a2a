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
 * BitmapSlot - Bitmap buffer management for a single RX
 *
 * Each slot manages the bitmaps for all queue positions of one RX
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
 * AddrSlot - 1/8 of the Addr Buffer
 *
 * Adjacent tokens are distributed across 8 slots
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

    // each slot stores COMBINE_BITMAP_ENTRIES / 8 addrs
    Register<addr_tofino_t, bit<32>>(COMBINE_BITMAP_ENTRIES >> 3) reg_addr;

    // read
    RegisterAction<addr_tofino_t, bit<32>, addr_tofino_t>(reg_addr) ra_read = {
        void apply(inout addr_tofino_t value, out addr_tofino_t res) {
            res = value;
        }
    };

    // write
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
 * CombineIngress - main control logic
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
            value = 1;  // reset to 1 (current packet is 0, next is 1)
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

    Register<bit<8>, bit<32>>(COMBINE_BITMAP_ENTRIES) reg_clear_buffer;
    
    addr_tofino_t addr_write_val;
    

    // Before calling, set ig_md.bridge.tx_offset_val; a Register can only be read once, so write it this way
    RegisterAction<bit<8>, bit<32>, bit<8>>(reg_clear_buffer) ra_read_set_clear = {
        void apply(inout bit<8> value, out bit<8> result) {
            result = value;
            if(value <= ig_md.bridge.tx_offset_val){ // ideally should be ==
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
        hdr.bth.psn = psn; // If there's an ack header (e.g., RDMA_OP_ACK or Read response), PSN is determined by the ack, set here
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
        // ACK packet: UDP(8) + BTH(12) + AETH(4) + ICRC(4) = 28
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
        // CONN_CONTROL: query queue pointer (READ)
        // ================================================================
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_CONTROL) {
            if (hdr.bth.opcode == RDMA_OP_READ_REQ) {
         
                // Construct READ_RESPONSE_ONLY
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
        // CONN_BITMAP: rx writes bitmap (WRITE_ONLY)
        // ================================================================
        if (ig_md.bridge.conn_semantics == CONN_SEMANTICS.CONN_BITMAP) {
            if (hdr.bth.opcode != RDMA_OP_WRITE_ONLY) {
                ig_dprsr_md.drop_ctl = 1;
                return;
            }
            psn_to_check = (bit<32>)hdr.bth.psn;
            bit<32> expected_psn = ra_read_cond_inc_rx_bitmap_epsn.execute(channel_id);
            
            if ((bit<32>)hdr.bth.psn == expected_psn) {
                // PSN matches, write bitmap
                channel_class = channel_id >> 3; // EP_SIZE=8
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

                // return ACK
                set_aeth_ingress(AETH_ACK_CREDIT_INVALID, hdr.bth.psn, hdr.bth.psn + 1);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else if ((bit<32>)hdr.bth.psn < expected_psn) {
                // duplicate packet
                set_aeth_ingress(AETH_ACK_CREDIT_INVALID, (bit<24>)(expected_psn - 1), (bit<24>)expected_psn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else {
                // packet loss, return NAK
                set_aeth_ingress(AETH_NAK_SEQ_ERR, (bit<24>)(expected_psn - 1), (bit<24>)expected_psn);
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

            bit<32> expected_psn = ra_read_cond_inc_tx_epsn.execute(tx_reg_idx);
            bit<32> current_msn = ra_read_tx_msn.execute(tx_reg_idx);
            
            if ((bit<32>)hdr.bth.psn == expected_psn) {
                // PSN matches
                // Get loc and packet_offset
                if (hdr.bth.opcode == RDMA_OP_WRITE_FIRST || 
                    hdr.bth.opcode == RDMA_OP_WRITE_ONLY) {
                    // Get loc from reth.addr
                    ig_md.bridge.tx_loc_val = hdr.reth.addr[63:48];
                    ig_md.bridge.tx_offset_val = 0;
                    ra_write_tx_loc.execute(tx_reg_idx);
                    ra_reset_tx_offset.execute(tx_reg_idx);
                } else {
                    // Get from registers
                    ig_md.bridge.tx_loc_val = ra_read_tx_loc.execute(tx_reg_idx);
                    ig_md.bridge.tx_offset_val = ra_read_inc_tx_offset.execute(tx_reg_idx);
                }
                
                token_idx = channel_id * COMBINE_QUEUE_LENGTH + (bit<32>)ig_md.bridge.tx_loc_val;
                slot_id = token_idx[2:0];
                // Check whether this is the first tx to arrive
                ig_md.bridge.clear_offset = ra_read_set_clear.execute(token_idx);
                
                // If WRITE_LAST/ONLY: clear tx bit in bitmap and update MSN
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
                            //hdr.reth.setValid();
                            //hdr.reth.addr[31:0] = addr_result.lo;
                            //hdr.reth.addr[63:32] = addr_result.hi;
                            hdr.bridge.next_token_addr = addr_result;
                        }
                    }
                }

                // return ACK
                set_aeth_ingress(AETH_ACK_CREDIT_INVALID, (bit<24>)expected_psn, (bit<24>)current_msn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else if ((bit<32>)hdr.bth.psn < expected_psn) {
                // duplicate packet
                set_aeth_ingress(AETH_ACK_CREDIT_INVALID, (bit<24>)(expected_psn - 1), (bit<24>)current_msn);
                ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                
            } else {
                // packet loss
                set_aeth_ingress(AETH_NAK_SEQ_ERR, (bit<24>)(expected_psn - 1), (bit<24>)current_msn);
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
            bit<16> current_loc = hdr.payload.data00[15:0];
            ig_md.bridge.tx_loc_val = current_loc;
            ig_md.bridge.is_loopback = true;
            
            // Set multicast to rx (TOKEN_PACKETS packets)
            ig_tm_md.mcast_grp_a = (bit<16>)(100 + ig_md.bridge.root_rank_id);
            
            bit<32> base_psn = ra_read_add_rx_token_epsn.execute(channel_id);
            hdr.bth.psn = (bit<24>)base_psn;

            // Compute next loc (circular queue)
            bit<8> next_loc;
            if (current_loc >= COMBINE_QUEUE_LENGTH - 1) {
                next_loc = 0;
            } else {
                next_loc = current_loc + 1;
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
            
            // If next_loc == queue_tail, all tokens are processed; stop loopback
            if (next_loc != queue_tail) {
                // Check if bitmap of next loc is zero
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
                
                // Check queue_incomplete
                //bit<8> queue_incomplete_val = ra_read_queue_incomplete.execute(channel_id);
                
                // If next token is ready, continue loopback
                if (next_bitmap_result == 0 ) { //&& next_loc == queue_incomplete_val
                    // Update queue_incomplete and queue_head
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
                    
                    // Set loopback to continue and update payload.data00 to next_loc
                    ig_tm_md.mcast_grp_b = LOOPBACK_MCAST_GRP;
                    hdr.payload.data00 = (bit<32>)next_loc;
                    hdr.bridge.next_token_addr = addr_result;
                }
            }
            
            // Restore current loc for egress
            ig_md.bridge.tx_loc_val = current_loc;
            
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
    in egress_intrinsic_metadata_from_parser_t eg_prsr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    /***************************************************************************
     * Aggregator
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
     * RX info table - used to construct WRITE_FIRST for loopback
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
        // 1. Loopback port output - construct WRITE_FIRST to send to loopback for continued processing
        // ================================================================
        if (eg_intr_md.egress_port == LOOPBACK_PORT) {
            // Construct full WRITE_FIRST
            hdr.bth.opcode = RDMA_OP_WRITE_FIRST;
            
            // Set RETH
            hdr.reth.setValid();
            hdr.reth.addr[31:0] = eg_md.bridge.next_token_addr.lo;
            hdr.reth.addr[63:32] = eg_md.bridge.next_token_addr.hi;
            hdr.reth.length = TOKEN_SIZE;
            
            // Set payload.data00 to store loc
            hdr.payload.setValid();
            if (!eg_md.bridge.is_loopback) {
                // From CONN_TX: first time starting loop, set current loc
                hdr.payload.data00 = (bit<32>)eg_md.bridge.tx_loc_val;
            }
            // If is_loopback, payload.data00 was already set to next_loc in ingress
            
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
            bit<8> pkt_offset = (bit<8>)eg_intr_md.egress_rid;
            
            // Process PSN
            hdr.bth.psn = hdr.bth.psn + (bit<24>)pkt_offset;
            
            // Compute buffer index and read aggregation result
            buffer_idx = channel_id * PACKET_NUM_PER_CHANNEL_BUFFER 
                       + (bit<32>)eg_md.bridge.tx_loc_val * TOKEN_PACKETS 
                       + (bit<32>)pkt_offset;
            
            bit<32> agg_result = ra_read_agg.execute(buffer_idx);
            
            // Set payload
            hdr.payload.setValid();
            hdr.payload.data00 = agg_result;
            
            // Set opcode and header based on pkt_offset
            if (pkt_offset == 0) {
                // First packet: WRITE_FIRST
                hdr.bth.opcode = RDMA_OP_WRITE_FIRST;
                // RETH address preserved from original packet during ingress
                hdr.reth.setValid();
                hdr.reth.length = TOKEN_SIZE;
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
            buffer_idx = channel_id * PACKET_NUM_PER_CHANNEL_BUFFER 
                       + (bit<32>)eg_md.bridge.tx_loc_val * TOKEN_PACKETS 
                       + (bit<32>)eg_md.bridge.tx_offset_val;

            agg_val = hdr.payload.data00;

            // Aggregate or store
            if (eg_md.bridge.clear_offset <= eg_md.bridge.tx_offset_val) {
                ra_store.execute(buffer_idx);
            } else {
                ra_aggregate.execute(buffer_idx);
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