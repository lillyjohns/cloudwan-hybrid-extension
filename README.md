# Cloud WAN Hybrid Connectivity Extension — 2× DX + 2× VPN

An **extension of the AWS workshop** [Dual-stack global networks with AWS Cloud WAN and AWS Direct Connect](https://catalog.us-east-1.prod.workshops.aws/workshops/3d335f4f-0f81-42c0-b093-8ae623511e12/en-US/04-provision-dx/07-verify-connectivity).

The original workshop connects two on-premises data centers (DC1/DC2) to AWS Cloud WAN using **Direct Connect (DX) only**. This extension adds **Site-to-Site VPN attachments** alongside the existing DX attachments, so the final topology has **redundant hybrid paths**:

```
                    ┌──────────────────────────────────────────┐
                    │        AWS Cloud WAN Core Network        │
                    │  (us-west-2: ASN 64512 / ap-se-2: 64513) │
                    │                                          │
                    │  segments: prod / nonprod /              │
                    │            sharedservices / onprem       │
                    └───┬─────────┬──────────────┬─────────┬───┘
                        │         │              │         │
                   DX attach  VPN attach    DX attach  VPN attach
                   (dxgw)     (S2S)         (dxgw)     (S2S)
                        │         │              │         │
                    ┌───┴─────────┴───┐      ┌───┴─────────┴───┐
                    │   DC1 (VyOS)    │──────│   DC2 (VyOS)    │
                    │   AS 65101      │ DCI  │   AS 65102      │
                    │   10.1.0.0/16   │      │   10.2.0.0/16   │
                    └─────────────────┘      └─────────────────┘
```

**Why:** with both DX and VPN attached to the same `onprem` segment, you can test **Cloud WAN routing policies** — path preference, failover, AS-path prepending, and static-route overrides — without touching the physical circuits.

> Verified working on the live workshop event (July 2026): both IPsec tunnels UP, BGP established with the core network edge (AS 64512), 7 prefixes received over VPN in parallel with DX.

## Repo layout

| Path | Purpose |
|---|---|
| `templates/vpn-extension.yaml` | CloudFormation: CGW + standalone VPN + Cloud WAN S2S VPN attachment (per DC) |
| `templates/vpn-extension-cli.sh` | Same as above using pure AWS CLI (works when CFN resource support lags) |
| `policies/` | Core network policy documents for routing-policy experiments |
| `router-config/` | VyOS configuration for DC1/DC2 routers (IPsec + BGP over VTI) |
| `docs/routing-tests.md` | Test matrix: how to verify each routing policy scenario |

## Prerequisites

- Completed the workshop through **04 — Provision dual-stack Direct Connect** (DX VIFs BGP up).
- Cloud WAN core network available (from workshop stack `dxglobal`).
- Workshop participant role needs additional policies (the default `WSParticipantRole` cannot create VPN resources):
  - `AmazonEC2FullAccess`
  - `AmazonVPCFullAccess`
  - `AWSNetworkManagerFullAccess`

## Quick start (one DC)

```bash
aws cloudformation deploy \
  --template-file templates/vpn-extension.yaml \
  --stack-name cwan-vpn-dc1 \
  --parameter-overrides \
      CoreNetworkId=core-network-0f1c1de8f20aab19c \
      CoreNetworkArn=arn:aws:networkmanager::<ACCOUNT_ID>:core-network/core-network-0f1c1de8f20aab19c \
      CustomerGatewayIp=<DC1_PUBLIC_IP> \
      CustomerGatewayAsn=65101 \
      Segment=onprem \
      TunnelInsideCidr1=169.254.101.0/30 \
      TunnelInsideCidr2=169.254.101.4/30
```

Then configure the on-prem router — see `router-config/dc1-vyos.conf` (fill in the PSKs and outside IPs from the VPN's `CustomerGatewayConfiguration`).

Repeat for DC2 with `CustomerGatewayAsn=65102` and different tunnel CIDRs (e.g. `169.254.102.x`).

## Verify

```bash
# AWS side — both tunnels should be UP with accepted routes
aws ec2 describe-vpn-connections --vpn-connection-ids <vpn-id> \
  --query 'VpnConnections[0].VgwTelemetry[].{IP:OutsideIpAddress,Status:Status,Routes:AcceptedRouteCount}'
```

```
# VyOS side
show vpn ipsec sa          # both peers "up"
show ip bgp summary        # neighbors 169.254.10x.1 / .5 established (AS 64512)
show ip bgp neighbors 169.254.101.1 received-routes
```

## Routing policy experiments

With both DX and VPN in the `onprem` segment, DC prefixes are learned twice by the core network. See [`docs/routing-tests.md`](docs/routing-tests.md) for the full test matrix. Highlights:

1. **Baseline** — Cloud WAN prefers DX (shorter AS path via DXGW); VPN is standby.
2. **Failover** — shut the DX VIF on VyOS, watch traffic shift to VPN (`overlay` route change in the core network route table).
3. **Prefer VPN** — AS-path prepend on the DX BGP session from VyOS.
4. **Segment isolation / static override** — edit the core network policy documents in `policies/` and apply via `networkmanager put-core-network-policy`.

## Gotchas (learned the hard way)

- **Don't route VPN through a TGW + peering** to reach Cloud WAN — `create-transit-gateway-route-table-attachment` fails silently and intermittently. Use the **direct `SiteToSiteVpnAttachment`** with a standalone VPN connection (no VGW/TGW) instead. Cheaper too.
- The standalone VPN connection must exist **before** the attachment; attachment tagging (`Key=segment`) drives segment association via the policy's attachment rules.
- VyOS (equuleus) pairs with AWS VPN defaults using **IKEv1** + AES256/SHA256/DH14. IKEv2 needs extra proposal tuning.
- Attachment goes `CREATING → PENDING_NETWORK_UPDATE → AVAILABLE` (~5-8 min).

## Cost note

A standalone S2S VPN attachment costs ~$0.05/h (VPN) + Cloud WAN attachment-hours. No TGW required. Delete the stack when done.

## License

MIT — see [LICENSE](LICENSE).
