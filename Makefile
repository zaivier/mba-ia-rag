# Makefile - uma execucao por funcionalidade da aplicacao RAG.
#
# Rode `make` (ou `make help`) para ver o catalogo. A sequencia recomendada esta em
# GUIA_EXECUCAO.md. Um alvo por funcionalidade: a API e UM alvo (`make api`), nao um por
# rota - as rotas estao exemplificadas em test.http.
#
# Portavel entre Windows (cmd/PowerShell/Git Bash), Linux e macOS: nenhum alvo usa cp, cat,
# rm nem "VAR=valor comando"; variaveis de ambiente sao exportadas pelo proprio make.
# As mensagens impressas sao ASCII de proposito (consoles Windows nao-UTF-8).

.DEFAULT_GOAL := help

# --- Python -----------------------------------------------------------------------------
# SYS_PY cria o venv; PY usa o venv quando ele existe (avaliado na hora da receita, entao
# `make install chat` na mesma chamada ja enxerga o venv recem-criado).
ifeq ($(OS),Windows_NT)
  SYS_PY  ?= python
  VENV_PY := .venv/Scripts/python.exe
else
  SYS_PY  ?= python3
  VENV_PY := .venv/bin/python
endif
PY = $(if $(wildcard $(VENV_PY)),$(VENV_PY),$(SYS_PY))

# --- Parametros (sobrescreva na linha de comando: make api API_PORT=9000) ----------------
COMPOSE            ?= docker compose
API_HOST           ?= 127.0.0.1
API_PORT           ?= 8000
Q                  ?=
DOC                ?=
RETRIEVE_ARGS      ?=
LANGFUSE_SERVICES  := langfuse-web langfuse-worker langfuse-postgres langfuse-clickhouse langfuse-redis langfuse-minio

# --- TRACE: para onde vao os spans OpenTelemetry (vale para qualquer alvo de execucao) ---
#   make chat TRACE=console    spans impressos no terminal
#   make api  TRACE=jaeger     spans no Jaeger  (precisa de: make jaeger-up)
#   make chat TRACE=langfuse   spans no Langfuse (precisa de: make langfuse-up + chaves no .env)
#   make chat TRACE=off        desliga a telemetria, mesmo que o .env ligue
ifeq ($(TRACE),console)
export OBSERVABILITY_ENABLED := true
export OTEL_TRACES_EXPORTER  := console
else ifeq ($(TRACE),jaeger)
export OBSERVABILITY_ENABLED     := true
export OTEL_TRACES_EXPORTER      := otlp
export OTEL_EXPORTER_OTLP_ENDPOINT := http://localhost:4318
export LANGFUSE_PUBLIC_KEY       :=
export LANGFUSE_SECRET_KEY       :=
else ifeq ($(TRACE),langfuse)
export OBSERVABILITY_ENABLED := true
export OTEL_TRACES_EXPORTER  := otlp
else ifeq ($(TRACE),off)
export OBSERVABILITY_ENABLED := false
else ifneq ($(TRACE),)
$(error TRACE invalido: use console, jaeger, langfuse ou off)
endif

# --- POLICY: demonstra a governanca sem editar o .env (vale para qualquer alvo de execucao) -
#   make chat-debug POLICY=model    OPENAI_CHAT_MODEL fora de AI_ALLOWED_MODELS -> bloqueado
#   make api POLICY=budget          AI_MONTHLY_BUDGET_USD=0 -> bloqueado
# O bloqueio acontece antes do planner/embeddings: nao gasta nenhuma chamada ao modelo.
ifeq ($(POLICY),model)
export AI_ALLOWED_MODELS := gpt-4o
else ifeq ($(POLICY),budget)
export AI_MONTHLY_BUDGET_USD := 0
else ifneq ($(POLICY),)
$(error POLICY invalido: use model ou budget)
endif

# --- Ajuda ------------------------------------------------------------------------------
define HELP
RAG Knowledge Chat - alvos disponiveis (guia: GUIA_EXECUCAO.md)

PREPARACAO (uma vez)
  make setup            .env + venv + dependencias + Postgres/pgvector + validacao
  make env              cria o .env a partir do .env.example (se nao existir)
  make venv             cria o ambiente virtual .venv
  make install          instala o requirements.txt no .venv
  make check            valida .env, conexao com o banco e extensao pgvector

