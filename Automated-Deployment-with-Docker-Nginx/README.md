# Automated Deployment With Docker and Nginx

## 🪜 Step 1 — Set Up Your Working Environmen
Tools used:
- VS Code – to write and edit scripts locally
- Ubuntu (WSL) – as the main DevOps terminal
- GitHub – for version control and repository hosting
- AWS EC2 Ubuntu Server – as the remote deployment target

### Create a folder on Ubuntu `mkdir deployment-project` and `Cd` into it

- navigate to vscode through ubuntu with this cmd `code .`

## ⚙️ Step 2 — Create and Initialize Your Repository

1. On GitHub → created repo deployment-project and clone it to your local machine and `cd` into the clone repo.

2. Add a simple `index.html` page

``` bash
<!DOCTYPE html>
<html>
<head><title>DevOps Stage 1</title></head>
<body>
  <h1>Welcome to DevOps Stage 1 – Sandra Olisama</h1>
  <p>Successfully Deployed on AWS EC2</p>
  <p>Deployed: $(date)</p>
</body>
</html>
```

3. Added a Dockerfile to containerize the app:

``` bash
# Use official Nginx base image
FROM nginx:latest

# Copy your static web file into the Nginx default HTML directory
COPY index.html /usr/share/nginx/html/index.html

# Expose port 80 for web traffic
EXPOSE 80

# Run Nginx in the foreground
CMD ["nginx", "-g", "daemon off;"]
```

## 🐳 Step 3 — Build and Test Docker Container Locally 
NB: you can use 8080:80 if the port is available

``` bash
docker build -t test-app .
docker run -d -p 8081:80 test-app
```

✅ Confirmed “Welcome to Nginx” (and later custom HTML) worked at http://localhost:8081.


## 🖥️ Step 4 — Connect to Remote Server (EC2)

- Launched Ubuntu EC2 instance in AWS.
allow SSH (22) HTTP (80) and HTTPS (443)
- Connected via SSH: 

``` bash
ssh -i ~/.ssh/project-key.pem ubuntu@<public-ip>
```

## 🔐 Step 5 — Initial Deploy Script Setup

- Created `deploy.sh` inside `~/deploy-project`and make it executable

``` bash
vi deploy.sh
chmod +x deploy.sh
```

## 🧩 Step 6 — Enhance deploy.sh with All these Requirements according to the instruction.

### The script should have all these:

- #!/bin/bash (shebang)
- Logging to timestamped .log file
- Error handling (set -e, trap)
- Parameter collection (repo URL, branch, SSH host & user)
- SSH connectivity check
- Docker & Nginx installation on server
- Docker build and run (idempotent)
- Nginx reverse proxy setup to forward port 80 → 8080
- Deployment validation (checks via curl and systemctl)

