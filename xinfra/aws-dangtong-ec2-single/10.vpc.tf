# VPC 생성
resource "aws_vpc" "dangtong-vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "dangtong-vpc"
  }
}
# 퍼블릭 서브넷 생성
resource "aws_subnet" "dangtong-vpc-public-subnet-a" {
  vpc_id                  = aws_vpc.dangtong-vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "dangtong-vpc-public-subnet-a"
  }
}

# 인터넷 게이트웨이 생성
resource "aws_internet_gateway" "dangtong-igw" {
  vpc_id = aws_vpc.dangtong-vpc.id

  tags = {
    Name = "dangtong-igw"
  }
}

# 라우팅 테이블 생성
resource "aws_route_table" "dangtong-vpc-public-rt" {
  vpc_id = aws_vpc.dangtong-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dangtong-igw.id
  }

  tags = {
    Name = "dangtong-vpc-public-rt"
    
  }
}

# 서브넷을 라우팅 테이블과 연결
resource "aws_route_table_association" "dangtong-vpc-public-rt-a" {
  subnet_id      = aws_subnet.dangtong-vpc-public-subnet-a.id
  route_table_id = aws_route_table.dangtong-vpc-public-rt.id
}