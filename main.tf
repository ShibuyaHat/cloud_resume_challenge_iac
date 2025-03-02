/* 
Name: Cloud Resume Challenge - AWS - Gianluca Poddighe
Description: Cloud Resume Challenge, AWS based, for Gianluca Poddighe
Contributors: Gianluca Poddighe
*/

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Owner       = "Gianluca"
      ManagedBy   = "Terraform"
      Environment = terraform.workspace
      Project = var.project_name
    }
  }
}

/* 
FRONTEND
Host the frontend on S3, use Cloudfront to distribute the content.
*/

# Create Random String for S3 bucket name
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Create Bucket
resource "aws_s3_bucket" "website_bucket" {
  bucket = "cloud_resume_challenge_${random_string.suffix.result}"  # Change to a globally unique name
}

# Enable website hosting on the bucket
resource "aws_s3_bucket_website_configuration" "website_config" {
  bucket = aws_s3_bucket.website_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

# Make the bucket private
resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket                  = aws_s3_bucket.website_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Create an S3 bucket policy to allow CloudFront access
resource "aws_s3_bucket_policy" "cloudfront_policy" {
  bucket = aws_s3_bucket.website_bucket.id
  policy = data.aws_iam_policy_document.cloudfront_s3_policy.json
}

# IAM policy to allow CloudFront to read from S3
data "aws_iam_policy_document" "cloudfront_s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.website_bucket.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.website_distribution.arn]
    }
  }
}

# Create a CloudFront Origin Access Control (OAC)
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "s3-oac-${aws_s3_bucket.website_bucket.id}"
  description                       = "OAC for S3 private website"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Create CloudFront Distribution
resource "aws_cloudfront_distribution" "website_distribution" {
  origin {
    domain_name              = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.website_bucket.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  enabled             = true
  default_root_object = "index.html"

  # Cache behavior
  default_cache_behavior {
    target_origin_id       = "S3-${aws_s3_bucket.website_bucket.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  # Restrict access to CloudFront only (prevent direct S3 access)
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Clone the GitHub repository and upload to S3
resource "null_resource" "clone_and_upload_frontend" {
  provisioner "local-exec" {
    command = <<EOT
      # Clone GitHub repository
      git clone ${var.frontend_git_repository_url} frontend_repo
      
      # Sync repository contents to S3
      aws s3 sync downloads s3://${aws_s3_bucket.website_bucket.id}/ --acl private
      
      # Clean up cloned files
      rm -rf frontend_repo
    EOT
  }

  # Ensure this runs after the S3 bucket is created
  depends_on = [aws_s3_bucket.website_bucket]
}

