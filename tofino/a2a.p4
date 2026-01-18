/* -*- P4_16 -*- */
#include <core.p4>
#include <tna.p4>

#include "a2a_types.p4"
#include "dispatch_control.p4"
#include "combine_control.p4"
#include "a2a_ingress_parser.p4"
#include "a2a_ingress_control.p4"
#include "a2a_egress_parser.p4"
#include "a2a_egress_control.p4"

Pipeline(
    A2AIngressParser(), 
    A2AIngress(), 
    A2AIngressDeparser(), 
    A2AEgressParser(), 
    A2AEgress(), 
    A2AEgressDeparser()
) pipe;

Switch(pipe) main;
