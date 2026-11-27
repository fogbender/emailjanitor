mock_provider "aws" {
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:janitor-test-receipts" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:123456789012:janitor-test-mail" }
  }
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
    condition = (
      jsondecode(aws_kms_key.spool.policy).Statement[1].Principal.Service == "sns.amazonaws.com" &&
      toset(jsondecode(aws_kms_key.spool.policy).Statement[1].Action) == toset(["kms:GenerateDataKey", "kms:Decrypt"]) &&
      jsondecode(aws_kms_key.spool.policy).Statement[1].Condition.ArnEquals["aws:SourceArn"] == aws_sns_topic.receipts.arn &&
      jsondecode(aws_kms_key.spool.policy).Statement[1].Condition.StringEquals["kms:EncryptionContext:aws:sns:topicArn"] == aws_sns_topic.receipts.arn &&
      jsondecode(aws_kms_key.spool.policy).Statement[0].Principal.AWS == "arn:aws:iam::123456789012:root"
    )
    error_message = "SNS must use the custom key only for this account's exact receipt topic; IAM delegation must remain enabled."
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
    condition     = one(aws_ses_receipt_rule.mail.s3_action).topic_arn == aws_sns_topic.receipts.arn && aws_sns_topic_subscription.receipts.raw_message_delivery && aws_sqs_queue.mail.sqs_managed_sse_enabled && aws_sqs_queue.failed.sqs_managed_sse_enabled && aws_sns_topic.receipts.kms_master_key_id == aws_kms_key.spool.arn
    error_message = "SES receipt metadata must use the encrypted S3-action SNS→SQS path, excluding MIME content."
  }
  assert {
    condition     = jsondecode(aws_sqs_queue_policy.mail.policy).Statement[0].Condition.ArnEquals["aws:SourceArn"] == aws_sns_topic.receipts.arn && jsondecode(aws_sqs_queue_policy.mail.policy).Statement[1].Effect == "Deny" && jsondecode(aws_sqs_queue_policy.mail.policy).Statement[1].Condition.ArnNotEquals["aws:SourceArn"] == aws_sns_topic.receipts.arn
    error_message = "Only the SES receipt topic can inject messages, including when another IAM policy grants SendMessage."
  }
  assert {
    condition     = jsondecode(aws_sns_topic_policy.receipts.policy).Statement[0].Condition.ArnNotEquals["aws:PrincipalArn"] == aws_iam_role.ses_delivery.arn && jsondecode(aws_iam_role_policy.ses_delivery.policy).Statement[2].Resource == aws_sns_topic.receipts.arn && aws_sqs_queue.mail.message_retention_seconds == 5400 && aws_sqs_queue.failed.message_retention_seconds == 5400
    error_message = "Only the exact SES delivery role can publish bounded-retention receipt metadata."
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
