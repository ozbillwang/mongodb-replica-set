# MongoDB three-node replica set

A Docker Compose lab for learning MongoDB replication, elections, and failover. It runs three data-bearing MongoDB 8.0 members by default in replica set `rs0` and initializes itself on the first start.

| Service | Default port | Election priority |
| --- | --- | --- |
| `mongo1` | 27017 | 1 |
| `mongo2` | 27018 | 0.5 |
| `mongo3` | 27019 | 0.5 |

`mongo1` is preferred as primary, but elections depend on member availability and replication progress. Always query the current primary before stopping it.

This is a **local development and learning lab**. Authentication and TLS are disabled, and published ports bind to `0.0.0.0` by default. Use a trusted private network and restrict access to these unauthenticated ports. All containers share one machine, so this demonstrates process failure rather than protection from host failure. Production deployments need authentication, TLS, backups, and separate failure domains.

## Start

Install Docker with Compose v2.20+ (or a newer major version). Bash is needed for the helper scripts; on Windows use WSL or Git Bash. No host MongoDB installation is needed for the container commands.

```sh
git clone https://github.com/ozbillwang/mongodb-replica-set.git
cd mongodb-replica-set
docker compose up -d --wait --wait-timeout 180
docker compose ps
./scripts/mongosh.sh --quiet --eval 'printjson(rs.status())'
```

Startup may take a minute, in addition to the first image download. The healthcheck on `mongo1` initializes the set only when MongoDB reports `NotYetInitialized` (code 94). Every member must reach PRIMARY or SECONDARY before it becomes healthy. Other errors are surfaced rather than interpreted as a reason to initialize again.

## Select the MongoDB version

All three services use `mongo:${MONGO_VERSION:-8.0}`. The default image tag is `8.0`; set `MONGO_VERSION` in `.env` to choose another supported MongoDB image tag:

```dotenv
MONGO_VERSION=8.0
```

For a fresh lab, start the selected version with:

```sh
docker compose pull
docker compose up -d --wait --wait-timeout 180
```

Use the same version for all members. The `8.0` tag follows patch releases within the 8.0 series; an exact patch tag can be used for reproducibility. Changing this setting does not migrate stored data or automatically change MongoDB's feature compatibility version (FCV).

