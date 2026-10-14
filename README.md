# MongoDB three-node replica set

A Docker Compose lab with three MongoDB 8.0.17 members in replica set `rs0`. The first start initializes the set automatically. All three containers run on one Docker host, so this lab demonstrates member failover, not host failover.

| Service | Port | Election priority |
| --- | ---: | ---: |
| `mongo1` | 27017 | 1 |
| `mongo2` | 27018 | 0.5 |
| `mongo3` | 27019 | 0.5 |

The higher priority makes `mongo1` the preferred primary, but another member can become primary during an election. Always query the set to see which member is primary now.

## Start

Install Docker with Compose. Copy the example environment file and set `MONGO_HOST_IP` to the **MongoDB Docker host's actual IP**. That address must be reachable from all three MongoDB containers and from your application host. `10.0.1.1` in the example is a placeholder.

```sh
cp .env.example .env
# Edit .env: MONGO_HOST_IP=<MongoDB host IP>
docker compose config --quiet
docker compose up -d --wait --wait-timeout 180
./scripts/mongosh.sh --quiet --eval 'printjson(rs.status().members.map(m => ({name:m.name,state:m.stateStr})))'
```

The three containers use `restart: unless-stopped`, so Docker starts them again after the Docker service starts on reboot. After updating an existing deployment, run `docker compose up -d` once to apply the policy. Containers you explicitly stop or remove remain stopped.

The Compose file publishes ports 27017–27019 on all host interfaces. Its initialization healthcheck advertises `${MONGO_HOST_IP}:27017`, `${MONGO_HOST_IP}:27018`, and `${MONGO_HOST_IP}:27019` to clients. MongoDB 8 normally rejects IP addresses as replica-set member names; the Compose commands include `disableSplitHorizonIPCheck=true` for this local lab. No `host.docker.internal` mapping is used.

The three services have fixed ports and a fixed `mongo:8.0.17` image. Changing `.env` alone does not change those values.

## Connect from the application

Use the Docker host's IP in the application connection string. For a database named `qjp`:

```json
{
  "databaseURI": "mongodb://10.0.1.1:27017,10.0.1.1:27018,10.0.1.1:27019/qjp?replicaSet=rs0"
}
```

Replace **every** `10.0.1.1` with the real `MONGO_HOST_IP`. The database `qjp` appears after the first write; no separate initialization step is needed. The lab has no username or password. If your application can tolerate temporarily stale reads when the primary is unavailable, you can append `&readPreference=primaryPreferred` to the URI.

The MongoDB driver contacts one of the listed ports, then discovers the member addresses stored in the replica set. Check those addresses with:

```sh
./scripts/mongosh.sh --quiet --eval 'printjson(rs.conf().members.map(m => m.host))'
```

They should all show your chosen host IP and the three ports. If they show an old IP or hostname, changing `.env` does **not** update an already initialized set: its configuration is stored in the data volumes.

## Test failover

Run the smoke test from this repository on the MongoDB Docker host:

```sh
./scripts/smoke-test.sh
```

It writes test records with majority write concern to `replica_set_lab.checks`, stops whichever member is currently primary, waits for a new primary, writes again, restarts the stopped member, and verifies both records on all three members. It leaves the lab running and keeps its test records. GitHub Actions runs the same test in a disposable Compose project.

To inspect the current primary directly:

```sh
./scripts/mongosh.sh --quiet --eval 'print(db.hello().primary)'
```

If the smoke test waits without finding a primary, check that `.env` contains the correct `MONGO_HOST_IP` and that all three containers can reach the host on ports 27017–27019. Then inspect `docker compose ps`, `docker compose logs --tail 100`, and the replica-set status above. The helper scripts use the fixed ports in the current Compose file; they do not require a `MONGO_PORT` environment variable.

## Keep or reset data

Named data and config volumes preserve the replica-set configuration across restarts. To stop and start without deleting data:

```sh
docker compose down
docker compose up -d --wait --wait-timeout 180
```

If this is a disposable lab and you changed its member addresses, **delete this Compose project's volumes** so the next start initializes the set with the new IP:

```sh
docker compose down --volumes
docker compose up -d --wait --wait-timeout 180
```

This deletes the database contents. The healthcheck only calls `rs.initiate()` on a new set; it does not rewrite addresses in an existing set.

## Scope

This lab disables authentication and TLS and publishes MongoDB on all host interfaces. Use it only on a trusted network. For production, put members on separate hosts and configure authentication, TLS, and backups.

- [MongoDB: three-member replica sets](https://www.mongodb.com/docs/manual/core/replica-set-architecture-three-members/)
- [MongoDB: replica-set configuration](https://www.mongodb.com/docs/manual/reference/replica-configuration/)
- [MongoDB: `disableSplitHorizonIPCheck`](https://www.mongodb.com/docs/v8.0/reference/parameters/#mongodb-parameter-param.disableSplitHorizonIPCheck)
