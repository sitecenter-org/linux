# SiteCenter Kubernetes Monitoring

Add SiteCenter monitoring to your Kubernetes deployments with a simple init container.

## Overview

This solution adds monitoring to any Kubernetes deployment by including an init container that downloads and configures the SiteCenter monitoring script before your application starts.

## Quick Start

Add the following init container to your existing `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: your-app
spec:
  template:
    spec:
      initContainers:
      - name: sitecenter-setup
        image: alpine/curl:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          wget -O /tmp/add-monitoring.sh https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/k8s/add-monitoring.sh
          chmod +x /tmp/add-monitoring.sh
          /tmp/add-monitoring.sh
        env:
        - name: SITECENTER_ACCOUNT_CODE
          value: "your-account-code"
        - name: SITECENTER_MONITOR_CODE
          value: "your-monitor-code"
        - name: SITECENTER_SECRET_CODE
          value: "your-secret-code"
        - name: APP_NAME
          value: "your-app-name"
        - name: SITECENTER_INTERVAL
          value: "300"
        - name: MONITORING_MODE
          value: "cron"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
      
      containers:
      # Your existing containers remain unchanged
      - name: your-app
        image: your-app:latest
```

## Configuration

### Required Environment Variables

Replace these values with your SiteCenter credentials:

| Variable | Description |
|----------|-------------|
| `SITECENTER_ACCOUNT_CODE` | Your SiteCenter account code |
| `SITECENTER_MONITOR_CODE` | Your monitor code |
| `SITECENTER_SECRET_CODE` | Your secret code |
| `APP_NAME` | Descriptive name for your application |

### Optional Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SITECENTER_INTERVAL` | `300` | Monitoring interval in seconds |
| `MONITORING_MODE` | `cron` | Monitoring mode: `cron`, `daemon`, or `oneshot` |

### Kubernetes Metadata

The following environment variables are automatically populated using the Kubernetes downward API:

- `POD_NAME` - Current pod name
- `POD_NAMESPACE` - Current namespace
- `NODE_NAME` - Node where pod is running

## Complete Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-server
  labels:
    app: web-server
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-server
  template:
    metadata:
      labels:
        app: web-server
    spec:
      initContainers:
      - name: sitecenter-setup
        image: alpine/curl:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          wget -O /tmp/add-monitoring.sh https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/k8s/add-monitoring.sh
          chmod +x /tmp/add-monitoring.sh
          /tmp/add-monitoring.sh
        env:
        - name: SITECENTER_ACCOUNT_CODE
          value: "SC123456"
        - name: SITECENTER_MONITOR_CODE
          value: "MON789"
        - name: SITECENTER_SECRET_CODE
          value: "SECRET123ABC"
        - name: APP_NAME
          value: "web-server"
        - name: SITECENTER_INTERVAL
          value: "300"
        - name: MONITORING_MODE
          value: "cron"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
      
      containers:
      - name: web-server
        image: nginx:alpine
        ports:
        - containerPort: 80
```

## Deployment

1. Update your deployment YAML file with the init container configuration
2. Apply the changes:

```bash
kubectl apply -f deployment.yaml
```

3. Verify the deployment:

```bash
kubectl get pods -l app=your-app
```

## Verification

Check that monitoring was set up correctly:

```bash
# View init container logs
kubectl logs deployment/your-app -c sitecenter-setup

# Verify monitoring files exist
kubectl exec deployment/your-app -- ls -la /opt/sitecenter/

# Check cron jobs were created
kubectl exec deployment/your-app -- crontab -l

# Test monitoring manually
kubectl exec deployment/your-app -- /opt/sitecenter/k8s-monitor.sh
```

## How It Works

1. **Init Container Runs**: Before your main application starts, the `sitecenter-setup` init container executes
2. **Script Download**: Downloads the monitoring setup script from the SiteCenter GitHub repository
3. **Monitoring Setup**: Configures monitoring with cron jobs, installs required packages, and creates monitoring scripts
4. **Application Starts**: Your main application container starts with monitoring already configured and running

## Troubleshooting

### Init Container Fails

Check the init container logs for errors:

```bash
kubectl logs deployment/your-app -c sitecenter-setup
```

Common issues:
- Network connectivity to GitHub
- Invalid SiteCenter credentials
- Missing wget/curl in base image

### Monitoring Not Active

1. Check if monitoring processes are running:

```bash
kubectl exec deployment/your-app -- ps aux | grep -E "(cron|monitor)"
```

2. Verify cron jobs exist:

```bash
kubectl exec deployment/your-app -- crontab -l
```

3. Check for monitoring errors:

```bash
kubectl exec deployment/your-app -- cat /tmp/sitecenter-error.log
```

4. Test monitoring manually:

```bash
kubectl exec deployment/your-app -- /opt/sitecenter/k8s-monitor.sh "account-code" "monitor-code" "secret-code"
```

## Requirements

- Kubernetes cluster with internet access
- Containers must support cron (most Linux-based images do)
- SiteCenter account with valid credentials

## Security Considerations

- Credentials are passed as environment variables
- Init container requires network access to download scripts
- Monitoring runs with container user permissions
- No persistent storage or external volumes required