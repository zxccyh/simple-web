# TLS 프라이빗 키 생성 (공개 키 포함)
resource "tls_private_key" "ec2_private_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# AWS에서 키 페어 생성
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2-key_pair" # AWS에서 사용할 키 페어 이름
  public_key = tls_private_key.ec2_private_key.public_key_openssh
}
# 시작 템플릿 생성
resource "aws_launch_template" "nginx_template" {
  name_prefix   = "nginx-template"
  image_id      = "ami-08b09b6acd8d62254"
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups            = [aws_security_group.nginx_sg.id]
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  key_name = aws_key_pair.ec2_key_pair.key_name

  user_data = base64encode(<<-EOF
              #!/bin/bash
              yum update -y

              # Ruby 설치
              yum install -y ruby wget

              # CodeDeploy Agent 설치
              cd /home/ec2-user
              wget https://aws-codedeploy-ap-northeast-2.s3.ap-northeast-2.amazonaws.com/latest/install
              chmod +x ./install
              ./install auto

              # CodeDeploy Agent 서비스 시작
              systemctl start codedeploy-agent
              systemctl enable codedeploy-agent

              # nginx 설치
              amazon-linux-extras install nginx1 -y
              systemctl start nginx
              systemctl enable nginx
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "nginx-server"
      Environment = "Production"
    }
  }
}


# Auto Scaling Group 생성
resource "aws_autoscaling_group" "nginx_asg" {
  name                = "nginx-asg"
  desired_capacity    = 2
  max_size           = 4
  min_size           = 1
  target_group_arns  = [aws_lb_target_group.nginx_tg.arn]
  vpc_zone_identifier = [
    aws_subnet.dangtong-vpc-public-subnet["a"].id,
    aws_subnet.dangtong-vpc-public-subnet["c"].id
  ]

  launch_template {
    id      = aws_launch_template.nginx_template.id
    version = "$Latest"
  }

  tag {
    key                 = "Environment"
    value               = "Production"
    propagate_at_launch = true
  }
}

# Application Load Balancer 생성
resource "aws_lb" "nginx_alb" {
  name               = "nginx-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets           = [
    aws_subnet.dangtong-vpc-public-subnet["a"].id,
    aws_subnet.dangtong-vpc-public-subnet["c"].id
  ]

  tags = {
    Name = "nginx-alb"
  }
}

# ALB Target Group
resource "aws_lb_target_group" "nginx_tg" {
  name     = "nginx-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.dangtong-vpc.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher            = "200"
    path               = "/"
    port               = "traffic-port"
    timeout            = 5
    unhealthy_threshold = 2
  }
}

# ALB Listener
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.nginx_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx_tg.arn
  }
}

# ALB Security Group
resource "aws_security_group" "alb_sg" {
  name_prefix = "alb-sg"
  vpc_id      = aws_vpc.dangtong-vpc.id

  ingress {
    description = "HTTP from anywhere"
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

# 출력: ALB DNS 이름
output "alb_dns_name" {
  value       = aws_lb.nginx_alb.dns_name
  description = "DNS name of the Application Load Balancer"
}

# 출력: SSH 접속에 사용할 Private Key
output "ssh_private_key_pem" {
  value       = tls_private_key.ec2_private_key.private_key_pem
  description = "Private key for SSH access"
  sensitive   = true
}