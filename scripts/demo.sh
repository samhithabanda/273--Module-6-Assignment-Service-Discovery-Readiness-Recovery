#!/usr/bin/env bash
# Runs the three lab experiments and saves terminal output to docs/logs/.
# Usage: ./scripts/demo.sh   (cluster must already have the app deployed)
set -uo pipefail
cd "$(dirname "$0")/.."
LOG=docs/logs
mkdir -p "$LOG"
CLIENT=$(kubectl get pod -l app=inventory-client -o jsonpath='{.items[0].metadata.name}')

run() { echo "\$ $*"; eval "$@"; echo; }
tally() { # count which Pods served the client's last N seconds of requests
  kubectl logs "$CLIENT" --since="$1"s | grep -o 'served_by=[^ ]*' | sort | uniq -c
}

# ---------------------------------------------------------------- 1. deploy
{
  run kubectl get deployment inventory inventory-client
  run kubectl get pods -o wide
  run kubectl get service inventory-service
  run kubectl get endpoints inventory-service
  run "kubectl exec $CLIENT -- python -c \"import socket;print('inventory-service resolves to', socket.gethostbyname('inventory-service'))\""
  run "kubectl exec $CLIENT -- python -c \"import urllib.request;print(urllib.request.urlopen('http://inventory-service:8080/items').read().decode())\""
} 2>&1 | tee "$LOG/01-deploy.txt"

sleep 20
{
  run "kubectl logs $CLIENT --tail=20"
  echo "# Requests per replica over the last 20 seconds:"
  run tally 20
  for p in $(kubectl get pods -l app=inventory -o name); do
    run "kubectl logs $p --tail=3"
  done
} 2>&1 | tee "$LOG/02-load-balancing.txt"

# ------------------------------------------------------------- 2. readiness
read -r A B < <(kubectl get pods -l app=inventory -o jsonpath='{.items[0].metadata.name} {.items[1].metadata.name}')
{
  echo "# Pod to make unready: $A   (other Pod: $B)"
  run kubectl exec "$A" -- touch /tmp/not-ready
  sleep 6
  run kubectl get pods -l app=inventory -o wide
  run kubectl get endpoints inventory-service
  run "kubectl describe pod $A | grep -E 'Ready|Readiness|Unhealthy' "
  run "kubectl get pod $A -o jsonpath='{.status.phase}{\"  restarts=\"}{.status.containerStatuses[0].restartCount}{\"\\n\"}'"
  sleep 15
  echo "# Client traffic over the last 15 seconds (only the ready Pod should appear):"
  run tally 15
  run "kubectl logs $CLIENT --tail=8"
} 2>&1 | tee "$LOG/03-readiness-failure.txt"

{
  run kubectl exec "$A" -- rm /tmp/not-ready
  sleep 6
  run kubectl get pods -l app=inventory -o wide
  run kubectl get endpoints inventory-service
  sleep 15
  echo "# Client traffic over the last 15 seconds (both Pods again):"
  run tally 15
  run "kubectl logs $CLIENT --tail=8"
} 2>&1 | tee "$LOG/04-readiness-recovery.txt"

# ----------------------------------------------------- 3. failure/recovery
{
  run kubectl get service inventory-service -o wide
  run kubectl get pods -l app=inventory -o wide
  run kubectl delete pod "$A" --wait=false
  sleep 1
  run kubectl get pods -l app=inventory -o wide
  kubectl wait --for=delete pod/"$A" --timeout=90s >/dev/null
  kubectl wait --for=condition=Ready pod -l app=inventory --timeout=60s >/dev/null
  run kubectl get pods -l app=inventory -o wide
  run kubectl get service inventory-service -o wide
  run kubectl get endpoints inventory-service
  run "kubectl get events --sort-by=.lastTimestamp | grep -E 'Killing|SuccessfulCreate|Scheduled|Started' | tail -8"
  sleep 15
  NEW=$(kubectl get pods -l app=inventory -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v -e "$B" -e "$A")
  echo "# Deleted Pod: $A   Replacement Pod: $NEW"
  echo "# Client traffic over the last 15 seconds (served by $B and the new $NEW):"
  run tally 15
  echo "# Failed client requests during the whole delete/replace window (60s):"
  run "kubectl logs $CLIENT --since=60s | grep -c ERR || true"
  run "kubectl logs $CLIENT --tail=10"
} 2>&1 | tee "$LOG/05-pod-recovery.txt"
