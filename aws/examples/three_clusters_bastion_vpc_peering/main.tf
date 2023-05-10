# Example to deploy 3 environments with vpc peering

provider "aws" {
  alias  = "region1"
  region = var.region1
}

provider "aws" {
  alias  = "region2"
  region = var.region2
}

provider "aws" {
  alias  = "region3"
  region = var.region3
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

resource "random_id" "deployment_tag" {
  byte_length = 4
}

# Local for tag to attach to all items
locals {
  tags = merge(
    var.tags,
    {
      "DeploymentTag" = random_id.deployment_tag.hex
    },
  )
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/${random_id.deployment_tag.hex}-key.pem"
  file_permission = "0400"
}

data "aws_availability_zones" "available" {
  provider = aws.region1
  state    = "available"
}

module "bastion_vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name   = "${random_id.deployment_tag.hex}-bastion"

  cidr = "192.168.0.0/16"

  azs             = [data.aws_availability_zones.available.names[0]]
  private_subnets = ["192.168.1.0/24"]
  public_subnets  = ["192.168.101.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    Name = "bastion-public"
  }

  tags = local.tags

  vpc_tags = {
    Name = "bastion-vpc"
  }
  providers = {
    aws = aws.region1
  }
}

resource "aws_default_security_group" "bastion_default" {
  provider = aws.region1
  vpc_id   = module.bastion_vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }


  lifecycle {
    ignore_changes = [
      tags
    ]
  }

}

