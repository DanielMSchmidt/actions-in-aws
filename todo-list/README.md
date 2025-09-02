# TODO List Lambda (Node.js + Drizzle ORM + PostgreSQL)

A minimal, production‑ready TODO list REST API designed to run on AWS Lambda with API Gateway using:

- Node.js 18+
- TypeScript
- Drizzle ORM (PostgreSQL dialect)
- `pg` driver (compatible with RDS, Aurora, Supabase, Render, Railway, etc.)
- Environment‑provided `DATABASE_URL`

The function exposes CRUD endpoints to add, list, toggle completion, and delete TODO items.

---

## Features

- Lightweight handler with zero external HTTP frameworks
- Drizzle ORM schema + typed query helpers
- Safe JSON parsing and validation
- Lean connection pooling strategy appropriate for Lambda
- CORS enabled by default (`*`)
- Strict TypeScript configuration
- ESLint + Prettier for consistent code quality

---

## Endpoints

Base path assumes an API Gateway REST or HTTP API proxy integration.

| Method | Path            | Description                                  | Body Example |
|--------|-----------------|----------------------------------------------|--------------|
| GET    | `/health`       | Health check (DB connectivity)               | —            |
| GET    | `/todos`        | List all TODOs                               | —            |
| POST   | `/todos`        | Create a new TODO                            | `{ "text": "Buy milk" }` |
| PATCH  | `/todos/{id}`   | Mark completed / uncompleted                 | `{ "completed": true }` |
| DELETE | `/todos/{id}`   | Delete a TODO                                | —            |
| OPTIONS| `*`             | CORS preflight                               | —            |

### Response Shapes

Success:
```json
{ "data": { ... } }
```

Error:
```json
{ "error": { "message": "Description here" } }
```

---

## Data Model

Single table `todos`:

| Column      | Type                | Notes                                   |
|-------------|---------------------|-----------------------------------------|
| id          | serial PK           | Auto-increment                          |
| text        | text NOT NULL       | Max 500 chars enforced in handler       |
| completed   | boolean NOT NULL    | Defaults to false                       |
| created_at  | timestamptz NOT NULL| Default now()                           |
| updated_at  | timestamptz NOT NULL| Auto-updated via Drizzle `$onUpdate`    |

Defined in `src/schema.ts`.

---

## Quick Start (Local Dev)

1. Clone repository (already inside monorepo path `actions-in-aws/todo-list`).

2. Set environment variable (example using a local Postgres):
   ```bash
   export DATABASE_URL="postgres://user:pass@localhost:5432/todos"
   ```

3. Install dependencies:
   ```bash
   npm install
   ```

4. Generate and run migrations (see Migrations section below).

5. Run a local dev loop (uses `tsx`):
   ```bash
   npm run dev
   ```

6. Simulate an event (using `ts-node` or a small script) or deploy via SAM / Serverless Framework for real HTTP testing.

---

## Migrations (Drizzle)

This project uses `drizzle-kit`:

Generate initial migration from schema:
```bash
npm run generate
```

This creates SQL files under `./drizzle`.

Apply migrations:
```bash
npm run migrate
```

(Internally `drizzle-kit migrate` will look at generated SQL migration files.)

If you modify the schema:
1. Adjust `src/schema.ts`
2. Re-run `npm run generate`
3. Re-run `npm run migrate`

Commit both the schema and generated migration files so deployments are deterministic.

---

## Environment Variables

| Name          | Required | Description                                           |
|---------------|----------|-------------------------------------------------------|
| `DATABASE_URL`| Yes      | Postgres connection string (standard URI format)     |

Connection pooling:
- The code creates a singleton `pg.Pool` with `max: 3`. For high concurrency, rely on Postgres server scaling rather than large pool sizes in Lambda (each concurrent cold execution gets its own pool anyway).
- If using a serverless Postgres provider like Neon, you can optionally switch to the Neon serverless client; the dependency is already included (`@neondatabase/serverless`). See “Optional: Neon Driver” below.

---

## Example Usage (with curl)

Assuming your API is deployed at `https://example.execute-api.us-east-1.amazonaws.com/prod`:

Create:
```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"text":"Buy milk"}' \
  https://example.execute-api.us-east-1.amazonaws.com/prod/todos
```

List:
```bash
curl https://example.execute-api.us-east-1.amazonaws.com/prod/todos
```

