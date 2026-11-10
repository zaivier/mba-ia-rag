import psycopg

from app.config import settings

# Without a timeout, psycopg waits on the OS default. On Windows, when the database is
# not reachable (Docker Desktop closed, container not up yet), that is minutes of a
# frozen terminal instead of an error.
CONNECT_TIMEOUT_SECONDS = 5


class DatabaseUnavailableError(RuntimeError):
    pass


def get_connection() -> psycopg.Connection:
    return psycopg.connect(settings.psycopg_dsn, connect_timeout=CONNECT_TIMEOUT_SECONDS)


def test_connection() -> None:
    try:
        with get_connection() as conn:
            conn.execute("SELECT 1")
    except (psycopg.OperationalError, UnicodeDecodeError) as exc:
        # UnicodeDecodeError: on Windows with a non-English locale, libpq can hand
        # psycopg an error message that is not UTF-8, hiding the real failure.
        raise DatabaseUnavailableError(
            "Could not connect to Postgres "
            f"({settings.psycopg_dsn.rsplit('@', 1)[-1]}). "
            "Is Docker running and the database up? Try: make infra-up"
        ) from exc


def enable_vector_extension() -> None:
    with get_connection() as conn:
        conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
        conn.commit()
