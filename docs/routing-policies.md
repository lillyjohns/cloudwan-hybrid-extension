# Cloud WAN Routing Policies — selective prefix filtering (tested live)

Goal: prove **attachment routing policies** can (a) selectively allow only
specific prefixes outbound to a DC, and (b) accept a `/32` exception inbound
while dropping everything else not on the list — the "selective allow prefix
list out, advertise /32 in" pattern used for production cross-connects
(DX + VPN backup).

Tested live on this workshop environment, 2026-07-27. Working policy:
[`policies/routing-policy-selective-dc1.json`](../policies/routing-policy-selective-dc1.json).
The original production-style policy document (BNA/MTG DX+VPN, summarize +
communities + AS-prepend) is kept for reference as
[`policies/xconnect-routing-policies-original.json`](../policies/xconnect-routing-policies-original.json)
— it needs the schema fixes below before it will validate.

## Schema gotchas (found via live validator)

1. **Policy version must be `2025.11`.** Advanced routing is rejected on
   `2021.12`: `ADVANCED_ROUTING_UNSUPPORTED_VERSION_2021_12`. Valid enum
   values are `[2021.12, 2025.11]`; the rest of the policy document (segments,
   attachment-policies, segment-actions) is unchanged by the version bump.
2. **No hyphens in names.** `routing-policy-name`, `routing-policy-label`
   values must match `[A-Za-z][A-Za-z0-9]*` (< 64 chars). `BNA-THDX-Outbound`
   → `BNATHDXOutbound`.
3. **There is no top-level `prefix-lists` key** (`ADDITIONAL_PROPERTIES`
   error; also rejected when nested under a routing policy). Inline the
   prefixes instead, as multiple `match-conditions` with
   `"condition-logic": "or"`:
   - `prefix-equals` — exact prefix match (use for `/32` exceptions)
   - `prefix-in-cidr` — prefix contained in CIDR (use for summaries)
4. **Non-terminal actions before terminal actions** (as the original file's
   notes say): `set-local-preference` / `add-community` / `prepend-asn-list` /
   `summarize` rules must have lower rule numbers than the `allow`/`drop`
   that matches the same prefixes.
5. **Catch-all drop**: final rule `prefix-in-cidr 0.0.0.0/0` + `drop` gives
   the implicit-deny behavior.

## Apply flow (CLI)

```bash
CORE=core-network-0f1c1de8f20aab19c   # yours will differ (scripts/discover.sh)
R=us-west-2

# 1. Put the policy (returns a new version id)
aws networkmanager put-core-network-policy --region $R \
  --core-network-id $CORE \
  --policy-document file://policies/routing-policy-selective-dc1.json \
  --cli-error-format json          # <- shows per-path validation errors

# 2. Wait for READY_TO_EXECUTE, then execute
aws networkmanager list-core-network-policy-versions --region $R \
  --core-network-id $CORE \
  --query 'CoreNetworkPolicyVersions[?PolicyVersionId==`<VER>`].ChangeSetState'
aws networkmanager execute-core-network-change-set --region $R \
  --core-network-id $CORE --policy-version-id <VER>
# NOTE: fails with "Cannot execute change-set while attachments are being
# created" — wait for any in-flight attachments first. If the change set goes
# OUT_OF_DATE while blocked, re-put the policy to get a fresh version.

# 3. Label the attachment (this is what binds policies to it)
aws networkmanager put-attachment-routing-policy-label --region $R \
  --core-network-id $CORE \
  --attachment-id <DX-or-VPN-attachment-id> \
  --routing-policy-label DC1DX

# 4. Watch the association go pending -> active (~1 min)
aws networkmanager list-attachment-routing-policy-associations --region $R \
  --core-network-id $CORE
```

The policy's `attachment-routing-policy-rules` match on the label and
associate the inbound/outbound policies:

```json
{
  "rule-number": 200,
  "conditions": [{ "type": "routing-policy-label", "value": "DC1DX" }],
  "action": { "associate-routing-policies": ["DC1DXOutbound", "DC1DXInbound"] }
}
```

## What the test policy does

Applied to **DC1's DX attachment** only (VPN attachments left unfiltered as
control):

- **Outbound (core → DC1):** allow only `172.21.0.0/24` + `10.2.0.0/16`,
  drop the rest (`prefix-in-cidr 0.0.0.0/0` catch-all).
- **Inbound (DC1 → core):** allow `10.1.255.1/32` (exception, with
  `set-local-preference 1000` before the allow), allow `prefix-in-cidr
  10.1.0.0/16` (the DC summary), drop everything else.

## Verified results

On `dc1-router`, routes received from the DX peer dropped from 7 to exactly
the allowed 2:

```
show ip bgp neighbors 169.254.96.33 routes
*  10.2.0.0/16      169.254.96.33   0 65000 64513 65002 65102 i
*  172.21.0.0/24    169.254.96.33   0 65000 64512 i
```

Then `dc1-router` advertised two extra prefixes — one on the exception list,
one not:

```
set protocols bgp 65101 address-family ipv4-unicast network 10.1.255.1/32
set protocols bgp 65101 address-family ipv4-unicast network 192.168.99.0/24
set policy prefix-list DC1-OUT rule 20 { action permit; prefix 10.1.255.1/32 }
set policy prefix-list DC1-OUT rule 30 { action permit; prefix 192.168.99.0/24 }
```

Core network onprem segment route table (`get-network-routes`):

- `10.1.255.1/32` → arrives via the **DX attachment** ✅ (exception allowed)
- `192.168.99.0/24` → **dropped at DX**; present only via the unfiltered VPN
  attachment — proving the inbound filter acted on DX specifically ✅

## Notes

- Routing policy state is *outside* the policy document's segment logic —
  labels survive policy re-puts, but a new policy version must still define
  the matching `attachment-routing-policy-rules` + `routing-policies`.
- `remove-attachment-routing-policy-label` detaches the policies from an
  attachment.
- Filtering happens on the Cloud WAN side: the router still *sends* the
  denied prefix; it just never enters the core network's RIB via that
  attachment.
