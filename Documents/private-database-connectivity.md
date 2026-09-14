# Private database connectivity

Follow-up to the item flagged in [`Documents/azure-architecture.md`](../Documents/azure-architecture.md):
"Before going to production, must address: private networking for Postgres."
The dev PostgreSQL Flexible Server previously had a public endpoint, open to
every IP (`0.0.0.0`-`255.255.255.255`) via a firewall rule. It's now
VNet-integrated with no public endpoint at all.

Terraform: `infra/azure/modules/networking/` (new), plus updates to
`infra/azure/modules/postgresql/`, `infra/azure/modules/container_apps_environment/`,
and `infra/azure/environments/dev/main.tf`.

## At a glance: every networking change

| Resource | Before | After |
|---|---|---|
| VNet | none | `vnet-novacart-dev` (`10.0.0.0/16`) — new |
| Container Apps subnet | none | `snet-novacart-dev-container-apps` (`10.0.0.0/23`), delegated to `Microsoft.App/environments` — new |
| Postgres subnet | none | `snet-novacart-dev-postgres` (`10.0.2.0/28`), delegated to `Microsoft.DBforPostgreSQL/flexibleServers` — new |
| Private DNS zone | none | `privatelink.postgres.database.azure.com` — new |
| DNS zone ↔ VNet link | none | `vnl-novacart-dev-postgres` links the zone above to the VNet — new |
| Container Apps Environment | no VNet integration (`infrastructure_subnet_id` unset) | `infrastructure_subnet_id = snet-novacart-dev-container-apps` — **updated in-place** |
| Postgres `public_network_access_enabled` | `true` | explicitly `false` (required once `delegated_subnet_id` is set) — **forces replacement** |
| Postgres `delegated_subnet_id` | unset | `snet-novacart-dev-postgres` — **forces replacement** |
| Postgres `private_dns_zone_id` | unset | `privatelink.postgres.database.azure.com` zone ID — **forces replacement** |
| Postgres firewall rules | 1 rule, `AllowAllPublicDev` (`0.0.0.0`–`255.255.255.255`) | 0 rules (`allowed_cidr_ranges` defaults to `[]`; also rejected by the API on a private server anyway) |
| Frontend/backend Container Apps | reachable only via public internet + Container Apps Environment's own routing | now also have a private address in `snet-novacart-dev-container-apps`, routed to the Postgres subnet over the shared VNet |
| Postgres reachability | any public IP, over the internet | only from inside the VNet (currently: the Container Apps subnet) |

Net effect: 5 new networking resources, 1 in-place update (Container Apps
Environment), and Postgres forced to replace (new server, same name/config
otherwise) because `delegated_subnet_id`/`private_dns_zone_id` can only be
set at creation time.

## How PostgreSQL connectivity changed

| | Before | After |
|---|---|---|
| Endpoint | Public FQDN, internet-routable | Same FQDN, but resolves to a private IP only inside the VNet |
| Access control | Firewall rule allowing all public IPs | No firewall rules (Flexible Server rejects them once VNet-integrated) — access is controlled by network topology, not an IP allowlist |
| `public_network_access_enabled` | `true` | explicitly `false` (required once `delegated_subnet_id` is set — see `modules/postgresql/main.tf`) |
| Reachable from | Anywhere | Only from `module.networking`'s VNet (currently: the Container Apps Environment's subnet) |

The connection string (`DATABASE_URL`, built in `environments/dev/main.tf` locals)
is unchanged in shape — same FQDN, same `sslmode=require` — because the
Flexible Server's hostname doesn't change with this migration. What changed
is *who can resolve and route to it*.

## Azure networking resources introduced

All in the new `infra/azure/modules/networking` module, one VNet shared by
both subnets so traffic between them is routed by Azure automatically (no
peering/gateway needed):

- **`azurerm_virtual_network`** (`vnet-novacart-dev`, `10.0.0.0/16`)
- **`azurerm_subnet`** `snet-novacart-dev-container-apps` (`10.0.0.0/23`) —
  delegated to `Microsoft.App/environments`. The Container Apps Environment
  VNet-integrates into this subnet.
- **`azurerm_subnet`** `snet-novacart-dev-postgres` (`10.0.2.0/28`, Azure's
  minimum size for this) — delegated to
  `Microsoft.DBforPostgreSQL/flexibleServers`. The Postgres Flexible Server
  is created inside this subnet instead of behind a public endpoint.
- **`azurerm_private_dns_zone`** `privatelink.postgres.database.azure.com`
  (name-resolution, see below).
- **`azurerm_private_dns_zone_virtual_network_link`** linking that zone to
  the VNet.

## How application compute reaches PostgreSQL

`azurerm_container_app_environment.infrastructure_subnet_id` now points at
`snet-novacart-dev-container-apps`. That gives every Container App in the
environment — frontend and backend alike — a private address inside the
same VNet as the Postgres subnet. Because both subnets belong to one VNet,
Azure routes traffic between them privately with no extra hop.