INFRAESTRUTURA (Docker)
  make db-up            sobe o Postgres com pgvector (porta 5433) e espera ficar saudavel
  make db-down          para o Postgres (os dados ficam no volume)
  make jaeger-up        sobe o Jaeger, backend OTLP leve (UI http://localhost:16686)
  make jaeger-down      para o Jaeger
  make langfuse-up      sobe o Langfuse completo, 6 containers (UI http://localhost:3000)
  make langfuse-down    para o Langfuse
  make ps               lista os containers do projeto
  make down             para tudo (Postgres, Jaeger, Langfuse); mantem os volumes

BASE DE CONHECIMENTO
  make ingest           le/valida knowledge_base/ e gera data/chunks.jsonl
  make ingest-no-header idem, sem o cabecalho de contexto nos chunks (para comparar)
  make index            embeddings + pgvector, so do que mudou (incremental)
  make index-force      recria o indice do zero
  make build-index      ingest + index (o caminho normal apos editar documentos)
  make rebuild-index    ingest + index-force

USO
  make chat             chat RAG no terminal (digite exit para sair)
  make chat-debug       + query plan, chunks, tempos, tokens e politica
  make chat-prompt      + os tres prompts enviados ao modelo
  make chat-no-rerank   pula o reranking (usa os 4 primeiros do retrieval)
  make api              API HTTP em http://$(API_HOST):$(API_PORT) (rotas: test.http)
  make api-health       chama GET /health da API que esta no ar

FERRAMENTAS DE LABORATORIO (sem politica de governanca)
  make retrieve Q="pergunta" [RETRIEVE_ARGS="--plan enterprise --top-k 5"]
                        so busca vetorial, sem modelo de chat
  make chat-baseline    chat SEM RAG, direto no modelo (linha de base)
  make chat-context [DOC=arquivo.md]
                        chat com UM documento inteiro no prompt, sem embeddings

GOVERNANCA
  make ledger           mostra o historico de uso estimado (data/ai_usage.jsonl)
  POLICY=model|budget   modificador: simula bloqueio por modelo fora da lista ou por
                        budget esgotado.  ex.: make chat-debug POLICY=budget

OBSERVABILIDADE
  TRACE=console|jaeger|langfuse|off   modificador.  ex.: make chat-debug TRACE=console

MODIFICADORES valem para chat*, api, e podem ser combinados: make api TRACE=jaeger
endef

# Impresso em tempo de leitura do Makefile (portavel, sem depender de shell).
ifneq ($(filter help,$(or $(MAKECMDGOALS),help)),)
$(info $(HELP))
endif

.PHONY: help
help: ; @$(SYS_PY) -c "print()"

# --- Preparacao -------------------------------------------------------------------------
.PHONY: setup env venv install check
setup: env venv install db-up check
	@$(info )
	@$(info Setup concluido. Confirme OPENAI_API_KEY no .env e rode: make build-index)

env: .env

.env:
	@$(SYS_PY) -c "import shutil; shutil.copy('.env.example', '.env')"
	@$(info .env criado a partir do .env.example. PREENCHA OPENAI_API_KEY antes de continuar.)

venv: $(VENV_PY)

$(VENV_PY):
	$(SYS_PY) -m venv .venv

install: venv
	$(VENV_PY) -m pip install -r requirements.txt

check:
	$(PY) -m app.main

# --- Infraestrutura ---------------------------------------------------------------------
.PHONY: db-up db-down jaeger-up jaeger-down langfuse-up langfuse-down ps down
db-up:
	$(COMPOSE) up -d --wait postgres

db-down:
	$(COMPOSE) stop postgres

jaeger-up:
	$(COMPOSE) --profile jaeger up -d jaeger
	@$(info Jaeger: http://localhost:16686  (use TRACE=jaeger nos alvos de execucao))

jaeger-down:
	$(COMPOSE) --profile jaeger stop jaeger

langfuse-up:
	$(COMPOSE) --profile observability up -d
	@$(info Langfuse: http://localhost:3000  login admin@fcai.local / langfuse123)
	@$(info Chaves locais: veja LANGFUSE_* no README (use TRACE=langfuse nos alvos de execucao))

langfuse-down:
	$(COMPOSE) --profile observability stop $(LANGFUSE_SERVICES)

ps:
	$(COMPOSE) --profile jaeger --profile observability ps

down:
	$(COMPOSE) --profile jaeger --profile observability down

# --- Base de conhecimento ---------------------------------------------------------------
.PHONY: ingest ingest-no-header index index-force build-index rebuild-index
ingest:
	$(PY) -m app.ingest

ingest-no-header:
	$(PY) -m app.ingest --no-context-header

index:
	$(PY) -m app.index

index-force:
	$(PY) -m app.index --force

build-index: ingest index

rebuild-index: ingest index-force

# --- Uso: chat e API --------------------------------------------------------------------
.PHONY: chat chat-debug chat-prompt chat-no-rerank api api-health
chat:
	$(PY) -m app.rag_chat

chat-debug:
	$(PY) -m app.rag_chat --debug

chat-prompt:
	$(PY) -m app.rag_chat --show-prompt

chat-no-rerank:
	$(PY) -m app.rag_chat --no-rerank

api:
	$(PY) -m uvicorn app.api:app --reload --host $(API_HOST) --port $(API_PORT)

api-health:
	$(PY) -c "import urllib.request as u; print(u.urlopen('http://$(API_HOST):$(API_PORT)/health').read().decode())"

# --- Ferramentas de laboratorio (bypass da governanca, por design) -----------------------
.PHONY: retrieve chat-baseline chat-context
retrieve:
	$(PY) -m app.retrieve $(if $(Q),"$(Q)") $(RETRIEVE_ARGS)

chat-baseline:
	$(PY) -m app.chat

chat-context:
	$(PY) -m app.context_chat $(DOC)

# --- Governanca -------------------------------------------------------------------------
.PHONY: ledger
ledger:
	$(PY) -c "from app.config import settings as s; p = s.usage_ledger_path; print(p.read_text(encoding='utf-8') if p.exists() else 'Ledger vazio: nenhuma chamada ao modelo registrada ainda (' + str(p) + ')')"
