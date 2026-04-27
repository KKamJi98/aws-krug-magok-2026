# IRSA trust policy 길이 한도(2048자) 데모 — Terraform 버전.
#
# bash 데모(scripts/irsa-trust-limit-demo.sh)에서 등록한 fake OIDC provider 12개를
# 그대로 재사용한다. 이 모듈은 별도 Role(role-trust-limit-demo-tf)을 만들고
# trust_count 변수로 trust statement 수를 조절한다.
#
# 사용:
#   make demo-trust-tf-init
#   make demo-trust-tf-apply TRUST_COUNT=4   # OK (length ~2114)
#   make demo-trust-tf-apply TRUST_COUNT=5   # FAIL (LimitExceeded, ACLSizePerRole 2048)
#   make demo-trust-tf-destroy

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "role_name" {
  type    = string
  default = "role-trust-limit-demo-tf"
}

variable "service_account_sub" {
  type    = string
  default = "system:serviceaccount:external-dns:external-dns"
}

variable "audience" {
  type    = string
  default = "sts.amazonaws.com"
}

variable "trust_count" {
  description = "trust statement 에 포함할 OIDC provider 수 (1..12). bash 데모 기준 5 부터 ACLSizePerRole 한도 초과."
  type        = number
  default     = 5

  validation {
    condition     = var.trust_count >= 1 && var.trust_count <= 12
    error_message = "trust_count 는 1~12 사이여야 합니다 (provision 단계에서 12개를 등록함)."
  }
}

variable "provider_id_prefix" {
  description = "fake OIDC provider id 의 prefix (bash 데모와 일치해야 함)."
  type        = string
  default     = "DEMO00000000000000000000000000"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  oidc_urls = [
    for i in range(1, var.trust_count + 1) :
    "oidc.eks.${var.region}.amazonaws.com/id/${var.provider_id_prefix}${format("%02d", i)}"
  ]

  trust_statements = [
    for url in local.oidc_urls : {
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${local.account_id}:oidc-provider/${url}"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${url}:aud" = var.audience
          "${url}:sub" = var.service_account_sub
        }
      }
    }
  ]

  trust_policy_doc = jsonencode({
    Version   = "2012-10-17"
    Statement = local.trust_statements
  })
}

resource "aws_iam_role" "demo" {
  name               = var.role_name
  description        = "AWS KRUG 2026 IRSA trust policy size limit demo (Terraform)"
  assume_role_policy = local.trust_policy_doc

  tags = {
    creator = "kkamji"
    purpose = "aws-krug-2026-irsa-trust-limit-demo"
  }
}

output "trust_count" {
  description = "현재 적용된 trust statement 수"
  value       = var.trust_count
}

output "trust_policy_length_chars" {
  description = "Terraform 가 IAM 에 보내는 trust policy JSON 의 글자 수 (compact)"
  value       = length(local.trust_policy_doc)
}

output "role_arn" {
  description = "생성된 데모 Role ARN"
  value       = aws_iam_role.demo.arn
}
