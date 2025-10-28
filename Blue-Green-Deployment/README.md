# Blue–Green Deployment Project

## 💯 Detailed explanation, step-by-step approach.

## 1. Project Goals

I Ran two identical `Node.js` app instances (Blue and Green) behind an `Nginx` reverse proxy so:

- Normal traffic goes to `Blue`.
- When Blue fails, Nginx automatically retries and serves from Green within the same client request (no client errors).
- Everything is run via `Docker Compose`, parameterized with `.env.`

## 2. High-level architecture

``` bash
Client → Nginx (public endpoint) → upstreams: Blue (primary) + Green (backup)
                      │
             Blue (localhost:8081)  Green (localhost:8082)
```

- Nginx is templated from `ACTIVE_POOL` so `Blue` is primary by default.
- App images are pre-built (I used yimikaade/wonderful:devops-stage-two (the blue and the green Images provide)), so Compose pulls and runs them.
- Chaos endpoints on each app `(/chaos/start, /chaos/stop)` simulate failures for testing.

## 3. Files you created (What and Why)

``` bash
blue-green-project/
├─ docker-compose.yml            # Compose describes 3 services: app_blue, app_green, nginx
├─ .env.example                  # Template env values the grader will override
├─ .env                          # local copy with environment values (not pushed)
├─ nginx/
│  ├─ default.conf.tmpl          # Nginx template (placeholders replaced by start.sh)
│  ├─ start.sh                   # Render template -> /etc/nginx/conf.d/default.conf and start nginx
│  └─ reload.sh                  # Re-render & reload nginx (used for toggles)
├─ start.sh / reload.sh          # (if present at repo root) convenience wrappers (optional)
├─ README.md                     # Usage instructions
```

### Key file contents (summary):

- **docker-compose.yml** — parameterized with $ `(BLUE-IMAGE)` and $ `(GREEN_IMAGE)`, and `{ACTIVE_POOL}`, ports mapping `(8081-blue)`, `(8082-green)`, `(8080-nginx)`.

- **.env.example** — shows the keys grader will set: `BLUE_IMAGE`, `GREEN_IMAGE`, `ACTIVE_POOL`, `RELEASE_ID_BLUE`, `RELEASE_ID_GREEN`, `PORT`, `NGINX_PUBLIC_PORT`.

- **nginx/default.conf.tmpl** — upstream block uses `PRIMARY_HOST`, `BACKUP_HOST`, `PRIMARY_PORT`, `BACKUP_PORT` placeholders. Includes `proxy_next_upstream` and `proxy_next_upstream`_tries and `proxy_pass_header` lines to forward `X-App-Pool` and `X-Release-Id`.

- **nginx/start.sh** — reads `ACTIVE_POOL` and `APP_PORT` env vars, substitutes the placeholders and runs nginx `(nginx -g 'daemon off;')`.

- `nginx/reload.sh` — same substitution but then runs `nginx -s reload`.


## 4. Step-by-step configuration & commands I ran

All commands assume are in `~/Documents/blue-green-project` in an `Ubuntu/WSL terminal`. Use `code .` to open `VS Code` when I need to edit files.

## A. Environment and Perequisites
Installed Docker & Compose (official repo) and ensured WSL integration.

``` bash
sudo apt update
sudo apt install -y docker.io docker-compose curl jq
sudo usermod -aG docker $USER   # sign out & in / restart shell afterwards
```
- I ensure Docker Desktop WSL integration is ON


## B. Create `.env.example` (template)

``` bash
BLUE_IMAGE=yimikaade/wonderful:devops-stage-two  #Image from Dockerhub
GREEN_IMAGE=yimikaade/wonderful:devops-stage-two  # Image from Dockerhub
ACTIVE_POOL=blue
RELEASE_ID_BLUE=blue-v1
RELEASE_ID_GREEN=green-v1
PORT=3000
NGINX_PUBLIC_PORT=8080
```

## C. created `docker-compose.yml`

Key points:
- app_blue & app_green services use image: ${BLUE_IMAGE} and ${GREEN_IMAGE}.

- Expose 8081:${PORT} and 8082:${PORT} for direct chaos calls.

- nginx mounts nginx/default.conf.tmpl and runs /etc/nginx/start.sh.

- Healthchecks on apps (recommended) and depends_on for startup order.

