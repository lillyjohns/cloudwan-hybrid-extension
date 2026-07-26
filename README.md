# Cloud WAN Hybrid Connectivity Extension — 2× DX + 2× VPN

An **extension of the AWS workshop** [Dual-stack global networks with AWS Cloud WAN and AWS Direct Connect](https://catalog.us-east-1.prod.workshops.aws/workshops/3d335f4f-0f81-42c0-b093-8ae623511e12/en-US/04-provision-dx/07-verify-connectivity).

The base workshop connects two on-premises data centers (DC1/DC2) to AWS Cloud WAN through a **Direct Connect gateway**. This extension adds **Site-to-Site VPN attachments** alongside, so the final topology has **redundant hybrid paths per DC** — the ideal playground for testing **Cloud WAN routing policies** (path preference, failover, prepending, static overrides) without touching the DX circuits.

```
                 ┌─────────────────────────────────────────────────┐
                 │            AWS Cloud WAN Core Network           │
                 │      edge us-west-2        edge ap-southeast-2  │
                 │        ASN 64512               ASN 64513        │
                 │                                                 │
                 │   segments: prod / nonprod /                    │
                 │             sharedservices / onprem             │
                 └──────┬──────────────┬───────────────┬───────────┘
                        │              │               │
              DX GW attachment    VPN attachment   VPN attachment
                 (onprem)           (onprem)         (onprem)
                        │              │               │
               ┌────────┴────────┐    │               │
               │   DX Gateway    │    │               │
               │    ASN 65000    │    │               │
               │ (own BGP ASN —  │    │               │
               │  separate hop)  │    │               │
               └───┬─────────┬───┘    │               │
            transit VIF   transit VIF │               │
            (DC1, dual-   (DC2, dual- │               │
             stack BGP)    stack BGP) │               │
                   │             │    │               │
              ┌────┴─────┐  ┌────┴────┴─┐             │
              │DC1 (VyOS)│  │DC2 (VyOS) │─────────────┘
              │ AS 65101 │──│ AS 65102  │
              │10.1.0.0/16│DCI│10.2.0.0/16│
              └──────────┘  └───────────┘
```

Note the **DX gateway is its own BGP hop with its own ASN (65000)** — DC routers peer with the DXGW (AS 65000), which then attaches to the core network edges (AS 64512/64513). The VPN attachments terminate **directly on the core network edge ASN** instead. This asymmetry (AS-path via DX: `65000 6451x` vs via VPN: `6451x`) is part of what makes the routing-policy tests interesting.

> Verified on a live workshop event (July 2026): both IPsec tunnels UP, BGP established to the core edge, prefixes received over VPN in parallel with DX.

## Repo layout

| Path | Purpose |
|---|---|
| `deploy.sh` | **One command, zero manual input** — auto-discovers everything and deploys |
| `templates/vpn-extension.yaml` | CloudFormation: CGW + standalone VPN + Cloud WAN S2S VPN attachment (per DC) |
| `scripts/discover.sh` | Auto-discovery: core network, CGW IPs, ASNs (single core network per account/region assumed, as in the workshop) |
| `scripts/generate-router-config.sh` | Renders ready-to-paste VyOS config with real outside IPs + PSKs filled in |
| `policies/` | Core network policy documents for routing-policy experiments |
| `docs/routing-tests.md` | Test matrix for routing-policy scenarios |

## Prerequisites

- Base workshop deployed through **04 — Provision dual-stack Direct Connect** (DX VIFs BGP up).
- If running as a Workshop Studio participant, `WSParticipantRole` needs: `AmazonEC2FullAccess`, `AmazonVPCFullAccess`, `AWSNetworkManagerFullAccess`.

## Quick start — one command

```bash
./deploy.sh            # deploys DC1 + DC2 VPNs, waits for AVAILABLE, prints router configs
./deploy.sh dc1        # or one DC at a time
```

No IDs to look up: the script discovers the core network (`aws networkmanager list-core-networks` — the workshop has exactly one per account), the on-prem router public IPs, and the DC ASNs, then deploys the CloudFormation stack(s) and renders the VyOS configs into `out/dc1-vyos.conf` / `out/dc2-vyos.conf` with the tunnel PSKs and outside IPs already substituted.

Last manual step is pasting the generated config into each DC router (SSM Session Manager → `dc1-router` / `dc2-router`), which is intentional — the routers simulate customer-managed on-prem gear.

If you prefer raw CloudFormation, the template works standalone too:

```bash
aws cloudformation deploy \
  --template-file templates/vpn-extension.yaml \
  --stack-name cwan-vpn-dc1 \
  --parameter-overrides $(scripts/discover.sh dc1 --cfn-params)
```

## Verify

```bash
# AWS side — both tunnels UP with accepted routes
aws ec2 describe-vpn-connections --vpn-connection-ids <vpn-id> \
  --query 'VpnConnections[0].VgwTelemetry[].{IP:OutsideIpAddress,Status:Status,Routes:AcceptedRouteCount}'
```

```
# VyOS side
show vpn ipsec sa
show ip bgp summary
show ip bgp neighbors 169.254.101.1 received-routes
```

## Routing policy experiments

With DX and VPN both in the `onprem` segment, each DC prefix reaches the core network twice via different attachment types. See [`docs/routing-tests.md`](docs/routing-tests.md):

1. **Baseline** — attachment-type preference: DX gateway attachments beat VPN.
2. **Failover** — shut the DX BGP session, watch routes shift to the VPN attachment.
3. **AS-path prepend on DX** — demonstrates that attachment-type preference is evaluated *before* AS-path length.
4. **Segment isolation** — apply `policies/isolate-onprem-from-nonprod.json`.
5. **Static route override** — static beats BGP-learned.

## Cost note

Standalone S2S VPN ≈ $0.05/h + Cloud WAN attachment-hours. No VGW/TGW needed. `./deploy.sh --destroy` removes everything this extension created.

## License

MIT — see [LICENSE](LICENSE).
