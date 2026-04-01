# %% Configuration %%

locals {
  gcp_organization_prefix = "ms"
  app_base_name           = "hello-world"
  app_variant             = "gcs"
}

terraform {
  required_version = ">= 1.14"

  backend "gcs" {
    # bucket = <provided via command-line arguments>
    prefix = "apps/hello-world/gcs/foundation"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.25"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.11"
    }
  }
}

# %% Inputs %%

variable "shared_terraform_gcs_state_bucket_name" {
  description = "Shared Terraform GCS state bucket name."
  type        = string
}

variable "github_app_repo_name" {
  description = "GitHub app repository name."
  type        = string
}

variable "github_token" {
  description = "Organization-owned GitHub token used for setting Actions variables."
  type        = string
  sensitive   = true
}

# %% Remote common foundation state %%

data "terraform_remote_state" "shared_foundation_state" {
  backend = "gcs"

  config = {
    bucket = var.shared_terraform_gcs_state_bucket_name
    prefix = "shared/foundation"
  }
}

locals {
  gcp_organization_id                    = data.terraform_remote_state.shared_foundation_state.outputs.gcp_organization_id
  gcp_primary_location                   = data.terraform_remote_state.shared_foundation_state.outputs.gcp_primary_location
  gcp_primary_billing_account_id         = data.terraform_remote_state.shared_foundation_state.outputs.gcp_primary_billing_account_id
  gcp_github_workload_identity_pool_name = data.terraform_remote_state.shared_foundation_state.outputs.gcp_github_workload_identity_pool_name
  github_organization_name               = data.terraform_remote_state.shared_foundation_state.outputs.github_organization_name
}

# %% App GCP project %%

resource "random_id" "app_project_random_id" {
  byte_length = 4
}

locals {
  gcp_app_project_id = "${local.gcp_organization_prefix}-${local.app_base_name}-${random_id.app_project_random_id.hex}"
}

resource "google_project" "gcp_app_project" {
  org_id          = local.gcp_organization_id
  billing_account = local.gcp_primary_billing_account_id

  name       = "${local.app_base_name} - ${local.app_variant}"
  project_id = local.gcp_app_project_id

  auto_create_network = false
}

resource "google_billing_project_info" "primary_billing_info" {
  project         = local.gcp_app_project_id
  billing_account = local.gcp_primary_billing_account_id
}

provider "google" {
  project = local.gcp_app_project_id
  region  = local.gcp_primary_location
}

# Enable required GCP APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "firestore.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "orgpolicy.googleapis.com",
  ])

  project            = local.gcp_app_project_id
  service            = each.key
  disable_on_destroy = false

  depends_on = [google_billing_project_info.primary_billing_info]
}

# %%% GitHub Actions app-specific service account %%%

# App-specific service account for GitHub Actions CI/CD
resource "google_service_account" "github_actions_service_account" {
  project      = local.gcp_app_project_id
  account_id   = "github-actions"
  display_name = "App-specific GitHub Actions Service Account"
}

# Allow GitHub Actions to impersonate its dedicated service account
resource "google_service_account_iam_member" "github_actions_sa_wiu_member" {
  service_account_id = google_service_account.github_actions_service_account.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.gcp_github_workload_identity_pool_name}/attribute.repository/${local.github_organization_name}/${var.github_app_repo_name}"
}

# Grant GitHub Actions service account read-only access to the Terraform state bucket
resource "google_storage_bucket_iam_member" "github_actions_sa_list" {
  bucket = var.shared_terraform_gcs_state_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.github_actions_service_account.email}"
}

# Grant GitHub Actions service account full permissions inside the app's specific prefix.
resource "google_storage_bucket_iam_member" "github_actions_sa_object_admin_member" {
  bucket = var.shared_terraform_gcs_state_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.github_actions_service_account.email}"

  condition {
    title       = "app_prefix_only"
    description = "Allow read/write access to objects in the app prefix"
    expression  = "resource.name.startsWith('projects/_/buckets/${var.shared_terraform_gcs_state_bucket_name}/objects/apps/${local.app_base_name}/${local.app_variant}/')"
  }
}

