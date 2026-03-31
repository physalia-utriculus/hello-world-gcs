# hello-world

A minimal Ktor application running on Google Cloud Run with Firestore persistence.

## Features

- **GET /** - Returns "Hello, World!"
- **POST /counter/increment** - Increments a counter in Firestore and returns the new value
- **GET /counter** - Returns the current counter value

## Local Development

```bash
cd code
./gradlew run
```

The application will start on port 8080.

## Building

```bash
cd code
./gradlew build           # Build and test
./gradlew :app:buildFatJar  # Build fat JAR for deployment
```

## Infrastructure

### Foundation Stack (`infra/foundation/`)

Creates resources requiring elevated permissions (run locally with high-privilege account):

- GCP APIs enablement
- App service account for Cloud Run
- GitHub Actions service account with Workload Identity Federation

```bash
cd infra/foundation
terraform init -backend-config="bucket=<TERRAFORM_STATE_BUCKET>"
terraform apply \
  -var="project_id=<PROJECT_ID>" \
  -var="github_org=<GITHUB_ORG>"
```

### Support Stack (`infra/support/`)

Creates supporting resources (run via GitHub Actions):

- Artifact Registry repository
- Firestore database
- Cloud Run service

### GitHub Actions Variables Required

Set these at repository or organization level:

| Variable | Description |
|----------|-------------|
| `GCP_PROJECT_ID` | GCP project ID |
| `TERRAFORM_GCS_STATE_BUCKET_NAME` | GCS bucket for Terraform state |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | WIF provider (from foundation output) |
| `GCP_SERVICE_ACCOUNT` | GitHub Actions service account email |
| `GCP_APP_SERVICE_ACCOUNT` | App service account email |

## API Usage

```bash
# Increment counter
curl -X POST https://<SERVICE_URL>/counter/increment

# Get current count
curl https://<SERVICE_URL>/counter
```
