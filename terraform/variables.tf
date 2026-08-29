variable "project" {
  type    = string
  default = "pg-ha"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "region" {
  description = "Single core region. DR region is a later stage, not provisioned yet."
  type        = string
  default     = "us-east-1"
}

variable "azs" {
  description = "3 AZs — one per PostgreSQL node."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "pg_instance_type" {
  type    = string
  default = "m6i.2xlarge"
}

variable "lb_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "mon_instance_type" {
  type    = string
  default = "m6i.xlarge"
}

variable "pgdata_volume_size_gb" {
  type    = number
  default = 500
}

variable "pgwal_volume_size_gb" {
  type    = number
  default = 100
}

variable "etcd_volume_size_gb" {
  type    = number
  default = 20
}

variable "key_pair_name" {
  description = "Existing EC2 key pair name. CHANGE_ME."
  type        = string
  default     = "CHANGE_ME"
}

variable "admin_cidr" {
  description = "Your IP, e.g. 203.0.113.42/32. CHANGE_ME — never 0.0.0.0/0."
  type        = string
  default     = "CHANGE_ME/32"
}

variable "backup_bucket_name" {
  type    = string
  default = "pg-ha-backups"
}

variable "aws_profile" {
  description = "AWS CLI profile to use. 'default' matches your current setup (no named profiles configured)."
  type        = string
  default     = "default"
}