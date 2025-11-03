# Implemented Nginx-based blue/green routing, a Python watcher that tails Nginx JSON logs and posts Slack alerts on failovers and high 5xx error rates, and a runbook describing operator actions.

- Project Root: `/mnt/c/Users/DELL/Documents/stage3-blue-green`


Here is a complete, step-by-step breakdown to implement my Stage 3 HNG-13 Internship: `Observability & Alerts` on top of my existing Blue/Green Stage 2 project.

# 1. Goals & Requirements (what I implemented)

- Structured Nginx logs that include: `pool`, `release`, `upstream_status`, `upstream_addr`, `request_time`, `upstream_response_time`.

- Shared log volume between Nginx and watcher.

- A lightweight Python watcher that:
1. Tails Nginx logs (JSON-lines).

2. Maintains a sliding window of the last `WINDOW_SIZE` requests.

3. Detects high 5xx error rate `(> ERROR_RATE_THRESHOLD)` and sends Slack alert.

4. Detects failover `(pool switch)` and sends Slack alert.

5. Enforces `ALERT_COOLDOWN_SEC` between duplicate alerts.

6. Reads `SLACK_WEBHOOK_URL` and other config from .env (no secrets in code).

- A `runbook.md` describing operator actions for each alert.

- Submission artifacts: docker-compose, watcher.py, nginx.conf.template, requirements.txt, .env.example, screenshots.


# 2. Files & folder layout

``` bash
stage3-blue-green/
├─ docker-compose.yml
├─ .env          (private, not in repo)
├─ .env.example
├─ nginx/
│  ├─ nginx.conf.tmpl
│  ├─ start.sh (optional)
│  └─ reload.sh (optional)
├─ watcher/
│  ├─ Dockerfile
│  ├─ requirements.txt
│  └─ watcher.py
├─ logs/         (optional local logs)
├─ runbook.md
└─ README.md
```
# 3. Step-by-step approach (what I did and why)

### Step A — Prepare project structure

1. Created folders: `nginx/,` `watcher/` and ensured `docker-compose.yml` sits in project root.

2. Kept the app images as prebuilt Docker Hub images (no change to app images per requirements):

- `yimikaade/wonderful:devops-stage-two` used for both `app_blue` and `app_green`.

*WHY:* Keeps scope limited to logs, watcher and Compose wiring; obeys constraint to not modify app images.

#### First: I cloned my existing Blue-Green stage 2 configured project to my local machine and edited all the files and added other files to suit the above project layout and structure in my stage 3-project.

### Step B — Nginx configuration (structured JSON logs).

File: `nginx/nginx.conf.tmpl`

``` bash
# nginx/nginx.conf.template
worker_processes auto;
events { worker_connections 1024; }

http {
    log_format custom_json escape=json '{'
        '"time_local":"$time_local",'
        '"remote_addr":"$remote_addr",'
        '"request":"$request",'
        '"status":"$status",'
        '"upstream_status":"$upstream_status",'
        '"upstream_addr":"$upstream_addr",'
        '"request_time":"$request_time",'
        '"upstream_response_time":"$upstream_response_time",'
        '"pool":"$http_x_app_pool",'
        '"release":"$http_x_release_id"'
    '}';

    access_log /var/log/nginx/access.log custom_json;

    upstream backend_blue {
        server app_blue:80;
    }

    upstream backend_green {
        server app_green:80;
    }

    server {
        listen 80;

        location / {
            proxy_pass http://backend_blue;  # Initial pool
            proxy_set_header X-App-Pool $http_x_app_pool;
            proxy_set_header X-Release-Id $http_x_release_id;
        }
    }
}
```

Key points:

- Defined a `log_format` that emits `JSON` with fields:

`time_local`, `remote_addr`, `request`, `status`, `upstream_status`, `upstream_addr`, `request_time,` `upstream_response_time,` pool (from `X-App-Pool`), release (from `X-Release-Id`).

- Configured `access_log /var/log/nginx/access.log stage3_json;`.

- Upstream backends configured to point at `app_blue` and `app_green` (internal service names).

Nginx listens on container port 80 (mapped to host 8080).

*WHY:* Structured JSON lines make parsing deterministic and robust for the watcher.

### Step C — Shared logs volume

In `docker-compose.yml`