``` bash
version: "3.8"

services:
  app_blue:
    image: \${BLUE_IMAGE}
    container_name: app_blue
    environment:
      - RELEASE_ID=\${RELEASE_ID_BLUE}
      - APP_POOL=blue
      - PORT=\${PORT:-3000}
    ports:
      - "8081:\${PORT:-3000}"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:\${PORT:-3000}/healthz"]
      interval: 5s
      timeout: 2s
      retries: 3

  app_green:
    image: \${GREEN_IMAGE}
    container_name: app_green
    environment:
      - RELEASE_ID=\${RELEASE_ID_GREEN}
      - APP_POOL=green
      - PORT=\${PORT:-3000}
    ports:
      - "8082:\${PORT:-3000}"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:\${PORT:-3000}/healthz"]
      interval: 5s
      timeout: 2s
      retries: 3

  nginx:
    image: nginx:stable
    container_name: bg_nginx
    depends_on:
      - app_blue
      - app_green
    ports:
      - "\${NGINX_PUBLIC_PORT:-8080}:80"
    volumes:
      - ./nginx/default.conf.tmpl:/etc/nginx/templates/default.conf.tmpl:ro
      - ./nginx/start.sh:/etc/nginx/start.sh:ro
      - ./nginx/reload.sh:/etc/nginx/reload.sh:ro
    environment:
      - ACTIVE_POOL=\${ACTIVE_POOL}
      - APP_PORT=\${PORT:-3000}
    command: ["/bin/sh", "-c", "/etc/nginx/start.sh"]
EOF
```


Copy `.env.example` to `.env` and edited sample values:

``` bash
cp .env.example .env
# edit .env if necessary (e.g., change NGINX_PORT to 8080 while resolving conflicts, and change the green image to the actual image id)
```

## D. Create Nginx template `nginx/default.conf.tmpl`

``` bash
mkdir -p nginx
cat > nginx/default.conf.tmpl <<'EOF'
upstream app_upstream {
    server PRIMARY_HOST:PRIMARY_PORT max_fails=1 fail_timeout=3s;
    server BACKUP_HOST:BACKUP_PORT backup;
    keepalive 16;
}

server {
    listen 80;

    proxy_connect_timeout 1s;
    proxy_send_timeout 3s;
    proxy_read_timeout 5s;

    proxy_next_upstream error timeout http_500 http_502 http_503 http_504;
    proxy_next_upstream_tries 2;

    location / {
        proxy_pass http://app_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-App-Proxy "nginx-blue-green";

        proxy_pass_header X-App-Pool;
        proxy_pass_header X-Release-Id;
    }

    location /healthz {
        proxy_pass http://app_upstream/healthz;
        proxy_set_header Host $host;
    }
}
EOF
```

## E. Create `nginx/start.sh` and `nginx/reload.sh` and grant premission for both

### nginx/start.sh

``` bash
cat > nginx/start.sh <<'EOF'
#!/bin/sh
set -eu
TEMPLATE=/etc/nginx/templates/default.conf.tmpl
OUT=/etc/nginx/conf.d/default.conf
ACTIVE_POOL=${ACTIVE_POOL:-blue}
APP_PORT=${APP_PORT:-3000}
if [ "$ACTIVE_POOL" = "blue" ]; then
  PRIMARY_HOST="app_blue"
  BACKUP_HOST="app_green"
elif [ "$ACTIVE_POOL" = "green" ]; then
  PRIMARY_HOST="app_green"
  BACKUP_HOST="app_blue"
else
  echo "Invalid ACTIVE_POOL: $ACTIVE_POOL"
  exit 1
fi
sed -e "s/PRIMARY_HOST/${PRIMARY_HOST}/g" -e "s/BACKUP_HOST/${BACKUP_HOST}/g" -e "s/PRIMARY_PORT/${APP_PORT}/g" -e "s/BACKUP_PORT/${APP_PORT}/g" "$TEMPLATE" > "$OUT"
echo "Generated $OUT with PRIMARY=${PRIMARY_HOST}:${APP_PORT} BACKUP=${BACKUP_HOST}:${APP_PORT}"
nginx -t && nginx -g 'daemon off;'
EOF
```

``` bash
 chmod +x nginx/start.sh
 ```


### nginx/reload.sh

