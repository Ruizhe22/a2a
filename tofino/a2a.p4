/**
 * @file a2a.p4
 * @brief Main P4 program for All-to-All collective communication
 *
 * This program implements an in-network All-to-All collective operation
 * for RoCEv2/RDMA traffic on Intel Tofino switches. It consists of two
 * main phases:
 *
 *   1. Dispatch Phase: Scatters data from each sender to all receivers
 *      using bitmap-based multicast routing
 *
 *   2. Combine Phase: Aggregates data from multiple senders with
 *      in-network reduction (sum operation)
 *
 * Architecture:
 *   - Ingress: Parses packets, classifies traffic, and applies
 *     dispatch/combine ingress logic
 *   - Egress: Handles multicast replica processing, PSN management,
 *     and packet transformation
 *
 * @note Requires Intel Tofino Native Architecture (TNA)
 */

/* -*- P4_16 -*- */
#include <core.p4>
#include <tna.p4>

/* Type definitions and constants */
#include "a2a_types.p4"

/* Control plane logic */
#include "dispatch_control.p4"
#include "combine_control.p4"

/* Parsers */
#include "a2a_ingress_parser.p4"
#include "a2a_egress_parser.p4"

/* Control blocks */
#include "a2a_ingress_control.p4"
#include "a2a_egress_control.p4"

/* =============================================================================
 * Pipeline Instantiation
 * ============================================================================= */

Pipeline(
    A2AIngressParser(),
    A2AIngress(),
    A2AIngressDeparser(),
    A2AEgressParser(),
    A2AEgress(),
    A2AEgressDeparser()
) pipe;

/* =============================================================================
 * Switch Instantiation
 * ============================================================================= */

Switch(pipe) main;