``` bash
# docker-compose.yml
services:
  # --------------------
  # Blue App
  # --------------------
  app_blue:
    image: yimikaade/wonderful:devops-stage-two
    container_name: app_blue
    ports:
      - "8081:3000"   # internal port 3000 exposed as 8081
    environment:
      - X_APP_POOL=blue
      - X_RELEASE_ID=blue-v1
    volumes:
      - nginx_logs:/var/log/nginx

  # --------------------
  # Green App
  # --------------------
  app_green:
    image: yimikaade/wonderful:devops-stage-two
    container_name: app_green
    ports:
      - "8082:3000"   # internal port 3000 exposed as 8082
    environment:
      - X_APP_POOL=green
      - X_RELEASE_ID=green-v1
    volumes:
      - nginx_logs:/var/log/nginx

  # --------------------
  # Nginx Reverse Proxy
  # --------------------
  nginx:
    image: nginx:latest
    container_name: nginx
    ports:
      - "8080:80"
    volumes:
      - ./nginx/nginx.conf.template:/etc/nginx/nginx.conf:ro
      - nginx_logs:/var/log/nginx
    depends_on:
      - app_blue
      - app_green
    environment:
      - ACTIVE_POOL=${ACTIVE_POOL}

  # --------------------
  # Alert Watcher
  # --------------------
  alert_watcher:
    build: ./watcher
    container_name: alert_watcher
    working_dir: /watcher
    command: python3 watcher.py
    environment:
      - SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
      - ACTIVE_POOL=${ACTIVE_POOL}
      - ERROR_RATE_THRESHOLD=${ERROR_RATE_THRESHOLD}
      - WINDOW_SIZE=${WINDOW_SIZE}
      - ALERT_COOLDOWN_SEC=${ALERT_COOLDOWN_SEC}
    volumes:
      - ./watcher:/watcher
      - nginx_logs:/var/log/nginx:ro
    depends_on:
      - nginx
      - app_blue
      - app_green

volumes:
  nginx_logs:
```

- Declared a top-level volume `nginx_logs`.

- Mounted it in:

a. Nginx: `/var/log/nginx` (write)

b. `app_blue` & `app_green`: `/var/log/nginx` (if apps produce logs there)

c. watcher: `/var/log/nginx:ro` (read-only)

*WHY:* Shared volume lets watcher tail the same log file Nginx writes


### Step D — Watcher service

*Folder*: `watcher/`

*Files*:

- `Dockerfile` — lightweight Python base (Alpine or slim). Final choice used `python:3.11-slim` or `python:3.11-alpine` depending on environment issues.


``` bash
# watcher/Dockerfile

# Use lightweight Alpine Python image
FROM python:3.11-alpine

# Set working directory
WORKDIR /opt

# Copy watcher code
COPY watcher.py /opt/watcher.py
COPY requirements.txt /opt/requirements.txt

# Install dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Run watcher
CMD ["python", "/opt/watcher.py"]
```


- `requirements.txt` — requests


``` bash
# watcher/requirement.txt
requests>=2.28
```

- `watcher.py` — the log tailing + alert logic.


*WHY:* Build the `watcher` image so requests is installed; mount logs read-only.


### Step E — watcher.py logic (core)

Main logic implemented

1. Read config from environment:

- `SLACK_WEBHOOK_URL`, `ACTIVE_POOL` (initial), `ERROR_RATE_THRESHOLD`, `WINDOW_SIZE`, `ALERT_COOLDOWN_SEC`.

2. Tail `/var/log/nginx/access.log` using a loop that calls `readline()` and `time.sleep()` when no data; *do not use* `seek()` because some mounts are not seekable.

3. Parse each line as JSON. From each record:
- Extract `pool` (string), `upstream_status` (string/int), `upstream_addr`.
- Append 1 for 5xx status and 0 `otherwise to a deque(maxlen=WINDOW_SIZE)`.

4. Failover detection:

- If `pool` field changes from `current_active_pool` and last failover alert was more than `ALERT_COOLDOWN_SEC` seconds, send failover alert and set `active_pool` to new value.

5. Error rate detection:

