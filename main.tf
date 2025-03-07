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
      Project     = var.project_name
    }
  }
}

/* 
FRONTEND
Host the frontend on S3, use Cloudfront to distribute the content.
*/

# Create Random String for S3 bucket name
resource "random_string" "suffix" {
  length  = 12
  special = false
  upper   = false
}

# Create Bucket
resource "aws_s3_bucket" "website_bucket" {
  bucket = "cloud-resume-challenge-${random_string.suffix.result}" # Use that random string for unique name
}

# Enable website hosting on the bucket
# Need to fix the error_document 
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

  # Add Alternate Domain Names (CNAMEs) here
  aliases = ["${var.my_domain}", "www.${var.my_domain}"]

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

  # Price Class (selecting Price Class 100 for cheaper cost) Use only North America and Europe
  price_class = "PriceClass_100"

  # Restrict access to CloudFront only (prevent direct S3 access)
  # Need to be edited for ACM
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# Clone the GitHub repository and upload to S3
# Works on bash, but if we run from powershell we may have problems. 
# Refactor this in python? 
# Also, need to be edited for backend later
# NEED A FIX - I need to pass my ENV for the session to work
resource "null_resource" "clone_and_upload_frontend" {
  provisioner "local-exec" {
    command = <<EOT
      git clone ${var.frontend_git_repository_url} frontend_repo
      aws s3 sync frontend_repo s3://${aws_s3_bucket.website_bucket.id}/ --acl private
      rmdir /s /q frontend_repo
    EOT
    interpreter = ["cmd", "/C"]
  }
  

  # Ensure this runs after the S3 bucket is created
  depends_on = [aws_s3_bucket.website_bucket]
}

# Fetch the existing hosted zone for mydomain since the hosted zone already exist from domain registration
data "aws_route53_zone" "mydomain" {
  name         = var.my_domain
  private_zone = false
}

# Create a Route 53 record for www.mydomain.com pointing to CloudFront
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.mydomain.zone_id
  name    = "www.${var.my_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.website_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

# Create a Route 53 record for mydomain.com (root domain) pointing to CloudFront
resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.mydomain.zone_id
  name    = var.my_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.website_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}


# ACM to deploy SSL/TLS Certificate for HTTPS
resource "aws_acm_certificate" "cert" {
  domain_name       = var.my_domain
  validation_method = "DNS"

  subject_alternative_names = ["www.${var.my_domain}"]

  lifecycle {
    create_before_destroy = true
  }
}

# Now I need to validate the certificate
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.mydomain.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cert_validation" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}


/* 
BACKEND
The frontend will call the API Gateway, which forwards a request to a python lambda that retrieve values from DynamoDB and send the response to the Frontend.
Need to update JS code in the frontend to use API Gateway Endpoints.
*/