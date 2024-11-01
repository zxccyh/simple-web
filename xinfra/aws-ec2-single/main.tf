provider "aws" {
  region = "ap-northeast-2" # 사용할 AWS 리전
}

# 보안 그룹 설정: SSH(22) 및 HTTP(80) 트래픽 허용
resource "aws_security_group" "nginx_sg" {
  name_prefix = "nginx-sg-"

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# TLS 프라이빗 키 생성 (공개 키 포함)
resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# AWS에서 키 페어 생성
resource "aws_key_pair" "ec2_key" {
  key_name   = "ec2-key" # AWS에서 사용할 키 페어 이름
  public_key = tls_private_key.example.public_key_openssh
}

# EC2용 IAM 역할
resource "aws_iam_role" "ec2_codedeploy_role" {
  name = "ec2-codedeploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# EC2 인스턴스 프로파일
resource "aws_iam_instance_profile" "ec2_codedeploy_profile" {
  name = "ec2-codedeploy-profile"
  role = aws_iam_role.ec2_codedeploy_role.name
}

# EC2에 필요한 정책 연결
resource "aws_iam_role_policy_attachment" "ec2_codedeploy_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
  role       = aws_iam_role.ec2_codedeploy_role.name
}

# EC2에 S3 접근 권한 추가
resource "aws_iam_role_policy_attachment" "ec2_s3_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  role       = aws_iam_role.ec2_codedeploy_role.name
}

# EC2 인스턴스 생성
resource "aws_instance" "nginx_instance" {
  ami             = "ami-08b09b6acd8d62254" # Amazon Linux 2 AMI (리전별로 AMI ID가 다를 수 있음)
  instance_type   = "t2.micro"
  key_name        = aws_key_pair.ec2_key.key_name # AWS에서 생성한 SSH 키 적용
  security_groups = [aws_security_group.nginx_sg.name]

  # EC2 시작 시 Nginx 설치 및 실행을 위한 User Data
  user_data = <<-EOF
              #!/bin/bash
              yum update -y

              # Ruby 설치 (CodeDeploy Agent 요구사항)
              yum install -y ruby wget

              # CodeDeploy Agent 설치
              cd /home/ec2-user
              wget https://aws-codedeploy-ap-northeast-2.s3.ap-northeast-2.amazonaws.com/latest/install
              chmod +x ./install
              ./install auto

              # CodeDeploy Agent 서비스 시작
              service codedeploy-agent start

              # nginx 설치
              amazon-linux-extras install nginx1 -y
              systemctl start nginx
              systemctl enable nginx
              EOF
  tags = {
    Name        = "nginx-server"
    Environment = "Production" # CodeDeploy 배포 그룹의 태그와 일치
  }
}


# 웹 컨텐츠용 S3 버킷 생성
resource "aws_s3_bucket" "web_content" {
  bucket = "simple-web-content"
}

# 버킷 버전 관리 설정
resource "aws_s3_bucket_versioning" "web_content" {
  bucket = aws_s3_bucket.web_content.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 서버측 암호화 설정
resource "aws_s3_bucket_server_side_encryption_configuration" "web_content" {
  bucket = aws_s3_bucket.web_content.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 버킷 정책 설정 (CodeDeploy가 접근할 수 있도록)
resource "aws_s3_bucket_policy" "web_content" {
  bucket = aws_s3_bucket.web_content.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCodeDeployAccess"
        Effect = "Allow"
        Principal = {
          Service = "codedeploy.amazonaws.com"
        }
        Action = [
          "s3:Get*",
          "s3:List*"
        ]
        Resource = [
          aws_s3_bucket.web_content.arn,
          "${aws_s3_bucket.web_content.arn}/*"
        ]
      }
    ]
  })
}

# CodeDeploy용 IAM 역할 생성
resource "aws_iam_role" "codedeploy_service_role" {
  name = "codedeploy-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codedeploy.amazonaws.com"
        }
      }
    ]
  })
}

# CodeDeploy IAM 역할에 정책 연결
resource "aws_iam_role_policy_attachment" "codedeploy_service_role_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
  role       = aws_iam_role.codedeploy_service_role.name
}

# CodeDeploy 애플리케이션 생성
resource "aws_codedeploy_app" "web_app" {
  name             = "simple-web-app"
  compute_platform = "Server" # EC2/온프레미스 배포
}

# CodeDeploy 배포 그룹 생성
resource "aws_codedeploy_deployment_group" "web_deploy_group" {
  app_name              = aws_codedeploy_app.web_app.name
  deployment_group_name = "simple-web-deploy-group"
  service_role_arn      = aws_iam_role.codedeploy_service_role.arn

  deployment_style {
    deployment_option = "WITHOUT_TRAFFIC_CONTROL"
    deployment_type   = "IN_PLACE"
  }

  ec2_tag_set {
    ec2_tag_filter {
      key   = "Environment"
      type  = "KEY_AND_VALUE"
      value = "Production"
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}

# 출력 설정
output "codedeploy_app_name" {
  value = aws_codedeploy_app.web_app.name
}

output "codedeploy_deployment_group_name" {
  value = aws_codedeploy_deployment_group.web_deploy_group.deployment_group_name
}

# 출력 설정 (버킷 이름과 ARN을 확인할 수 있도록)
output "web_content_bucket_name" {
  value = aws_s3_bucket.web_content.id
}

output "web_content_bucket_arn" {
  value = aws_s3_bucket.web_content.arn
}


# 출력: EC2 인스턴스의 퍼블릭 IP 주소
output "nginx_instance_public_ip" {
  value       = aws_instance.nginx_instance.public_ip
  description = "Public IP of the Nginx EC2 instance"
}

# 출력: SSH 접속에 사용할 Private Key
output "ssh_private_key_pem" {
  value       = tls_private_key.example.private_key_pem
  description = "Private key for SSH access"
  sensitive   = true
}
