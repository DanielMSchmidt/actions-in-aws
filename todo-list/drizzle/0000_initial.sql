-- drizzle migration: initial schema for todos table
-- Generated manually for first deployment.
-- Applies id, text, completed, created_at, updated_at columns.

BEGIN;

CREATE TABLE IF NOT EXISTS "todos" (
    "id" serial PRIMARY KEY,
    "text" text NOT NULL,
    "completed" boolean NOT NULL DEFAULT false,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now()
);

-- Optional helpful indexes (not strictly required, but useful for common queries)
CREATE INDEX IF NOT EXISTS "todos_created_at_idx" ON "todos" ("created_at");
CREATE INDEX IF NOT EXISTS "todos_completed_idx" ON "todos" ("completed");

COMMIT;