``` bash
#!/bin/bash

# Stage 1 DevOps Project - Automated Deployment Script

set -e
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "[ERROR] Something failed. Check $LOG_FILE for details." >&2' ERR

echo "============================================"
echo "[INFO] Starting Automated Deployment Script"
echo "============================================"

# === 1. Collect User Inputs ===
read -p "Enter Git Repository URL (default: https://github.com/Sandraolis/deployment-project.git): " GIT_URL
GIT_URL=${GIT_URL:-https://github.com/Sandraolis/deployment-project.git}

read -p "Enter branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter remote SSH username: " SSH_USER
read -p "Enter remote host IP or DNS: " SSH_HOST
read -p "Enter SSH port (default: 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

echo "[INFO] Git: $GIT_URL | Branch: $BRANCH"
echo "[INFO] Target Server: $SSH_USER@$SSH_HOST:$SSH_PORT"

# === 2. Validate SSH Connectivity ===
echo "[INFO] Checking SSH connectivity..."
if ssh -o BatchMode=yes -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "echo connected" >/dev/null 2>&1; then
    echo "[INFO] SSH connection successful!"
else
    echo "[ERROR] SSH connection failed. Exiting."
    exit 1
fi

# === 3. Clone or Update Repo ===
if [ -d "deployment-project" ]; then
    echo "[INFO] Repository exists. Pulling latest changes..."
    cd deployment-project && git pull origin "$BRANCH" && cd ..
else
    echo "[INFO] Cloning repository..."
    git clone -b "$BRANCH" "$GIT_URL"
fi

# === 4. Transfer Files to Remote Server ===
echo "[INFO] Copying files to remote server..."
scp -P "$SSH_PORT" -r deployment-project "$SSH_USER@$SSH_HOST:~/deployment-project"

# === 5. Server Preparation ===
echo "[INFO] Preparing server (Docker + Nginx)..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
echo "[REMOTE] Updating packages..."
sudo apt-get update -y

echo "[REMOTE] Installing Docker..."
sudo apt-get install -y docker.io
sudo systemctl enable docker
sudo usermod -aG docker $USER

echo "[REMOTE] Installing Nginx..."
sudo apt-get install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx
EOF

# === 6. Docker Deployment (Idempotent) ===
echo "[INFO] Deploying Docker container..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
cd ~/deployment-project

# Stop and remove old container if exists
if sudo docker ps -a --format '{{.Names}}' | grep -q "myapp"; then
    echo "[REMOTE] Stopping old container..."
    sudo docker stop myapp || true
    sudo docker rm myapp || true
fi

# Build new image
echo "[REMOTE] Building Docker image..."
sudo docker build -t myapp .

# Run container
echo "[REMOTE] Starting container on port 8080..."
sudo docker run -d --name myapp -p 8080:80 myapp
EOF

# === 7. Configure Nginx Reverse Proxy ===
echo "[INFO] Configuring Nginx reverse proxy..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
sudo bash -c 'cat > /etc/nginx/sites-available/default <<NGINXCONF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # SSL placeholder for future use
    # ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;
    # ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;
}
NGINXCONF'

echo "[REMOTE] Testing and reloading Nginx..."
sudo nginx -t
sudo systemctl reload nginx
EOF

# === 8. Deployment Validation ===
echo "[INFO] Running deployment validation..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" bash <<'EOF'
set -e
echo "[REMOTE] Checking Docker container status..."
sudo docker ps | grep myapp && echo "[REMOTE] Docker container running."

echo "[REMOTE] Checking Nginx service..."
sudo systemctl status nginx | grep active && echo "[REMOTE] Nginx is active."

echo "[REMOTE] Performing curl check..."
curl -I http://localhost | grep "200 OK" && echo "[REMOTE] App responding successfully."
EOF

# === 9. Cleanup & Idempotency ===
echo "[INFO] Cleaning up temporary files..."
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "sudo docker system prune -f >/dev/null 2>&1 || true"

echo "[SUCCESS]  Deployment Completed Successfully!"
echo "[INFO] Log file: $LOG_FILE"
```

## 🧱 Step 7 — Commit and Push to GitHub

``` bash
git add deploy.sh
git commit -m "Added automated deployment script"
git push -u origin main
```

## Step 8 — Run and Validate Deployment

1. Executed locally

```bash
./deploy.sh
```

2. Provided prompts, when you execute the script (./deploy.sh)

``` bash
Repository URL → https://github.com/Sandraolis/deployment-project.git
Branch → main
Remote User → ubuntu
Remote Host → <your EC2 IP>
Port → 22
```

3. Verified steps in log: if these were executed.

- Repo cloned to server
- Docker & Nginx installed
- Container built and running
- Nginx proxy configured
- Validation checks successful

✅ Visit ur browser and paste ur EC2 public IP Address. http://<EC2-IP> to display your custom page.

## Step 9 Check your project repository to confirm if what you pushed was pushed successfully, and it should look like this tree

``` bash
deployment-project/
 ├─ Dockerfile
 ├─ index.html
 ├─ deploy.sh
 ├─ deploy_*.log
 └─ README.md   (to document my setup)
```








