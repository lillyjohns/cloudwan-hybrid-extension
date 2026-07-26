#!/usr/bin/env bash
# One-command deployment: discovers workshop resources, creates the VPN
# extension (CGW + standalone VPN + Cloud WAN attachment) per DC, waits for
# AVAILABLE, and renders ready-to-paste VyOS configs into out/.
#
# Uses plain AWS CLI calls (works with the workshop participant role, which
# has no CloudFormation permissions). Prefer templates/vpn-extension.yaml if
# you have CFN access and want stack lifecycle management.
# Compatible with bash 3.2 (macOS default).
#
# Usage:
#   ./deploy.sh              # both DCs
#   ./deploy.sh dc1          # one DC
#   ./deploy.sh --destroy    # delete everything this script created
set -euo pipefail
cd "$(dirname "$0")"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

destroy() {
  for dc in dc1 dc2; do
    VPN_ID=$(aws ec2 describe-vpn-connections --region "$REGION" \
      --filters "Name=tag:Name,Values=${dc}-cwan-vpn" "Name=state,Values=available,pending" \
      --query 'VpnConnections[0].VpnConnectionId' --output text)
    if [[ -n "$VPN_ID" && "$VPN_ID" != "None" ]]; then
      ATT_ID=$(aws networkmanager list-attachments --region "$REGION" \
        --attachment-type SITE_TO_SITE_VPN \
        --query "Attachments[?ResourceArn=='arn:aws:ec2:${REGION}:${ACCOUNT_ID}:vpn-connection/${VPN_ID}'].AttachmentId" --output text)
      if [[ -n "$ATT_ID" && "$ATT_ID" != "None" ]]; then
        echo "==> [$dc] deleting attachment $ATT_ID"
        aws networkmanager delete-attachment --region "$REGION" --attachment-id "$ATT_ID" >/dev/null
        while aws networkmanager get-site-to-site-vpn-attachment --region "$REGION" \
            --attachment-id "$ATT_ID" >/dev/null 2>&1; do sleep 20; echo "    waiting"; done
      fi
      echo "==> [$dc] deleting VPN $VPN_ID"
      aws ec2 delete-vpn-connection --region "$REGION" --vpn-connection-id "$VPN_ID" >/dev/null
    fi
    CGW_ID=$(aws ec2 describe-customer-gateways --region "$REGION" \
      --filters "Name=tag:Name,Values=${dc}-cgw" "Name=state,Values=available" \
      --query 'CustomerGateways[0].CustomerGatewayId' --output text)
    if [[ -n "$CGW_ID" && "$CGW_ID" != "None" ]]; then
      echo "==> [$dc] deleting CGW $CGW_ID"
      sleep 10
      aws ec2 delete-customer-gateway --region "$REGION" --customer-gateway-id "$CGW_ID" >/dev/null || \
        { sleep 60; aws ec2 delete-customer-gateway --region "$REGION" --customer-gateway-id "$CGW_ID" >/dev/null; }
    fi
  done
  echo "done"
}

if [[ "${1:-}" == "--destroy" ]]; then destroy; exit 0; fi

DCS="${*:-dc1 dc2}"

for dc in $DCS; do
  echo "==> [$dc] discovering workshop resources"
  eval "$(scripts/discover.sh "$dc")"

  echo "==> [$dc] customer gateway ($CGW_IP, ASN $ASN)"
  CGW_ID=$(aws ec2 create-customer-gateway --region "$REGION" \
    --type ipsec.1 --public-ip "$CGW_IP" --bgp-asn "$ASN" \
    --tag-specifications "ResourceType=customer-gateway,Tags=[{Key=Name,Value=${dc}-cgw}]" \
    --query 'CustomerGateway.CustomerGatewayId' --output text)
  echo "    $CGW_ID"

  echo "==> [$dc] standalone VPN connection (no VGW/TGW)"
  VPN_ID=$(aws ec2 create-vpn-connection --region "$REGION" \
    --type ipsec.1 --customer-gateway-id "$CGW_ID" \
    --options "TunnelOptions=[{TunnelInsideCidr=${T1}},{TunnelInsideCidr=${T2}}]" \
    --tag-specifications "ResourceType=vpn-connection,Tags=[{Key=Name,Value=${dc}-cwan-vpn}]" \
    --query 'VpnConnection.VpnConnectionId' --output text)
  echo "    $VPN_ID"

  echo "==> [$dc] Cloud WAN site-to-site VPN attachment (segment via tag)"
  ATT_ID=$(aws networkmanager create-site-to-site-vpn-attachment --region "$REGION" \
    --core-network-id "$CORE_ID" \
    --vpn-connection-arn "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:vpn-connection/${VPN_ID}" \
    --tags Key=segment,Value=onprem Key=Name,Value="${dc}-cwan-vpn-attachment" \
    --query 'SiteToSiteVpnAttachment.Attachment.AttachmentId' --output text)
  echo "    $ATT_ID"

  echo "==> [$dc] waiting for AVAILABLE (CREATING -> PENDING_NETWORK_UPDATE -> AVAILABLE, ~5-8 min)"
  while true; do
    STATE=$(aws networkmanager get-site-to-site-vpn-attachment --region "$REGION" \
      --attachment-id "$ATT_ID" \
      --query 'SiteToSiteVpnAttachment.Attachment.State' --output text)
    echo "    $STATE"
    [[ "$STATE" == "AVAILABLE" ]] && break
    [[ "$STATE" == "FAILED" ]] && { echo "attachment FAILED" >&2; exit 1; }
    sleep 30
  done

  echo "==> [$dc] rendering router config"
  scripts/generate-router-config.sh "$dc" "$VPN_ID"
done

echo
echo "All done. Paste the generated config(s) into the router(s):"
echo "  SSM Session Manager -> onprem host -> choose dc1-router / dc2-router"
ls -1 out/*.conf 2>/dev/null | sed 's/^/  /'
