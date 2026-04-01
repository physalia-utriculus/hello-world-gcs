# %% Configuration %%

locals {
  app_base_name = "hello-world"
  app_variant   = "gcs"
}

terraform {
  required_version = ">= 1.14"

  backend "gcs" {
    # bucket = <provided via command-line arguments>
    prefix = "apps/hello-world/gcs/support"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.25"
    }
  }
}

# %% Inputs %%

variable "shared_terraform_gcs_state_bucket_name" {
  description = "Shared Terraform GCS state bucket name."
  type        = string
}

variable "app_image_reference" {
  description = "Container image reference for the built app to deploy."
  type        = string
}

# %% Remote app foundation state %%

data "terraform_remote_state" "app_foundation_state" {
  backend = "gcs"

  config = {
    bucket = var.shared_terraform_gcs_state_bucket_name
    prefix = "apps/${local.app_base_name}/${local.app_variant}/foundation"
  }
}

locals {
  gcp_primary_location          = data.terraform_remote_state.app_foundation_state.outputs.gcp_primary_location
  gcp_app_project_id            = data.terraform_remote_state.app_foundation_state.outputs.gcp_app_project_id
  gcp_app_service_account_email = data.terraform_remote_state.app_foundation_state.outputs.gcp_app_service_account_email
}

# %% App GCP project setup %%

provider "google" {
  project = local.gcp_app_project_id
  region  = local.gcp_primary_location
}

# Cloud Storage bucket for app data
resource "google_storage_bucket" "app_bucket" {
  name          = "${local.gcp_app_project_id}-app-data"
  location      = local.gcp_primary_location
  force_destroy = true

  uniform_bucket_level_access = true
}

# Grant app service account read/write access to the app bucket
resource "google_storage_bucket_iam_member" "app_sa_bucket_object_admin" {
  bucket = google_storage_bucket.app_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.gcp_app_service_account_email}"
}

# Cloud Run service
resource "google_cloud_run_v2_service" "app_service" {
  name     = "hello-world"
  location = local.gcp_primary_location

  template {
    service_account = local.gcp_app_service_account_email

    containers {
      image = var.app_image_reference

      ports {
        container_port = 8080
      }

      env {
        name  = "GCS_BUCKET_NAME"
        value = google_storage_bucket.app_bucket.name
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

# Allow unauthenticated access to Cloud Run
resource "google_cloud_run_v2_service_iam_member" "public" {
  project  = local.gcp_app_project_id
  location = local.gcp_primary_location
  name     = google_cloud_run_v2_service.app_service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# %% Outputs %%

output "service_url" {
  value = google_cloud_run_v2_service.app_service.uri
}
