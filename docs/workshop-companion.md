# Workshop companion — follow along with section 04

Use this guide **while** working through [04 — Provision dual-stack Direct Connect](https://catalog.us-east-1.prod.workshops.aws/workshops/3d335f4f-0f81-42c0-b093-8ae623511e12/en-US/04-provision-dx). You don't complete the workshop first and then rework it — instead, at each workshop step, do the step **with the changes highlighted below**, and you end up at the 2× DXGW + 2× VPN topology directly.

Only the deltas are listed. Anything not mentioned: do exactly as the workshop says.

---

## 04-01 · Create Direct Connect gateway

**Workshop:** create one DXGW `dxgw` with Amazon-side ASN **65000**.

**Change: create two DXGWs, one per DC, each with its own ASN.**

```bash
aws directconnect create-direct-connect-gateway \
  --direct-connect-gateway-name dxgw1 --amazon-side-asn 65001
aws directconnect create-direct-connect-gateway \
  --direct-connect-gateway-name dxgw2 --amazon-side-asn 65002
```

> DXGWs are global resources, but the CLI calls must run in a region — keep it consistent with where your DX connections live.

## 04-02 · Create transit virtual interfaces

**Workshop:** create the DC1 and DC2 transit VIFs, both pointing at the single `dxgw`.

**Change: point each VIF at its own gateway** — DC1's VIF → `dxgw1`, DC2's VIF → `dxgw2`. Everything else (VLAN, ASN 65101/65102, BGP addresses, auth keys) stays exactly as written.

> ⚠️ A transit VIF is bound to its DXGW at creation and **cannot be moved later** — if you attach both to one gateway here, fixing it means deleting and re-ordering a VIF (each workshop DX connection allows only 1 VIF, and the deletion takes ~3 minutes before you can recreate). Getting this step right avoids `scripts/split-dxgw.sh` entirely.

## 04-03 · Add IPv6 peering to virtual interfaces

**No change.** Follow as-is (IPv6 peers are auto-assigned per VIF regardless of which DXGW it belongs to).

## 04-04 · Attach Direct Connect gateway to Cloud WAN

**Workshop:** create one `DIRECT_CONNECT_GATEWAY` attachment for `dxgw`.

**Change: create two attachments, one per DXGW**, both tagged `segment=onprem`:

```bash
for GW_ARN in <dxgw1-arn> <dxgw2-arn>; do
  aws networkmanager create-direct-connect-gateway-attachment \
    --core-network-id <core-id> \
    --direct-connect-gateway-arn "$GW_ARN" \
    --edge-locations us-west-2 ap-southeast-2 \
    --tags Key=segment,Value=onprem
done
```

DXGW ARN format: `arn:aws:directconnect::<account-id>:dx-gateway/<dxgw-id>`.

## 04-05 · On-premises router primer

**No change.** (Worth reading — the VTI/BGP concepts are reused by the VPN config below.)

## 04-06 · Configure on-premises routers

**Workshop:** configure eth3 subinterfaces and BGP neighbors with `remote-as 65000` on both routers.

**Change: the remote AS differs per DC** — dc1-router peers with dxgw1, dc2-router with dxgw2:

- dc1-router: `set protocols bgp 65101 neighbor <amazon-v4/v6> remote-as 65001`
- dc2-router: `set protocols bgp 65102 neighbor <amazon-v4/v6> remote-as 65002`

Everything else (addresses, passwords/auth keys, prefix-lists) as written.

## 04-07 · Verify connectivity

**Workshop:** verify BGP up and routes received.

**Change: the AS-paths now differ per DC** — that's the visible proof of the split. From dc2-router, `10.1.0.0/16` should look like:

```
65002 64513 65001 65101   (in via dxgw2 → core network → out via dxgw1)
```

instead of the workshop's `65000 64513 65000 65101` (same gateway both ways).

---

## 04-08 (extension) · Add Site-to-Site VPN per DC

New step, not in the workshop. After 04-07 passes, add the VPN paths:

```bash
./deploy.sh          # both DCs: CGW + standalone VPN + Cloud WAN attachment + rendered VyOS config
```

Then paste `out/dc1-vyos.conf` / `out/dc2-vyos.conf` into the routers (SSM → onprem host → router menu). Wait ~1 minute and verify each router now shows **4 BGP sessions**: 1 DX + 2 VPN tunnels + the DCI peer.

Expected route view from dc2-router afterwards:

```
10.1.0.0/16    64512 65101              ← via VPN (direct to core edge)
               65002 64513 65001 65101  ← via DX (two DXGW hops)
               65101                    ← best: DCI link
172.21.x.0/24  64512                    ← VPN wins on the router (shorter AS-path)
               65002 64512              ← DX
```

Note the asymmetry: **routers prefer VPN** (shorter AS-path — DXGW adds a hop), while **Cloud WAN prefers DX** for return traffic (attachment-type preference). This is the starting point for the [routing-policy tests](routing-tests.md).

## If you already completed section 04 as written

Use `scripts/split-dxgw.sh <dx-region> --execute` to retrofit the per-DC DXGW split (it re-creates DC2's VIF on a new DXGW2 — verified on a live event, ~10 minutes including BGP re-establishment), then run `./deploy.sh` for the VPNs.
