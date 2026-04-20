# Results — April 2026 run, Sweden Central

Raw sanitized excerpts from a real lab execution. Resource names, subscription IDs,
and tenant-specific identifiers have been removed.

## VM DNS resolution (from inside the VNet, VNet DNS pointed at resolver inbound)

```json
{
  "tests": {
    "example.com": {
      "ok": false,
      "error": "gaierror(-2, 'Name or service not known')"
    },
    "microsoft.com": {
      "ok": true,
      "ips": ["13.107.226.53", "13.107.253.53"]
    },
    "login.microsoftonline.com": {
      "ok": true,
      "ips": [
        "20.190.147.0", "20.190.147.4", "20.190.147.5", "20.190.147.6",
        "20.190.147.8", "20.190.177.146", "20.190.177.149", "20.190.177.21"
      ]
    }
  }
}
```

`resolv.conf` on the test VM resolves via `127.0.0.53` (systemd-resolved stub), whose
uplink is the VNet DNS server — i.e. the resolver inbound endpoint.

## Wildcard forwarding rule (sanitized)

```json
{
  "name": "wildcard-root",
  "domainName": ".",
  "forwardingRuleState": "Enabled",
  "provisioningState": "Succeeded",
  "targetDnsServers": [
    { "ipAddress": "10.255.255.253", "port": 53 },
    { "ipAddress": "10.255.255.254", "port": 53 }
  ]
}
```

Targets are RFC1918 addresses that are not routed anywhere in the VNet — so all DNS
queries forwarded here time out.

## Azure Firewall Premium provisioning (wildcard rule active)

| Step | Outcome |
|---|---|
| `az network firewall create --sku AZFW_VNet --tier Premium` | Succeeded |
| `az network firewall ip-config create` | Succeeded |
| Activity log: `Creates or updates an Azure Firewall` | Succeeded |
| `ipConfigurations[0].provisioningState` | Succeeded |
| Firewall `provisioningState` at capture time | Updating (converges) |

Relevant portion of `az network firewall show`:

```json
{
  "provisioningState": "Updating",
  "sku": { "name": "AZFW_VNet", "tier": "Premium" },
  "ipConfigurations": [
    {
      "name": "fwconfig",
      "provisioningState": "Succeeded",
      "publicIPAddress": { "id": "…/publicIPAddresses/pip-afw" },
      "subnet": { "id": "…/virtualNetworks/vnet/subnets/AzureFirewallSubnet" }
    }
  ]
}
```

## Conclusion

- **Data-plane DNS is broken for public names** (as intended).
- **Microsoft-owned domains still resolve** via the resolver's implicit bypass list.
- **Azure Firewall Premium control-plane deploy is unaffected** by the broken
  workload DNS path — its provisioning relies on platform-internal mechanisms, not
  VM-visible DNS.
