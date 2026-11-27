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
  name       = "janitor-test"
  project_id = "janitor-test-project"
  azure_identity = {
    tenant_id = "11111111-1111-1111-1111-111111111111"
    object_id = "22222222-2222-2222-2222-222222222222"
    client_id = "33333333-3333-3333-3333-333333333333"
    audience  = "api://44444444-4444-4444-4444-444444444444"
  }
}

run "exact_azure_managed_identity" {
  command = plan
  override_resource {
    target = google_iam_workload_identity_pool.host
    values = { name = "projects/123456789012/locations/global/workloadIdentityPools/janitor-test-azure" }
  }
  override_resource {
    target = google_iam_workload_identity_pool_provider.host
    values = { name = "projects/123456789012/locations/global/workloadIdentityPools/janitor-test-azure/providers/azure-managed-identity" }
  }
  assert {
    condition = (
      length(google_iam_workload_identity_pool_provider.host.aws) == 0 &&
      length(google_iam_workload_identity_pool_provider.host.oidc) == 1 &&
      one(google_iam_workload_identity_pool_provider.host.oidc).issuer_uri == "https://sts.windows.net/11111111-1111-1111-1111-111111111111/" &&
      toset(one(google_iam_workload_identity_pool_provider.host.oidc).allowed_audiences) == toset(["api://44444444-4444-4444-4444-444444444444"]) &&
      google_iam_workload_identity_pool_provider.host.attribute_condition == "assertion.tid == '11111111-1111-1111-1111-111111111111' && assertion.oid == '22222222-2222-2222-2222-222222222222' && assertion.aud == 'api://44444444-4444-4444-4444-444444444444'"
    )
    error_message = "Only the exact tenant, managed identity object and dedicated audience may federate; never an AWS provider or an unscoped Azure tenant."
  }
  assert {
    condition = (
      google_iam_workload_identity_pool_provider.host.attribute_mapping["google.subject"] == "assertion.oid" &&
      google_service_account_iam_member.federated_host.member == "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/janitor-test-azure/attribute.azure_oid/22222222-2222-2222-2222-222222222222" &&
      google_service_account_iam_member.federated_host.role == "roles/iam.workloadIdentityUser" &&
      google_pubsub_subscription_iam_member.consume.subscription == google_pubsub_subscription.gmail.name &&
      google_pubsub_subscription_iam_member.consume.role == "roles/pubsub.subscriber"
    )
    error_message = "Impersonation and consumption must remain scoped to this one identity/service account/subscription."
  }
  assert {
    condition = (
      output.external_account_configuration.type == "external_account" &&
      output.external_account_configuration.subject_token_type == "urn:ietf:params:oauth:token-type:jwt" &&
      output.external_account_configuration.audience == "//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/janitor-test-azure/providers/azure-managed-identity" &&
      output.external_account_configuration.token_url == "https://sts.googleapis.com/v1/token" &&
      output.external_account_configuration.service_account_impersonation.token_lifetime_seconds == 3600 &&
      output.external_account_configuration.service_account_impersonation_url == "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/janitor-test-gmail@janitor-test-project.iam.gserviceaccount.com:generateAccessToken" &&
      output.external_account_configuration.credential_source.url == "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&client_id=33333333-3333-3333-3333-333333333333&resource=api%3A%2F%2F44444444-4444-4444-4444-444444444444" &&
      output.external_account_configuration.credential_source.headers.Metadata == "True" &&
      output.external_account_configuration.credential_source.format.subject_token_field_name == "access_token"
    )
    error_message = "The SDK helper needs exact non-secret WIF/MI metadata with its audience and impersonation target bound."
  }
}

run "reject_mixed_cloud_authority" {
  command = plan
  variables {
    aws_account_id        = "123456789012"
    aws_runtime_role_name = "janitor-runtime"
  }
  expect_failures = [var.aws_account_id]
}

run "reject_arbitrary_azure_audience" {
  command = plan
  variables {
    azure_identity = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      object_id = "22222222-2222-2222-2222-222222222222"
      client_id = "33333333-3333-3333-3333-333333333333"
      audience  = "https://unrelated.example/token"
    }
  }
  expect_failures = [var.azure_identity]
}