# Grant GitHub Actions service account permissions to deploy Cloud Run
resource "google_project_iam_member" "github_actions_sa_run_admin_member" {
  project = local.gcp_app_project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.github_actions_service_account.email}"
}

# Grant GitHub Actions service account permissions to provision Firestore databases
resource "google_project_iam_member" "github_actions_sa_datastore_admin_member" {
  project = local.gcp_app_project_id
  role    = "roles/datastore.owner"
  member  = "serviceAccount:${google_service_account.github_actions_service_account.email}"
}

# Grant GitHub Actions service account permissions to push to Artifact Registry
resource "google_project_iam_member" "github_actions_sa_ar_writer_member" {
  project = local.gcp_app_project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions_service_account.email}"
}

# Grant GitHub Actions service account permissions to manage IAM policies (e.g. allow allUsers on Cloud Run)
resource "google_project_iam_member" "github_actions_sa_security_admin_member" {
  project = local.gcp_app_project_id
  role    = "roles/iam.securityAdmin"
  member  = "serviceAccount:${google_service_account.github_actions_service_account.email}"
}

# Override org policy to allow allUsers/allAuthenticatedUsers IAM members in this project (needed for public Cloud Run)
resource "google_project_organization_policy" "allow_all_iam_members" {
  project    = local.gcp_app_project_id
  constraint = "iam.allowedPolicyMemberDomains"

  restore_policy {
    default = true
  }

  depends_on = [
    google_project_service.apis["cloudresourcemanager.googleapis.com"],
    google_project_service.apis["orgpolicy.googleapis.com"],
  ]
}

# %%% Cloud Run app service account %%%

# Service account for the application (used by Cloud Run)
resource "google_service_account" "app_service_account" {
  project      = local.gcp_app_project_id
  account_id   = "${local.app_base_name}-app"
  display_name = "Hello World App Service Account"
}

# Grant app service account Firestore access
resource "google_project_iam_member" "app_sa_datastore_user_member" {
  project = local.gcp_app_project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.app_service_account.email}"
}

# Grant GitHub Actions service account permissions to act as the app service account
resource "google_service_account_iam_member" "github_actions_sa_sau_member" {
  service_account_id = google_service_account.app_service_account.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.github_actions_service_account.email}"
}

# %%% Artifact Registry repository %%%

# Artifact Registry repository for container images (prerequisite for CI/CD)
resource "google_artifact_registry_repository" "app_repository" {
  project       = local.gcp_app_project_id
  location      = local.gcp_primary_location
  repository_id = "app"
  format        = "DOCKER"
  description   = "Docker repository for the app images"

  depends_on = [google_project_service.apis["artifactregistry.googleapis.com"]]
}

locals {
  app_partial_image_reference = google_artifact_registry_repository.app_repository.registry_uri # this is not URI
  app_registry_hostname       = split("/", local.app_partial_image_reference)[0]
}

# %% Project-specific GitHub variables %%

provider "github" {
  owner = local.github_organization_name
  token = var.github_token
}

resource "github_actions_variable" "gh_ci_service_account_email_var" {
  repository    = var.github_app_repo_name
  variable_name = "GCP_CI_SERVICE_ACCOUNT_EMAIL"
  value         = google_service_account.github_actions_service_account.email
}

resource "github_actions_variable" "gh_app_registry_hostname_var" {
  repository    = var.github_app_repo_name
  variable_name = "APP_REGISTRY_HOSTNAME"
  value         = local.app_registry_hostname
}

resource "github_actions_variable" "gh_app_partial_image_reference_var" {
  repository    = var.github_app_repo_name
  variable_name = "APP_PARTIAL_IMAGE_REFERENCE"
  value         = local.app_partial_image_reference
}

# %% Outputs %%

output "gcp_primary_location" {
  value = local.gcp_primary_location
}

output "gcp_app_project_id" {
  value = local.gcp_app_project_id
}

output "gcp_ci_service_account_email" {
  value = google_service_account.github_actions_service_account.email
}

output "gcp_app_service_account_email" {
  value = google_service_account.app_service_account.email
}

output "app_partial_image_reference" {
  value = local.app_partial_image_reference
}
