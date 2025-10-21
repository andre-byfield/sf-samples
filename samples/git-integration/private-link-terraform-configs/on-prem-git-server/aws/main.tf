terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.95.0"
    }
  }
}

provider "aws" {
  profile                  = "default"
  region                   = var.b_region
}

variable "b_region" {
  type        = string
  description = "Snowflake region (example value: us-west-2)"
  default = "us-east-1"
}

variable "c_availability_zone" {
  type        = string
  description = "Availability zone within the region (example value: us-west-2b)"
  default = "us-east-1a"
}

variable "d_arn" {
  type        = string
  description = "ARN to be added as an allowed principal for the VPC endpoint service"
  default = "arn:aws:iam::107279681708:root"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.19.0"

  name = "snowflake-vpc"
  cidr = "10.0.0.0/16"

  azs             = [var.c_availability_zone]
  private_subnets = ["10.0.1.0/24"]
  public_subnets  = ["10.0.101.0/24"]

  enable_dns_hostnames = true
  enable_nat_gateway   = true
  enable_vpn_gateway   = false

  reuse_nat_ips = false
  
  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}

resource "aws_vpc_endpoint_service" "snowflake_pl_es" {
  acceptance_required        = true
  allowed_principals         = [var.d_arn]
  network_load_balancer_arns = [aws_lb.snowflake_pl_lb.arn]

  tags = {
    Name = "snowflake_pl_es"
  }
}

resource "aws_lb" "snowflake_pl_lb" {
  name               = "snowflake-privatelink-lb"
  internal           = true
  load_balancer_type = "network"
  enable_cross_zone_load_balancing = true
  security_groups    = [aws_security_group.snowflake_pl_sg.id]
  subnets            = module.vpc.private_subnets
}

resource "aws_lb_listener" "snowflake_pl_lbl" {
  load_balancer_arn = aws_lb.snowflake_pl_lb.arn
  port              = "443"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.snowflake_pl_tg.arn
  }
}

resource "aws_lb_target_group" "snowflake_pl_tg" {
  name     = "snowflake-privatelink-tg"
  port     = 443
  protocol = "TCP"
  vpc_id   = module.vpc.vpc_id
}

resource "aws_lb_target_group_attachment" "snowflake_pl_tg_ec2" {
  target_group_arn = aws_lb_target_group.snowflake_pl_tg.arn
  target_id        = aws_instance.snowflake_pl_git_server.id
  port             = 443
}

resource "aws_security_group" "snowflake_pl_sg" {
  name        = "snowflake_pl_https_443_sg"
  description = "Allow HTTPS traffic from anywhere"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "TCP"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow HTTPS traffic from anywhere
  }

  egress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# create EC2 proxy instance
resource "aws_instance" "snowflake_pl_git_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = module.vpc.private_subnets[0]  # use first private subnet
  key_name      = null # This ensures the instance is created without a key pair

  vpc_security_group_ids = [aws_security_group.snowflake_pl_ssh_sg.id, aws_security_group.snowflake_pl_sg.id]

  tags = {
    Name = "snowflake_pl_git_server"
  }
}


data "aws_ami" "amazon_linux" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-5.10-hvm-*-x86_64-gp2"] # Pattern for Amazon Linux 2023 AMI
  }

  filter {
    name   = "owner-id"
    values = ["137112412989"] # Amazon's official owner ID for Amazon Linux
  }
}

resource "aws_security_group" "snowflake_pl_ssh_sg" {
  name        = "snowflake_pl_ssh_sg"
  description = "Allow SSH traffic from anywhere"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow SSH traffic from anywhere
  }

  egress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}