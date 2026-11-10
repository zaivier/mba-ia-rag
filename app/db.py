import asyncio
import sys

import psycopg

from app.config import settings

# Windows runs asyncio on the ProactorEventLoop by default, and psycopg refuses to use
# it in async mode. langchain_postgres (PGEngine) opens its connections from a loop it
# creates itself, so the policy has to be set before that loop exists: importing this
# module, which every PGEngine user does first, is early enough.
if sys.platform == "win32" and hasattr(asyncio, "WindowsSelectorEventLoopPolicy"):
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
