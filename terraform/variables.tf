variable "project_name" {
  description = "Tên dự án để gắn tag tài nguyên"
  type        = string
  default     = "k3s-monitoring"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1" # Singapore - đổi nếu muốn
}

variable "master_instance_type" {
  type        = string
  default     = "t3.small"
}

variable "worker_instance_type" {
  type        = string
  default     = "t3.small"
}

variable "worker_count" {
  description = "Số lượng worker"
  type        = number
  default     = 2
}

variable "master_volume_gb" {
  type    = number
  default = 20
}

variable "worker_volume_gb" {
  type    = number
  default = 20
}
