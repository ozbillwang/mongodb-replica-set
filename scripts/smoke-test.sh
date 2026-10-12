#!/usr/bin/env bash
# Run only against a disposable lab: stops a primary and writes to replica_set_lab.
set -euo pipefail
cd "$(dirname "$0")/.."
stopped=''
restore() {
  if [[ -n "$stopped" ]]; then docker compose start "$stopped" >&2; fi
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mongo() {
  ./scripts/mongosh.sh --quiet --eval "
    function checkWrite(r) {
      if (r.ok !== 1 || r.writeErrors?.length || r.writeConcernError) {
        throw new Error(EJSON.stringify(r));
      }
    }
    $1"
}
wait_for_primary() {
  for ((attempt=0; attempt<30; attempt++)); do
    if mongo 'if (!db.hello().isWritablePrimary) quit(1)' >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo 'Timed out waiting for a writable primary' >&2
  return 1
}
docker compose up -d --wait --wait-timeout 180
wait_for_primary
run_id="$(date +%s)-${RANDOM}"
mongo "checkWrite(db.getSiblingDB('replica_set_lab').runCommand({insert:'checks',documents:[{_id:'${run_id}-before',phase:'before'}],writeConcern:{w:'majority',wtimeout:10000}}))"
primary_id=$(mongo 'print(rs.status().members.find(m => m.state === 1)._id)')
case "$primary_id" in
  0) primary=mongo1 ;;
  1) primary=mongo2 ;;
  2) primary=mongo3 ;;
  *) echo "Unexpected primary member ID: $primary_id" >&2; exit 1 ;;
esac
printf 'Stopping current primary: %s\n' "$primary"
stopped=$primary
docker compose stop "$primary"
wait_for_primary
replacement=$(mongo 'print(db.hello().primary)')
replacement_id=$(mongo 'print(rs.status().members.find(m => m.state === 1)._id)')
[[ "$replacement_id" != "$primary_id" ]]
printf 'New primary: %s\n' "$replacement"
mongo "const lab=db.getSiblingDB('replica_set_lab'); if (!lab.checks.findOne({_id:'${run_id}-before'})) throw new Error('Missing pre-failover document'); checkWrite(lab.runCommand({insert:'checks',documents:[{_id:'${run_id}-after',phase:'after'}],writeConcern:{w:'majority',wtimeout:10000}}))"
docker compose up -d --wait --wait-timeout 180
stopped=''
wait_for_primary
# Verify both documents on every member, including the recovered node.
for service in mongo1 mongo2 mongo3; do
  case "$service" in
    mongo1) port=27017 ;;
    mongo2) port=27018 ;;
    mongo3) port=27019 ;;
  esac
  docker compose exec -T "$service" mongosh \
    "mongodb://localhost:${port}/?directConnection=true&readPreference=secondaryPreferred" \
    --quiet --eval "const deadline=Date.now()+60000; while (db.getSiblingDB('replica_set_lab').checks.countDocuments({_id:{\$in:['${run_id}-before','${run_id}-after']}}) !== 2) { if (Date.now()>deadline) throw new Error('Documents did not replicate to $service'); sleep(1000); }"
done
mongo 'printjson(rs.status().members.map(m => ({name:m.name,state:m.stateStr})))'
echo 'PASS: majority writes, primary failover, recovery, and replication to all three members.'
