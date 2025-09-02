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

## TODO List Lambda Subproject

The directory `todo-list/` contains a Node.js 18+ AWS Lambda implementation of a simple TODO REST API using Drizzle ORM and PostgreSQL. It provides endpoints for creating, listing, updating (completion state), and deleting todos, plus a `/health` check. The function is framework-less (no Express) to keep cold starts small and is suitable for deployment behind API Gateway and CloudFront.

### Outline of Use

1. Create / configure a PostgreSQL database (RDS, Aurora, Neon, etc.) and export `DATABASE_URL`.
2. From `todo-list/` run:
   ```
   npm install
   npm run generate
   npm run migrate
   npm run build
   ```
3. Deploy the Lambda with handler `dist/handler.handler` (runtime: `nodejs18.x`).
4. Expose it via API Gateway (proxy integration) and optionally front it with CloudFront (as this demo does for the existing lambda).
5. On future schema changes: update `src/schema.ts`, regenerate + apply migrations before (or as part of) updating the live Lambda version.

### Terraform Actions Integration

You can extend the existing Terraform Actions flow to:
- Invoke a migration lambda (or a one-off action) immediately after publishing new code.
- Trigger a CloudFront invalidation so clients receive updated API responses if any caching layer is used.
- Optionally perform a health check invocation (`/health`) before finalizing deployment.

This keeps database schema, function code, and edge cache state synchronized.