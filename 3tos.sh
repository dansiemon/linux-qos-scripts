#!/bin/bash
##
# Dan Siemon <dan@coverfire.com>
#
# License: Affero GPLv3
#
# This script creates three traffic classes and directs traffic into
# each class based on the value of the TOS bits.
#
# Other than the variables in the top secton of this script you'll
# also want to remove 'linklayer atm' if you aren't using ATM
# (most DSL types use ATM).
#

DEVICE="tunl1"

RATE="4500kbit"
# Below three rates should add up to RATE.
RATE_1="1500kbit"
RATE_2="1500kbit"
RATE_3="1500kbit"

MTU="1436"

# Pick a queue length with sane upper bound on latency.
# Eg, 10 * 1436 = 14360 / (4500000 / 8) = ~25ms
SFQ_LEN="10"
SFQ_LEN_LONG="20"

# How often to perturb the hashes.
PERTURB="60"

# 40 bytes for PPPoE
# 20 bytes for IPIP
OVERHEAD="60"

# Delete the existing qdiscs etc if they exist.
tc qdisc del dev ${DEVICE} root

# HTB QDisc at the root. Default all traffic into the prio qdisc.
tc qdisc add dev ${DEVICE} root handle 1: htb default 30

# Shape all traffic to just under the upload link rate.
tc class add dev ${DEVICE} parent 1: classid 1:1 htb rate ${RATE} linklayer atm overhead ${OVERHEAD}

# Create three taffic classes.
tc class add dev ${DEVICE} parent 1:1 classid 1:10 htb rate ${RATE_1} ceil ${RATE} prio 0 linklayer atm overhead ${OVERHEAD}
tc class add dev ${DEVICE} parent 1:1 classid 1:20 htb rate ${RATE_2} ceil ${RATE} prio 1 linklayer atm overhead ${OVERHEAD}
tc class add dev ${DEVICE} parent 1:1 classid 1:30 htb rate ${RATE_3} ceil ${RATE} prio 2 linklayer atm overhead ${OVERHEAD}

# Within each traffic class use an SFQ to ensure inter-flow fairness.
tc qdisc add dev ${DEVICE} parent 1:10 handle 10 sfq perturb ${PERTURB} quantum ${MTU} limit ${SFQ_LEN}
tc qdisc add dev ${DEVICE} parent 1:20 handle 20 sfq perturb ${PERTURB} quantum ${MTU} limit ${SFQ_LEN_LONG}
tc qdisc add dev ${DEVICE} parent 1:30 handle 30 sfq perturb ${PERTURB} quantum ${MTU} limit ${SFQ_LEN_LONG}

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
