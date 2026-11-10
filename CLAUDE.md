# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A RAG Q&A assistant (Python, LangChain v1, Postgres + pgvector) over a fictional SaaS company's docs in `knowledge_base/`, plus **five layers of evaluation** built on top of it. The pipeline is the small part; measuring it is the point. Prose docs are in Portuguese; `docs/pipeline.md` and `docs/evaluation.md` are the detailed references and `docs/execution-guide.md` has the recommended command order.

## Commands

The Makefile is the entry point (needs a POSIX shell; on Windows, Git Bash). `make` lists everything. It uses `.venv/Scripts/python` on Windows and `.venv/bin/python` elsewhere.

```bash
make setup               # .env + .venv + deps (then fill OPENAI_API_KEY in .env)
make db-up               # Postgres/pgvector on localhost:5433
make prepare             # ingest (free) + index (embeddings, costs tokens)
make chat [DEBUG=1 SHOW_PROMPT=1 NORERANK=1]
make api                 # uvicorn on 127.0.0.1:8000; request examples in test.http
make test                # pytest: free, no DB, no OpenAI key
```

Single test: `.venv/Scripts/python -m pytest tests/test_experiment_report.py::test_name` (swap `Scripts` for `bin` on Linux/macOS). There is no linter or build step configured.

Evaluation targets (`eval-components`, `eval-ragas`, `eval-judge`, `eval-baseline`, `eval-no-rerank`, `eval-ab`) call the OpenAI API and take minutes; **start with `LIMIT=3`** (or `CASE=<id>`). `eval-validate`, `eval-compare` and `test` are free. `eval-dataset`, `eval-components` (unless `NOLANGFUSE=1`) and the experiments also need Langfuse running (`make observability-up`) with `LANGFUSE_*` keys in `.env`.

Don't run paid targets, or `make infra-reset` (deletes the index and Langfuse volumes), without the user asking.

## Architecture

**One pipeline, three consumers.** `app/rag_pipeline.py` (`RagPipeline.run`) returns a plain data object (`RagPipelineResult`); `app/api.py`, `app/rag_chat.py` and every `app/eval_*.py` call it. Flow: governance check → query planner → filtered vector search (top 8) → rerank (top 4) → answer. The chat model is called exactly three times (planner, reranker, answer). Planner clarification and "no relevant chunk" both short-circuit before the answer call.

**Indexing is offline and incremental.** `app.ingest` validates front matter and writes `data/chunks.jsonl`; `app.index` diffs it against `data/index_manifest.json` (document SHA256 + deterministic `chunk_id`) and embeds only new/changed documents. The API and chat never index. Table `fcai_knowledge_base` in pgvector.

**Invariants that span files:**
- Security filters (`SAFE_FILTERS`: tenant, product, status) are fixed in `app/query_planner.py`, outside the model's reach. The model only proposes `doc_type` and `plan`, and the metadata filter is eliminatory (applied before similarity search).
- Sources are not written by the model: the app cross-checks the `used_chunk_ids` the model cites against the chunks actually retrieved and drops invented ids.
- Adding a new `doc_type`/`plan` requires updating the `Literal`s **and** the document-type catalog in the planner prompt (`app/query_planner.py`); `ensure_planner_covers_index` fails at startup if they diverge. The same `Literal`s validate `expected_doc_types`/`expected_plan` in the eval dataset.
- Chunk text must never reach telemetry, logs, the API response or `RagPipelineResult`. The evals get contexts through an `on_context` callback (`run_for_evaluation` → `EvaluationRun.selected_contexts`), which is why the API cannot serialize them. Telemetry carries only counts, ids, flags, timings and tokens.
- `app/governance.py` runs before anything else: model allowlist (`AI_ALLOWED_MODELS`), monthly budget read from the `data/ai_usage.jsonl` ledger, max output tokens. A block returns HTTP 200 with `has_answer=false` and a fixed message, not an error. The price table is fictional. `app.chat`, `app.context_chat` and `app.retrieve` are lab tools that bypass this policy on purpose.
- `app/api.py` builds the pipeline lazily on first request (not at import) so contract tests can put a fake in `app.state.pipeline`. Keep it that way.
- OpenTelemetry lives only in `app/observability.py`; the app never depends on a backend SDK. Langfuse/Jaeger are just OTLP endpoints chosen by env vars. `OBSERVABILITY_CAPTURE_CONTENT=true` is refused at startup outside `APP_ENV=development`. The Langfuse SDK is imported only by the `eval_*` modules.

**Evaluation layers** (`app/eval_*.py`; dataset `evals/fcai_knowledge_chat.jsonl`, 37 cases, source of truth, synced to Langfuse as `v1`):
- *contract tests* (`tests/`): fake pipeline, no LLM.
- *components*: planner/retrieval/rerank scored by field comparison; gated by `RUN_COMPONENT_EVALS=true` (the Makefile sets it).
- *Ragas* and *judge*: model-scored, answerable cases only; share `app/eval_runner.py`. The judge's rubric is versioned (`RUBRIC_VERSION`) and calibrated against `evals/judge_calibration.jsonl`; bump the version when the rubric changes so reports stay comparable.
- *experiments* (`eval_experiment.py`): variants `baseline` (rerank) vs `no-rerank`, reports in `data/eval_runs/`; `--compare` refuses runs over different case sets or datasets.
- Convention across the evals: a case where a metric does not apply yields `None` and no score (never a free pass), and changing dataset expectations after measuring means a new dataset version, not an edit.

**Dependency pin:** `langchain-community==0.4.1` is deliberate (ragas 0.4.3 breaks on 0.4.2+); `app/eval_ragas.py` also sets `RAGAS_DO_NOT_TRACK` before importing ragas. Don't unpin or reorder.

## Configuration

Settings load from `.env` via `app/config.py` (pydantic-settings); `OPENAI_API_KEY`, `OPENAI_CHAT_MODEL`, `OPENAI_EMBEDDING_MODEL` and `DATABASE_URL` are required, everything else has a default. The Makefile sets `PYTHONUTF8=1` because of Windows console encoding; keep `echo` text in Makefile recipes ASCII for the same reason. `data/` is generated and git-ignored.