Complete:
```bash
curl -X PATCH \
  -H "Content-Type: application/json" \
  -d '{"completed":true}' \
  https://example.execute-api.us-east-1.amazonaws.com/prod/todos/1
```

Delete:
```bash
curl -X DELETE https://example.execute-api.us-east-1.amazonaws.com/prod/todos/1
```

Health:
```bash
curl https://example.execute-api.us-east-1.amazonaws.com/prod/health
```

---

## Deployment (AWS Lambda)

You can deploy using several methods. Core requirement: bundle `dist/` artifacts plus `node_modules` and set `handler` to `dist/handler.handler`.

### 1. AWS SAM (outline)

`template.yaml` snippet:
```yaml
Resources:
  TodoFunction:
    Type: AWS::Lambda::Function
    Properties:
      Runtime: nodejs18.x
      Handler: dist/handler.handler
      Timeout: 10
      MemorySize: 256
      Environment:
        Variables:
          DATABASE_URL: YOUR_CONNECTION_STRING
      Architecture: arm64
      CodeUri: .
      Policies:
        - AWSLambdaBasicExecutionRole
  Api:
    Type: AWS::ApiGatewayV2::Api
    Properties:
      Name: TodoHttpApi
      ProtocolType: HTTP
      Target: !GetAtt TodoFunction.Arn
```

Build & package:
```bash
npm run build
sam build
sam deploy --guided
```

### 2. Serverless Framework (outline)

`serverless.yml` snippet:
```yaml
service: todo-list
frameworkVersion: '3'
provider:
  name: aws
  runtime: nodejs18.x
  environment:
    DATABASE_URL: ${env:DATABASE_URL}
functions:
  api:
    handler: dist/handler.handler
    events:
      - httpApi: '*'
package:
  patterns:
    - dist/**
    - node_modules/**
    - package.json
    - package-lock.json
```

After building:
```bash
npm run build
npx serverless deploy
```

### 3. AWS CDK (outline)

Create a `lambda.Function` with:
- `entry` (if using `aws-lambda-nodejs`) pointed at `src/handler.ts` OR
- Use a prepared asset directory with `dist/`.

---

## Build

```bash
npm run build
```

Outputs to `dist/`.

To perform a type-only check:
```bash
npm run check
```

Lint:
```bash
npm run lint
```

---

## Testing Locally (Ad-hoc)

Basic Node invocation:
```bash
node -e 'import("./dist/handler.js").then(m=>m.handler({ httpMethod:"GET", path:"/todos"}).then(r=>console.log(r)))'
```

Or with `tsx` without building:
```bash
node -e 'import("./src/handler.ts").then(m=>m.handler({ httpMethod:"GET", path:"/health"}).then(r=>console.log(r)))'
```

---

## Optional: Neon Serverless Driver

If you use Neon, you might prefer their serverless client to reduce cold start latency:

1. Replace pool creation in `src/schema.ts`:

```ts
import { Pool } from '@neondatabase/serverless'; // instead of 'pg'
```

2. Remove or adapt options (Neon pool ignores some `pg` options).
3. Rebuild and deploy.

---

## Error Handling Policy

- All unhandled errors return `500` with a generic message.
- Input validation errors return `400`.
- Missing entities return `404`.
- Non-supported methods return `405`.

CloudWatch logs include stack traces for diagnostics.

---

## Extending

Ideas:
- Add pagination for `/todos`
- Add user scoping (multi-tenant) with `user_id` column
- Add OpenAPI spec for documentation
- Introduce optimistic concurrency via `updated_at`
- Add soft deletion

---

## Security Notes

- Currently open CORS (`*`). Restrict origins in production if needed.
- No authentication layer included; add an authorizer (JWT, Cognito, etc.) for protected usage.
- Validate length of `text` to mitigate oversized payloads.

---

## Performance Considerations

- Minimal dependencies = smaller cold start footprint.
- `pg` pool limited to 3 connections to avoid exhausting DB with many warm executions.
- Avoids large frameworks (Express/Fastify) to keep bundle small.

---

## License

MIT

---

## Support / Maintenance

- Update dependencies regularly (`npm outdated` / `npm audit`).
- Regenerate migrations when schema changes.
- Monitor Lambda duration & concurrent connections in DB.

---

Happy building!