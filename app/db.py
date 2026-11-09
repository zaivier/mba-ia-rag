import asyncio
from threading import Thread

import psycopg
from langchain_postgres import PGEngine
from sqlalchemy.ext.asyncio import create_async_engine

from app.config import settings

_engine_loop: asyncio.AbstractEventLoop | None = None


def _get_engine_loop() -> asyncio.AbstractEventLoop:
    """Loop em thread de fundo, compartilhado por todos os PGEngine do processo."""
    global _engine_loop
    if _engine_loop is None:
        _engine_loop = asyncio.SelectorEventLoop()
        Thread(target=_engine_loop.run_forever, daemon=True).start()
    return _engine_loop


def create_pg_engine() -> PGEngine:
    """Cria o PGEngine com um SelectorEventLoop explicito.

    PGEngine.from_connection_string cria o proprio loop com asyncio.new_event_loop(),
    que no Windows e um ProactorEventLoop, e o psycopg 3 recusa esse loop no modo
    async. Passar o loop via from_engine evita isso sem alterar a politica global
    do asyncio (set_event_loop_policy esta deprecado desde o Python 3.14).
    """
    return PGEngine.from_engine(
        create_async_engine(settings.database_url), loop=_get_engine_loop()
    )


def get_connection() -> psycopg.Connection:
    return psycopg.connect(settings.psycopg_dsn)


def test_connection() -> None:
    with get_connection() as conn:
        conn.execute("SELECT 1")


def enable_vector_extension() -> None:
    with get_connection() as conn:
        conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
        conn.commit()
