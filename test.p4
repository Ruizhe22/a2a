#include <core.p4>
#include <tna.p4>

/*************************************************************************
 ***********************  C O N S T A N T S  *****************************
 *************************************************************************/

const bit<16> ETHERTYPE_IPV4 = 0x0800;

/*************************************************************************
 ***********************  H E A D E R S  *********************************
 *************************************************************************/

header ethernet_h {
    bit<48> dst_addr;
    bit<48> src_addr;
    bit<16> ether_type;
}

struct header_t {
    ethernet_h ethernet;
}

struct metadata_t {
    bit<32> counter_index;
    bit<32> increment_amount;
    bool inc;
}

/*************************************************************************
 ***********************  P A R S E R  ***********************************
 *************************************************************************/

parser SwitchIngressParser(
    packet_in pkt,
    out header_t hdr,
    out metadata_t meta,
    out ingress_intrinsic_metadata_t ig_intr_md)
{
    state start {
        pkt.extract(ig_intr_md);
        pkt.advance(PORT_METADATA_SIZE);
        meta.counter_index = 0;
        meta.increment_amount = 1;
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition accept;
    }
}


/*************************************************************************
 **************  I N G R E S S   P R O C E S S I N G   *******************
 *************************************************************************/

control SwitchIngress(
    inout header_t hdr,
    inout metadata_t meta,
    in ingress_intrinsic_metadata_t ig_intr_md,
    in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md)
{
    Register<bit<32>, bit<32>>(4096) counters;

    RegisterAction<bit<32>, bit<32>, void>(counters) increment_counter = {
        void apply(inout bit<32> value) {
            value = value + meta.increment_amount;
        }
    };

    RegisterAction<bit<32>, bit<32>, bit<32>>(counters) read_counter = {
        void apply(inout bit<32> value, out bit<32> result) {
            result = value;
        }
    };


    action forward(PortId_t port) {
        ig_tm_md.ucast_egress_port = port;
    }

    action drop() {
        ig_dprsr_md.drop_ctl = 1;
    }

    table dmac_table {
        key = {
            hdr.ethernet.dst_addr : exact;
        }
        actions = {
            forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }

    action ainc(){
        meta.increment_amount = meta.increment_amount + 1;
    }

    apply {
        // 用 src_addr 的低 12 位作为 counter index
        meta.counter_index = (bit<32>)hdr.ethernet.src_addr[11:0];
        meta.increment_amount = 1;
        if(meta.inc){
            ainc();
            ainc();
            ainc();
            ainc();
            ainc();
            ainc();
            ainc();
            ainc();
            ainc();
            ainc();
            if(meta.increment_amount == 100){
                increment_counter.execute(meta.counter_index);
            }
        }
        else {
            bit<32> res = read_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);
            increment_counter.execute(meta.counter_index);



        }
        

        // 转发逻辑
        dmac_table.apply();
    }
}

/*************************************************************************
 ****************  I N G R E S S   D E P A R S E R  **********************
 *************************************************************************/

control SwitchIngressDeparser(
    packet_out pkt,
    inout header_t hdr,
    in metadata_t meta,
    in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md)
{
    apply {
        pkt.emit(hdr.ethernet);
    }
}

/*************************************************************************
 *****************  E G R E S S   P A R S E R  ***************************
 *************************************************************************/

parser SwitchEgressParser(
    packet_in pkt,
    out header_t hdr,
    out metadata_t meta,
    out egress_intrinsic_metadata_t eg_intr_md)
{
    state start {
        pkt.extract(eg_intr_md);
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition accept;
    }
}

/*************************************************************************
 ****************  E G R E S S   P R O C E S S I N G   *******************
 *************************************************************************/

control SwitchEgress(
    inout header_t hdr,
    inout metadata_t meta,
    in egress_intrinsic_metadata_t eg_intr_md,
    in egress_intrinsic_metadata_from_parser_t eg_prsr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
    inout egress_intrinsic_metadata_for_output_port_t eg_oport_md)
{
    apply { }
}

/*************************************************************************
 ****************  E G R E S S   D E P A R S E R  ************************
 *************************************************************************/

control SwitchEgressDeparser(
    packet_out pkt,
    inout header_t hdr,
    in metadata_t meta,
    in egress_intrinsic_metadata_for_deparser_t eg_dprsr_md)
{
    apply {
        pkt.emit(hdr.ethernet);
    }
}

/*************************************************************************
 ***********************  S W I T C H  ***********************************
 *************************************************************************/

Pipeline(
    SwitchIngressParser(),
    SwitchIngress(),
    SwitchIngressDeparser(),
    SwitchEgressParser(),
    SwitchEgress(),
    SwitchEgressDeparser()
) pipe;

Switch(pipe) main;