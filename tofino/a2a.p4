/* -*- P4_16 -*- */
#include <core.p4>
#if __TARGET_TOFINO__ == 2
#include <t2na.p4>
#else
#include <tna.p4>
#endif

#include "a2a_header.p4"
#include "a2a_ingress_parser.p4"
#include "a2a_ingress.p4"
#include "a2a_egress_parser.p4"
#include "a2a_egress.p4"

Pipeline(
    A2AIngressParser(), 
    Ingress(), 
    IngressDeparser(), 
    EgressParser(), 
    Egress(), 
    EgressDeparser()
) pipe;

Switch(pipe) main;
