#!/usr/bin/env bash
# Discover a running seed and use normal replica-set driver discovery.
set -euo pipefail
cd "$(dirname "$0")/.."
for service in mongo1 mongo2 mongo3; do
  if [[ -n "$(docker compose ps --status running -q "$service")" ]]; then
    case "$service" in
      mongo1) port=27017 ;;
      mongo2) port=27018 ;;
      mongo3) port=27019 ;;
    esac
    exec docker compose exec -T "$service" mongosh \
      "mongodb://${service}:${port}/?replicaSet=rs0&serverSelectionTimeoutMS=10000" "$@"
  fi
done
echo 'No running MongoDB service. Run: docker compose up -d --wait' >&2
exit 1
