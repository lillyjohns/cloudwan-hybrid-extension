#!/usr/bin/env bash
# Split the workshop's single shared DX gateway into two — one per DC.
# Verified end-to-end on a live workshop event (July 2026).
#
# Base workshop: one DXGW (ASN 65000) carrying both DC1 + DC2 transit VIFs,
# with a single Cloud WAN DIRECT_CONNECT_GATEWAY attachment.
# Target: DXGW2 (ASN 65002) owning DC2's VIF + its own Cloud WAN attachment.
#
# Notes from the live run:
#   - DXGWs are global but describe/create calls must hit the region where the
#     DX connections live (ap-southeast-2 in the workshop), not the console region.
#   - Each workshop DX connection allows exactly 1 VIF, so the old VIF must be
#     fully "deleted" (~3 min) before the replacement can be created.
#   - A transit VIF cannot be re-associated to another DXGW: delete + recreate
#     on the same connection with identical VLAN/BGP-v4 parameters.
#   - IPv6 peers only get auto-assigned addresses; the recreated VIF will have
#     a NEW v6 /125 + auth key — the router's eth3 vif address and v6 neighbor
#     must be updated accordingly (v4 params can be reused verbatim).
#
# Usage: scripts/split-dxgw.sh <dx-region> [--execute]
set -euo pipefail
DX_REGION="${1:?region where DX connections live (workshop: ap-southeast-2)}"
EXECUTE="${2:-}"
CN_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> Current VIFs in $DX_REGION"
aws directconnect describe-virtual-interfaces --region "$DX_REGION" \
  --query 'virtualInterfaces[].{Id:virtualInterfaceId,Name:virtualInterfaceName,Vlan:vlan,ASN:asn,DXGW:directConnectGatewayId,Conn:connectionId,State:virtualInterfaceState}' --output table

DC2_VIF=$(aws directconnect describe-virtual-interfaces --region "$DX_REGION" \
  --query 'virtualInterfaces[?virtualInterfaceName==`DC2`]|[0].virtualInterfaceId' --output text)
DC2_CONN=$(aws directconnect describe-virtual-interfaces --region "$DX_REGION" \
  --query 'virtualInterfaces[?virtualInterfaceName==`DC2`]|[0].connectionId' --output text)
CORE_ID=$(aws networkmanager list-core-networks --region "$CN_REGION" \
  --query 'CoreNetworks[?State==`AVAILABLE`]|[0].CoreNetworkId' --output text)

echo "==> Backing up DC2 VIF ($DC2_VIF) BGP parameters to out/dc2-vif-backup.json"
mkdir -p out
aws directconnect describe-virtual-interfaces --region "$DX_REGION" --virtual-interface-id "$DC2_VIF" \
  --query 'virtualInterfaces[0]' --output json > out/dc2-vif-backup.json
V4_AMZ=$(jq -r '.bgpPeers[]|select(.addressFamily=="ipv4").amazonAddress' out/dc2-vif-backup.json)
V4_CUST=$(jq -r '.bgpPeers[]|select(.addressFamily=="ipv4").customerAddress' out/dc2-vif-backup.json)
V4_AUTH=$(jq -r '.bgpPeers[]|select(.addressFamily=="ipv4").authKey' out/dc2-vif-backup.json)
VLAN=$(jq -r .vlan out/dc2-vif-backup.json)
ASN=$(jq -r .asn out/dc2-vif-backup.json)

if [[ "$EXECUTE" != "--execute" ]]; then
  echo; echo "Dry-run. Would: create DXGW2 (65002) -> CWAN attachment -> delete $DC2_VIF -> recreate on $DC2_CONN (vlan $VLAN, asn $ASN) -> add v6 peer."
  echo "Re-run with: scripts/split-dxgw.sh $DX_REGION --execute"
  exit 0
fi

echo "==> 1) Create DXGW2 (ASN 65002)"
DXGW2=$(aws directconnect create-direct-connect-gateway --region "$CN_REGION" \
  --direct-connect-gateway-name dxgw2 --amazon-side-asn 65002 \
  --query 'directConnectGateway.directConnectGatewayId' --output text)
echo "    $DXGW2"

