/**
 * AWS Lambda HTTP handler for the TODO list service.
 *
 * Supported endpoints (assumes API Gateway proxy integration):
 *   OPTIONS  /{any}                   -> CORS preflight
 *   GET      /health                  -> health check
 *   GET      /todos                   -> list all todos
 *   POST     /todos                   -> create a todo (body: { "text": string })
 *   PATCH    /todos/{id}              -> update completion state (body: { "completed": boolean })
 *   DELETE   /todos/{id}              -> delete a todo
 *
 * All successful responses are JSON: { data: ..., meta?: ... }
 * Error responses: { error: { message: string } }
 *
 * This file is intentionally dependency‑light to fit well in a Lambda bundle.
 */

import { createTodo, listTodos, setTodoCompleted, deleteTodo, healthCheck } from './schema';

interface LambdaEvent {
  // Subset of the API Gateway proxy event we rely on (kept minimal to avoid extra type deps)
  httpMethod?: string;
  requestContext?: { httpMethod?: string };
  path?: string;
  rawPath?: string;
  body?: string | null;
  headers?: Record<string, string | undefined>;
  isBase64Encoded?: boolean;
}

interface LambdaResult {
  statusCode: number;
  headers?: Record<string, string>;
  body?: string;
}

/* ---------- Utility helpers ---------- */

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type,Authorization,X-Requested-With',
  'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS',
  'Access-Control-Allow-Credentials': 'false',
};

function json(
  statusCode: number,
  payload: unknown,
  extraHeaders?: Record<string, string>,
): LambdaResult {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      ...CORS_HEADERS,
      ...(extraHeaders ?? {}),
    },
    body: JSON.stringify(payload),
  };
}

function error(statusCode: number, message: string): LambdaResult {
  return json(statusCode, { error: { message } });
}

function notFound(): LambdaResult {
  return error(404, 'Not Found');
}

function methodNotAllowed(): LambdaResult {
  return error(405, 'Method Not Allowed');
}

function parseId(segment: string | undefined): number | null {
  if (!segment) return null;
  const n = Number(segment);
  return Number.isInteger(n) && n > 0 ? n : null;
}

function safeParseJson<T>(
  raw: string | null | undefined,
): { ok: true; value: T } | { ok: false; err: string } {
  if (!raw) return { ok: false, err: 'Empty body' };
  try {
    return { ok: true, value: JSON.parse(raw) as T };
  } catch {
    return { ok: false, err: 'Invalid JSON' };
  }
}

/* ---------- Route Handling ---------- */

export const handler = async (event: LambdaEvent): Promise<LambdaResult> => {
  const method =
    event.httpMethod ||
    event.requestContext?.httpMethod ||
    // Some runtimes supply uppercase; enforce uppercase
    'GET';
  const path = normalizePath(event.rawPath || event.path || '/');

  // Handle CORS preflight
  if (method === 'OPTIONS') {
    return {
      statusCode: 204,
      headers: {
        ...CORS_HEADERS,
        'Content-Length': '0',
      },
      body: '',
    };
  }

  try {
    if (path === '/health' && method === 'GET') {
      await healthCheck();
      return json(200, { data: { ok: true } });
    }

    if (path === '/todos') {
      if (method === 'GET') {
        const todos = await listTodos();
        return json(200, { data: todos });
      }
      if (method === 'POST') {
        if (event.isBase64Encoded) {
          return error(400, 'Base64-encoded bodies are not supported');
        }
        const parsed = safeParseJson<{ text?: unknown }>(event.body);
        if (!parsed.ok) {
          return error(400, parsed.err);
        }
        const { text } = parsed.value;
        if (typeof text !== 'string' || text.trim().length === 0) {
          return error(400, '`text` must be a non-empty string');
        }
        if (text.length > 500) {
          return error(400, '`text` exceeds 500 characters');
        }
        const todo = await createTodo(text.trim());
        return json(201, { data: todo });
      }
      return methodNotAllowed();
    }

    // Match /todos/{id}
    if (path.startsWith('/todos/')) {
      const segments = path.split('/');
      // ['', 'todos', '{id}']
      const id = parseId(segments[2]);
      if (!id) {
        return error(400, 'Invalid ID');
      }

      if (method === 'PATCH') {
        if (event.isBase64Encoded) {
          return error(400, 'Base64-encoded bodies are not supported');
        }
        const parsed = safeParseJson<{ completed?: unknown }>(event.body);
        if (!parsed.ok) return error(400, parsed.err);
        const { completed } = parsed.value;
        if (typeof completed !== 'boolean') {
          return error(400, '`completed` must be a boolean');
        }
        const updated = await setTodoCompleted(id, completed);
        if (!updated) {
          return notFound();
        }
        return json(200, { data: updated });
      }

      if (method === 'DELETE') {
        const ok = await deleteTodo(id);
        if (!ok) {
          return notFound();
        }
        return json(200, { data: { id, deleted: true } });
      }

      return methodNotAllowed();
    }

    return notFound();
  } catch (err) {
    // Log the error for CloudWatch; avoid exposing stack traces to clients.
    // eslint-disable-next-line no-console
    (globalThis as { console?: { error: (...a: unknown[]) => void } }).console?.error(
      'Unhandled error',
      {
        message: (err as Error).message,
        stack: (err as Error).stack,
      },
    );
    return error(500, 'Internal Server Error');
  }
};

/* ---------- Helpers ---------- */

function normalizePath(p: string): string {
  if (!p.startsWith('/')) p = '/' + p;
  if (p.length > 1 && p.endsWith('/')) p = p.slice(0, -1);
  return p;
}
