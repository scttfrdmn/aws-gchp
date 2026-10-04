#!/bin/bash
# compute-multinic-fix.sh — compute-node OnNodeConfigured for MULTI-NIC instances (m8gn/m8gb = 2 cards).
# Problem observed: on a 2-ENI m8gn compute node, under heavy S3 traffic the slurmd<->slurmctld control
# channel (port 6818) timed out -> node marked DOWN -> job requeued. Root cause = asymmetric routing:
# the 2nd ENI's presence makes the kernel drop return-path packets (strict rp_filter) or send replies
# out the wrong interface, starving slurm's control plane under load.
#
# Fix (low-risk, standard AWS multi-NIC remedy):
#   1. rp_filter=2 (LOOSE reverse-path) on all interfaces -> stop dropping asymmetric return packets.
#   2. Keep the PRIMARY ENI (the one slurm/DNS registered) as the default route so control traffic
#      and S3 both egress predictably; the 2nd card still carries flows the kernel hashes to it.
# This does NOT disable the 2nd NIC (we WANT its bandwidth for S3) -- it just stops the routing from
# breaking slurm's health check.
set -uo pipefail
echo "[multinic-fix] $(date) applying loose rp_filter for multi-NIC slurm control-plane stability"

# 1. loose reverse-path filtering (2 = RFC3704 loose mode) on all + default, persistent
sudo sysctl -w net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
sudo sysctl -w net.ipv4.conf.default.rp_filter=2 2>/dev/null || true
for ifc in $(ls /sys/class/net | grep -vE '^lo$'); do
  sudo sysctl -w "net.ipv4.conf.${ifc}.rp_filter=2" 2>/dev/null || true
done
printf 'net.ipv4.conf.all.rp_filter=2\nnet.ipv4.conf.default.rp_filter=2\n' | sudo tee /etc/sysctl.d/99-multinic-rpfilter.conf >/dev/null 2>&1 || true

echo "[multinic-fix] rp_filter now: $(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)"
echo "[multinic-fix] interfaces: $(ls /sys/class/net | grep -vE '^lo$' | paste -sd,)"
echo "[multinic-fix] done"