For an **existing replica set**, back up first and follow the [official 7.0-to-8.0 replica-set upgrade procedure](https://www.mongodb.com/docs/manual/release-notes/8.0-upgrade-replica-set/): verify FCV 7.0, upgrade secondaries one at a time, step down and upgrade the old primary, then validate the set. Enable FCV 8.0 on the primary once ready to use 8.0 features:

```sh
./scripts/mongosh.sh --quiet --eval 'printjson(db.adminCommand({setFeatureCompatibilityVersion:"8.0", confirm:true}))'
```

Do not downgrade an existing data volume simply by selecting an older image. Local upgrade backups under `.mongodb-backups/` are excluded from Git.

## Connect

The replica set advertises the original host-based addresses:

```text
host.docker.internal:27017
host.docker.internal:27018
host.docker.internal:27019
```

Each MongoDB service maps `host.docker.internal` to `${MONGO_HOST_IP:-host-gateway}` using `extra_hosts`. The default `host-gateway` value points to the Docker host. Set `MONGO_HOST_IP` in `.env` to a reachable host IP if needed. Member traffic passes through the host's published ports, so the ports must be accessible through that address; binding only to loopback generally will not work with a native Linux host gateway.

Inside the MongoDB containers, use the helper or connect directly:

```sh
./scripts/mongosh.sh --quiet --eval 'printjson(db.hello())'
docker compose exec mongo1 mongosh 'mongodb://host.docker.internal:27017,host.docker.internal:27018,host.docker.internal:27019/qjp?replicaSet=rs0'
```

For an application running directly on the Docker host, ensure `host.docker.internal` resolves there. If necessary, add this to that host's `/etc/hosts` (on Windows, `C:\Windows\System32\drivers\etc\hosts`):

```text
127.0.0.1 host.docker.internal
```

For a client on another machine, map that name to the MongoDB host's reachable IP instead. A replica-aware client discovers these advertised addresses even if its initial URI uses IP seeds.

### Application container on another host

Containers do not inherit the host machine's `/etc/hosts`. In the **application's** `.env`, set the MongoDB host IP, for example:

```dotenv
MONGO_HOST_IP=10.0.1.107
```

In that application's existing Compose service, add:

```yaml
extra_hosts:
  - "host.docker.internal:${MONGO_HOST_IP:?Set MONGO_HOST_IP in .env}"
```

Use this application configuration:

```json
{
  "databaseURI": "mongodb://host.docker.internal:27017,host.docker.internal:27018,host.docker.internal:27019/qjp?replicaSet=rs0"
}
```

Replace the example IP and ports as needed, then recreate the application service with `docker compose up -d --force-recreate <app-service>`. Do not use `host-gateway` for an application on a different host: it would target that application's Docker host rather than the MongoDB host.

### Existing sets initialized with mongo1/mongo2/mongo3

Editing `rs.initiate()` affects only a fresh set. An existing set keeps its advertised names in the data volumes. To migrate without deleting data, back up first, apply the new Compose host mappings, and verify the host-published endpoints:

```sh
docker compose up -d --wait --wait-timeout 180
docker compose exec mongo1 mongosh 'mongodb://host.docker.internal:27017/?directConnection=true' --quiet --eval 'printjson(db.hello())'
```

Check all three endpoints from each MongoDB container before reconfiguring. Adjust the ports if customized. Then run this through the helper, which connects to the current primary:

```sh
./scripts/mongosh.sh --quiet --eval '
  const config = rs.conf();
  for (const member of config.members) {
    const match = /^(mongo[123]|host\.docker\.internal):([0-9]+)$/.exec(member.host);
    if (!match) throw new Error("Unexpected member address: " + member.host);
    member.host = "host.docker.internal:" + match[2];
  }
  printjson(rs.reconfig(config, {maxTimeMS: 60000}));
'
./scripts/mongosh.sh --quiet --eval 'printjson(rs.status().members.map(m => ({name:m.name,state:m.stateStr})))'
```

Reconfiguration can trigger an election and briefly interrupt connections. Do not use `force: true` or delete volumes for this change. Clients must resolve `host.docker.internal` before using the updated set.

## Connect through the host IP

For a direct connection from the Docker host itself, no hosts-file entry is needed:

```text
mongodb://127.0.0.1:27017/?directConnection=true
```

Choose **Authentication: None** in Compass. Port 27017 is `mongo1`; verify the current primary before writing:

```sh
./scripts/mongosh.sh --quiet --eval 'print(db.hello().primary)'
```

Match the primary address's port to the service table: 27018 is `mongo2` and 27019 is `mongo3` (or use your configured ports). A direct connection targets one member and does **not** automatically follow primary elections.

### From another computer on your LAN

Set `MONGO_BIND_IP` in `.env` to the Docker host's actual LAN IPv4 address. For example, if it is `192.168.1.50`:

```dotenv
MONGO_BIND_IP=192.168.1.50
```

Keep any existing port settings in `.env`. Apply the binding change without deleting data:

```sh
docker compose up -d --wait --wait-timeout 180
```

This recreates containers as needed and briefly interrupts connections. On the other computer, connect to the selected member using the host's IP:

```text
mongodb://192.168.1.50:27017/?directConnection=true
```

Replace the example IP with your host's LAN IP. The chosen interface must exist on the Docker host. This exposes an **unauthenticated** database on that interface; use only a trusted private network, restrict access with your firewall, and do not forward these ports from the internet.

For **automatic failover**, the client must also resolve the member names returned by MongoDB. Add `HOST_LAN_IP host.docker.internal` (using the real IP) to the **client's** hosts file, then use the three-member URI in the Connect section without `directConnection=true`. Supplying three IP seeds alone does not change the advertised names.

## Experiment with failover

1. Find the current primary:

   ```sh
   ./scripts/mongosh.sh --quiet --eval 'print(db.hello().primary)'
   ```

2. Match the returned port to the service table and stop that service (27017 is `mongo1`, 27018 is `mongo2`, and 27019 is `mongo3` by default):

   ```sh
   docker compose stop mongo1
   ```

3. Wait for an election, then query through a surviving member:

   ```sh
   ./scripts/mongosh.sh --quiet --eval 'printjson(rs.status().members.map(m => ({name:m.name,state:m.stateStr})))'
   ```

4. Restore all members:

   ```sh
   docker compose up -d --wait --wait-timeout 180
   ```

There is a brief write interruption during an election. Two out of three voting members must be available to maintain a primary and acknowledge majority writes. Stopping a secondary leaves the set available; stopping two members prevents it from sustaining a primary. A restarted `mongo1` may eventually take over again because of its higher priority.

### Automated failover test

Run this only against the lab: it writes test documents to `replica_set_lab.checks`, stops the actual primary, verifies a replacement accepts majority writes, restarts the stopped member, and checks both documents on all three members.

```sh
./scripts/smoke-test.sh
```

The test leaves containers running and retains its test documents. GitHub Actions runs the same test in a disposable environment and removes its volumes afterward.

## Persistent storage and cleanup

Each member has named data and config volumes. Restarting containers or taking the stack down preserves them:

```sh
docker compose stop
docker compose start --wait
docker compose down
```

To **delete this Compose project's data** and start fresh:

```sh
docker compose down --volumes
docker compose up -d --wait --wait-timeout 180
```

## Port conflicts and troubleshooting

- If ports 27017–27019 are occupied, copy `.env.example` to `.env` **before the first start** and choose three unused ports. The advertised, container, and published ports change together. Update your client URI to match.
- Replica-set configuration persists in the data volumes. Changing ports after initialization requires a deliberate `rs.reconfig()` migration or deleting this lab's volumes if its data is disposable. The healthcheck does not rewrite an existing set.
- Check `docker compose ps`, `docker compose logs --tail 100`, and `docker compose config` if startup fails. All three services must be started together for initial setup.
- If a host client connects to a seed but times out during discovery, check that `host.docker.internal` resolves to the MongoDB host inside the client environment. Application containers need their own `extra_hosts` mapping; they do not inherit the host's hosts file.
- A healthy secondary alone does not mean the set has a writable primary; query `db.hello()` or `rs.status()` to inspect the topology.

For example, an isolated test alongside another MongoDB installation on macOS/Linux:

```sh
export COMPOSE_PROJECT_NAME=mongodb-rs-lab
export MONGO1_PORT=37017 MONGO2_PORT=37018 MONGO3_PORT=37019
./scripts/smoke-test.sh
# Removes ONLY this test project's containers and volumes:
docker compose down --volumes
```

Keep the same project name and port settings for all commands targeting that stack.

## References

- [MongoDB: three-member replica sets](https://www.mongodb.com/docs/manual/core/replica-set-architecture-three-members/)
- [MongoDB: replica-set elections](https://www.mongodb.com/docs/manual/core/replica-set-elections/)
- [MongoDB: member hostnames and priority](https://www.mongodb.com/docs/manual/reference/replica-configuration/)
- [Docker: networking in Compose](https://docs.docker.com/compose/how-tos/networking/)
- [Docker: published ports on Docker Desktop](https://docs.docker.com/desktop/features/networking/)