resource "aws_key_pair" "key" {
  provider   = aws.region1
  key_name   = "${random_id.deployment_tag.hex}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

# Lookup most recent AMI
data "aws_ami" "latest-image" {
  provider    = aws.region1
  most_recent = true
  owners      = ["099720109477"] # Canonical
  name_regex  = "ubuntu-jammy.*"

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

}

resource "aws_instance" "bastion" {
  provider                    = aws.region1
  ami                         = data.aws_ami.latest-image.id
  instance_type               = "t3.micro"
  subnet_id                   = module.bastion_vpc.public_subnets[0]
  key_name                    = aws_key_pair.key.key_name
  associate_public_ip_address = true
  user_data                   = <<EOF
#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y unzip netcat dnsutils

wget https://releases.hashicorp.com/vault/1.13.2+ent/vault_1.13.2+ent_linux_amd64.zip -O vault.zip
unzip vault
mv vault /usr/bin/vault
EOF

  tags = merge(local.tags, {
    "Name" = "bastion"
  })
}

resource "null_resource" "update_hosts" {
  provisioner "local-exec" {
    command = <<EOC
      cat <<-EOF >> /etc/ssh/ssh_config
Host bastion
    HostName ${aws_instance.bastion.public_ip}
    User ubuntu
    IdentityFile ${abspath(local_sensitive_file.private_key.filename)}
EOF
    EOC
  }
}

module "primary_cluster" {
  source                     = "../../"
  prefix                     = "primary-cluster"
  vault_version              = "1.13.2+ent"
  vault_cluster_size         = 3
  enable_deletion_protection = false
  subnet_second_octet        = "0"
  force_bucket_destroy       = true
  vault_license              = var.vault_license
  tags                       = local.tags
  providers = {
    aws = aws.region1
  }
}

module "dr_cluster" {
  source                     = "../../"
  prefix                     = "dr-cluster"
  vault_version              = "1.13.2+ent"
  vault_cluster_size         = 1
  enable_deletion_protection = false
  subnet_second_octet        = "1"
  force_bucket_destroy       = true
  vault_license              = var.vault_license
  tags                       = local.tags
  providers = {
    aws = aws.region2
  }
}

module "eu_cluster" {
  source                     = "../../"
  prefix                     = "perf-cluster"
  vault_version              = "1.13.2+ent"
  vault_cluster_size         = 1
  enable_deletion_protection = false
  subnet_second_octet        = "2"
  force_bucket_destroy       = true
  vault_license              = var.vault_license
  tags                       = local.tags
  providers = {
    aws = aws.region3
  }
}

resource "aws_vpc_peering_connection" "bastion_connectivity" {
  provider    = aws.region1
  peer_vpc_id = module.bastion_vpc.vpc_id
  vpc_id      = module.primary_cluster.vpc_id
  auto_accept = true
  tags = {
    Name = "Bastion to Primary"
  }
}

resource "aws_vpc_peering_connection" "bastion_connectivity_dr" {
  provider    = aws.region2
  peer_vpc_id = module.bastion_vpc.vpc_id
  vpc_id      = module.dr_cluster.vpc_id
  auto_accept = false
  peer_region = var.region1
  tags = {
    Name = "Bastion to DR"
  }
}

resource "aws_vpc_peering_connection_accepter" "bastion_connectivity_dr" {
  provider                  = aws.region1
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity_dr.id
  auto_accept               = true
}

resource "aws_vpc_peering_connection" "bastion_connectivity_eu" {
  provider    = aws.region3
  peer_vpc_id = module.bastion_vpc.vpc_id
  vpc_id      = module.eu_cluster.vpc_id
  auto_accept = false
  peer_region = var.region1
  tags = {
    Name = "Bastion to Perf"
  }
}

resource "aws_vpc_peering_connection_accepter" "bastion_connectivity_eu" {
  provider                  = aws.region1
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity_eu.id
  auto_accept               = true
}

resource "aws_vpc_peering_connection" "vault_connectivity_dr" {
  provider    = aws.region2
  peer_vpc_id = module.primary_cluster.vpc_id
  vpc_id      = module.dr_cluster.vpc_id
  auto_accept = false
  peer_region = var.region1
  tags = {
    Name = "Primary to DR"
  }
}

resource "aws_vpc_peering_connection_accepter" "vault_connectivity_dr" {
  provider                  = aws.region1
  vpc_peering_connection_id = aws_vpc_peering_connection.vault_connectivity_dr.id
  auto_accept               = true
}

resource "aws_vpc_peering_connection" "vault_connectivity_eu" {
  provider    = aws.region3
  peer_vpc_id = module.primary_cluster.vpc_id
  vpc_id      = module.eu_cluster.vpc_id
  auto_accept = false
  peer_region = var.region1

  tags = {
    Name = "Primary to Perf"
  }
}

resource "aws_vpc_peering_connection_accepter" "vault_connectivity_eu" {
  provider                  = aws.region1
  vpc_peering_connection_id = aws_vpc_peering_connection.vault_connectivity_eu.id
  auto_accept               = true
}

resource "aws_default_security_group" "primary_cluster" {
  provider = aws.region1
  vpc_id   = module.primary_cluster.vpc_id

  ingress {
    protocol  = -1
    self      = true
    from_port = 0
    to_port   = 0
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  ingress {
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  ingress {
    from_port   = 8200
    to_port     = 8201
    protocol    = "tcp"
    cidr_blocks = concat(module.dr_cluster.private_subnets_cidr_blocks, module.eu_cluster.private_subnets_cidr_blocks)
  }

  ingress {
    from_port   = 8500
    to_port     = 8500
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    ignore_changes = [
      tags
    ]
  }

}

resource "aws_default_security_group" "dr_cluster" {
  provider = aws.region2
  vpc_id   = module.dr_cluster.vpc_id

  ingress {
    protocol  = -1
    self      = true
    from_port = 0
    to_port   = 0
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  ingress {
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  ingress {
    from_port   = 8200
    to_port     = 8201
    protocol    = "tcp"
    cidr_blocks = module.primary_cluster.public_subnets_cidr_blocks
  }

  ingress {
    from_port   = 8500
    to_port     = 8500
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    ignore_changes = [
      tags
    ]
  }
}

resource "aws_default_security_group" "eu_cluster" {
  provider = aws.region3
  vpc_id   = module.eu_cluster.vpc_id

  ingress {
    protocol  = -1
    self      = true
    from_port = 0
    to_port   = 0
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  ingress {
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  ingress {
    from_port   = 8200
    to_port     = 8201
    protocol    = "tcp"
    cidr_blocks = module.primary_cluster.public_subnets_cidr_blocks
  }

  ingress {
    from_port   = 8500
    to_port     = 8500
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  lifecycle {
    ignore_changes = [
      tags
    ]
  }
}

resource "aws_route" "bastion_to_primary" {
  provider = aws.region1
  count    = length(setproduct(module.primary_cluster.private_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids))

  route_table_id            = element(setproduct(module.primary_cluster.private_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids), count.index)[1]
  destination_cidr_block    = element(setproduct(module.primary_cluster.private_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity.id
}


resource "aws_route" "primary_to_bastion" {
  provider = aws.region1
  count    = length(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.primary_cluster.private_route_tables))

  route_table_id            = element(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.primary_cluster.private_route_tables), count.index)[1]
  destination_cidr_block    = element(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.primary_cluster.private_route_tables), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity.id
}

resource "aws_route" "bastion_to_dr" {
  provider = aws.region1
  count    = length(setproduct(module.dr_cluster.private_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids))

  route_table_id            = element(setproduct(module.dr_cluster.private_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids), count.index)[1]
  destination_cidr_block    = element(setproduct(module.dr_cluster.private_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity_dr.id
}

resource "aws_route" "dr_to_bastion" {
  provider = aws.region2
  count    = length(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.dr_cluster.private_route_tables))

  route_table_id            = element(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.dr_cluster.private_route_tables), count.index)[1]
  destination_cidr_block    = element(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.dr_cluster.private_route_tables), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity_dr.id
}


resource "aws_route" "bastion_to_perf" {
  provider = aws.region1
  count    = length(setproduct(module.eu_cluster.private_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids))

  route_table_id            = element(setproduct(module.eu_cluster.private_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids), count.index)[1]
  destination_cidr_block    = element(setproduct(module.eu_cluster.private_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity_eu.id
}



resource "aws_route" "perf_to_bastion" {
  provider = aws.region3
  count    = length(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.eu_cluster.private_route_tables))

  route_table_id            = element(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.eu_cluster.private_route_tables), count.index)[1]
  destination_cidr_block    = element(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.eu_cluster.private_route_tables), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity_eu.id
}

resource "aws_route" "primary_to_dr" {
  provider = aws.region1
  count    = length(setproduct(module.dr_cluster.private_subnets_cidr_blocks, module.primary_cluster.private_route_tables))

  route_table_id            = element(setproduct(module.dr_cluster.private_subnets_cidr_blocks, module.primary_cluster.private_route_tables), count.index)[1]
  destination_cidr_block    = element(setproduct(module.dr_cluster.private_subnets_cidr_blocks, module.primary_cluster.private_route_tables), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.vault_connectivity_dr.id
}


resource "aws_route" "dr_to_primary" {
  provider = aws.region2
  count    = length(setproduct(module.primary_cluster.private_subnets_cidr_blocks, module.dr_cluster.private_route_tables))

  route_table_id            = element(setproduct(module.primary_cluster.private_subnets_cidr_blocks, module.dr_cluster.private_route_tables), count.index)[1]
  destination_cidr_block    = element(setproduct(module.primary_cluster.private_subnets_cidr_blocks, module.dr_cluster.private_route_tables), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.vault_connectivity_dr.id
}

resource "aws_route" "primary_to_perf" {
  provider = aws.region1
  count    = length(setproduct(module.eu_cluster.private_subnets_cidr_blocks, module.primary_cluster.private_route_tables))

  route_table_id            = element(setproduct(module.eu_cluster.private_subnets_cidr_blocks, module.primary_cluster.private_route_tables), count.index)[1]
  destination_cidr_block    = element(setproduct(module.eu_cluster.private_subnets_cidr_blocks, module.primary_cluster.private_route_tables), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.vault_connectivity_eu.id
}


resource "aws_route" "perf_to_primary" {
  provider = aws.region3
  count    = length(setproduct(module.primary_cluster.private_subnets_cidr_blocks, module.eu_cluster.private_route_tables))

  route_table_id            = element(setproduct(module.primary_cluster.private_subnets_cidr_blocks, module.eu_cluster.private_route_tables), count.index)[1]
  destination_cidr_block    = element(setproduct(module.primary_cluster.private_subnets_cidr_blocks, module.eu_cluster.private_route_tables), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.vault_connectivity_eu.id
}
