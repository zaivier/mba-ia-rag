# RAG Knowledge Chat: uma receita por funcionalidade, não por rota da API.
#
#   make            lista tudo (o mesmo que make help)
#   make setup      prepara o ambiente Python
#
# A ordem recomendada de execução está em docs/execution-guide.md.
#
# Precisa de um shell POSIX (Linux, macOS, ou Git Bash/MSYS no Windows) e de Docker.
# Variáveis opcionais (veja cada alvo): LIMIT, CASE, NORERANK, DEBUG, Q, DOC, ...

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------

# Python que cria o venv (o do sistema). No Linux/macOS use: make setup BOOTSTRAP_PYTHON=python3
BOOTSTRAP_PYTHON ?= python

ifeq ($(OS),Windows_NT)
  PY ?= .venv/Scripts/python
else
  PY ?= .venv/bin/python
endif

COMPOSE := docker compose
HOST    ?= 127.0.0.1
PORT    ?= 8000

# Evita UnicodeEncodeError com acentos no console do Windows.
export PYTHONUTF8 := 1

# Flags opcionais, montadas só quando a variável é passada: make eval-judge LIMIT=3 NORERANK=1
LIMIT_FLAG    = $(if $(LIMIT),--limit $(LIMIT))
CASE_FLAG     = $(if $(CASE),--case-id $(CASE))
NORERANK_FLAG = $(if $(NORERANK),--no-rerank)
EVAL_FLAGS    = $(LIMIT_FLAG) $(CASE_FLAG) $(NORERANK_FLAG)

.PHONY: help \
	setup env venv install check-venv \
	db-up observability-up jaeger-up down infra-status infra-reset \
	check ingest ingest-no-header index index-force prepare \
	retrieve chat chat-no-rag chat-context \
	api test \
	eval-validate eval-dataset eval-components eval-ragas eval-judge eval-calibrate \
	eval-baseline eval-no-rerank eval-compare eval-ab

# ---------------------------------------------------------------------------
# Ajuda
# ---------------------------------------------------------------------------

help: ## Lista os comandos disponíveis
	@echo "RAG Knowledge Chat - comandos (ordem completa em docs/execution-guide.md)"
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "} {printf "  %-18s %s\n", $$1, $$2}'
	@echo ""
	@echo "Variaveis: LIMIT=n  CASE=id  NORERANK=1  DEBUG=1  SHOW_PROMPT=1  Q=\"pergunta\"  DOC=arquivo.md"

# ---------------------------------------------------------------------------
# 1. Ambiente Python
# ---------------------------------------------------------------------------

setup: env venv install ## Ambiente completo: .env + venv + dependências

env: ## Cria o .env a partir do .env.example (não sobrescreve)
	@if [ -f .env ]; then echo ".env ja existe, mantido."; \
	else cp .env.example .env && echo ".env criado: preencha OPENAI_API_KEY."; fi

venv: ## Cria o ambiente virtual em .venv
	@if [ -f $(PY) ]; then echo ".venv ja existe."; \
	else $(BOOTSTRAP_PYTHON) -m venv .venv && echo ".venv criado."; fi

install: venv ## Instala o requirements.txt no .venv
	$(PY) -m pip install -r requirements.txt

check-venv:
	@test -f $(PY) || { echo "Ambiente virtual nao encontrado. Rode: make setup"; exit 1; }

# ---------------------------------------------------------------------------
# 2. Infraestrutura (Docker)
# ---------------------------------------------------------------------------

db-up: ## Sobe só o Postgres com pgvector (localhost:5433)
	$(COMPOSE) up -d --wait postgres

observability-up: ## Sobe Postgres + Langfuse (UI em http://localhost:3000)
	$(COMPOSE) --profile observability up -d

jaeger-up: ## Sobe Postgres + Jaeger, alternativa leve (UI em http://localhost:16686)
	$(COMPOSE) --profile jaeger up -d

down: ## Para todos os containers, mantendo os dados
	$(COMPOSE) --profile observability --profile jaeger down

infra-status: ## Mostra o estado dos containers
	$(COMPOSE) --profile observability --profile jaeger ps

infra-reset: ## DESTRUTIVO: para tudo e apaga os volumes (índice e Langfuse)
	$(COMPOSE) --profile observability --profile jaeger down -v

# ---------------------------------------------------------------------------
# 3. Base de conhecimento: validar, ingerir, indexar
# ---------------------------------------------------------------------------

