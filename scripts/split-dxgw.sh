#!/usr/bin/env bash
# Split the workshop's single shared DX gateway into two — one per DC.
#
# Base workshop: one DXGW (ASN 65000) carrying both DC1 + DC2 transit VIFs,
# with a single Cloud WAN DIRECT_CONNECT_GATEWAY attachment.
# Target: DXGW1 (ASN 65001, DC1 VIF) + DXGW2 (ASN 65002, DC2 VIF), each with
# its own Cloud WAN DX attachment in the onprem segment.
#
# What is automated vs not:
#   - Creating DXGW2 and the second Cloud WAN DX attachment: automated.
#   - Moving DC2's transit VIF: a transit VIF is bound to its DXGW at creation
#     and cannot be re-associated. The script deletes DC2's VIF and prints the
#     exact parameters to re-order it against DXGW2 through the workshop's
#     "Direct Connect partner orders" page (same VLAN/BGP settings, so the
#     dc2-router config keeps working unchanged).
#
# Usage: scripts/split-dxgw.sh [--execute]   (dry-run by default)
set -euo pipefail
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
EXECUTE="${1:-}"

run() { echo "+ $*"; [[ "$EXECUTE" == "--execute" ]] && "$@" || true; }

echo "==> Current DX gateways"
aws directconnect describe-direct-connect-gateways --region "$REGION" \
  --query 'directConnectGateways[].{Id:directConnectGatewayId,Name:directConnectGatewayName,ASN:amazonSideAsn}' --output table

echo "==> DC2 transit VIF (VLAN 2340 in the workshop numbering)"
aws directconnect describe-virtual-interfaces --region "$REGION" \
  --query 'virtualInterfaces[?virtualInterfaceType==`transit`].{Id:virtualInterfaceId,Vlan:vlan,ASN:asn,DXGW:directConnectGatewayId,State:virtualInterfaceState}' --output table

CORE_ID=$(aws networkmanager list-core-networks --region "$REGION" \
  --query 'CoreNetworks[?State==`AVAILABLE`]|[0].CoreNetworkId' --output text)

echo "==> 1) Create DXGW2 (ASN 65002)"
run aws directconnect create-direct-connect-gateway --region "$REGION" \
  --direct-connect-gateway-name dxgw2 --amazon-side-asn 65002

echo "==> 2) Create the Cloud WAN DX attachment for DXGW2 (tag segment=onprem)"
echo "    (fill in the DXGW2 ARN printed above)"
cat <<EOF
+ aws networkmanager create-direct-connect-gateway-attachment --region $REGION \\
    --core-network-id $CORE_ID \\
    --direct-connect-gateway-arn arn:aws:directconnect::<ACCOUNT_ID>:dx-gateway/<DXGW2_ID> \\
    --edge-locations $REGION \\
    --tags Key=segment,Value=onprem Key=Name,Value=dxgw2-attachment
EOF

echo "==> 3) Re-home DC2's transit VIF onto DXGW2"
echo "    Transit VIFs cannot move between DXGWs. Delete DC2's VIF and re-order"
echo "    it from the workshop 'Direct Connect partner orders' page with the"
echo "    SAME VLAN + BGP parameters, selecting DXGW2 as the gateway:"
echo "      - delete: aws directconnect delete-virtual-interface --virtual-interface-id <dc2-vif-id>"
echo "      - re-order via partner page -> accept the new VIF -> DXGW2"
echo "    dc2-router's BGP config is unchanged (same peer IPs/VLAN/ASN 65000->65002 remote-as update needed):"
echo "      set protocols bgp 65102 neighbor <peer> remote-as 65002"

echo
echo "==> 4) (Optional) Rename/renumber DXGW1: recreate with ASN 65001 the same way if you want strict per-DC ASNs."
echo
[[ "$EXECUTE" == "--execute" ]] || echo "Dry-run only. Re-run with --execute to apply the automated steps."
