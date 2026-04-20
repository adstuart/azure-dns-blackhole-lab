#!/usr/bin/env bash
# Azure DNS Private Resolver wildcard blackhole + Azure Firewall Premium lab.
#
# Creates a fresh resource group with:
#   - VNet with 4 subnets (inbound, outbound, vms, AzureFirewallSubnet)
#   - DNS Private Resolver + inbound/outbound endpoints
#   - Forwarding ruleset with a wildcard '.' rule pointing to unreachable IPs
#   - VNet DNS set to the resolver inbound endpoint
#   - A small Linux VM that tests DNS resolution
#   - Azure Firewall Premium + PIP (to see if it provisions despite the blackhole)
#
# Writes artifacts to lab/out/run-<timestamp>/.
# Tear down with:   az group delete -n "$RG" --yes --no-wait

set -euo pipefail

LOCATION="${LOCATION:-swedencentral}"
PREFIX="${PREFIX:-dnsbh}"
STAMP="$(date -u +%m%d%H%M)"
RG="rg-${PREFIX}-${STAMP}"
VNET="vnet-${PREFIX}"
RESOLVER="dnspr-${PREFIX}"
RULESET="ruleset-${PREFIX}"
VM_NAME="vm-${PREFIX}"
AFW="afw-${PREFIX}"
PIP_AFW="pip-${AFW}"

BLACKHOLE_A="10.255.255.253"
BLACKHOLE_B="10.255.255.254"

OUT_DIR="$(dirname "$0")/out/run-${STAMP}"
mkdir -p "$OUT_DIR"
exec > >(tee -a "$OUT_DIR/lab.log") 2>&1

echo "== Region=$LOCATION  RG=$RG =="

az group create -g "$RG" -l "$LOCATION" -o json >"$OUT_DIR/group.json"

echo "== VNet + subnets =="
az network vnet create -g "$RG" -n "$VNET" \
    --address-prefixes 10.250.0.0/16 \
    --subnet-name dns-inbound --subnet-prefixes 10.250.0.0/28 \
    -o json >"$OUT_DIR/vnet.json"

for S in \
    "dns-outbound 10.250.0.16/28" \
    "vms          10.250.1.0/24" \
    "AzureFirewallSubnet 10.250.2.0/26" ; do
    read -r NAME CIDR <<<"$S"
    az network vnet subnet create -g "$RG" --vnet-name "$VNET" \
        -n "$NAME" --address-prefixes "$CIDR" -o json >"$OUT_DIR/subnet-${NAME}.json"
done

az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n dns-inbound \
    --delegations Microsoft.Network/dnsResolvers -o none
az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n dns-outbound \
    --delegations Microsoft.Network/dnsResolvers -o none

echo "== DNS Private Resolver =="
VNET_ID=$(az network vnet show -g "$RG" -n "$VNET" --query id -o tsv)
SUB_ID=$(az account show --query id -o tsv)
az dns-resolver create -g "$RG" -n "$RESOLVER" -l "$LOCATION" \
    --id "/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.Network/dnsResolvers/$RESOLVER" \
    --virtual-network "$VNET_ID" -o json >"$OUT_DIR/resolver.json"

INBOUND_SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n dns-inbound --query id -o tsv)
OUTBOUND_SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n dns-outbound --query id -o tsv)

az dns-resolver inbound-endpoint create -g "$RG" --dns-resolver-name "$RESOLVER" \
    -n inbound -l "$LOCATION" \
    --ip-configurations "[{private-ip-allocation-method:Dynamic,subnet:{id:$INBOUND_SUBNET_ID}}]" \
    -o json >"$OUT_DIR/inbound.json"

az dns-resolver outbound-endpoint create -g "$RG" --dns-resolver-name "$RESOLVER" \
    -n outbound -l "$LOCATION" --subnet "$OUTBOUND_SUBNET_ID" \
    -o json >"$OUT_DIR/outbound.json"

INBOUND_IP=$(jq -r '.ipConfigurations[0].privateIpAddress' "$OUT_DIR/inbound.json")
echo "Resolver inbound IP: $INBOUND_IP"

echo "== Forwarding ruleset + wildcard rule =="
OUTBOUND_ID=$(az dns-resolver outbound-endpoint show -g "$RG" \
    --dns-resolver-name "$RESOLVER" -n outbound --query id -o tsv)

az dns-resolver forwarding-ruleset create -g "$RG" -n "$RULESET" -l "$LOCATION" \
    --outbound-endpoints "[{id:$OUTBOUND_ID}]" -o json >"$OUT_DIR/ruleset.json"

az dns-resolver vnet-link create -g "$RG" --ruleset-name "$RULESET" \
    -n "link-$VNET" --virtual-network "{id:$VNET_ID}" \
    -o json >"$OUT_DIR/vnet-link.json"

az dns-resolver forwarding-rule create -g "$RG" --ruleset-name "$RULESET" \
    -n wildcard-root --domain-name "." --forwarding-rule-state Enabled \
    --target-dns-servers "[{ip-address:$BLACKHOLE_A,port:53},{ip-address:$BLACKHOLE_B,port:53}]" \
    -o json >"$OUT_DIR/rule.json"

echo "== Point VNet DNS at resolver inbound =="
az network vnet update -g "$RG" -n "$VNET" --dns-servers "$INBOUND_IP" \
    -o json >"$OUT_DIR/vnet-dns.json"

echo "== Test VM =="
az vm create -g "$RG" -n "$VM_NAME" \
    --image Ubuntu2204 --size Standard_D2s_v5 \
    --vnet-name "$VNET" --subnet vms \
    --admin-username azureuser --generate-ssh-keys \
    --public-ip-sku Standard \
    -o json >"$OUT_DIR/vm.json"

echo "== DNS test from VM =="
cat >"$OUT_DIR/vm_dns_test.sh" <<'EOF'
python3 - <<'PY'
import json, socket
tests = {}
for host in ("example.com", "microsoft.com", "login.microsoftonline.com"):
    try:
        ips = sorted({ai[4][0] for ai in socket.getaddrinfo(host, 53)})
        tests[host] = {"ok": True, "ips": ips}
    except Exception as e:
        tests[host] = {"ok": False, "error": f"{type(e).__name__}({e.errno}, {e.strerror!r})"}
with open("/etc/resolv.conf") as f: resolv = f.read()
print(json.dumps({"resolv_conf": resolv, "tests": tests}, indent=2))
PY
EOF
az vm run-command invoke -g "$RG" -n "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "@$OUT_DIR/vm_dns_test.sh" \
    -o json >"$OUT_DIR/vm-test.json"

echo "== Azure Firewall Premium =="
az network public-ip create -g "$RG" -n "$PIP_AFW" \
    --sku Standard --allocation-method Static \
    -o json >"$OUT_DIR/pip-afw.json"

az network firewall create -g "$RG" -n "$AFW" --sku AZFW_VNet --tier Premium \
    -l "$LOCATION" -o json >"$OUT_DIR/fw-create.json"

az network firewall ip-config create -g "$RG" -f "$AFW" -n fwconfig \
    --public-ip-address "$PIP_AFW" --vnet-name "$VNET" \
    -o json >"$OUT_DIR/fw-ipcfg.json"

az network firewall show -g "$RG" -n "$AFW" -o json >"$OUT_DIR/fw-final.json"

echo "== Done. Artifacts: $OUT_DIR =="
