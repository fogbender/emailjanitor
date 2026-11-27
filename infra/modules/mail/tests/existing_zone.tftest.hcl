mock_provider "aws" {
  mock_resource "aws_sns_topic" { defaults = { arn = "arn:aws:sns:us-east-1:123456789012:janitor-test-receipts" } }
  mock_resource "aws_sqs_queue" { defaults = { arn = "arn:aws:sqs:us-east-1:123456789012:janitor-test-mail" } }
  mock_resource "aws_ses_domain_dkim" { defaults = { dkim_tokens = ["one", "two", "three"] } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/janitor-test" } }
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { region = "us-east-1", name = "us-east-1" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_route53_zone" {
    defaults = { zone_id = "ZEXISTINGJANITOR", name_servers = ["ns1.example.net", "ns2.example.net"] }
  }
}

variables {
  name                    = "janitor-test"
  mail_domain             = "janitor.example.com"
  runtime_role_name       = "janitor-runtime-test"
  existing_hosted_zone_id = "ZEXISTINGJANITOR"
}

run "reuse_exact_public_zone_without_replacing_nameservers_or_existing_records" {
  command = plan
  assert {
    condition     = data.aws_route53_zone.existing[0].name == "janitor.example.com" && !data.aws_route53_zone.existing[0].private_zone && length(aws_route53_zone.mail) == 0 && aws_route53_record.mx.zone_id == "ZEXISTINGJANITOR" && output.hosted_zone_id == "ZEXISTINGJANITOR"
    error_message = "An existing delegated zone must never be duplicated or replaced."
  }
  assert {
    condition     = !aws_route53_record.mx.allow_overwrite && !aws_route53_record.dmarc.allow_overwrite && !aws_route53_record.verification.allow_overwrite && alltrue([for r in aws_route53_record.dkim : !r.allow_overwrite])
    error_message = "Mail setup must refuse existing MX, DMARC, verification or DKIM records instead of overwriting another service."
  }
  assert {
    condition     = length(aws_ses_active_receipt_rule_set.mail) == 0 && output.name_servers == tolist(["ns1.example.net", "ns2.example.net"])
    error_message = "Zone reuse must not activate receiving or alter existing delegation."
  }
}

run "reject_different_hosted_zone_id" {
  command = plan
  override_data {
    target = data.aws_route53_zone.existing
    values = { zone_id = "ZDIFFERENT" }
  }
  expect_failures = [data.aws_route53_zone.existing]
}

run "reject_arn_instead_of_zone_id" {
  command = plan
  variables { existing_hosted_zone_id = "arn:aws:route53:::hostedzone/ZEXISTINGJANITOR" }
  expect_failures = [var.existing_hosted_zone_id]
}
