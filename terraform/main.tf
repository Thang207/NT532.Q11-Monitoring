########################
# AMI & default subnets
########################
data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Dùng default VPC và một public subnet bất kỳ
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Chọn subnet đầu tiên (đơn giản)
locals {
  subnet_id = data.aws_subnets.default_public.ids[0]
}

locals {
  common_tags = {
    Project = var.project_name
  }
}


###################
# Keypair (TLS -> AWS)
###################
resource "random_id" "suffix" {
  byte_length = 2
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "this" {
  key_name   = "${var.project_name}-${random_id.suffix.hex}"
  public_key = tls_private_key.ssh.public_key_openssh
  tags = {
    Project = var.project_name
  }
}

# Lưu private key ra file .pem (CHỈ local máy bạn)
resource "local_file" "private_key_pem" {
  filename        = "${path.module}/${aws_key_pair.this.key_name}.pem"
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0600"
}

###################
# Security Group
###################
resource "aws_security_group" "k3s" {
  name        = "${var.project_name}-sg"
  description = "SG for K3s cluster"
  vpc_id      = data.aws_vpc.default.id

  # SSH từ bất kỳ đâu (có thể siết lại IP của bạn)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP/HTTPS public
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Toàn bộ traffic nội bộ giữa các node (K3s cần rất nhiều port)
  ingress {
    description      = "All intra-cluster traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    self             = true
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_name
  }
}

#################################
# K3s token (dùng cho server+agent)
#################################
resource "random_password" "k3s_token" {
  length  = 32
  special = false
}


###################
# User data scripts
###################

# Master user_data: cài K3s server với token từ terraform
locals {
  master_user_data = <<-EOF
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates
    # Lưu token vào file (cho debug)
    echo "${random_password.k3s_token.result}" > /etc/k3s_token
    chmod 600 /etc/k3s_token

    # Cài k3s server với token (K3S_TOKEN env)
    curl -sfL https://get.k3s.io | K3S_TOKEN='${random_password.k3s_token.result}' INSTALL_K3S_EXEC="--write-kubeconfig-mode=644" sh -s - server --cluster-init

    # Kiểm tra trạng thái
    sleep 5
    /usr/local/bin/kubectl get nodes || true

    # In token và kubeconfig location vào cloud-init output
    echo "K3S token stored at /etc/k3s_token"
    echo "kubeconfig at /etc/rancher/k3s/k3s.yaml"
  EOF

  worker_user_data = <<-EOF
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates
    # Agent sẽ được join qua K3S_URL và K3S_TOKEN (gắn bằng terraform)
    curl -sfL https://get.k3s.io | K3S_URL="https://${aws_instance.master.private_ip}:6443" K3S_TOKEN='${random_password.k3s_token.result}' sh -
    # chờ 3s rồi check agent node show up
    sleep 5
    # nothing more
  EOF
}

###################
# EC2 instances (master + workers) with user_data
###################

resource "aws_instance" "master" {
  ami                         = data.aws_ami.ubuntu_2204.id
  instance_type               = var.master_instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  key_name                    = aws_key_pair.this.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.master_volume_gb
    volume_type = "gp3"
  }

  user_data = local.master_user_data

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-master"
    Role = "master"
  })
}

resource "aws_instance" "worker" {
  count = var.worker_count

  ami                         = data.aws_ami.ubuntu_2204.id
  instance_type               = var.worker_instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  key_name                    = aws_key_pair.this.key_name
associate_public_ip_address = true
  root_block_device {
    volume_size = var.worker_volume_gb
    volume_type = "gp3"
  }

  # Ghi chú: user_data tham chiếu aws_instance.master.private_ip (ít khả năng gây vòng phụ thuộc vì master resource cùng file)
  user_data = replace(local.worker_user_data, "${aws_instance.master.private_ip}", aws_instance.master.private_ip)

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-worker-${count.index + 1}"
    Role = "worker"
  })
}

