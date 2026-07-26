#!/usr/bin/env bash
# Auto-discover workshop resources. The workshop deploys exactly one Cloud WAN
# core network per account, so no IDs need to be provided by the user.
#
# Usage:
#   scripts/discover.sh dc1              # print discovered values (env format)
#   scripts/discover.sh dc1 --cfn-params # print CloudFormation parameter overrides
set -euo pipefail

DC="${1:?usage: discover.sh <dc1|dc2> [--cfn-params]}"
MODE="${2:-env}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"

case "$DC" in
  dc1) ASN=65101; T1=169.254.101.0/30; T2=169.254.101.4/30 ;;
  dc2) ASN=65102; T1=169.254.102.0/30; T2=169.254.102.4/30 ;;
  *) echo "unknown DC: $DC (expected dc1|dc2)" >&2; exit 1 ;;
esac

# --- Core network: workshop guarantees exactly one per account ---
read -r CORE_ID CORE_ARN < <(aws networkmanager list-core-networks --region "$REGION" \
  --query 'CoreNetworks[?State==`AVAILABLE`] | [0].[CoreNetworkId,CoreNetworkArn]' --output text)
if [[ -z "$CORE_ID" || "$CORE_ID" == "None" ]]; then
  echo "no AVAILABLE core network found in $REGION" >&2; exit 1
fi

# --- On-prem router public IP: the workshop's onprem host fronts both DC
# routers behind one EIP; instance is tagged Name=onprem ---
CGW_IP=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=onprem" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
if [[ -z "$CGW_IP" || "$CGW_IP" == "None" ]]; then
  echo "no running instance tagged Name=onprem found in $REGION" >&2; exit 1
fi

if [[ "$MODE" == "--cfn-params" ]]; then
  echo "CoreNetworkId=$CORE_ID CoreNetworkArn=$CORE_ARN CustomerGatewayIp=$CGW_IP CustomerGatewayAsn=$ASN DcName=$DC TunnelInsideCidr1=$T1 TunnelInsideCidr2=$T2 Segment=onprem"
else
  cat <<EOF
CORE_ID=$CORE_ID
CORE_ARN=$CORE_ARN
CGW_IP=$CGW_IP
ASN=$ASN
DC=$DC
T1=$T1
T2=$T2
REGION=$REGION
EOF
fi
