## mba-ia-rag — atalhos para as funcionalidades da aplicacao
## Uso: make <alvo>  (ex.: make index, make chat, make api)

.DEFAULT_GOAL := help
.PHONY: help env install up down logs db-up setup \
	ingest index index-force reindex \
	chat chat-debug chat-show-prompt chat-no-rerank \
	api retrieve chat-baseline context-chat

PYTHON ?= python

help: ## Lista as funcionalidades disponiveis
	@echo "Alvos disponiveis:"
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /|/' | awk -F'|' '{printf "  %-16s %s\n", $$1, $$2}'

env: ## Cria o .env a partir do .env.example (nao sobrescreve um .env existente)
	@test -f .env || cp .env.example .env
	@echo "Preencha OPENAI_API_KEY em .env"

install: ## Instala as dependencias Python
	$(PYTHON) -m pip install -r requirements.txt

up: ## Sobe o Postgres + pgvector via Docker Compose
	docker compose up -d

down: ## Derruba os containers do Docker Compose
	docker compose down

logs: ## Acompanha os logs do container de banco de dados
	docker compose logs -f postgres

setup: env up install ## Prepara o ambiente completo (env + Postgres + dependencias) e valida a conexao
	$(PYTHON) -m app.main

ingest: ## Le knowledge_base/, valida front matter e gera data/chunks.jsonl
	$(PYTHON) -m app.ingest

index: ## Gera embeddings e indexa no pgvector (incremental, baseado no manifest)
	$(PYTHON) -m app.index

index-force: ## Reindexa do zero, ignorando o manifest (wipe + rebuild)
	$(PYTHON) -m app.index --force

reindex: ingest index ## Pipeline completo de reindexacao incremental (ingest + index)

chat: ## Chat RAG completo no terminal (planner -> retrieval -> rerank -> resposta)
	$(PYTHON) -m app.rag_chat

chat-debug: ## Chat RAG com QueryPlan e chunks recuperados/selecionados
	$(PYTHON) -m app.rag_chat --debug

chat-show-prompt: ## Chat RAG exibindo os prompts de planner/reranker/resposta
	$(PYTHON) -m app.rag_chat --show-prompt

chat-no-rerank: ## Chat RAG sem reranking (usa direto o top 4 da recuperacao)
	$(PYTHON) -m app.rag_chat --no-rerank

api: ## Sobe a API HTTP (FastAPI/uvicorn) com reload
	uvicorn app.api:app --reload

retrieve: ## Busca vetorial isolada, sem chamada ao modelo de chat (uso: make retrieve Q="pergunta")
	$(PYTHON) -m app.retrieve "$(Q)"

chat-baseline: ## Chat sem RAG, baseline para comparacao
	$(PYTHON) -m app.chat

context-chat: ## Chat com o documento inteiro no prompt, baseline sem retrieval (uso: make context-chat FILE=arquivo.md)
	$(PYTHON) -m app.context_chat $(FILE)
