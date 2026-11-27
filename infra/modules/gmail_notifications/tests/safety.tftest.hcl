mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email = "janitor-test-gmail@janitor-test-project.iam.gserviceaccount.com"
      name  = "projects/janitor-test-project/serviceAccounts/janitor-test-gmail@janitor-test-project.iam.gserviceaccount.com"
    }
  }
}
mock_provider "google-beta" {
  mock_resource "google_project_service_identity" {
    defaults = { email = "service-123456789012@gcp-sa-pubsub.iam.gserviceaccount.com" }
  }
}

variables {
  name                  = "janitor-test"
  project_id            = "janitor-test-project"
  aws_account_id        = "123456789012"
  aws_runtime_role_name = "janitor-test-runtime"
}

run "private_persistent_notifications" {
  command = plan
  assert {
    condition     = length(google_pubsub_subscription.gmail.push_config) == 0 && one(google_pubsub_subscription.gmail.expiration_policy).ttl == ""
    error_message = "Use a persistent pull subscription without a public push endpoint."
  }
  assert {
    condition = (
      one(google_pubsub_subscription.gmail.dead_letter_policy).dead_letter_topic == google_pubsub_topic.dead_letters.id &&
      one(google_pubsub_subscription.gmail.dead_letter_policy).max_delivery_attempts == 5 &&
      google_pubsub_topic.dead_letters.message_retention_duration == "86400s" &&
      google_pubsub_subscription.dead_letters.message_retention_duration == "86400s" &&
      length(google_pubsub_subscription.dead_letters.push_config) == 0
    )
    error_message = "Poison notification hints must leave the source pull for a bounded-retention private dead-letter subscription."
  }
  assert {
    condition = (
      google_pubsub_topic_iam_member.dead_letter_publish.member == "serviceAccount:service-123456789012@gcp-sa-pubsub.iam.gserviceaccount.com" &&
      google_pubsub_topic_iam_member.dead_letter_publish.role == "roles/pubsub.publisher" &&
      google_pubsub_topic_iam_member.dead_letter_publish.topic == google_pubsub_topic.dead_letters.name &&
      google_pubsub_subscription_iam_member.dead_letter_acknowledge.member == google_pubsub_topic_iam_member.dead_letter_publish.member &&
      google_pubsub_subscription_iam_member.dead_letter_acknowledge.role == "roles/pubsub.subscriber" &&
      google_pubsub_subscription_iam_member.dead_letter_acknowledge.subscription == google_pubsub_subscription.gmail.name
    )
    error_message = "Only the Pub/Sub service agent gets resource-scoped forwarding and source-acknowledgement grants."
  }
  assert {
    condition     = google_pubsub_topic_iam_member.gmail_publish.member == "serviceAccount:gmail-api-push@system.gserviceaccount.com" && google_pubsub_topic_iam_member.gmail_publish.role == "roles/pubsub.publisher"
    error_message = "Only Gmail's publishing identity should receive the publisher grant."
  }
  assert {
    condition     = google_pubsub_subscription_iam_member.consume.role == "roles/pubsub.subscriber" && google_pubsub_subscription_iam_member.consume.member == "serviceAccount:janitor-test-gmail@janitor-test-project.iam.gserviceaccount.com"
    error_message = "The consumer needs only its subscription-scoped subscriber role."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.aws.attribute_condition == "assertion.arn.startsWith('arn:aws:sts::123456789012:assumed-role/janitor-test-runtime/')" && google_service_account_iam_member.federated_host.role == "roles/iam.workloadIdentityUser"
    error_message = "Federation must restrict the account and role, with no long-lived service-account keys."
  }
  assert {
    condition     = alltrue([for api in google_project_service.apis : !api.disable_on_destroy])
    error_message = "Removing Janitor must not disable shared Google project APIs."
  }
}