``` bash
cat > nginx/reload.sh <<'EOF'
#!/bin/sh
set -eu
TEMPLATE=/etc/nginx/templates/default.conf.tmpl
OUT=/etc/nginx/conf.d/default.conf
ACTIVE_POOL=${ACTIVE_POOL:-blue}
APP_PORT=${APP_PORT:-3000}
if [ "$ACTIVE_POOL" = "blue" ]; then
  PRIMARY_HOST="app_blue"
  BACKUP_HOST="app_green"
elif [ "$ACTIVE_POOL" = "green" ]; then
  PRIMARY_HOST="app_green"
  BACKUP_HOST="app_blue"
else
  echo "Invalid ACTIVE_POOL: $ACTIVE_POOL"
  exit 1
fi
sed -e "s/PRIMARY_HOST/${PRIMARY_HOST}/g" -e "s/BACKUP_HOST/${BACKUP_HOST}/g" -e "s/PRIMARY_PORT/${APP_PORT}/g" -e "s/BACKUP_PORT/${APP_PORT}/g" "$TEMPLATE" > "$OUT"
echo "Reloading nginx with PRIMARY=${PRIMARY_HOST}:${APP_PORT} BACKUP=${BACKUP_HOST}:${APP_PORT}"
nginx -t && nginx -s reload
EOF
```


``` bash
chmod +x nginx/reload.sh
```


## Run & verify locally

1. Start the Stack:

``` bash
docker-compose up -d
docker-compose ps
```

## 2. Baseline verification — Blue active:

``` bash
curl -i http://localhost:8080/version
# Expect headers:
# X-App-Pool: blue
# X-Release-Id: $RELEASE_ID_BLUE
```

![](./Images/1.%20blue-active.png)


Check each service directly 

``` bash
curl -i http://localhost:8081/version  # Blue
curl -i http://localhost:8082/version  # Green
```


## 3. Induce chaos on Blue grader uses these endpoints; 
## I test the failover, and stimulated failure:

``` bash
curl -X POST "http://localhost:8081/chaos/start?mode=error"
# Response: {"error":"Simulated error activated"}
```

![](./Images/2.%20start-chaos.png)


##### Then immediately checked the Nginx endpoint:

``` bash
curl -i http://localhost:8080/version
# Expect 200 and headers:
# X-App-Pool: green
# X-Release-Id: green-v1
```


![](./Images/3.%20verify-err-r-switch2green.png)

This proves Nginx retried and sent the request to Green without returning an error to the client.


## 4. Stop chaos

``` bash
curl -X POST "http://localhost:8081/chaos/stop"
# Response: {"message":"Simulation stopped"}
```

![](./Images/4.%20stop-chaos.png)

Then validate `http://localhost:8080/version` returns Blue again (depending on fail_timeout and max_fails it may switch back).
`confirm recovery`

![](./Images/5.%20confirm-recover.png)


## 7. If you need to reload Nginx after changing ACTIVE_POOL inside container:

``` bash
# if you updated env or want to re-render template inside running container:
docker exec bg_nginx /etc/nginx/reload.sh
```

(But grader will set `.env` and re-run compose/exec as needed.)

## Additional tests I ran (grader-style loop)

I ran loops to ensure:

- `0 non-200` responses during the failover window

- ≥95% responses from Green while Blue was failing

``` bash
while true; do curl -s -I http://localhost:8080/version | awk '/X-App-Pool|X-Release-Id/ {print;} END {print "----"}'; sleep 0.5; done
# In another terminal:
curl -X POST http://localhost:8081/chaos/start?mode=error
sleep 5
curl -X POST http://localhost:8081/chaos/stop
```

## 7. Troubleshooting I encountered & how I fixed them

`docker-compose` **missing** — fixed by using `docker compose` (Compose V2) or installing Compose plugin / enabling Docker Desktop WSL integration.

**Port 8080 in use** — `ss/netstat` showed listening sockets. Determined Docker Desktop `(com.docker.backend.exe)` was binding `8080` on Windows. Options:

- Temporary: changed Nginx mapping to `8088:80` to continue testing.

- Later: stopped Jenkins or Docker Desktop when you needed 8080 and switched Compose back to `8080:80`.

**Vim E212 permission error** — fixed by `sudo chown $USER:$USER` <file> to take file ownership.

**Containers running but** `unhealthy` — checked `docker logs app_blue` and `app_green` and ensured proper healthcheck endpoint existed `(/healthz)` and correct `PORT` env vars were passed.

**SSH key permission error when connecting to EC2** — fixed with `chmod 400 project-key.pem.`
