# Routing policy test matrix — 2× DX + 2× VPN on Cloud WAN

Topology after applying this extension: each DC has a **DX path** (via DX gateway attachment) and a **VPN path** (via S2S VPN attachment) into the `onprem` segment.

## How Cloud WAN picks a path

For equal prefixes learned from multiple attachments in the same segment, the core network route table prefers, in order:

1. Longest prefix match
2. Static routes over dynamic
3. **Direct Connect gateway attachments over VPN** (more preferred attachment type)
4. Shorter AS-path

So the **baseline is: DX wins, VPN is standby** — which is exactly what you want to test against.

## Test 1 — Baseline verification

```bash
aws networkmanager get-network-routes \
  --global-network-id <gn-id> \
  --route-table-identifier '{"coreNetworkSegmentEdge":{"coreNetworkId":"<core-id>","segmentName":"onprem","edgeLocation":"us-west-2"}}' \
  --query 'NetworkRoutes[].{Prefix:DestinationCidrBlock,Type:Destinations[0].ResourceType,Att:Destinations[0].CoreNetworkAttachmentId}'
```

Expect `10.1.0.0/16` / `10.2.0.0/16` to point at the **DIRECT_CONNECT_GATEWAY** attachment while VPN attachments hold no best routes.

On VyOS, confirm both sessions advertise the same prefix:

```
show ip bgp neighbors 169.254.96.33 advertised-routes    # DX session
show ip bgp neighbors 169.254.101.1 advertised-routes    # VPN session
```

## Test 2 — DX failure → VPN failover

On dc1-router:

```
configure
set protocols bgp 65101 neighbor 169.254.96.33 shutdown
set protocols bgp 65101 neighbor 2600:1ffd:1108:140:0:7:afd2:141 shutdown
commit
```

Within ~30-60 s re-run `get-network-routes`: `10.1.0.0/16` should now resolve via the **SITE_TO_SITE_VPN** attachment. Verify end-to-end with a ping from a workload VPC instance to `10.1.0.x`.

Rollback: `delete protocols bgp 65101 neighbor 169.254.96.33 shutdown` (and the v6 neighbor), commit.

## Test 3 — Prefer VPN by AS-path prepend on DX

Instead of shutting DX down, make it less attractive:

```
configure
set policy route-map DX-PREPEND rule 10 action permit
set policy route-map DX-PREPEND rule 10 set as-path-prepend '65101 65101 65101'
set protocols bgp 65101 neighbor 169.254.96.33 address-family ipv4-unicast route-map export DX-PREPEND
commit
```

> Note: attachment-type preference (DX > VPN) is evaluated before AS-path, so prepending alone may **not** shift traffic — this test demonstrates exactly that ordering. Document the observed behavior; it's the most common Cloud WAN misconception.

## Test 4 — Segment isolation via policy document

Apply `policies/isolate-onprem-from-nonprod.json`:

```bash
aws networkmanager put-core-network-policy \
  --core-network-id <core-id> \
  --policy-document file://policies/isolate-onprem-from-nonprod.json

# review the change set, then:
aws networkmanager execute-core-network-change-set \
  --core-network-id <core-id> --policy-version-id <new-version>
```

Expect: nonprod VPC instances lose reachability to `10.x.0.0/16` while prod keeps it. Restore with `policies/baseline-policy.json`.

## Test 5 — Static route override

Add a static route in the core network policy (`segments[].name=onprem` → `segment-actions` with `create-route`) pointing a test prefix at the VPN attachment, and confirm static beats BGP-learned.

## Cleanup

Delete in this order: VPN attachments → VPN connections → CGWs (CFN stack delete handles it). DX side belongs to the base workshop.
