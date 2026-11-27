terraform {
  required_version = ">= 1.11, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "= 6.74.0" }
  }
}

variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.name))
    error_message = "Use 3–20 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "mail_domain" {
  type        = string
  description = "A dedicated domain/subdomain delegated to this module's new Route53 zone."
  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,63}$", var.mail_domain))
    error_message = "Provide a lowercase DNS name without a trailing dot."
  }
}

variable "runtime_role_name" { type = string }
variable "activate_receiving" {
  type        = bool
  default     = false
  description = "Opt in only after checking SES has no other active receiving rules to preserve."
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
  ruleset    = "${var.name}-mail"
  rule       = "receive"
  rule_arn   = "arn:${local.partition}:ses:${local.region}:${local.account_id}:receipt-rule-set/${local.ruleset}:receipt-rule/${local.rule}"
  sender     = "janitor@${var.mail_domain}"
}

resource "aws_route53_zone" "mail" {
  name = var.mail_domain
  tags = { Application = "Email Janitor" }
}

resource "aws_ses_domain_identity" "mail" { domain = var.mail_domain }
resource "aws_ses_domain_dkim" "mail" { domain = aws_ses_domain_identity.mail.domain }

resource "aws_route53_record" "verification" {
  zone_id = aws_route53_zone.mail.zone_id
  name    = "_amazonses.${var.mail_domain}"
  type    = "TXT"
  ttl     = 300
  records = [aws_ses_domain_identity.mail.verification_token]
}

resource "aws_route53_record" "dkim" {
  count   = 3
  zone_id = aws_route53_zone.mail.zone_id
  name    = "${aws_ses_domain_dkim.mail.dkim_tokens[count.index]}._domainkey.${var.mail_domain}"
  type    = "CNAME"
  ttl     = 300
  records = ["${aws_ses_domain_dkim.mail.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "mx" {
  zone_id = aws_route53_zone.mail.zone_id
  name    = var.mail_domain
  type    = "MX"
  ttl     = 300
  records = ["10 inbound-smtp.${local.region}.amazonaws.com"]
}

resource "aws_route53_record" "dmarc" {
  zone_id = aws_route53_zone.mail.zone_id
  name    = "_dmarc.${var.mail_domain}"
  type    = "TXT"
  ttl     = 300
  records = ["v=DMARC1; p=reject; adkim=s; aspf=r"]
}

resource "aws_kms_key" "spool" {
  description             = "Email Janitor temporary incoming mail"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_s3_bucket" "spool" {
  bucket        = "${var.name}-${local.account_id}-${local.region}-spool"
  force_destroy = false
  tags          = { EmailJanitorDataClass = "temporary-mail-spool" }
}

resource "aws_s3_bucket_public_access_block" "spool" {
  bucket                  = aws_s3_bucket.spool.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "spool" {
  bucket = aws_s3_bucket.spool.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.spool.arn
    }
    bucket_key_enabled = true
  }
}

# Versioning, replication and backup are deliberately absent. This is a transport
# spool, never an email archive. The app must delete immediately and sweep failed
# processing after a short bounded interval; S3 lifecycle is only a slower fallback.
resource "aws_s3_bucket_lifecycle_configuration" "spool" {
  bucket = aws_s3_bucket.spool.id
  rule {
    id     = "transport-fallback-expiry"
    status = "Enabled"
    filter { prefix = "incoming/" }
    expiration { days = 1 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_s3_bucket_policy" "spool" {
  bucket = aws_s3_bucket.spool.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyPlaintextTransport", Effect = "Deny", Principal = "*", Action = "s3:*"
      Resource  = [aws_s3_bucket.spool.arn, "${aws_s3_bucket.spool.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_sqs_queue" "failed" {
  name                      = "${var.name}-mail-failed"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "mail" {
  name                       = "${var.name}-mail"
  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = 300
  receive_wait_time_seconds  = 20
  message_retention_seconds  = 86400
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.failed.arn, maxReceiveCount = 5
  })
}

resource "aws_sqs_queue_policy" "mail" {
  queue_url = aws_sqs_queue.mail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow", Principal = { Service = "s3.amazonaws.com" }, Action = "sqs:SendMessage"
      Resource = aws_sqs_queue.mail.arn
      Condition = {
        ArnEquals    = { "aws:SourceArn" = aws_s3_bucket.spool.arn }
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

# S3 notifications contain only object references and event metadata, never MIME.
resource "aws_s3_bucket_notification" "mail" {
  bucket = aws_s3_bucket.spool.id
  queue {
    queue_arn     = aws_sqs_queue.mail.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "incoming/"
  }
  depends_on = [aws_sqs_queue_policy.mail]
}

resource "aws_iam_role" "ses_delivery" {
  name = "${var.name}-ses-delivery"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "ses.amazonaws.com" }, Action = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnEquals    = { "aws:SourceArn" = local.rule_arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ses_delivery" {
  role = aws_iam_role.ses_delivery.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.spool.arn}/incoming/*" },
      { Effect = "Allow", Action = ["kms:GenerateDataKey"], Resource = aws_kms_key.spool.arn }
    ]
  })
}

resource "aws_ses_receipt_rule_set" "mail" { rule_set_name = local.ruleset }

resource "aws_ses_receipt_rule" "mail" {
  name          = local.rule
  rule_set_name = aws_ses_receipt_rule_set.mail.rule_set_name
  recipients    = [local.sender]
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Require"
  s3_action {
    position          = 1
    bucket_name       = aws_s3_bucket.spool.id
    object_key_prefix = "incoming/"
    iam_role_arn      = aws_iam_role.ses_delivery.arn
    # No kms_key_arn here: SES client-side encryption needs a separate encryption
    # client. Bucket-default SSE-KMS is decryptable with normal GetObject.
  }
  depends_on = [aws_iam_role_policy.ses_delivery, aws_s3_bucket_server_side_encryption_configuration.spool,
  aws_s3_bucket_notification.mail]
}

resource "aws_ses_active_receipt_rule_set" "mail" {
  count         = var.activate_receiving ? 1 : 0
  rule_set_name = aws_ses_receipt_rule_set.mail.rule_set_name
  depends_on    = [aws_ses_receipt_rule.mail]
}

resource "aws_iam_role_policy" "runtime_mail" {
  role = var.runtime_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.spool.arn}/incoming/*" },
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.spool.arn,
      Condition = { StringLike = { "s3:prefix" = ["incoming/", "incoming/*"] } } },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = aws_kms_key.spool.arn },
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"],
      Resource = [aws_sqs_queue.mail.arn, aws_sqs_queue.failed.arn] },
      { Effect = "Allow", Action = ["ses:SendEmail", "ses:SendRawEmail"], Resource = aws_ses_domain_identity.mail.arn,
      Condition = { StringEquals = { "ses:FromAddress" = local.sender } } }
    ]
  })
}

output "name_servers" { value = aws_route53_zone.mail.name_servers }
output "sender" { value = local.sender }
output "spool_bucket" { value = aws_s3_bucket.spool.id }
output "queue_url" { value = aws_sqs_queue.mail.url }
output "kms_key_arn" { value = aws_kms_key.spool.arn }
output "receiving_activated" { value = var.activate_receiving }
