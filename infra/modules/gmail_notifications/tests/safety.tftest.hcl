mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email = "janitor-test-gmail@janitor-test-project.iam.gserviceaccount.com"
      name  = "projects/janitor-test-project/serviceAccounts/janitor-test-gmail@janitor-test-project.iam.gserviceaccount.com"
    }
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
