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
}

variables {
  name              = "janitor-test"
  mail_domain       = "janitor.example.com"
  runtime_role_name = "janitor-runtime-test"
}

run "safe_transport_defaults" {
  command = plan
  assert {
    condition     = length(aws_ses_active_receipt_rule_set.mail) == 0
    error_message = "Do not replace active receiving rules by default."
  }
  assert {
    condition     = (one(aws_ses_receipt_rule.mail.s3_action).kms_key_arn == null || one(aws_ses_receipt_rule.mail.s3_action).kms_key_arn == "") && length(aws_ses_receipt_rule.mail.sns_action) == 0
    error_message = "No SES client-side encryption or full-body SNS delivery is allowed."
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.spool.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "Mail transport objects must use server-side KMS encryption."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.spool.block_public_acls && aws_s3_bucket_public_access_block.spool.block_public_policy && aws_s3_bucket_public_access_block.spool.restrict_public_buckets
    error_message = "The mail spool must not be public."
  }
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.spool.rule).expiration[0].days == 1 && !aws_s3_bucket.spool.force_destroy
    error_message = "The transport spool needs a fallback expiry and intentional uninstall cleanup."
  }
  assert {
    condition     = one(aws_s3_bucket_notification.mail.queue).filter_prefix == "incoming/" && aws_sqs_queue.mail.sqs_managed_sse_enabled && aws_sqs_queue.failed.sqs_managed_sse_enabled
    error_message = "Mail events must use encrypted metadata-only queues."
  }
  assert {
    condition     = aws_route53_record.mx.zone_id == aws_route53_zone.mail.zone_id && length(aws_route53_record.dkim) == 3
    error_message = "MX and DKIM belong only to the dedicated new mail zone."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.runtime_mail.policy).Statement[4].Resource == aws_ses_domain_identity.mail.arn && jsondecode(aws_iam_role_policy.runtime_mail.policy).Statement[4].Condition.StringEquals["ses:FromAddress"] == "janitor@janitor.example.com"
    error_message = "Sending must remain scoped to the Janitor domain identity and exact From address."
  }
}

run "explicit_receiving_activation" {
  command = plan
  variables { activate_receiving = true }
  assert {
    condition     = length(aws_ses_active_receipt_rule_set.mail) == 1
    error_message = "Explicit opt-in must manage exactly one active receipt set assignment."
  }
}
