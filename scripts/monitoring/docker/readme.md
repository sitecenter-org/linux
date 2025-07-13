# Super Simple SiteCenter Monitoring

No complex Docker images, no script modifications, no base images. Just add monitoring to any existing container.
https://sitecenter.app - easy service to monitor your site.

## Method 1: Pure Sidecar (Zero Changes to Your App)

**Your existing docker-compose.yml:**
```yaml
services:
  my-app:
    image: my-existing-app:latest
    ports:
      - "8080:8080"
    # Your existing config stays exactly the same
```

**Just add this monitoring service:**
```yaml
  monitor:
    image: alpine:latest
    environment:
      - SITECENTER_ACCOUNT_CODE=abc123
      - SITECENTER_MONITOR_CODE=mon456
      - SITECENTER_SECRET_CODE=secret789
      - APP_NAME=my-app
    command: >
      sh -c '
        apk add --no-cache curl bash &&
        curl -sSL https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/docker/add-monitoring.sh | bash &&
        sleep infinity
      '
    restart: unless-stopped
```

**Total changes required: 0 to your existing app**

## Method 2: Modify Dockerfile CMD

**Your existing Dockerfile:**
```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY . .
RUN npm install
EXPOSE 3000
CMD ["npm", "start"]
```

**Modified Dockerfile:**
```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY . .
RUN npm install
EXPOSE 3000
# Change CMD to setup monitoring at runtime:
CMD ["sh", "-c", "curl -sSL https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/docker/add-monitoring.sh | bash && npm start"]
```

**Then run with environment variables:**
```bash
docker run -d \
  -e SITECENTER_ACCOUNT_CODE=abc123 \
  -e SITECENTER_MONITOR_CODE=mon456 \
  -e SITECENTER_SECRET_CODE=secret789 \
  my-app:latest
```

**Total changes: 1 line (the CMD)**

## Method 3: Runtime Setup (No Dockerfile Changes)

**Current docker run:**
```bash
docker run -d my-app:latest
```

**New docker run:**
```bash
docker run -d \
  -e SITECENTER_ACCOUNT_CODE=abc123 \
  -e SITECENTER_MONITOR_CODE=mon456 \
  -e SITECENTER_SECRET_CODE=secret789 \
  my-app:latest \
  sh -c 'curl -sSL https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/docker/add-monitoring.sh | bash && exec npm start'
```

**Total changes: 0 to your image**

## Method 4: Docker Compose Command Override

**Your existing docker-compose.yml:**
```yaml
services:
  app:
    image: my-app:latest
    ports:
      - "8080:8080"
```

**Modified version:**
```yaml
services:
  app:
    image: my-app:latest  # Same image
    ports:
      - "8080:8080"      # Same ports
    environment:          # Add env vars
      - SITECENTER_ACCOUNT_CODE=abc123
      - SITECENTER_MONITOR_CODE=mon456
      - SITECENTER_SECRET_CODE=secret789
    command: >            # Override command
      sh -c '
        curl -sSL https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/docker/add-monitoring.sh | bash &&
        exec npm start
      '
```

**Total changes: No image changes, just compose file**

## How It Works

The script downloads from GitHub:
1. **Downloads** the monitoring script from the official repository
2. **Installs** curl and cron if missing
3. **Sets up** a cron job to run every 5 minutes
4. **Tests** the connection once
5. **Exits** so your app can start normally

**The monitoring runs in the background automatically.**

## ⚠️ Important: Build-time vs Runtime

**Build-time (RUN commands)**: Execute when you build the image with `docker build`
- Environment variables from `docker run -e` are NOT available
- Cannot access runtime secrets

**Runtime (CMD/ENTRYPOINT)**: Execute when you start the container with `docker run`
- Environment variables from `docker run -e` are available
- Perfect for setup scripts that need configuration

**That's why we use CMD, not RUN, for the monitoring setup!**

## Which Method Should You Use?

- **Method 1 (Sidecar)**: If you want absolutely zero changes to existing apps
- **Method 2 (Dockerfile CMD)**: If you're rebuilding images and want built-in monitoring
- **Method 3 (Runtime)**: For testing or one-off containers
- **Method 4 (Compose)**: If you use docker-compose and want easy config

## Setup

1. **Set environment variables** with your SiteCenter credentials

2. **Choose your method** and apply

That's it! Your existing applications get monitoring with minimal effort.