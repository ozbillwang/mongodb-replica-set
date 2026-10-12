# MongoDB three-node replica set

A Docker Compose lab for learning MongoDB replication, elections, and failover. It runs three data-bearing MongoDB 7.0 members in replica set `rs0` and initializes itself on the first start.

| Service | Default port | Election priority |
| --- | --- | --- |
| `mongo1` | 27017 | 1 |
| `mongo2` | 27018 | 0.5 |
| `mongo3` | 27019 | 0.5 |

`mongo1` is preferred as primary, but elections depend on member availability and replication progress. Always query the current primary before stopping it.

This is a **local development and learning lab**. Authentication and TLS are disabled, and published ports bind to `127.0.0.1`. All containers share one machine, so this demonstrates process failure rather than protection from host failure. Production deployments need authentication, TLS, backups, and separate failure domains.

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

## Connect

Inside the Compose network, Docker resolves service names automatically. The helper selects a running container and connects using normal replica-set discovery, so it also works while `mongo1` is stopped:

```sh
./scripts/mongosh.sh --quiet --eval 'printjson(db.hello())'
```

For an interactive shell while `mongo1` is running:

```sh
docker compose exec mongo1 mongosh 'mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0'
```

For an application on your **host computer**, first add this line to its hosts file with administrator privileges:

```text
127.0.0.1 mongo1 mongo2 mongo3
```

The file is `/etc/hosts` on macOS and Linux, or `C:\Windows\System32\drivers\etc\hosts` on Windows. Edit the file in the environment where your client runs (Windows and WSL may have separate files).

Then use this URI in `mongosh`, MongoDB Compass, or your application:

```text
mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0
```

A replica-aware client learns member addresses from MongoDB after contacting a seed. Those advertised names must resolve from the client as well as from the containers. Using `127.0.0.1` for the seeds alone does not remove that requirement. `directConnection=true` is useful for inspecting an individual member, but does not provide automatic failover.

This repo uses Docker service DNS for member-to-member traffic instead of routing it through `host.docker.internal` and host-published ports. No host-gateway override is required. Do not map `host.docker.internal` to the example address `127.17.0.1`: loopback addresses refer to the current network namespace, and Docker gateway addresses vary by environment.

## Experiment with failover

1. Find the current primary:

   ```sh
   ./scripts/mongosh.sh --quiet --eval 'print(db.hello().primary)'
   ```

2. Stop that service (replace `mongo1` if another service is primary):

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
- If a host client connects to a seed but times out during discovery, check the hosts-file entries for all three service names. Containers use Docker DNS and do not need those host entries.
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
