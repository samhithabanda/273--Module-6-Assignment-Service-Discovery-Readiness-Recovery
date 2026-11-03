"""Inventory client - calls the Inventory Service by its Kubernetes Service name.

It never uses Pod IPs: the only address it knows is INVENTORY_URL,
which defaults to the cluster DNS name of the Service.
"""
import json
import os
import time
import urllib.request
from datetime import datetime

URL = os.environ.get("INVENTORY_URL", "http://inventory-service:8080/items")
INTERVAL = float(os.environ.get("INTERVAL_SECONDS", "1"))

print(f"Client starting. Target = {URL}", flush=True)
n = 0
while True:
    n += 1
    ts = datetime.now().strftime("%H:%M:%S")
    try:
        with urllib.request.urlopen(URL, timeout=2) as resp:
            body = json.loads(resp.read())
            print(f"{ts} req#{n:04d} OK  served_by={body['served_by']} ip={body['pod_ip']}", flush=True)
    except Exception as exc:  # keep going so we can watch recovery
        print(f"{ts} req#{n:04d} ERR {exc}", flush=True)
    time.sleep(INTERVAL)
