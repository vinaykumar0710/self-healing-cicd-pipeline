# Self-Healing CI/CD Deployment Pipeline

An automated CI/CD deployment system that detects failed releases, restores the previous known-good version, and verifies recovery with health checks.

## Overview

Traditional deployments can leave an application unavailable when a new release fails after deployment. This project implements a self-healing deployment workflow using Jenkins, Docker, PowerShell, and Nginx blue-green deployment.

The pipeline builds and tests a Flask application, deploys a candidate release, verifies its health, promotes it to production traffic, and automatically rolls back when post-promotion verification fails.

## Architecture

```text
Developer Push
      |
      v
 GitHub Repository
      |
      v
 Jenkins CI Pipeline
      |
      +---- Run automated tests
      |
      +---- Build Docker image
      |
      v
 Windows Deployment Agent
      |
      v
 Start isolated candidate
      |
      v
 Candidate health checks
      |
      +---- Unhealthy ---> Reject candidate
      |
      v
 Recreate inactive Blue/Green service
      |
      v
 Verify service health
      |
      v
 Update Nginx upstream
      |
      v
 Reload Nginx and verify release
      |
      +---- Failure ---> Automatic rollback
      |                       |
      |                       v
      |                Restore previous route
      |                Restore previous service
      |                Verify previous release
      |
      v
 Update deployment state
      |
      v
 Record deployment audit event
```

## Technology Stack

- **CI/CD:** Jenkins, GitHub
- **Containers:** Docker, Docker Compose
- **Deployment strategy:** Blue-green deployment
- **Reverse proxy:** Nginx
- **Automation:** PowerShell
- **Application:** Python, Flask
- **Testing:** Pytest
- **Observability:** HTTP health checks, deployment state, JSONL audit logs

## Key Features

### 1. Automated CI pipeline

- Checks out source code from GitHub.
- Creates an isolated Python virtual environment.
- Installs application and test dependencies.
- Executes automated tests.
- Builds and verifies a versioned Docker image.

### 2. Blue-green deployment

The application runs in two deployment slots: blue and green.

The deployment controller identifies the inactive slot, starts the candidate release, and validates its health before switching production traffic through Nginx.

This minimizes disruption during releases and keeps the existing production route unchanged until the candidate passes its pre-promotion checks.

### 3. Health-check retries

The controller retries health checks when an application is still starting or its endpoint is temporarily unavailable.

- Configurable retry count and delay.
- Candidate validation before promotion.
- Stable-service validation after recreation.
- Concise health-check failure messages.

### 4. Automatic rollback

If a failure occurs after traffic promotion, the controller attempts to:

1. Restore the previous Nginx upstream configuration.
2. Reload Nginx after validating its configuration.
3. Restore the inactive service's previous image and environment.
4. Restore the previous deployment-state record.
5. Verify that the previous release is serving healthy traffic.

The deployment is marked as critically failed if recovery cannot be fully verified.

### 5. Deployment audit trail

Each deployment attempt records a JSONL audit event containing:

- Commit SHA and candidate image.
- Candidate and previous deployment versions.
- Previous and candidate deployment colors.
- Deployment status.
- Rollback status.
- Start and finish timestamps.
- Error information, when applicable.

## Project Structure

```text
self-healing-cicd-pipeline/
├── app/
│   └── main.py
├── tests/
│   └── test_app.py
├── scripts/
│   └── deploy.ps1
├── proxy/
│   └── upstream.conf
├── logs/
│   └── deployments.jsonl
├── compose.yaml
├── Dockerfile
├── Jenkinsfile
├── requirements.txt
├── deployment-state.json
└── README.md
```

Runtime files such as `deployment-state.json`, `proxy/upstream.conf`, and `logs/deployments.jsonl` are maintained by the deployment controller. Their values can change during deployments and rollback operations.

## Prerequisites

- Git
- Docker Desktop with Linux containers enabled
- Docker Compose
- Python 3 and pip
- Jenkins
- A connected Windows Jenkins agent with PowerShell and Docker CLI access
- A GitHub repository accessible to Jenkins

The Jenkins controller and deployment agent must be configured so the deployment agent can access the required Docker daemon and runtime files.

## Local Setup

### 1. Clone the repository

```powershell
git clone https://github.com/vinaykumar0710/self-healing-cicd-pipeline.git
cd self-healing-cicd-pipeline
```

### 2. Start the application infrastructure

Ensure Docker Desktop is running, then start the Compose services:

```powershell
docker compose up -d
docker compose ps
```

Confirm that the application services and Nginx proxy are running before executing the deployment controller.

### 3. Run application tests

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python -m pytest -v
```

### 4. Verify the application

Check the production health endpoint:

```powershell
Invoke-RestMethod http://localhost:8080/health
```

Check the deployed version:

```powershell
Invoke-RestMethod http://localhost:8080/version
```

The health endpoint should report a healthy status, and the version endpoint should identify the currently deployed release.

## Jenkins Pipeline

Configure Jenkins to use the repository's `Jenkinsfile` and ensure the `windows-deployer` agent is online.

The pipeline includes the following stages:

1. **Checkout and Test** — retrieve the source and run automated tests.
2. **Build Docker Image** — build and inspect a versioned image.
3. **Deploy on Windows Agent** — execute the deployment controller, verify health, and promote the candidate.
4. **Post Actions** — report successful deployment or verified rollback.

The pipeline also supports the `SIMULATE_POST_PROMOTION_FAILURE` parameter for testing the recovery workflow.

## Testing Automatic Rollback

To test recovery without relying on a naturally occurring deployment failure:

1. Open the Jenkins job `self-healing-cicd-pipeline`.
2. Select **Build with Parameters**.
3. Enable `SIMULATE_POST_PROMOTION_FAILURE`.
4. Run the pipeline and inspect the console output.
5. Confirm that the injected failure is detected and the previous release is restored.
6. Verify the live health endpoint and compare its version with the previous known-good release.

The rollback test is considered successful only when recovery is verified. The expected injected failure may appear in the deployment logs even when Jenkins correctly reports the rollback test as successful.

## Verified Test Results

The following results were observed during project validation:

| Jenkins build | Scenario | Result |
|---|---|---|
| #13 | Normal deployment | Passed |
| #14 | Simulated post-promotion failure and rollback | Passed |

Build #13 deployed `build-13` to the green slot. Build #14 injected a failure after promotion and restored the previous healthy release, `build-13`.

The application test suite reported **4 passed tests** in both pipeline runs.

These results demonstrate successful deployment and recovery under the tested scenarios; they do not imply that every possible production failure has been covered.

## Configuration and Runtime State

The deployment controller uses:

- `deployment-state.json` to track the active color, active version, and last-known-good image.
- `proxy/upstream.conf` to configure the Nginx upstream.
- `logs/deployments.jsonl` to maintain deployment audit records.

Avoid manually editing runtime state while a deployment is in progress. Before committing changes, inspect `git status` and stage only the intended source files.

## Future Improvements

- Add build and deployment notifications.
- Publish structured deployment metrics and dashboards.
- Expand automated tests for rollback and failure scenarios.
- Add container image scanning and security checks.
- Integrate infrastructure provisioning and deployment configuration validation.
- Add retention and rotation policies for deployment audit logs.

## Author

**Vinaykumar Takankhar**

GitHub: https://github.com/vinaykumar0710
