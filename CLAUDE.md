# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RAG (Retrieval-Augmented Generation) Q&A assistant over a Markdown knowledge base, using
Python, LangChain v1, and Postgres with pgvector. The example knowledge base
(`knowledge_base/`) is fictional SaaS company documentation (company info, SLA, billing,
commercial policy, and three plan docs). The system answers **only** from indexed
documents — when retrieved context doesn't support an answer, it says so instead of
guessing, and every answer cites its sources.

The README.md (in Portuguese) is the canonical, detailed explanation of the pipeline,
observability, and governance design — read it for the full rationale. This file
summarizes the architecture for quick orientation and points to where to look.

## Commands

```bash
# Setup
cp .env.example .env                 # fill in OPENAI_API_KEY
docker compose up -d                 # Postgres+pgvector (Langfuse is profile "observability")
python3 -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python -m app.main                   # validates env, DB connection, pgvector extension

# Build the index (run after adding/editing docs in knowledge_base/)
python -m app.ingest                 # reads + validates docs, writes data/chunks.jsonl
python -m app.index                  # embeds + indexes only what changed in pgvector
python -m app.index --force          # rebuild the index from scratch

# Run
python -m app.rag_chat                     # terminal chat
python -m app.rag_chat --debug             # + query plan, chunks, timings, tokens, policy
python -m app.rag_chat --show-prompt       # + the three prompts sent to the model
python -m app.rag_chat --no-rerank         # skip reranking, use top 4 from retrieval
uvicorn app.api:app --reload                # HTTP API (GET /health, POST /chat)

# Inspection / comparison tools (no governance policy applied, lab use only)
python -m app.retrieve "sua pergunta"      # vector search only, no chat model
python -m app.chat                          # chat with no RAG (baseline)
python -m app.context_chat [arquivo.md]     # whole document in the prompt, no embeddings

# Observability backends
docker compose --profile jaeger up -d         # UI at http://localhost:16686 (lightest OTLP backend)
docker compose --profile observability up -d  # full Langfuse stack, UI at http://localhost:3000
```

Every command above has a `make` target (`make` prints the catalog; recommended order in
`GUIA_EXECUCAO.md`). `TRACE=console|jaeger|langfuse|off` and `POLICY=model|budget` are
modifiers for `chat*`/`api` targets, e.g. `make chat-debug TRACE=console`. Keep the
Makefile portable (Windows cmd/PowerShell/Git Bash): no `cp`/`cat`/`VAR=x cmd` in recipes.

There is no test suite, linter, or formatter configured in this repo. `test.http`
contains ready-made requests for the VS Code REST Client extension.

## Architecture

### Pipeline (`app/rag_pipeline.py`)

The whole pipeline lives in one function returning a plain data object; the terminal
(`app/rag_chat.py`) and the HTTP API (`app/api.py`) are the only two presentation layers
on top of it. Order of operations, each with a short-circuit:

1. **Governance check** (`app/governance.py`) — before anything else, including
   embeddings: is the configured model allowed, and is the monthly budget still available?
   Blocked requests return a controlled "policy" answer, not an error.
2. **Query planning** (`app/query_planner.py`) — the chat model reads the question and
   returns a structured `QueryPlan`: normalized question, literal terms to preserve,
   candidate `doc_types`, an optional `plan`, and `needs_clarification`. Ambiguous
   questions ("o plano da empresa" can mean two things) short-circuit here with a
   clarification question instead of a guess.
3. **Retrieval** (`app/query_planner.py`) — semantic search in pgvector with the
   normalized query, filtered by the plan's metadata. Deliberately generous (`TOP_K = 8`)
   so reranking has material to choose from. No chunks → "not found", stop.
4. **Reranking** (`app/rerank.py`) — the model reads the 8 candidates and keeps at most 4
   that actually help answer. Retrieval optimizes recall; reranking optimizes precision.
   No relevant chunk → stop here, **the answer model is never called**.
5. **Answer generation** (`app/rag_pipeline.py`) — the model answers using only the
   selected chunks, returning `answer`, `has_answer`, and `used_chunk_ids`.

The chat model is called at exactly three points: planner, reranker, answer. Ingestion
and indexing only ever call the embeddings model.

### Two decisions that shape everything else

- **The application owns security and sources, not the model.** `tenant`, `product`,
  `status` are fixed filters in code (`SAFE_FILTERS` in `app/query_planner.py`), outside
  the model's reach — it can only suggest content filters (`doc_type`, `plan`). Sources
  in the response are never written by the model: the application intersects the
  `used_chunk_ids` it cited against the metadata of chunks that were actually retrieved,
  discarding any invented id.
