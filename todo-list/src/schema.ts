// Drizzle schema for TODO list (tree-shakable / minimal imports)
import { pgTable, serial, text, boolean, timestamp } from 'drizzle-orm/pg-core';
import { drizzle } from 'drizzle-orm/node-postgres';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { eq } from 'drizzle-orm';
import { Pool } from 'pg';

/**
 * Environment variable name for the Postgres connection string.
 * Kept as a constant so bundlers can tree-shake unused code paths
 * if this module is partially imported.
 */
const DATABASE_URL_ENV = 'DATABASE_URL';

/**
 * Internal singleton references. They are intentionally NOT exported
 * to keep side-effect surface minimal and allow unused exports
 * to be pruned by bundlers (e.g. esbuild, webpack, rollup).
 */
let poolSingleton: Pool | null = null;
let dbSingleton: NodePgDatabase | null = null;

/**
 * Lazily create (or reuse) a pg Pool. No work is done at module load,
 * which helps cold start performance and enables tree-shaking of the
 * connection logic if only the types or table definitions are imported.
 */
function getPool(): Pool {
  if (poolSingleton) return poolSingleton;

  const connectionString = process.env[DATABASE_URL_ENV];
  if (!connectionString) {
    throw new Error(
      `Missing required environment variable ${DATABASE_URL_ENV}. Set it to your Postgres connection string.`,
    );
  }

  poolSingleton = new Pool({
    connectionString,
    // Keep small in Lambda to avoid exhausting connections with concurrency.
    max: 3,
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 30_000,
  });
  return poolSingleton;
}

/**
 * Obtain a Drizzle database instance (singleton).
 * Separated from table definition so importing only `todos`
 * does not pull in the driver layer if unused.
 */
export function getDb(): NodePgDatabase {
  if (dbSingleton) return dbSingleton;
  dbSingleton = drizzle(getPool());
  return dbSingleton;
}

/**
 * Table definition (pure metadata) – safe to import alone
 * without triggering any side effects (no Pool created yet).
 */
export const todos = pgTable('todos', {
  id: serial('id').primaryKey(),
  text: text('text').notNull(),
  completed: boolean('completed').notNull().default(false),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .$onUpdate(() => new Date()),
});

export type Todo = typeof todos.$inferSelect;
export type NewTodo = typeof todos.$inferInsert;

/* ---------- CRUD Helpers (each lazily initializes DB) ---------- */

export async function createTodo(textValue: string): Promise<Todo> {
  const db = getDb();
  const [row] = await db.insert(todos).values({ text: textValue }).returning();
  return row;
}

export async function listTodos(): Promise<Todo[]> {
  const db = getDb();
  return db.select().from(todos).orderBy(todos.createdAt);
}

export async function setTodoCompleted(id: number, completed: boolean): Promise<Todo | null> {
  const db = getDb();
  const [row] = await db.update(todos).set({ completed }).where(eq(todos.id, id)).returning();
  return row ?? null;
}

export async function deleteTodo(id: number): Promise<boolean> {
  const db = getDb();
  const result = await db.delete(todos).where(eq(todos.id, id)).returning({ id: todos.id });
  return result.length > 0;
}

/**
 * Lightweight health check – avoids importing the tagged template `sql`
 * so bundlers can tree-shake `sql` related code. We simply perform a trivial
 * select with a LIMIT 1 on the todos table (safe even if empty).
 */
export async function healthCheck(): Promise<boolean> {
  const db = getDb();
  // Selecting a constant via existing table ensures the query is valid even if empty.
  await db.select({ ok: todos.id }).from(todos).limit(1);
  return true;
}

/**
 * Utility for tests / shutdown hooks (optional). Not exported by default
 * to keep public surface area minimal; uncomment export if needed.
 */
// async function closePool(): Promise<void> {
//   if (poolSingleton) {
//     await poolSingleton.end();
//     poolSingleton = null;
//     dbSingleton = null;
//   }
// }
