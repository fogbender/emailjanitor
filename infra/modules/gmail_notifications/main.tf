terraform {
  required_version = ">= 1.11, < 2.0"
  required_providers {
    google      = { source = "hashicorp/google", version = "= 8.12.0" }
    google-beta = { source = "hashicorp/google-beta", version = "= 8.12.0" }
  }
}

variable "project_id" { type = string }
variable "name" { type = string }
variable "aws_account_id" {
  type    = string
  default = null
  validation {
    condition = var.azure_identity == null ? (
      can(regex("^[0-9]{12}$", var.aws_account_id)) &&
      can(regex("^[A-Za-z0-9_+=,.@-]{1,64}$", var.aws_runtime_role_name))
    ) : (var.aws_account_id == null && var.aws_runtime_role_name == null)
    error_message = "Configure exactly one host identity: an AWS account/role or the Azure managed identity, never both."
  }
}
variable "aws_runtime_role_name" {
  type    = string
  default = null
}
variable "azure_identity" {
  type        = object({ tenant_id = string, object_id = string, client_id = string, audience = string })
  default     = null
  description = "Dedicated SaaS managed identity and its dedicated Azure app audience; not an OAuth secret or user credential."
  validation {
    condition = var.azure_identity == null ? true : (
      alltrue([for id in [var.azure_identity.tenant_id, var.azure_identity.object_id, var.azure_identity.client_id] :
      can(regex("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", id))]) &&
      can(regex("^api://[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", var.azure_identity.audience))
    )
    error_message = "Azure federation requires canonical GUIDs and the dedicated api://application-client-id audience."
  }
}

locals { azure = var.azure_identity != null }

resource "google_project_service" "apis" {
  for_each = toset(["gmail.googleapis.com", "pubsub.googleapis.com", "iam.googleapis.com",
  "cloudresourcemanager.googleapis.com", "iamcredentials.googleapis.com", "sts.googleapis.com"])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_pubsub_topic" "gmail" {
  project    = var.project_id
  name       = "${var.name}-gmail"
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic_iam_member" "gmail_publish" {
  project = var.project_id
  topic   = google_pubsub_topic.gmail.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:gmail-api-push@system.gserviceaccount.com"
}

resource "google_project_service_identity" "pubsub" {
  provider   = google-beta
  project    = var.project_id
  service    = "pubsub.googleapis.com"
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "dead_letters" {
  project                    = var.project_id
  name                       = "${var.name}-gmail-dead-letters"
  message_retention_duration = "86400s"
  depends_on                 = [google_project_service.apis]
}

resource "google_pubsub_subscription" "dead_letters" {
  project                    = var.project_id
  name                       = "${var.name}-gmail-dead-letters"
  topic                      = google_pubsub_topic.dead_letters.id
  message_retention_duration = "86400s"
  expiration_policy { ttl = "" }
}

resource "google_pubsub_topic_iam_member" "dead_letter_publish" {
  project = var.project_id
  topic   = google_pubsub_topic.dead_letters.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_project_service_identity.pubsub.email}"
}

resource "google_pubsub_subscription" "gmail" {
  project                    = var.project_id
  name                       = "${var.name}-gmail"
  topic                      = google_pubsub_topic.gmail.id
  ack_deadline_seconds       = 120
  message_retention_duration = "604800s"
  expiration_policy { ttl = "" }
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letters.id
    max_delivery_attempts = 5
  }
  depends_on = [google_pubsub_topic_iam_member.dead_letter_publish,
  google_pubsub_subscription.dead_letters]
}

resource "google_pubsub_subscription_iam_member" "dead_letter_acknowledge" {
  project      = var.project_id
  subscription = google_pubsub_subscription.gmail.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_project_service_identity.pubsub.email}"
}

resource "google_pubsub_subscription_iam_member" "consume" {
  project      = var.project_id
  subscription = google_pubsub_subscription.gmail.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.consumer.email}"
}