- When the rolling window is full, compute error rate = 100 * (# of 5xx) / WINDOW_SIZE.

- If above threshold and last error alert older than cooldown, send Slack alert.

6. Slack posting via `requests.post(SLACK_WEBHOOK_URL, json={'text': message})`.

7. Optional: Respect MAINTENANCE_MODE flag to suppress alerts during planned toggles.


``` bash
# watcher/watcher.py

import os
import time
import json
import requests
from datetime import datetime
from collections import deque

# Environment variables
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL")
ACTIVE_POOL = os.getenv("ACTIVE_POOL", "blue")
ERROR_RATE_THRESHOLD = float(os.getenv("ERROR_RATE_THRESHOLD", "2"))
WINDOW_SIZE = int(os.getenv("WINDOW_SIZE", "200"))
ALERT_COOLDOWN_SEC = int(os.getenv("ALERT_COOLDOWN_SEC", "300"))

# Shared log file path
LOG_FILE = "/var/log/nginx/access.log"

# Rolling window for error rate
rolling_window = deque(maxlen=WINDOW_SIZE)

# Last alert timestamps
last_failover_alert = 0
last_error_rate_alert = 0

def post_slack(message):
    if SLACK_WEBHOOK_URL:
        payload = {"text": message}
        try:
            requests.post(SLACK_WEBHOOK_URL, json=payload, timeout=5)
        except Exception as e:
            print(f"Failed to send Slack alert: {e}")

# Track active pool
active_pool = ACTIVE_POOL

def tail_log(file_path):
    """Tail the Nginx log file."""
    with open(file_path, "r") as f:
        # Go to the end of file
        f.seek(0,2)
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.1)
                continue
            yield line

def parse_log_line(line):
    try:
        return json.loads(line)
    except:
        return {}

for line in tail_log(LOG_FILE):
    data = parse_log_line(line)
    if not data:
        continue

    # Add to rolling window
    rolling_window.append(data)

    # Check failover
    current_pool = data.get("pool", active_pool)
    if current_pool != active_pool and (time.time() - last_failover_alert) > ALERT_COOLDOWN_SEC:
        msg = f"Failover detected: {active_pool} → {current_pool} at {datetime.now()}"
        post_slack(msg)
        active_pool = current_pool
        last_failover_alert = time.time()

    # Check error rate
    if len(rolling_window) == WINDOW_SIZE:
        error_count = sum(1 for r in rolling_window if str(r.get("upstream_status","")).startswith("5"))
        error_rate = (error_count / len(rolling_window)) * 100
        if error_rate > ERROR_RATE_THRESHOLD and (time.time() - last_error_rate_alert) > ALERT_COOLDOWN_SEC:
            msg = f"High error rate detected: {error_rate:.2f}% over last {WINDOW_SIZE} requests at {datetime.now()}"
            post_slack(msg)
            last_error_rate_alert = time.time()
```

*WHY:* Rolling window for accurate rate, cooldowns prevent spam, environment config avoid hand coded secrets.


### Step F — .env handling

- Created `.env.example` with placeholders (no real secrets).
- Created `.env` on local dev and on EC2 with real `SLACK_WEBHOOK_URL.`
- Ensured `.env` is next to `docker-compose.yml` so Compose picks it up.

``` bash
# .env.example

# Blue and Green image references
BLUE_IMAGE=yimikaade/wonderful:devops-stage-two   # Blue image
GREEN_IMAGE=yimikaade/wonderful:devops-stage-two  # Green image

# Which pool is currently active
ACTIVE_POOL=blue

# Release IDs for header identification
RELEASE_ID_BLUE=blue-v1
RELEASE_ID_GREEN=green-v1

# Exposed ports
PORT_BLUE=8081
PORT_GREEN=8082
NGINX_PORT=8080


# Stage 3 observability + Slack
SLACK_WEBHOOK_URL=

# Alerting thresholds (defaults)
ERROR_RATE_THRESHOLD=2        # percent
WINDOW_SIZE=200               # number of requests in rolling window
ALERT_COOLDOWN_SEC=300        # seconds between same alert

# Existing Stage2 variables (keep them)
BLUE_IMAGE=...
GREEN_IMAGE=...
ACTIVE_POOL=blue
RELEASE_ID_BLUE=blue-v1
RELEASE_ID_GREEN=green-v1
PORT=3000
NGINX_PUBLIC_PORT=8080
```

created `.env`

``` bash
# .env

SLACK_WEBHOOK_URL=https://slack # input the real slack URL here
ACTIVE_POOL=blue
ERROR_RATE_THRESHOLD=2
WINDOW_SIZE=200
ALERT_COOLDOWN_SEC=300
```

*WHY:* Keeps secrets out of code and repo; Docker Compose automatically exposes these variables.


## Added bash script `monitor_failover.sh` and `notify_slack.sh` these scripts were created at the root directory

ready-to-run command that simulated failover on my `blue-green` setup and trigger `Slack` so you can test end-to-end.

1. Using a bash script to send Slack Message

# notify_slack.sh

``` bash
# notify_slack.sh

#!/bin/bash

# Webhook URL (replace with your actual Slack webhook URL)
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"

# Message to send
MESSAGE="Failover"

# Send to Slack
curl -X POST -H 'Content-type: application/json' \
     --data "{\"text\":\"$MESSAGE\"}" \
     $SLACK_WEBHOOK_URL
```

#### make it executable

``` bash
chmod +x notify_slack.sh
```

### Trigger failover stimulation
I stopped my primary container

``` bash
docker stop app_green
```

Then called my slack script

``` bash
./notify_slack.sh
```

### ✅ Slack will receive a message

![](./Images/12a.%20Failover-event.png)


### Optional: Combine in one command

You can test everything in one goal

``` bash
docker stop app_green && curl -X POST -H 'Content-type: application/json' \
     --data '{"text":"Failover"}' \
     https://hooks.slack.com/services/XXX/YYY/ZZZ
```

- Replace the `webhook URL` with your Slack webhook.
- This stops the primary container and immediately sends the `“Failover” `alert.



## Here is a full failover monitoring script that watch my containers and sends a Slack alert stating “Failover”


1. `monitor_failover.sh`

``` bash

# monitor_failover.sh

#!/bin/bash

# Containers to monitor
CONTAINERS=("app_green" "app_blue")

for CONTAINER in "${CONTAINERS[@]}"; do
    STATUS=$(docker inspect -f '{{.State.Running}}' $CONTAINER 2>/dev/null)
    if [ "$STATUS" != "true" ]; then
        # Send Slack alert
        ./notify_slack.sh "Failover - $CONTAINER is down!"
    fi
done
```

#### Make it executable

``` bash
chmod +x monitor_failover.sh
```

Then I stopped a container to stimulate failover 

``` bash
docker stop app_blue
```

Then I ran the monitor 

``` bash
./monitor_failover.sh
```

Then got a message on slack

![](./Images/16a%20Failover-event.png)



### 4. Commands used

I ensure my docker machine was running

``` 
docker ps
docker image
docker compose down -v
docker ps
```

``` bash
# from project root
docker compose up -d --build
docker compose ps
docker compose logs -f alert_watcher
docker compose exec alert_watcher sh   # to run debug commands inside
```

### Test Slack connectivity inside watcher

``` bash
docker compose exec alert_watcher python3 -c "import os, requests; print(requests.post(os.getenv('SLACK_WEBHOOK_URL'), json={'text':'Test alert'}) .status_code)"
```

### 1. Simulate failover (manual log injection)

docker compose exec nginx sh -c "echo '{\"time_local\":\"now\",\"pool\":\"green\",\"release\":\"green-v1\",\"upstream_status\":\"200\",\"upstream_addr\":\"app_green:80\",\"request_time\":\"0.001\"}' >> /var/log/nginx/access.log"
```

Or use the one-line chaos command (appends failover + burst of statuses):

``` bash
docker compose exec nginx sh -c "echo 'Simulated failover from blue to green' >> /var/log/nginx/access.log && for i in \$(seq 1 250); do if [ \$((RANDOM % 10)) -lt 3 ]; then echo '500 Internal Server Error' >> /var/log/nginx/access.log; else echo '200 OK' >> /var/log/nginx/access.log; fi; done"
```

``` bash
# To restore
docker start app_green
```

### Simulate high error-rate (manual injection)

``` bash
# append many 500 responses to the log
for i in {1..250}; do docker compose exec nginx sh -c "echo '{\"time_local\":\"now\",\"pool\":\"blue\",\"release\":\"blue-v1\",\"upstream_status\":\"500\",\"upstream_addr\":\"app_blue:80\",\"request_time\":\"0.001\"}' >> /var/log/nginx/access.log"; done
```

Or use the one-line chaos command (appends failover + burst of statuses):

``` bash
docker compose exec nginx sh -c "echo 'Simulated failover from blue to green' >> /var/log/nginx/access.log && for i in \$(seq 1 250); do if [ \$((RANDOM % 10)) -lt 3 ]; then echo '500 Internal Server Error' >> /var/log/nginx/access.log; else echo '200 OK' >> /var/log/nginx/access.log; fi; done"
```

![](./Images/2.%20high-Error-Rate.png)



### 2. If it’s a service health check

If you have a script that triggers failover when the service returns errors (e.g., HTTP 5xx), you can simulate by forcing a failure:

``` bash
# For example, return HTTP 500 for testing
curl -X GET http://localhost:8080/failover-test
```

![](./Images/4.%20errors.png)

My monitoring script interpreted this as a failure and sends Slack notifications.

### Logs and verifications
``` bash
docker compose logs -f alert_watcher
docker compose exec nginx tail -n 50 /var/log/nginx/access.log
```

### 5. EC2 deployment specifics

Commands run on EC2 after SSH:

``` bash
# install docker & compose (Ubuntu)
sudo apt update -y
sudo apt install -y docker.io docker-compose
    or
sudo apt install docker-compose-plugin
sudo systemctl enable --now docker
sudo docker compose version
```

# clone repo
git clone https://github.com/yourusername/stage3-blue-green.git
cd stage3-blue-green

# create .env (copy .env.example then edit)
cp .env.example .env
# edit .env and set SLACK_WEBHOOK_URL

# start services
sudo docker compose up -d --build

# check status
sudo docker compose ps
sudo docker compose logs -f alert_watcher
```