echo "==> 2) Cloud WAN DX attachment for DXGW2 (segment=onprem via tag)"
EDGES=$(aws networkmanager get-core-network --region "$CN_REGION" --core-network-id "$CORE_ID" \
  --query 'CoreNetwork.Edges[].EdgeLocation' --output text)
# shellcheck disable=SC2086
ATT=$(aws networkmanager create-direct-connect-gateway-attachment --region "$CN_REGION" \
  --core-network-id "$CORE_ID" \
  --direct-connect-gateway-arn "arn:aws:directconnect::${ACCOUNT_ID}:dx-gateway/${DXGW2}" \
  --edge-locations $EDGES \
  --tags Key=segment,Value=onprem Key=Name,Value=dxgw2-attachment \
  --query 'DirectConnectGatewayAttachment.Attachment.AttachmentId' --output text)
echo "    $ATT"

echo "==> 3) Delete DC2 VIF and wait for full deletion (connection allows only 1 VIF)"
aws directconnect delete-virtual-interface --region "$DX_REGION" --virtual-interface-id "$DC2_VIF" >/dev/null
while true; do
  ST=$(aws directconnect describe-virtual-interfaces --region "$DX_REGION" \
    --virtual-interface-id "$DC2_VIF" \
    --query 'virtualInterfaces[0].virtualInterfaceState' --output text 2>/dev/null || echo deleted)
  echo "    $ST"; [[ "$ST" == "deleted" || "$ST" == "None" ]] && break; sleep 20
done

echo "==> 4) Recreate DC2 transit VIF on DXGW2 (same VLAN/v4 BGP params)"
NEW_VIF=$(aws directconnect create-transit-virtual-interface --region "$DX_REGION" \
  --connection-id "$DC2_CONN" \
  --new-transit-virtual-interface "{\"virtualInterfaceName\":\"DC2\",\"vlan\":$VLAN,\"asn\":$ASN,\"mtu\":1500,\"addressFamily\":\"ipv4\",\"amazonAddress\":\"$V4_AMZ\",\"customerAddress\":\"$V4_CUST\",\"authKey\":\"$V4_AUTH\",\"directConnectGatewayId\":\"$DXGW2\"}" \
  --query 'virtualInterface.virtualInterfaceId' --output text)
echo "    $NEW_VIF"

echo "==> 5) Add IPv6 peer (auto-assigned addresses only)"
aws directconnect create-bgp-peer --region "$DX_REGION" --virtual-interface-id "$NEW_VIF" \
  --new-bgp-peer "{\"asn\":$ASN,\"addressFamily\":\"ipv6\"}" >/dev/null
aws directconnect describe-virtual-interfaces --region "$DX_REGION" --virtual-interface-id "$NEW_VIF" \
  --query 'virtualInterfaces[0].bgpPeers[?addressFamily==`ipv6`].{Amazon:amazonAddress,Customer:customerAddress,AuthKey:authKey}' --output table

cat <<ROUTER

==> 6) Update dc2-router (SSM -> onprem host -> dc2-router), then wait ~3 min for BGP:
  configure
  set protocols bgp $ASN neighbor ${V4_AMZ%/*} remote-as 65002
  delete interfaces ethernet eth3 vif $VLAN address <OLD_V6_CUSTOMER/125>
  set interfaces ethernet eth3 vif $VLAN address <NEW_V6_CUSTOMER/125>
  delete protocols bgp $ASN neighbor <OLD_V6_AMAZON>
  set protocols bgp $ASN neighbor <NEW_V6_AMAZON> remote-as 65002
  set protocols bgp $ASN neighbor <NEW_V6_AMAZON> password <NEW_AUTH_KEY>
  set protocols bgp $ASN neighbor <NEW_V6_AMAZON> address-family ipv6-unicast prefix-list export DC2-OUT
  set protocols bgp $ASN neighbor <NEW_V6_AMAZON> address-family ipv6-unicast soft-reconfiguration inbound
  set protocols bgp $ASN neighbor <NEW_V6_AMAZON> solo
  commit; save

Verify: show ip bgp summary / show bgp ipv6 summary — expect AS 65002 established.
ROUTER
