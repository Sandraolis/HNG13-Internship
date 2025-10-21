# AWS Region
variables "region" {
    description = "Aws region"
    type        = string
    default     = "us-east-1"
}

 # VPC cidr block
variable "vpc_cidr" {
    description = "vpc cidr block"
    type        = string
    default     = "10.0.0.0/16"
}

# Public subnet cidr block
variable "public" {
    description = "public subnet cidr block"
    type        = string
    default     = "10.0.1.0/24"
}


# Availability Zones
variable "availability_zones" {
    description = "AWS availability zones"
    type        = string
    default     = "us-east-1a" , "us-east-1"
}


# EC2 Instance type
variable "instance_type" {
    description = "EC2 instance type"
    type        = string
    default     = "t2.micro"
}


# AMI ID
variable "ami_id" {
    description = "Ubuntu Server 24.04 LTS"
    type        = string
    default     = "ami-0360c520857e3138f"
}


# SSH Key pair
variable "key_pair" {
    description = "SSH key pair"
    type        = string
    default     = "project-key.pem"
}


# project name tag
variable "project_name" {
    description = "name of ec2 instance server"
    type        = string
    defaulty    = "devops-nginx"
}