This is VNet integration, not an internal load balancer: each Container
App's own `external_ingress` setting is untouched, so the frontend still
gets a public FQDN and the backend stays internal-only (per
`Documents/azure-architecture.md`'s request flow). Only the *backend*
actually talks to Postgres, and it now does so entirely inside the VNet.

## Name resolution

Postgres Flexible Server's VNet-integration mode requires a private DNS
zone whose name ends in `.postgres.database.azure.com`
(`privatelink.postgres.database.azure.com` here, Microsoft's own recommended
value) linked to the VNet. The server registers an A record for its FQDN in
that zone, pointing at its private IP — there is no public DNS record for
it anymore. Only clients that can both resolve the private zone (i.e. are
in, or linked to, the VNet) and route to the subnet can find the server.

Terraform ordering note: the DNS zone must be linked to the VNet *before*
the server is created, or server creation fails looking up the link. That
dependency isn't visible from resource ID references alone (the link is a
sibling resource, not something `private_dns_zone_id` points at), so
`module.postgresql` carries an explicit `depends_on = [module.networking]`
in `environments/dev/main.tf`.

## What changed in the app-to-database path

```
Before: backend Container App --(public internet, TLS)--> Postgres public endpoint (firewall: allow all)
After:  backend Container App --(private VNet routing, TLS)--> Postgres private endpoint (no public endpoint exists)
```

The backend's `DATABASE_URL` still uses the server's FQDN and
`sslmode=require` — TLS is unchanged and still enforced. What's gone is the
public path: there is no longer an IP-based firewall allowlist standing
between "the internet" and the database, because there is no longer a
route from the internet to the database at all.

## Verifying the database is no longer public

After `terraform apply`:

```bash
# 1. Azure's own view of the server's network config: should show
#    publicNetworkAccess: Disabled and a delegatedSubnetResourceId set.
az postgres flexible-server show \
  --resource-group rg-novacart-dev \
  --name <server-name-from-terraform-output-postgres_server_fqdn> \
  --query "{publicNetworkAccess: network.publicNetworkAccess, subnet: network.delegatedSubnetResourceId}"

# 2. Attempt a connection from outside the VNet (e.g. your own machine).
#    Expect a connection timeout, not an auth failure -- a timeout means
#    there's no route/listener reachable from the public internet at all.
psql "host=<postgres_server_fqdn output> port=5432 dbname=novacart sslmode=require" -c "select 1"
# expected: timeout (not "password authentication failed", which would mean
# it's still reachable and only credentials were wrong)

# 3. Confirm there's no public DNS record for it (NXDOMAIN or no A record):
dig +short <postgres_server_fqdn output>

# 4. Confirm the private DNS zone does have the A record, privately:
az network private-dns record-set a list \
  --resource-group rg-novacart-dev \
  --zone-name privatelink.postgres.database.azure.com
```

A public timeout (step 2) plus a populated private A record (step 4) is the
combination that confirms the server is private, not just "port closed" —
the record still exists, it's just no longer publicly resolvable or
routable.

## Verifying the application still works

After `terraform apply`, from a machine that *can* reach the internet (the
frontend is still public):

```bash
# 1. Frontend is still publicly reachable.
curl -sS -o /dev/null -w "%{http_code}\n" "https://$(terraform output -raw frontend_fqdn)/"
# expected: 200

# 2. Exercise a path that round-trips through the backend to Postgres
#    (adjust to an actual API route, e.g. a list/read endpoint).
curl -sS "https://$(terraform output -raw frontend_fqdn)/api/<some-read-endpoint>"
# expected: normal JSON response, not a 502/504 (which would indicate the
# backend can't reach the database over the VNet)

# 3. Check the backend's own logs in Log Analytics for DB connection
#    errors around the time of the apply/verification:
az monitor log-analytics query \
  --workspace <log_analytics_workspace_id output, customer ID form> \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'ca-novacart-dev-backend' | where TimeGenerated > ago(15m) | order by TimeGenerated desc" \
  --output table

# 4. Confirm the backend Container App's readiness probe (/ready, per
#    Documents/azure-architecture.md) is passing -- it would fail if the
#    app can't reach Postgres at startup:
az containerapp revision list \
  --resource-group rg-novacart-dev \
  --name ca-novacart-dev-backend \
  --query "[].{revision:name, active:properties.active, healthState:properties.healthState}"
```

A 200 from the frontend plus a successful DB-backed API response confirms
the backend is reaching Postgres over the private path end-to-end, not just
that the container started.

## Operational note: this is a destructive change on an existing environment

`delegated_subnet_id` on `azurerm_postgresql_flexible_server` and
`infrastructure_subnet_id` on `azurerm_container_app_environment` can only
be set at creation time — Azure doesn't support adding VNet integration to
an existing server or environment in place. Applying this against an
already-deployed `dev` environment **replaces** (destroys + recreates) the
Postgres Flexible Server (data loss on whatever's in it) and the Container
Apps Environment (which cascades to replacing both Container Apps, and
issues the frontend a new FQDN). Run `terraform plan` first and expect to
see those replacements; this is normal for this specific change, not a
sign something's wrong. For a dev database worth keeping, take a manual
backup/export before applying.