resource "google_service_account" "consumer" {
  project      = var.project_id
  account_id   = "${var.name}-gmail"
  display_name = "Email Janitor Gmail notification consumer"
  depends_on   = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool" "host" {
  project                   = var.project_id
  workload_identity_pool_id = "${var.name}-${local.azure ? "azure" : "aws"}"
  display_name              = local.azure ? "Email Janitor Azure host" : "Email Janitor AWS host"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "host" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.host.workload_identity_pool_id
  workload_identity_pool_provider_id = local.azure ? "azure-managed-identity" : "aws-ec2"
  attribute_mapping = local.azure ? {
    "google.subject"      = "assertion.oid"
    "attribute.azure_oid" = "assertion.oid"
    "attribute.tenant"    = "assertion.tid"
    } : {
    "google.subject"     = "assertion.arn"
    "attribute.account"  = "assertion.account"
    "attribute.aws_role" = "assertion.arn.extract('assumed-role/{role_name}/')"
  }
  attribute_condition = local.azure ? "assertion.tid == '${var.azure_identity.tenant_id}' && assertion.oid == '${var.azure_identity.object_id}' && assertion.aud == '${var.azure_identity.audience}'" : "assertion.arn.startsWith('arn:aws:sts::${var.aws_account_id}:assumed-role/${var.aws_runtime_role_name}/')"
  dynamic "aws" {
    for_each = local.azure ? [] : [var.aws_account_id]
    content { account_id = aws.value }
  }
  dynamic "oidc" {
    for_each = local.azure ? [var.azure_identity] : []
    content {
      issuer_uri        = "https://sts.windows.net/${oidc.value.tenant_id}/"
      allowed_audiences = [oidc.value.audience]
    }
  }
}

# Keep existing AWS resource identities stable while naming the shared resource
# for the host rather than one cloud. Default AWS IDs/claims are unchanged.
moved {
  from = google_iam_workload_identity_pool.aws
  to   = google_iam_workload_identity_pool.host
}
moved {
  from = google_iam_workload_identity_pool_provider.aws
  to   = google_iam_workload_identity_pool_provider.host
}

resource "google_service_account_iam_member" "federated_host" {
  service_account_id = google_service_account.consumer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.azure ? "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.host.name}/attribute.azure_oid/${var.azure_identity.object_id}" : "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.host.name}/attribute.aws_role/${var.aws_runtime_role_name}"
}

output "topic" { value = google_pubsub_topic.gmail.id }
output "subscription" { value = google_pubsub_subscription.gmail.id }
output "dead_letter_subscription" { value = google_pubsub_subscription.dead_letters.id }
output "consumer_service_account" { value = google_service_account.consumer.email }
output "workload_identity_provider" { value = google_iam_workload_identity_pool_provider.host.name }
output "external_account_configuration" {
  description = "Non-secret configuration for the pinned official Google auth SDK helper."
  value = {
    type                              = "external_account"
    audience                          = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.host.name}"
    token_url                         = "https://sts.googleapis.com/v1/token"
    subject_token_type                = local.azure ? "urn:ietf:params:oauth:token-type:jwt" : "urn:ietf:params:aws:token-type:aws4_request"
    service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${google_service_account.consumer.email}:generateAccessToken"
    service_account_impersonation     = { token_lifetime_seconds = 3600 }
    credential_source = jsondecode(local.azure ? jsonencode({
      url     = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&client_id=${var.azure_identity.client_id}&resource=${urlencode(var.azure_identity.audience)}"
      headers = { Metadata = "True" }
      format  = { type = "json", subject_token_field_name = "access_token" }
      }) : jsonencode({
      environment_id                 = "aws1"
      region_url                     = "http://169.254.169.254/latest/meta-data/placement/availability-zone"
      url                            = "http://169.254.169.254/latest/meta-data/iam/security-credentials"
      regional_cred_verification_url = "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"
      imdsv2_session_token_url       = "http://169.254.169.254/latest/api/token"
    }))
  }
}
