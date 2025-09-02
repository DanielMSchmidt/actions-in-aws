# Terraform Actions in AWS

This is a demo for how to use Terraform Actions in AWS.

## Content

This demo has an lambda function todo app served through a CloudFront distribution.
We have a lambda function to update the database schema run after the lambda function was updated.
We also invalidate the cache when the lambda function was updated.

## Prerequisites

- Latest Terraform build
- A local AWS provider with these PRs
  - [New action: `aws_lambda_invoke`](https://github.com/hashicorp/terraform-provider-aws/pull/43972)
  - [New action: `aws_cloudfront_create_invalidation`](https://github.com/hashicorp/terraform-provider-aws/pull/43955)
- An AWS Account