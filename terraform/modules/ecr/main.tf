resource "aws_ecr_repository" "this" {
  #checkov:skip=CKV_AWS_136:Images are AES256-encrypted at rest and contain no secrets; switching encryption_type forces repository replacement.
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE" # Prevents tag overwriting — critical for supply chain integrity

  image_scanning_configuration {
    scan_on_push = true # AWS Basic Scanning on every push; enhanced scanning via Trivy in CI
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain the last ${var.image_count_policy} tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.image_count_policy
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images older than 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
    ]
  })
}
