terraform {
  required_version = ">= 1.11, < 2.0"
  required_providers {
    google      = { source = "hashicorp/google", version = "= 8.12.0" }
    google-beta = { source = "hashicorp/google-beta", version = "= 8.12.0" }
  }
}

variable "project_id" { type = string }
variable "name" { type = string }
variable "aws_account_id" { type = string }
variable "aws_runtime_role_name" { type = string }

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

resource "google_iam_workload_identity_pool" "aws" {
  project                   = var.project_id
  workload_identity_pool_id = "${var.name}-aws"
  display_name              = "Email Janitor AWS host"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "aws" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.aws.workload_identity_pool_id
  workload_identity_pool_provider_id = "aws-ec2"
  attribute_mapping = {
    "google.subject"     = "assertion.arn"
    "attribute.account"  = "assertion.account"
    "attribute.aws_role" = "assertion.arn.extract('assumed-role/{role_name}/')"
  }
  attribute_condition = "assertion.arn.startsWith('arn:aws:sts::${var.aws_account_id}:assumed-role/${var.aws_runtime_role_name}/')"
  aws { account_id = var.aws_account_id }
}

resource "google_service_account_iam_member" "federated_host" {
  service_account_id = google_service_account.consumer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.aws.name}/attribute.aws_role/${var.aws_runtime_role_name}"
}

output "topic" { value = google_pubsub_topic.gmail.id }
output "subscription" { value = google_pubsub_subscription.gmail.id }
output "dead_letter_subscription" { value = google_pubsub_subscription.dead_letters.id }
output "consumer_service_account" { value = google_service_account.consumer.email }
output "workload_identity_provider" { value = google_iam_workload_identity_pool_provider.aws.name }
