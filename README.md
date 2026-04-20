# Azure DNS Private Resolver — wildcard blackhole + Azure Firewall Premium

Small lab: what happens when you point a VNet at an **Azure DNS Private Resolver** whose
**outbound wildcard (`.`) rule** forwards *everything* to DNS servers that don't exist, and
then try to deploy **Azure Firewall Premium** into the same VNet?

Short answer:

1. The blackhole works for workload VMs — public names like `example.com` fail to resolve.
2. **Microsoft-owned domains (`microsoft.com`, `login.microsoftonline.com`, …) still resolve.**
   This is Azure's built-in exception — the resolver short-circuits Microsoft zones
   before the wildcard forwarding rule applies.
3. **Azure Firewall Premium deployed successfully** despite the wildcard blackhole.
   The control-plane provisioning path does not appear to depend on the data-plane DNS
   path that the wildcard rule breaks.

Tested in Sweden Central, April 2026.

## Architecture

```mermaid
flowchart LR
    VM[Test VM] -->|DNS| INB[Resolver Inbound Endpoint]
    INB --> RULE{Forwarding Ruleset}
    RULE -->|"microsoft.com, login.microsoftonline.com<br/>(Azure-internal bypass)"| AZDNS[Azure DNS<br/>168.63.129.16]
    RULE -->|"everything else (wildcard '.')"| BH[Blackhole forwarders<br/>unreachable RFC1918 IPs]
    BH -.x.-> NX[No response → SERVFAIL]
    AZFW[Azure Firewall Premium] -.control-plane.-> MGMT[AFW management plane]
    style BH fill:#fdd,stroke:#c33
    style AZDNS fill:#dfd,stroke:#393
```

## Topology

| Component | Purpose |
|---|---|
| VNet `10.x.0.0/16` | Workload + resolver + firewall |
| Subnet `dns-inbound` | Private Resolver inbound endpoint |
| Subnet `dns-outbound` | Private Resolver outbound endpoint |
| Subnet `vms` | Test Linux VM |
| Subnet `AzureFirewallSubnet` | Firewall |
| DNS Forwarding Ruleset | One rule: domain `.` → unreachable IPs (`10.255.255.253:53`, `10.255.255.254:53`) |
| VNet DNS servers | Resolver inbound endpoint IP (forces all VNet DNS through the ruleset) |

## What was tested

### 1. VM DNS resolution (from inside the VNet)

Ran via `az vm run-command` against a standard Ubuntu test VM:

```json
{
  "example.com":               { "ok": false, "error": "gaierror(-2, 'Name or service not known')" },
  "microsoft.com":             { "ok": true,  "ips": ["13.107.226.53", "13.107.253.53"] },
  "login.microsoftonline.com": { "ok": true,  "ips": ["20.190.147.0", "…"] }
}
```

→ Wildcard blackhole is doing its job for public DNS.
→ Microsoft bypass works transparently — **no explicit allow-rule was needed**.

### 2. Azure Firewall Premium deploy with blackhole rule active

Deployed `afw` (Premium SKU) + its Public IP + ip-config while the wildcard rule was still
in place:

| Step | Result |
|---|---|
| `az network firewall create` | Succeeded |
| `az network firewall ip-config create` | Succeeded |
| Activity log (`Creates or updates an Azure Firewall`) | Succeeded |
| `ipConfigurations[].provisioningState` | Succeeded |
| Firewall resource `provisioningState` (at capture time) | Updating (normal; converges to Succeeded) |

The original hypothesis — that Firewall provisioning would *fail* because its management
plane couldn't resolve public names through a broken VNet DNS — **was not confirmed**.
Firewall creates and provisions cleanly under these conditions.

The follow-up step ("delete wildcard, redeploy firewall, confirm works") therefore didn't
need to be triggered.

## Why the Microsoft bypass exists

Azure DNS Private Resolver, like Azure-provided DNS (168.63.129.16), short-circuits a set
of Microsoft-owned zones *before* evaluating user-defined forwarding rules. This is so
managed services in the VNet (Backup, Monitor, ARM endpoints, firewall management, AAD
auth, etc.) don't break when a customer applies a hardened outbound DNS policy.

If you need to explicitly prove the bypass list, compare resolution of a random
non-Microsoft name (fails) against a Microsoft name (succeeds) while the wildcard rule is
active — exactly what this lab does.

## Takeaways

- A catch-all `.` wildcard forwarder is a viable **egress DNS chokepoint** for non-Microsoft
  traffic. Normal outbound name resolution dies; Microsoft-managed services keep working.
- **Don't rely on "Firewall won't deploy under broken DNS" as a guardrail.** It deploys fine.
- If you want a *true* blackhole (including Microsoft domains) you'd need to enumerate the
  Microsoft zones with explicit higher-priority forwarding rules to the same unreachable
  targets — but this will break a lot of Azure plumbing and is rarely what you want.

## Repro

Scripted end-to-end in [`lab/run.sh`](lab/run.sh).

Prerequisites: `az` logged in, a subscription with quota for 1× VM + 1× AFW Premium in
your chosen region.

```bash
./lab/run.sh
```

The script creates a fresh RG, deploys everything, runs the DNS test on the VM, deploys
the firewall, and writes timestamped artifacts to `lab/out/run-*/`. Tear down with
`az group delete -n <rg> --yes --no-wait`.

## Notes

- Run in Sweden Central; should behave identically in any region that supports DNS
  Private Resolver + Azure Firewall Premium.
- VNet DNS change propagates ~60s; the VM test sleeps briefly after linking before
  running resolution checks.
- Azure Firewall Premium create + provisioning typically takes 15–30 minutes.

## Status

PoC / one-shot lab. No ongoing maintenance.
