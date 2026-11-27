mock_provider "aws" {
  mock_resource "aws_ses_domain_dkim" {
    defaults = { dkim_tokens = ["token-one", "token-two", "token-three"] }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/janitor-test" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a"] }
  }
}
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
  name              = "janitor-test"
  mail_domain       = "janitor.example.com"
  google_project_id = "janitor-test-project"
  nixos_ami         = "ami-0123456789abcdef0"
  ssh_key_name      = "test-only"
  ssh_source_cidr   = "203.0.113.1/32"
}

run "safe_defaults" {
  command = plan
  assert {
    condition     = !module.mail.receiving_activated
    error_message = "A default plan must not replace the account's active SES receiving rules."
  }
  assert {
    condition     = aws_instance.service.metadata_options[0].http_tokens == "required" && aws_instance.service.root_block_device[0].encrypted
    error_message = "The host must require IMDSv2 and encrypted storage."
  }
  assert {
    condition     = length(aws_security_group.service.ingress) == 1 && one(aws_security_group.service.ingress).from_port == 22 && length(one(aws_security_group.service.ingress).cidr_blocks) == 1 && contains(one(aws_security_group.service.ingress).cidr_blocks, "203.0.113.1/32")
    error_message = "The initial host may expose only restricted operator SSH."
  }
  assert {
    condition     = output.ready_for_processing == false
    error_message = "A successful infrastructure plan is not an application readiness check."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.runtime_model.policy).Statement[0].Resource == "arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-micro-v1:0" && jsondecode(aws_iam_role_policy.runtime_model.policy).Statement[0].Action == ["bedrock:InvokeModel"]
    error_message = "Use role credentials with only the exact configured Bedrock model permission."
  }
}

run "reject_public_ssh" {
  command = plan
  variables { ssh_source_cidr = "0.0.0.0/0" }
  expect_failures = [var.ssh_source_cidr]
}

run "reject_broad_ssh" {
  command = plan
  variables { ssh_source_cidr = "0.0.0.0/1" }
  expect_failures = [var.ssh_source_cidr]
}

run "reject_noncanonical_ssh" {
  command = plan
  variables { ssh_source_cidr = "203.0.113.1/24" }
  expect_failures = [var.ssh_source_cidr]
}

run "reject_wildcard_model" {
  command = plan
  variables { bedrock_model_id = "*" }
  expect_failures = [var.bedrock_model_id]
}

run "reject_cross_region_inference_profile" {
  command = plan
  variables { bedrock_model_id = "us.amazon.nova-micro-v1:0" }
  expect_failures = [var.bedrock_model_id]
}

run "reject_global_inference_profile" {
  command = plan
  variables { bedrock_model_id = "global.anthropic.claude-x" }
  expect_failures = [var.bedrock_model_id]
}

run "receiving_requires_explicit_opt_in" {
  command = plan
  variables { activate_receiving = true }
  assert {
    condition     = module.mail.receiving_activated
    error_message = "Explicit activation must produce exactly one receiving rule set assignment."
  }
}
