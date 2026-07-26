# Cloud WAN Hybrid Connectivity Extension — 2× DX + 2× VPN

An **extension of the AWS workshop** [Dual-stack global networks with AWS Cloud WAN and AWS Direct Connect](https://catalog.us-east-1.prod.workshops.aws/workshops/3d335f4f-0f81-42c0-b093-8ae623511e12/en-US/04-provision-dx/07-verify-connectivity).

The base workshop connects two on-premises data centers (DC1/DC2) to AWS Cloud WAN through a single shared **Direct Connect gateway**. This extension changes the hybrid design to **one DX gateway per DC** (each DXGW with its own ASN) and adds a **Site-to-Site VPN attachment per DC**, so the final topology has **four independent hybrid paths** — the ideal playground for testing **Cloud WAN routing policies** (path preference, failover, prepending, static overrides) without touching the DX circuits.

```
            ┌───────────────────────────────────────────────────────┐
            │              AWS Cloud WAN Core Network               │
            │       edge us-west-2          edge ap-southeast-2     │
            │         ASN 64512                 ASN 64513           │
            │                                                       │
            │     segments: prod / nonprod /                        │
            │               sharedservices / onprem                 │
            └──┬───────────┬────────────────┬───────────────┬───────┘
               │           │                │               │
         DXGW attach   VPN attach      DXGW attach     VPN attach
          (onprem)      (onprem)        (onprem)        (onprem)
               │           │                │               │
       ┌───────┴──────┐    │        ┌───────┴──────┐        │
       │ DX Gateway 1 │    │        │ DX Gateway 2 │        │
       │  ASN 65001   │    │        │  ASN 65002   │        │
       └───────┬──────┘    │        └───────┬──────┘        │
          transit VIF      │           transit VIF          │
        (dual-stack BGP)   │         (dual-stack BGP)       │
               │           │                │               │
         ┌─────┴───────────┴─┐        ┌─────┴───────────────┴─┐
         │     DC1 (VyOS)    │        │      DC2 (VyOS)       │
         │     AS 65101      │──DCI───│      AS 65102         │
         │    10.1.0.0/16    │        │     10.2.0.0/16       │
         └───────────────────┘        └───────────────────────┘
```

Key design points:

- **Two separate DX gateways, one per DC/circuit**, each a distinct BGP hop with its **own Amazon-side ASN** (DXGW1 = 65001, DXGW2 = 65002). This differs from the base workshop's single shared DXGW (ASN 65000) and gives each DX path an independent failure domain and a distinguishable AS-path.
- The **VPN attachments terminate directly on the core network edge ASN** (64512/64513) — no intermediate gateway hop.
- Resulting AS-paths for the same DC prefix: via DX `6500x 6451x`, via VPN `6451x`. Combined with Cloud WAN's attachment-type preference (DX > VPN), this asymmetry is what makes the routing-policy tests interesting.

> Migrating from the shared DXGW: `scripts/split-dxgw.sh` creates the second DXGW, re-associates DC2's transit VIF, and swaps the Cloud WAN DX attachments (see [DX gateway split](#dx-gateway-split)).

> Verified on a live workshop event (July 2026): both IPsec tunnels UP, BGP established to the core edge, prefixes received over VPN in parallel with DX.

## Repo layout

| Path | Purpose |
|---|---|
| `deploy.sh` | **One command, zero manual input** — auto-discovers everything and deploys |
| `templates/vpn-extension.yaml` | CloudFormation: CGW + standalone VPN + Cloud WAN S2S VPN attachment (per DC) |
| `scripts/discover.sh` | Auto-discovery: core network, CGW IPs, ASNs (single core network per account/region assumed, as in the workshop) |
| `scripts/generate-router-config.sh` | Renders ready-to-paste VyOS config with real outside IPs + PSKs filled in |
| `scripts/split-dxgw.sh` | Splits the workshop's shared DXGW into per-DC DXGWs (see below) |
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

## DX gateway split

The base workshop uses **one shared DXGW (ASN 65000)** for both DC transit VIFs. To reach the target diagram (per-DC DXGW with per-DC ASN):

```bash
scripts/split-dxgw.sh            # dry-run: shows current state + planned actions
scripts/split-dxgw.sh --execute  # creates DXGW2 (ASN 65002) + its Cloud WAN attachment
```

One step cannot be fully automated: a **transit VIF is bound to its DXGW at creation** and cannot be re-associated, so DC2's VIF must be deleted and re-ordered against DXGW2 through the workshop's *Direct Connect partner orders* page (same VLAN/BGP parameters — the script prints them). The only router-side change is `remote-as 65002` on dc2-router's AWS neighbors.

If you're building from scratch outside Workshop Studio, simply order each DC's transit VIF against its own DXGW from the start and this section doesn't apply.

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
