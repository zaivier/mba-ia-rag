import sys
import warnings

# psycopg's async mode (used by SQLAlchemy through langchain-postgres' PGEngine) cannot
# run on Windows' default ProactorEventLoop: it needs add_reader/add_writer, which only
# the selector loop has. PGEngine builds its own loop with asyncio.new_event_loop(), so
# the policy has to be set before the first engine exists. Doing it here covers every
# entry point (python -m app.*, uvicorn app.api:app, pytest), since they all import `app`.
if sys.platform == "win32":
    import asyncio

    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)  # deprecated from 3.14
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
