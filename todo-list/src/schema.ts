// Drizzle schema for TODO list
import { pgTable, serial, text, boolean, timestamp } from 'drizzle-orm/pg-core';
import { drizzle } from 'drizzle-orm/node-postgres';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { sql, eq } from 'drizzle-orm';
import { Pool } from 'pg';

const DATABASE_URL_ENV = 'DATABASE_URL';

let _pool: Pool | undefined;
let _db: NodePgDatabase | undefined;

/**
 * Acquire (or create) a singleton pg Pool.
 * In AWS Lambda we want to keep the pool between warm invocations; defining it at
 * module scope and reusing it achieves that. The pool size is kept intentionally low
 * because Lambdas are ephemeral and concurrent executions will create their own pools.
 */
function getPool(): Pool {
  if (_pool) {
    return _pool;
  }
  const connectionString = process.env[DATABASE_URL_ENV];
  if (!connectionString) {
    throw new Error(
      `Missing required environment variable ${DATABASE_URL_ENV}. Set it to your Postgres connection string.`,
    );
  }
  _pool = new Pool({
    connectionString,
    max: 3,
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 30_000,
  });
  return _pool;
}

export function getDb(): NodePgDatabase {
  if (_db) {
    return _db;
  }
  _db = drizzle(getPool());
  return _db;
}

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

export async function healthCheck(): Promise<boolean> {
  const db = getDb();
  await db.execute(sql`select 1`);
  return true;
}
