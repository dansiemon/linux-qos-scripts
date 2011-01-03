#!/bin/bash

DEVICE="ppp0"

# RATE should be set to just under your upload link rate.
RATE="620kbit"
# Below three rates should add up to RATE.
RATE_1="220kbit"
RATE_2="220kbit"
#RATE_3="200kbit"
RATE_3="180kbit"

SFQ_LEN="4"
PERTURB="15"

# Delete the existing qdiscs etc if they exist.
tc qdisc del dev ${DEVICE} root

# HTB QDisc at the root. Default all traffic into the prio qdisc.
tc qdisc add dev ${DEVICE} root handle 1: htb default 30

# Shape all traffic to RATE.
tc class add dev ${DEVICE} parent 1: classid 1:1 htb rate ${RATE}

# Create three taffic classes.
tc class add dev ${DEVICE} parent 1:1 classid 1:10 htb rate ${RATE_1} ceil ${RATE} prio 0
tc class add dev ${DEVICE} parent 1:1 classid 1:20 htb rate ${RATE_2} ceil ${RATE} prio 1
tc class add dev ${DEVICE} parent 1:1 classid 1:30 htb rate ${RATE_3} ceil ${RATE} prio 2

# Within each traffic class use an SFQ to ensure inter-flow fairness.
tc qdisc add dev ${DEVICE} parent 1:10 handle 10 sfq perturb ${PERTURB} limit ${SFQ_LEN}
tc qdisc add dev ${DEVICE} parent 1:20 handle 20 sfq perturb ${PERTURB} limit ${SFQ_LEN}
tc qdisc add dev ${DEVICE} parent 1:30 handle 30 sfq perturb ${PERTURB} limit ${SFQ_LEN}

# Add some filters to match on the TOS bits in the IPv6 header (IPv6 over v4 tunnel).
# Unfortunately it looks like Transmission and OpenSSH don't set the bits for IPv6.
# The below matches all IPv6 in IPv6 tunneled traffic.
tc filter add dev ${DEVICE} parent 1:0 protocol ip prio 10 u32 match ip protocol 41 0xff flowid 1:30

# Only mask against the three (used) TOS bits. The final two bits are used for ECN.
tc filter add dev ${DEVICE} parent 1:0 protocol ip prio 10 u32 match ip tos 0x00 0x1c flowid 1:20
tc filter add dev ${DEVICE} parent 1:0 protocol ip prio 10 u32 match ip tos 0x04 0x1c flowid 1:20
tc filter add dev ${DEVICE} parent 1:0 protocol ip prio 10 u32 match ip tos 0x08 0x1c flowid 1:30
tc filter add dev ${DEVICE} parent 1:0 protocol ip prio 10 u32 match ip tos 0x0c 0x1c flowid 1:30
tc filter add dev ${DEVICE} parent 1:0 protocol ip prio 10 u32 match ip tos 0x10 0x1c flowid 1:10
tc filter add dev ${DEVICE} parent 1:0 protocol ip prio 10 u32 match ip tos 0x14 0x1c flowid 1:10
tc filter add dev ${DEVICE} parent 1:0 protocol ip prio 10 u32 match ip tos 0x18 0x1c flowid 1:20
tc filter add dev ${DEVICE} parent 1:0 protocol ip prio 10 u32 match ip tos 0x1c 0x1c flowid 1:20

# Diffserv expedited forwarding. Put this in the high priority class.
tc filter add dev ${DEVICE} parent 1:0 protocol ip prio 10 u32 match ip tos 0xb8 0xfc flowid 1:10
