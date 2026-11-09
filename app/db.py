import asyncio
import sys

import psycopg

from app.config import settings

if sys.platform == "win32":
    # langchain-postgres talks to Postgres through psycopg's async API, which cannot
    # run on Windows' default ProactorEventLoop. Every entry point (index, retrieve,
    # chat, API) imports this module before opening a connection.
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


def get_connection() -> psycopg.Connection:
    return psycopg.connect(settings.psycopg_dsn)


def test_connection() -> None:
    with get_connection() as conn:
        conn.execute("SELECT 1")


def enable_vector_extension() -> None:
    with get_connection() as conn:
        conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
        conn.commit()