check: check-venv ## Valida .env, conexão com o banco e extensão pgvector
	$(PY) -m app.main

ingest: check-venv ## Lê knowledge_base/, valida o front matter e gera data/chunks.jsonl
	$(PY) -m app.ingest

ingest-no-header: check-venv ## Igual ao ingest, sem o cabeçalho de contexto (para comparar)
	$(PY) -m app.ingest --no-context-header

index: check-venv ## Gera embeddings e indexa no pgvector (incremental: só o que mudou)
	$(PY) -m app.index

index-force: check-venv ## Recria o índice do zero
	$(PY) -m app.index --force

prepare: ingest index ## Ingest + index: deixa a base pronta para consulta

# ---------------------------------------------------------------------------
# 4. Usar o sistema
# ---------------------------------------------------------------------------

chat: check-venv ## Chat RAG no terminal (DEBUG=1, SHOW_PROMPT=1, NORERANK=1)
	$(PY) -m app.rag_chat $(if $(DEBUG),--debug) $(if $(SHOW_PROMPT),--show-prompt) $(NORERANK_FLAG)

api: check-venv ## Sobe a API HTTP em http://127.0.0.1:8000 (exemplos em test.http)
	$(PY) -m uvicorn app.api:app --reload --host $(HOST) --port $(PORT)

retrieve: check-venv ## Só a busca vetorial: make retrieve Q="..." [TOP_K= PLAN= DOC_TYPE=]
	@test -n "$(Q)" || { echo 'Informe a pergunta: make retrieve Q="Qual o SLA do P1?"'; exit 1; }
	$(PY) -m app.retrieve "$(Q)" $(if $(TOP_K),--top-k $(TOP_K)) $(if $(PLAN),--plan $(PLAN)) $(if $(DOC_TYPE),--doc-type $(DOC_TYPE))

chat-no-rag: check-venv ## Linha de base: chat direto no modelo, sem a base
	$(PY) -m app.chat

chat-context: check-venv ## Chat com UM documento inteiro no prompt (DOC=arquivo.md)
	$(PY) -m app.context_chat $(DOC)

# ---------------------------------------------------------------------------
# 5. Avaliação (da mais barata à mais cara)
# ---------------------------------------------------------------------------

test: check-venv ## Contract tests (pytest): sem LLM, sem banco, custo zero
	$(PY) -m pytest

eval-validate: check-venv ## Valida o dataset de evaluation, offline
	$(PY) -m app.eval_dataset --validate-only

eval-dataset: check-venv ## Valida e sincroniza o dataset com o Langfuse
	$(PY) -m app.eval_dataset

eval-calibrate: check-venv ## Calibra o judge com respostas ruins conhecidas (LLM, sem banco)
	$(PY) -m app.eval_judge --calibrate

# Variável de ambiente por alvo: funciona em qualquer shell e é o "sim, quero gastar token".
eval-components: export RUN_COMPONENT_EVALS := true
eval-components: check-venv ## Planner, retrieval e rerank (~5 min; LIMIT, CASE, NORERANK, NOLANGFUSE=1)
	$(PY) -m app.eval_components $(EVAL_FLAGS) $(if $(NOLANGFUSE),--no-langfuse)

eval-ragas: check-venv ## Ragas: fidelidade, relevância, precisão (~6 min; LIMIT, CASE, NORERANK)
	$(PY) -m app.eval_ragas $(EVAL_FLAGS)

eval-judge: check-venv ## LLM-as-a-judge com rubrica (~5 min; LIMIT, CASE, NORERANK, MIN_SCORE=0.9)
	$(PY) -m app.eval_judge $(EVAL_FLAGS) $(if $(MIN_SCORE),--min-score $(MIN_SCORE))

eval-baseline: check-venv ## Experiment: pipeline COM rerank (~3 min; LIMIT, CASE)
	$(PY) -m app.eval_experiment --variant baseline $(LIMIT_FLAG) $(CASE_FLAG)

eval-no-rerank: check-venv ## Experiment: pipeline SEM rerank (~3 min; LIMIT, CASE)
	$(PY) -m app.eval_experiment --variant no-rerank $(LIMIT_FLAG) $(CASE_FLAG)

eval-compare: check-venv ## Compara os últimos relatórios baseline x no-rerank (sem custo)
	$(PY) -m app.eval_experiment --compare baseline no-rerank

eval-ab: eval-baseline eval-no-rerank eval-compare ## Experiment A/B completo: baseline, no-rerank e o diff
