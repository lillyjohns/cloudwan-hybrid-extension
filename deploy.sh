#!/usr/bin/env bash
# One-command deployment: discovers workshop resources, deploys the VPN
# extension stack(s), waits for the Cloud WAN attachment, and renders
# ready-to-paste VyOS configs.
#
# Usage:
#   ./deploy.sh              # both DCs
#   ./deploy.sh dc1          # one DC
#   ./deploy.sh --destroy    # delete both stacks
set -euo pipefail
cd "$(dirname "$0")"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"

if [[ "${1:-}" == "--destroy" ]]; then
  for dc in dc1 dc2; do
    if aws cloudformation describe-stacks --region "$REGION" --stack-name "cwan-vpn-$dc" >/dev/null 2>&1; then
      echo "==> deleting cwan-vpn-$dc"
      aws cloudformation delete-stack --region "$REGION" --stack-name "cwan-vpn-$dc"
      aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "cwan-vpn-$dc"
    fi
  done
  echo "done"
  exit 0
fi

DCS=("${@:-dc1 dc2}")
[[ $# -eq 0 ]] && DCS=(dc1 dc2)

for dc in "${DCS[@]}"; do
  echo "==> [$dc] discovering workshop resources"
  PARAMS=$(scripts/discover.sh "$dc" --cfn-params)
  echo "    $PARAMS"

  echo "==> [$dc] deploying CloudFormation stack cwan-vpn-$dc"
  # shellcheck disable=SC2086
  aws cloudformation deploy --region "$REGION" \
    --template-file templates/vpn-extension.yaml \
    --stack-name "cwan-vpn-$dc" \
    --parameter-overrides $PARAMS

  VPN_ID=$(aws cloudformation describe-stacks --region "$REGION" \
    --stack-name "cwan-vpn-$dc" \
    --query 'Stacks[0].Outputs[?OutputKey==`VpnConnectionId`].OutputValue' --output text)
  ATT_ID=$(aws cloudformation describe-stacks --region "$REGION" \
    --stack-name "cwan-vpn-$dc" \
    --query 'Stacks[0].Outputs[?OutputKey==`AttachmentId`].OutputValue' --output text)

  echo "==> [$dc] waiting for attachment $ATT_ID to become AVAILABLE (~5-8 min)"
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
