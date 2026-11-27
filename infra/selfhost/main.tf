terraform {
  required_version = ">= 1.11, < 2.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "= 6.74.0" }
    google = { source = "hashicorp/google", version = "= 8.12.0" }
  }
}

provider "aws" { region = var.aws_region }
provider "google" { project = var.google_project_id }

variable "name" { type = string }
variable "aws_region" {
  type    = string
  default = "us-east-1"
  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "The v1 AWS reference deployment uses us-east-1 for SES and Bedrock."
  }
}
variable "bedrock_model_id" {
  type        = string
  default     = "amazon.nova-micro-v1:0"
  description = "One regional Bedrock foundation model, not an inference profile or wildcard."
  validation {
    condition = (can(regex("^[a-z0-9-]+\\.[a-zA-Z0-9.:-]+$", var.bedrock_model_id)) &&
    !can(regex("^(us|eu|apac|global|jp|au|ca|us-gov)\\.", var.bedrock_model_id)))
    error_message = "Provide a regional foundation-model ID without slashes, ARN prefixes or wildcards."
  }
}
variable "mail_domain" { type = string }
variable "google_project_id" { type = string }
variable "nixos_ami" {
  type        = string
  description = "Your prebuilt NixOS AMI containing the supplied release and nix/module.nix configuration."
  validation {
    condition     = can(regex("^ami-[0-9a-f]{8}([0-9a-f]{9})?$", var.nixos_ami))
    error_message = "Provide a NixOS AMI ID for the selected region. No disk conversion or image is built by apply."
  }
}
variable "ssh_key_name" { type = string }
variable "ssh_source_cidr" {
  type = string
  validation {
    condition = try(can(cidrnetmask(var.ssh_source_cidr)) &&
      tonumber(split("/", var.ssh_source_cidr)[1]) >= 24 &&
    cidrhost(var.ssh_source_cidr, 0) == split("/", var.ssh_source_cidr)[0], false)
    error_message = "Provide a canonical operator IPv4 CIDR between /24 and /32."
  }
}
variable "activate_receiving" {
  type    = bool
  default = false
}

data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
resource "aws_vpc" "service" {
  cidr_block           = "10.73.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}
resource "aws_internet_gateway" "service" { vpc_id = aws_vpc.service.id }
resource "aws_subnet" "service" {
  vpc_id                  = aws_vpc.service.id
  cidr_block              = "10.73.0.0/26"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  lifecycle { ignore_changes = [availability_zone] }
}
resource "aws_route_table" "service" {
  vpc_id = aws_vpc.service.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.service.id
  }
}
resource "aws_route_table_association" "service" {
  subnet_id      = aws_subnet.service.id
  route_table_id = aws_route_table.service.id
}
resource "aws_security_group" "service" {
  name   = var.name
  vpc_id = aws_vpc.service.id
  ingress {
    description = "Operator SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_source_cidr]
  }
  # Web access is intentionally absent until the single-user host's authentication
  # and TLS are implemented. Use an SSH tunnel for the initial local pilot.
  egress {
    description = "HTTPS cloud APIs and model endpoint"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["10.73.0.2/32"]
  }
}

resource "aws_iam_role" "runtime" {
  name = "${var.name}-runtime"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_instance_profile" "runtime" {
  name = "${var.name}-runtime"
  role = aws_iam_role.runtime.name
}
resource "aws_iam_role_policy" "runtime_model" {
  role = aws_iam_role.runtime.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["bedrock:InvokeModel"]
      Resource = "arn:${data.aws_partition.current.partition}:bedrock:${var.aws_region}::foundation-model/${var.bedrock_model_id}"
    }]
  })
}
resource "aws_instance" "service" {
  ami                    = var.nixos_ami
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.service.id
  vpc_security_group_ids = [aws_security_group.service.id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.runtime.name
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_size = 24
    volume_type = "gp3"
    encrypted   = true
  }
  tags = { Name = var.name, Application = "Email Janitor" }
  # Durable PostgreSQL state initially lives on this disk. App releases are
  # updated on the running NixOS host, not by silently replacing its AMI.
  lifecycle { prevent_destroy = true }
}

module "mail" {
  source             = "../modules/mail"
  name               = var.name
  mail_domain        = var.mail_domain
  runtime_role_name  = aws_iam_role.runtime.name
  activate_receiving = var.activate_receiving
}
module "gmail_notifications" {
  source                = "../modules/gmail_notifications"
  name                  = var.name
  project_id            = var.google_project_id
  aws_account_id        = data.aws_caller_identity.current.account_id
  aws_runtime_role_name = aws_iam_role.runtime.name
}

output "host_ip" { value = aws_instance.service.public_ip }
output "mail_name_servers" { value = module.mail.name_servers }
output "sender" { value = module.mail.sender }
output "spool_bucket" { value = module.mail.spool_bucket }
output "incoming_queue_url" { value = module.mail.queue_url }
output "receipt_topic_arn" { value = module.mail.receipt_topic_arn }
output "gmail_topic" { value = module.gmail_notifications.topic }
output "gmail_subscription" { value = module.gmail_notifications.subscription }
output "google_consumer_service_account" { value = module.gmail_notifications.consumer_service_account }
output "google_workload_identity_provider" { value = module.gmail_notifications.workload_identity_provider }
output "bedrock_model_id" { value = var.bedrock_model_id }
output "ready_for_processing" {
  value       = false
  description = "Infrastructure is not a readiness check. Complete OAuth, SES, model and app round-trip validation."
}
