#!/usr/bin/env bash
# Render a ready-to-paste VyOS config for a DC from a deployed VPN connection:
# fills in outside IPs, PSKs, inside addresses, ASNs. No manual lookups.
#
# Usage: scripts/generate-router-config.sh <dc1|dc2> <vpn-connection-id> [out-file]
set -euo pipefail

DC="${1:?dc1|dc2}"
VPN_ID="${2:?vpn-connection-id}"
OUT="${3:-out/${DC}-vyos.conf}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"

case "$DC" in
  dc1) LOCAL_AS=65101; PLIST=DC1-OUT ;;
  dc2) LOCAL_AS=65102; PLIST=DC2-OUT ;;
  *) echo "unknown DC: $DC" >&2; exit 1 ;;
esac

# Core network edge ASN for this region (VPN terminates on the edge directly)
EDGE_AS=$(aws networkmanager list-core-networks --region "$REGION" \
  --query 'CoreNetworks[?State==`AVAILABLE`]|[0].CoreNetworkId' --output text | xargs -I{} \
  aws networkmanager get-core-network --region "$REGION" --core-network-id {} \
  --query "CoreNetwork.Edges[?EdgeLocation=='$REGION']|[0].Asn" --output text)

# Tunnel details
mapfile -t TUN < <(aws ec2 describe-vpn-connections --region "$REGION" \
  --vpn-connection-ids "$VPN_ID" \
  --query 'VpnConnections[0].Options.TunnelOptions[].[OutsideIpAddress,TunnelInsideCidr,PreSharedKey]' \
  --output text)
[[ ${#TUN[@]} -eq 2 ]] || { echo "expected 2 tunnels on $VPN_ID" >&2; exit 1; }

# The router's local (private) address used as IPsec local-address: the
# workshop routers sit behind 1:1 NAT; VyOS eth0 address is the local-address.
# We standardize on the workshop value; override with LOCAL_ADDR env if needed.
LOCAL_ADDR="${LOCAL_ADDR:-100.127.255.101}"
[[ "$DC" == "dc2" ]] && LOCAL_ADDR="${LOCAL_ADDR_DC2:-100.127.255.102}"

inside_ip() { # <cidr> <host-index> -> a.b.c.(base+idx)
  local net="${1%/*}" idx="$2"
  local base="${net##*.}" prefix="${net%.*}"
  echo "$prefix.$((base + idx))"
}

mkdir -p "$(dirname "$OUT")"
{
echo "# Generated $(date -u +%FT%TZ) for $DC from $VPN_ID (edge AS $EDGE_AS)"
echo "configure"
echo
cat <<'EOF'
set vpn ipsec ike-group AWS ikev2-reauth no
set vpn ipsec ike-group AWS key-exchange ikev1
set vpn ipsec ike-group AWS lifetime 28800
set vpn ipsec ike-group AWS proposal 1 dh-group 14
set vpn ipsec ike-group AWS proposal 1 encryption aes256
set vpn ipsec ike-group AWS proposal 1 hash sha256
set vpn ipsec ike-group AWS dead-peer-detection action restart
set vpn ipsec ike-group AWS dead-peer-detection interval 15
set vpn ipsec ike-group AWS dead-peer-detection timeout 30
set vpn ipsec esp-group AWS compression disable
set vpn ipsec esp-group AWS lifetime 3600
set vpn ipsec esp-group AWS mode tunnel
set vpn ipsec esp-group AWS pfs dh-group14
set vpn ipsec esp-group AWS proposal 1 encryption aes256
set vpn ipsec esp-group AWS proposal 1 hash sha256
set vpn ipsec ipsec-interfaces interface eth0
EOF
echo
i=0
for line in "${TUN[@]}"; do
  read -r OUTSIDE CIDR PSK <<<"$line"
  AWS_IP=$(inside_ip "$CIDR" 1)
  MY_IP=$(inside_ip "$CIDR" 2)
  echo "set interfaces vti vti$i address $MY_IP/30"
  echo "set interfaces vti vti$i description 'AWS-CWAN-Tunnel$((i+1))'"
  echo "set vpn ipsec site-to-site peer $OUTSIDE authentication mode pre-shared-secret"
  echo "set vpn ipsec site-to-site peer $OUTSIDE authentication pre-shared-secret '$PSK'"
  echo "set vpn ipsec site-to-site peer $OUTSIDE connection-type initiate"
  echo "set vpn ipsec site-to-site peer $OUTSIDE description 'AWS-CWAN-T$((i+1))'"
  echo "set vpn ipsec site-to-site peer $OUTSIDE ike-group AWS"
  echo "set vpn ipsec site-to-site peer $OUTSIDE local-address $LOCAL_ADDR"
  echo "set vpn ipsec site-to-site peer $OUTSIDE vti bind vti$i"
  echo "set vpn ipsec site-to-site peer $OUTSIDE vti esp-group AWS"
  echo "set protocols bgp $LOCAL_AS neighbor $AWS_IP remote-as $EDGE_AS"
  echo "set protocols bgp $LOCAL_AS neighbor $AWS_IP description 'AWS-CWAN-T$((i+1))'"
  echo "set protocols bgp $LOCAL_AS neighbor $AWS_IP address-family ipv4-unicast prefix-list export $PLIST"
  echo "set protocols bgp $LOCAL_AS neighbor $AWS_IP address-family ipv4-unicast soft-reconfiguration inbound"
  echo "set protocols bgp $LOCAL_AS neighbor $AWS_IP solo"
  echo
  i=$((i+1))
done
echo "commit"
echo "save"
echo "exit"
} > "$OUT"

echo "wrote $OUT"