- **The metadata filter is eliminatory, not advisory.** It runs before semantic search,
  like a `WHERE` clause — what doesn't pass can't be retrieved even if it contains the
  exact answer. This is why the planner is instructed to list *every* `doc_type` that
  could hold the answer (a plan's price lives in both `policy` and `plan` docs) and to
  leave the list empty rather than guess wrong.

### Ingestion and indexing (`app/ingest.py`, `app/index.py`, `app/manifest.py`)

- `ingest` requires complete YAML front matter per doc (`title`, `tenant`, `product`,
  `plan`, `doc_type`, `version`, `status`, `visibility`) and fails loudly if anything is
  missing. Chunking is structure-aware: `MarkdownHeaderTextSplitter` by section first,
  then `RecursiveCharacterTextSplitter` (900 chars, 150 overlap) for oversized sections.
  Each chunk is prefixed with a context header (title/type/product/plan/version/section)
  since metadata isn't embedded, only used for filtering.
- `index` is incremental: each chunk carries a SHA256 hash of its source doc, chunk ids
  are deterministic (file + hash + position), and `data/index_manifest.json` tracks what
  was indexed last run. New/changed/removed/unchanged docs are diffed so re-running
  `index` never duplicates data or re-spends embeddings. `--force` rebuilds from scratch.
- **The runtime never indexes.** Chat and API only query the existing index.

### Adding a document to the knowledge base

1. Add the `.md` to `knowledge_base/` with complete front matter.
2. If it introduces a new `doc_type` or `plan` value, update the `DocType`/`Plan`
   `Literal`s **and** the document-type catalog in `PLANNER_SYSTEM_PROMPT`
   (`app/query_planner.py`). The planner only "sees" the knowledge base through that
   catalog — an unknown type is never selected, so its documents silently disappear from
   every filtered search. `ensure_planner_covers_index()` validates this contract at
   startup and fails fast if the index has metadata the planner doesn't know about.
3. `python -m app.ingest && python -m app.index` — only the new/changed document is
   touched.
4. `plan: all` marks a document valid for every plan (filter becomes `plan IN [plan,
   "all"]`), for content that isn't plan-specific.

### Observability (`app/observability.py`)

OpenTelemetry spans, never a backend-specific SDK — where traces go is a config decision
(console in development; any OTLP endpoint — Langfuse, Jaeger, Phoenix, Datadog, etc. —
otherwise), not a code one. Root span `ai.rag.pipeline`, one child span per pipeline step
(`ai.rag.query_planning`, `ai.rag.retrieval`, `ai.rag.reranking`, `ai.rag.answer_generation`).
Answer generation uses GenAI semantic-convention attribute names (`gen_ai.*`); everything
project-specific uses the `app.*` prefix.

Governed by `APP_ENV` (`development`/`staging`/`production`), which controls sample rate
and whether raw content (question/answer) may ever be captured —
`OBSERVABILITY_CAPTURE_CONTENT=true` is only legal in `development` and
`validate_observability_policy()` refuses to start the app otherwise. Never captured in
any environment: prompts, assembled context, chunk content, documents,
`OPENAI_API_KEY`, `DATABASE_URL`, OTLP header values.

Structured JSON logs go to stdout per request with `request_id`, counts, timings, token
usage, and source files — never prompt/content/credentials.

### Governance (`app/governance.py`)

Runs before the query planner, retrieval, or any embedding call. Three policy levers from
env: `AI_ALLOWED_MODELS` (blocks disallowed `OPENAI_CHAT_MODEL`), `AI_MONTHLY_BUDGET_USD`
(blocks once estimated monthly spend hits the cap), `AI_MAX_OUTPUT_TOKENS` (passed to
`init_chat_model(..., max_tokens=...)`). A blocked request gets a controlled
"policy" answer with HTTP 200, `has_answer: false`, `sources: []` — not an error.

Every call that actually hits the model appends a line to `data/ai_usage.jsonl` (the
"ledger": tokens and an estimated cost using a fictional price table in
`governance.py`); the next request reads this file to know current month spend. This is
explicitly a local, non-production simulation (no DB transaction, no multi-process
coordination) meant to show where the governance decision lives and how it reuses
already-measured token counts — not a real billing system.

This policy applies only to `app/rag_pipeline.py`. The comparison tools (`app.chat`,
`app.context_chat`, `app.retrieve`) call the model/embeddings directly and bypass it,
by design (lab tools).

## Key files

| File | Role |
| --- | --- |
| `app/config.py` | Pydantic settings loaded from `.env` |
| `app/db.py` | Postgres connection + pgvector extension setup |
| `app/ingest.py` | Reads/validates `knowledge_base/`, writes `data/chunks.jsonl` |
| `app/index.py` | Incremental embedding + indexing into pgvector (`TABLE_NAME`) |
| `app/manifest.py` | Document hashing and `data/index_manifest.json` |
| `app/query_planner.py` | `QueryPlan`, `SAFE_FILTERS`, `DocType`/`Plan` literals, retrieval |
| `app/rerank.py` | Selects which retrieved chunks reach the final prompt |
| `app/rag_pipeline.py` | The full pipeline, shared by terminal and API |
| `app/observability.py` | All OpenTelemetry span/attribute logic, isolated here |
| `app/governance.py` | Model allowlist, budget policy, usage ledger |
| `app/rag_chat.py` | Terminal chat client |
| `app/api.py` | FastAPI HTTP client |
| `app/retrieve.py`, `app/chat.py`, `app/context_chat.py` | Comparison/inspection tools, bypass governance |

## Working in this repo

- Changing retrieval behavior almost always means touching both the `DocType`/`Plan`
  contract in `app/query_planner.py` and the planner's prompt catalog — they must stay in
  sync with what's actually in `knowledge_base/` and the index.
- Never add security/tenant filtering logic that the model can influence — that belongs
  in `SAFE_FILTERS`, fixed in code.
- Never add a telemetry attribute or log field carrying prompt text, chunk content, full
  documents, or credentials (`OPENAI_API_KEY`, `DATABASE_URL`). Counts, ids, flags,
  filters, and timings only.
- `app/governance.py`'s pricing table is intentionally fictional — don't treat it as real
  billing logic to "fix" or make accurate.
