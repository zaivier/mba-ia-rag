# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

RAG (Retrieval-Augmented Generation) knowledge chat built with Python, LangChain (v1), and
Postgres/pgvector. The knowledge base is a fictional SaaS company's (FCAI) internal docs
(Markdown with YAML front matter) under `knowledge_base/`. Code comments, docstrings, and the
README are in Portuguese; match that when editing existing files.

## Setup & commands

```bash
cp .env.example .env              # fill OPENAI_API_KEY
docker compose up -d              # Postgres + pgvector on localhost:5432
pip install -r requirements.txt
python -m app.main                # validates env, DB connection, pgvector extension
```

Build the index (required before chat/API work):

```bash
python -m app.ingest              # reads knowledge_base/, validates front matter, writes data/chunks.jsonl
python -m app.index                # embeds + indexes into pgvector; incremental by default
python -m app.index --force        # wipes and rebuilds the whole index
```

Run / inspect:

```bash
python -m app.rag_chat                 # terminal chat with full RAG pipeline
python -m app.rag_chat --debug         # prints QueryPlan + retrieved/selected chunks
python -m app.rag_chat --show-prompt   # prints planner/reranker/answer prompts
python -m app.rag_chat --no-rerank     # skips reranking, uses top 4 from retrieval

uvicorn app.api:app --reload           # HTTP API over the same pipeline (GET /health, POST /chat)

python -m app.retrieve "question" --top-k 5 --doc-type sla --plan all   # retrieval only, no LLM call
python -m app.chat                     # no-RAG baseline chat (streams)
python -m app.context_chat [file.md]   # whole-document-in-prompt baseline (no retrieval)
```

There is no test suite, linter, or formatter configured in this repo (no `pytest`, `ruff`,
`black`, etc. in `requirements.txt`). Don't assume one exists.

## Architecture

Everything funnels through one shared pipeline, `app/rag_pipeline.py`, used identically by the
terminal chat (`app/rag_chat.py`) and the HTTP API (`app/api.py`). Per question:

```
query planner (LLM, structured output)  → ambiguous? return clarification question, stop
        ↓
vector search in pgvector (normalized question + exact terms, metadata filters)
        ↓
reranking (LLM, structured output)      → no chunk supports an answer? return "not found", stop
        ↓
answer model (structured output)        → Answer + Sources (sources built by app code, never by the model)
```

The chat model is called at exactly those three points (planner, reranker, answer). Ingestion
and indexing never call the chat model — only the embeddings model.

**Module map** (`app/`):
- `config.py` — loads/validates env vars via pydantic-settings (`.env` at repo root)
- `db.py` — Postgres connection + pgvector extension setup
- `ingest.py` — reads `knowledge_base/*.md`, validates required front matter, chunks
  (`MarkdownHeaderTextSplitter` by section, then `RecursiveCharacterTextSplitter`,
  `chunk_size=900`/`chunk_overlap=150`), writes `data/chunks.jsonl`. Each document gets a
  SHA256 `document_hash`; each chunk gets a deterministic `chunk_id` (`file` + hash prefix +
  position), so identical content always produces identical ids and edits produce new ones.
- `manifest.py` — hashing + read/write of `data/index_manifest.json`
- `index.py` — embeds and upserts chunks into the `fcai_knowledge_base` table (`PGEngine` +
  `PGVectorStore` from `langchain-postgres`), reindexing only `new`/`changed`/`removed`
  documents per the manifest (`unchanged` costs zero embedding calls); `--force` rebuilds
  everything
- `retrieve.py` — standalone vector search with metadata filters, no LLM involved
- `query_planner.py` — `QueryPlan` structured output (`normalized_question`, `exact_terms`,
  `doc_types`, `plan`, `needs_clarification`); defines the `DocType`/`Plan` `Literal`s and the
  planner's catalog prompt
- `rerank.py` — `RerankResult` structured output; picks at most 4 `chunk_id`s from retrieval
  candidates that directly support the answer, or an empty list to short-circuit with "not found"
- `rag_pipeline.py` — orchestrates the flow above; shared by chat and API
- `rag_chat.py` — terminal chat (`--debug`, `--show-prompt`, `--no-rerank` flags)
- `api.py` — FastAPI app (`GET /health`, `POST /chat` with `debug`/`use_rerank` fields)
- `chat.py` / `context_chat.py` — comparison baselines (no RAG; whole-doc-in-prompt), not part
  of the main pipeline

### Windows event loop

`PGEngine.from_connection_string()` runs psycopg in async mode on its own event loop
(`asyncio.new_event_loop()`), and psycopg rejects Windows' default `ProactorEventLoop`. Always
build engines with `create_pg_engine()` (`app/db.py`), which passes an explicit
`SelectorEventLoop` via `PGEngine.from_engine`. Never call `PGEngine.from_connection_string`
directly, and don't use `asyncio.set_event_loop_policy` (deprecated since Python 3.14).

### Filters: model vs. application

The planner only *suggests* content filters (`doc_types`, `plan`). Access-control filters are
hardcoded in application code and never delegated to the model:

```python
SAFE_FILTERS = {"tenant": "fcai", "product": "fcai-cloud", "status": "published"}
```

The metadata filter runs *before* semantic search (eliminatory, like a `WHERE`), so the
planner is instructed to be generous with `doc_types` — recall matters more than precision at
that stage; reranking handles precision afterward.

### The planner/index contract

`DocType` and `Plan` in `query_planner.py` are `Literal`s. Adding a new `doc_type` or `plan` to
`knowledge_base/` requires updating both the `Literal` and the catalog text in
`PLANNER_SYSTEM_PROMPT` — otherwise documents with that value silently vanish from filtered
search. Startup validation (`ensure_planner_covers_index()`) checks the index's actual
`doc_type`/`plan` values against what the planner knows and fails loudly if they diverge.

### Sources and answers are never trusted from the model

The answer model returns structured output (`answer`, `has_answer`, `used_chunk_ids`). The
app cross-references `used_chunk_ids` against the actually-retrieved chunks to build
`Sources`; any id the model invents that wasn't in the candidate set is discarded. Same pattern
applies to reranker output.

### Observability

Each pipeline run gets a `request_id` (UUID), per-stage timings
(`query_planning_ms`/`retrieval_ms`/`reranking_ms`/`answer_generation_ms`/`total_ms`), and
per-model token usage (`model_usage`, via LangChain's `UsageMetadataCallbackHandler`). A
structured JSON log line is emitted per run (no prompts/context/credentials in it). The API
exposes this via `debug=true`; the terminal chat via `--debug`.

### Incremental indexing

`app/index.py` diffs current chunks against `data/index_manifest.json` and only touches
`new`/`changed`/`removed` documents — see the README's "Incremental indexing" section for the
full state table. Never reindex by deleting and reingesting everything unless `--force` is
actually what's needed; prefer letting the manifest-driven diff do its job.

## Adding a knowledge base document

1. Add the `.md` under `knowledge_base/` with complete YAML front matter (required fields:
   `title`, `tenant`, `product`, `plan`, `doc_type`, `version`, `status`, `visibility`).
2. If it introduces a new `doc_type` or `plan`, update the `DocType`/`Plan` `Literal`s **and**
   the catalog in `PLANNER_SYSTEM_PROMPT` (`app/query_planner.py`) — startup validation will
   point exactly at this if skipped.
3. Regenerate and reindex: `python -m app.ingest && python -m app.index` (only the new/changed
   document gets embedded).
