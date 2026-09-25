variable "repository_name" {
  type = string
}

variable "image_count_policy" {
  description = "Number of tagged images to retain. Older images are expired automatically."
  type        = number
  default     = 10
}
