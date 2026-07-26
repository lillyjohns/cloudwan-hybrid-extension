#!/usr/bin/env bash
# Cloud WAN hybrid extension - pure CLI version of vpn-extension.yaml.
# Useful if your CloudFormation coverage/permissions lag behind the APIs.
#
# Usage:
#   ./vpn-extension-cli.sh <core-network-id> <cgw-public-ip> <asn> <dc-name> <tunnel1-cidr> <tunnel2-cidr> [region]
# Example (DC1):
#   ./vpn-extension-cli.sh core-network-0f1c1de8f20aab19c 52.41.75.142 65101 dc1 169.254.101.0/30 169.254.101.4/30 us-west-2
set -euo pipefail

CORE_ID="${1:?core-network-id}"
CGW_IP="${2:?cgw public ip}"
ASN="${3:?asn}"
DC="${4:?dc name}"
T1="${5:?tunnel1 inside cidr}"
T2="${6:?tunnel2 inside cidr}"
REGION="${7:-us-west-2}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> 1/3 Customer gateway"
CGW_ID=$(aws ec2 create-customer-gateway --region "$REGION" \
  --type ipsec.1 --public-ip "$CGW_IP" --bgp-asn "$ASN" \
  --tag-specifications "ResourceType=customer-gateway,Tags=[{Key=Name,Value=${DC}-cgw}]" \
  --query 'CustomerGateway.CustomerGatewayId' --output text)
echo "    $CGW_ID"

echo "==> 2/3 Standalone VPN connection (no VGW/TGW)"
VPN_ID=$(aws ec2 create-vpn-connection --region "$REGION" \
  --type ipsec.1 --customer-gateway-id "$CGW_ID" \
  --options "TunnelOptions=[{TunnelInsideCidr=${T1}},{TunnelInsideCidr=${T2}}]" \
  --tag-specifications "ResourceType=vpn-connection,Tags=[{Key=Name,Value=${DC}-cwan-vpn}]" \
  --query 'VpnConnection.VpnConnectionId' --output text)
echo "    $VPN_ID"

echo "==> 3/3 Cloud WAN site-to-site VPN attachment (segment=onprem via tag)"
ATT_ID=$(aws networkmanager create-site-to-site-vpn-attachment --region "$REGION" \
  --core-network-id "$CORE_ID" \
  --vpn-connection-arn "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:vpn-connection/${VPN_ID}" \
  --tags Key=segment,Value=onprem Key=Name,Value="${DC}-cwan-vpn-attachment" \
  --query 'SiteToSiteVpnAttachment.Attachment.AttachmentId' --output text)
echo "    $ATT_ID"

echo "==> Waiting for attachment AVAILABLE (CREATING -> PENDING_NETWORK_UPDATE -> AVAILABLE, ~5-8 min)"
while true; do
  STATE=$(aws networkmanager get-site-to-site-vpn-attachment --region "$REGION" \
    --attachment-id "$ATT_ID" \
    --query 'SiteToSiteVpnAttachment.Attachment.State' --output text)
  echo "    $STATE"
  [[ "$STATE" == "AVAILABLE" ]] && break
  [[ "$STATE" == "FAILED" ]] && { echo "attachment FAILED"; exit 1; }
  sleep 30
done

echo
echo "==> Tunnel details for the on-prem router (outside IPs + PSKs):"
aws ec2 describe-vpn-connections --region "$REGION" --vpn-connection-ids "$VPN_ID" \
  --query 'VpnConnections[0].Options.TunnelOptions[].{OutsideIp:OutsideIpAddress,InsideCidr:TunnelInsideCidr,PSK:PreSharedKey}' \
  --output table

echo "Done. Now configure the router - see router-config/${DC}-vyos.conf"
