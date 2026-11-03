#!/usr/bin/env bash
# Lab walkthrough, split into steps so each one fits in one terminal screenshot.
#   ./scripts/demo.sh <step>    e.g. ./scripts/demo.sh 07
#   ./scripts/demo.sh all       run every step in order
# Output of each step is also saved to docs/logs/<step>.txt
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/logs
STATE=.demo-state
touch "$STATE"; source "$STATE"

save() { echo "$1=$2" >> "$STATE"; }
run() { printf '\033[1;32m$ %s\033[0m\n' "$*"; eval "$@"; echo; }
note() { printf '\033[1;33m# %s\033[0m\n' "$*"; }
client() { kubectl get pod -l app=inventory-client -o jsonpath='{.items[0].metadata.name}'; }

step01() { # cluster
  run kind get clusters
  run kubectl get nodes -o wide
  run kubectl cluster-info
}
step02() { # images
  run docker build -q -t inventory-service:1.0 app
  run docker build -q -t inventory-client:1.0 client
  run "docker images | grep -E 'REPOSITORY|inventory'"
  run kind load docker-image inventory-service:1.0 inventory-client:1.0 --name module6
}
step03() { # deploy
  run kubectl apply -f k8s/
  run kubectl rollout status deployment/inventory
  run kubectl rollout status deployment/inventory-client
  run kubectl get deployments
  run kubectl get pods -o wide
}
step04() { # service + endpoints
  run kubectl get service inventory-service
  run kubectl get endpoints inventory-service
  run "kubectl describe service inventory-service | grep -E 'Name:|Selector|Type:|^IP:|Port:|Endpoints'"
}
step05() { # client uses the service name
  local c; c=$(client)
  run "grep -n 'inventory-service' client/client.py k8s/client-deployment.yaml"
  run kubectl exec "$c" -- printenv INVENTORY_URL
  run "kubectl exec $c -- python -c \"import socket; print(socket.gethostbyname('inventory-service'))\""
  run "kubectl exec $c -- python -c \"import urllib.request; print(urllib.request.urlopen('http://inventory-service:8080/items').read().decode())\" | cut -c1-110"
}
step06() { # both replicas get traffic
  sleep 30
  run kubectl logs deploy/inventory-client --tail=12
  note "which pod answered each of the client's requests in the last 30s:"
  run "kubectl logs deploy/inventory-client --since=30s | grep -o 'served_by=[^ ]*' | sort | uniq -c"
  for p in $(kubectl get pods -l app=inventory -o name); do
    run "kubectl logs $p --tail=2"
  done
}
step07() { # break readiness on one pod
  read -r A B < <(kubectl get pods -l app=inventory -o jsonpath='{.items[0].metadata.name} {.items[1].metadata.name}')
  save A "$A"; save B "$B"
  note "making $A fail its readiness probe"
  run kubectl exec "$A" -- touch /tmp/not-ready
  sleep 5
  run kubectl get pods -l app=inventory -o wide
  run kubectl get endpoints inventory-service
}
step08() { # probe events
  run "kubectl describe pod $A | grep -E '^ *Ready|Readiness:|Unhealthy'"
}
step09() { # traffic only goes to the ready pod
  sleep 12
  note "client requests in the last 12s:"
  run "kubectl logs deploy/inventory-client --since=12s | grep -o 'served_by=[^ ]*' | sort | uniq -c"
  note "requests the unready pod ($A) itself logged in the last 12s:"
  run "kubectl logs $A --since=12s | grep -c 'GET /items'"
  run kubectl logs deploy/inventory-client --tail=6
}
step10() { # unready pod is still alive
  run "kubectl get pod $A -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount"
  run "kubectl exec $A -- python -c \"import urllib.request; print(urllib.request.urlopen('http://localhost:8080/healthz').read().decode())\""
  run "kubectl exec $A -- python -c \"import urllib.request as u
try: u.urlopen('http://localhost:8080/ready')
except Exception as e: print(e)\""
}
step11() { # restore readiness
  run kubectl exec "$A" -- rm /tmp/not-ready
  save RESTORED "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sleep 5
  run kubectl get pods -l app=inventory -o wide
  run kubectl get endpoints inventory-service
}
step12() { # traffic comes back
  sleep 12
  note "client requests since readiness was restored:"
  run "kubectl logs deploy/inventory-client --since-time="$RESTORED" | grep -o 'served_by=[^ ]*' | sort | uniq -c"
  note "first request the restored pod answered:"
  run "kubectl logs deploy/inventory-client --since-time=$RESTORED | grep -m1 $A"
  run kubectl logs deploy/inventory-client --tail=6
}
step13() { # before deleting
  run kubectl get service inventory-service -o wide
  run kubectl get pods -l app=inventory -o wide
  run kubectl get endpoints inventory-service
}
step14() { # delete + watch
  save DELETED_IP "$(kubectl get pod "$A" -o jsonpath='{.status.podIP}')"
  save DELETED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run kubectl delete pod "$A" --wait=false
  printf '\033[1;32m$ kubectl get pods -l app=inventory -w\033[0m   (stopped after 40s)\n'
  kubectl get pods -l app=inventory -w & w=$!
  sleep 40; kill $w; wait $w 2>/dev/null; echo
}
step15() { # after replacement
  local new ip
  new=$(kubectl get pods -l app=inventory -o name | sed 's|pod/||' | grep -v -e "$A" -e "$B")
  ip=$(kubectl get pod "$new" -o jsonpath='{.status.podIP}')
  save NEW "$new"
  run kubectl get deployment inventory
  run kubectl get pods -l app=inventory -o wide
  run kubectl get service inventory-service
  run kubectl get endpoints inventory-service
  note "before vs after"
  printf '  %-12s %-30s %s\n' "" "BEFORE" "AFTER" \
    "pod name" "$A" "$new" "pod IP" "$DELETED_IP" "$ip" \
    "service" "inventory-service" "inventory-service" \
    "cluster IP" "$(kubectl get svc inventory-service -o jsonpath='{.spec.clusterIP}')" "(same)"
  echo
  run "kubectl get events --sort-by=.lastTimestamp | grep -E 'Killing|SuccessfulCreate' | tail -3"
}
step16() { # client keeps working
  note "client requests since the pod was deleted:"
  run "kubectl logs deploy/inventory-client --since-time="$DELETED_AT" | grep -o 'served_by=[^ ]*' | sort | uniq -c"
  note "failed requests since the pod was deleted:"
  run "kubectl logs deploy/inventory-client --since-time=$DELETED_AT | grep -c ERR"
  note "first request answered by the new pod:"
  run "kubectl logs deploy/inventory-client --since-time=$DELETED_AT | grep -m1 $NEW"
  run kubectl logs deploy/inventory-client --tail=8
}

steps=("$@"); [ "${1:-}" = all ] && steps=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16)
for s in "${steps[@]}"; do
  [ "$s" = 01 ] && : > "$STATE"
  source "$STATE"
  "step$s" 2>&1 | tee >(sed 's/\x1b\[[0-9;]*m//g' > "docs/logs/$s.txt")
done
