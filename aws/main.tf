resource "random_id" "cluster_name" {
  byte_length = 4
}

# Local for tag to attach to all items
locals {
  resource_prefix = var.prefix != "" ? var.prefix : random_id.cluster_name.hex
  tags = merge(
    var.tags,
    {
      "ClusterName" = local.resource_prefix
    },
  )
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}


module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name   = "${local.resource_prefix}-vpc"

  cidr = "10.${var.subnet_second_octet}.0.0/16"

  azs = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [
    for num in range(0, length(slice(data.aws_availability_zones.available.names, 0, 3))) :
    cidrsubnet("10.${var.subnet_second_octet}.1.0/16", 8, 1 + num)
  ]
  public_subnets = [
    for num in range(0, length(slice(data.aws_availability_zones.available.names, 0, 3))) :
    cidrsubnet("10.${var.subnet_second_octet}.101.0/16", 8, 101 + num)
  ]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    Name = "${var.prefix}-public"
  }

  tags = local.tags

  vpc_tags = {
    Name    = "${local.resource_prefix}-vpc"
    Purpose = "vault"
  }
}

# AWS S3 Bucket for Certificates, Private Keys, Encryption Key, and License
resource "aws_s3_bucket" "setup_bucket" {
  bucket_prefix = "${local.resource_prefix}-setup"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "setup_bucket_sse" {
  bucket = aws_s3_bucket.setup_bucket.bucket
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.bucketkms.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

data "aws_iam_policy_document" "setup_bucket_access" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
      "${aws_s3_bucket.setup_bucket.arn}/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]
    resources = [
      aws_s3_bucket.setup_bucket.arn
    ]
  }
}


resource "aws_iam_role_policy" "setup_bucket" {
  name   = "${local.resource_prefix}-setup_bucket_access"
  role   = aws_iam_role.instance_role.id
  policy = data.aws_iam_policy_document.setup_bucket_access.json
}

resource "aws_kms_key" "bucketkms" {
  description             = "${local.resource_prefix}-bucketkey"
  deletion_window_in_days = 7
  # Add deny all policy to kms key to ensure accessing secrets
  # is a break-glass proceedure
  #  policy                  = "arn:aws:iam::aws:policy/AWSDenyAll"
  lifecycle {
    create_before_destroy = true
  }
  tags = local.tags
}


data "aws_iam_policy_document" "bucketkms" {
  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey"
    ]
    resources = [
      aws_kms_key.bucketkms.arn
    ]
  }
}

resource "aws_iam_role_policy" "bucketkms" {
  name   = "${random_id.cluster_name.id}-bucketkms"
  role   = aws_iam_role.instance_role.id
  policy = data.aws_iam_policy_document.bucketkms.json
}

# Lookup most recent AMI
data "aws_ami" "latest-image" {
  most_recent = true
  owners      = var.ami_filter_owners

  filter {
    name   = "name"
    values = var.ami_filter_name
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_iam_instance_profile" "instance_profile" {
  name_prefix = "${random_id.cluster_name.id}-instance_profile"
  role        = aws_iam_role.instance_role.name

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "instance_role" {
  name_prefix        = "${random_id.cluster_name.id}-instance-role"
  assume_role_policy = data.aws_iam_policy_document.instance_role.json

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "instance_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}


resource "aws_iam_role_policy" "auto_discover_cluster" {
  name   = "auto-discover-cluster"
  role   = aws_iam_role.instance_role.name
  policy = data.aws_iam_policy_document.auto_discover_cluster.json
}

data "aws_iam_policy_document" "auto_discover_cluster" {
  statement {
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "autoscaling:DescribeAutoScalingGroups",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy_attachment" "SystemsManager" {
  role       = aws_iam_role.instance_role.id
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_kms_key" "vault_unseal" {
  description             = "Vault unseal key"
  deletion_window_in_days = 10

  tags = {
    Name = "vault-kms-unseal-${local.resource_prefix}"
  }
}

data "aws_iam_policy_document" "vault-kms-unseal" {
  statement {
    sid       = "VaultKMSUnseal"
    effect    = "Allow"
    resources = ["*"]

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
  }
}

resource "aws_iam_role_policy" "kms_key" {
  name   = "${random_id.cluster_name.id}-unseal-key"
  role   = aws_iam_role.instance_role.id
  policy = data.aws_iam_policy_document.vault-kms-unseal.json
}


# Install Vault
data "template_cloudinit_config" "vault" {
  gzip          = true
  base64_encode = true
  part {
    filename     = "install-vault.sh"
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/install-vault.tpl",
      {
        vault_binary             = var.vault_binary
        vault_version            = var.vault_version,
        cluster_tag_key          = "ClusterName",
        cluster_tag_value        = local.resource_prefix,
        enable_gossip_encryption = var.enable_gossip_encryption,
        enable_rpc_encryption    = var.enable_rpc_encryption,
        environment              = var.environment,
        bucket                   = aws_s3_bucket.setup_bucket.id,
        bucketkms                = aws_kms_key.bucketkms.id,
        skip_init                = var.skip_init
        additional_setup         = var.additional_setup
        vault_load_balancer      = aws_lb.vault.dns_name
        vault_license            = var.vault_license
        seal_config = {
          type = "awskms"
          attributes = {
            region     = data.aws_region.current.name
            kms_key_id = aws_kms_key.vault_unseal.id
          }
        }
      }
    )
  }
}


module "vault" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "5.1.1"

  image_id                  = var.ami_id != "" ? var.ami_id : data.aws_ami.latest-image.id
  name                      = "${local.resource_prefix}-vault"
  health_check_type         = "EC2"
  max_size                  = var.vault_cluster_size
  min_size                  = var.vault_cluster_size
  desired_capacity          = var.vault_cluster_size
  instance_type             = "t3.small"
  target_group_arns         = [aws_lb_target_group.vault.arn]
  vpc_zone_identifier       = module.vpc.private_subnets
  key_name                  = var.ssh_key_name
  enabled_metrics           = ["GroupTotalInstances"]
  force_delete              = true
  iam_instance_profile_name = aws_iam_instance_profile.instance_profile.name
  user_data_base64          = data.template_cloudinit_config.vault.rendered
  create_launch_template    = true
  update_default_version    = true
  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      instance_warmup        = 0
      min_healthy_percentage = 0
    }
    triggers = ["tag"]
  }

  tags = merge(local.tags,
    # This updates the tags when user data changes to enforce instance refresh
  { ud_md5 = md5(data.template_cloudinit_config.vault.rendered) })
}

resource "aws_lb" "vault" {
  name               = "${local.resource_prefix}-vault-lb"
  internal           = true
  load_balancer_type = "application"
  subnets            = module.vpc.private_subnets

  enable_deletion_protection = var.enable_deletion_protection
  tags                       = local.tags

}

resource "aws_lb_target_group" "vault" {
  name     = "${local.resource_prefix}-vault-lb"
  port     = 8200
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
  health_check {
    interval            = "5"
    timeout             = "2"
    path                = "/v1/sys/health?uninitcode=474&perfstandbyok=true"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200,472,473,474"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "vault" {
  load_balancer_arn = aws_lb.vault.arn
  port              = "8200"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault.arn
  }
}
