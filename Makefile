# RAG Knowledge Chat — um alvo por FUNCIONALIDADE, não por rota ou por flag.
#
#   make help              lista tudo
#   make quickstart        o caminho recomendado do zero ao chat funcionando
#
# Parâmetros opcionais (valem para os alvos que os citam no `make help`):
#   LIMIT=5      roda só os N primeiros casos de uma evaluation
#   CASE=<id>    roda só um caso de uma evaluation
#   ARGS="..."   repassa flags extras ao comando (ex.: ARGS="--no-rerank")
#
# Só usa comandos simples e `python -c`, então funciona igual no Windows (cmd/PowerShell/
# Git Bash) e no Linux/macOS. Guia completo de ordem de execução: GUIA_EXECUCAO.md

# ---------------------------------------------------------------- configuração

ifeq ($(OS),Windows_NT)
  VENV_PY := .venv/Scripts/python.exe
  SYS_PY  ?= python
else
  VENV_PY := .venv/bin/python
  SYS_PY  ?= python3
endif

# O interpretador do projeto. Para usar outro ambiente: make chat PY=python
PY ?= $(VENV_PY)

HOST ?= 127.0.0.1
PORT ?= 8000
DOC  ?= product-support-sla.md

EVAL_FLAGS = $(if $(LIMIT),--limit $(LIMIT)) $(if $(CASE),--case-id $(CASE)) $(ARGS)

.DEFAULT_GOAL := help

.PHONY: help quickstart \
        setup venv install env \
        infra-up infra-observability infra-jaeger infra-down infra-status infra-logs infra-reset \
        db-check ingest index index-force prepare retrieve \
        chat chat-debug chat-no-rerank chat-no-rag chat-document \
        api api-health \
        agent agent-debug agent-tools agent-tools-rag \
        test \
        eval-datasets eval-datasets-validate eval-components eval-ragas eval-judge \
        eval-judge-calibrate eval-agent eval-experiment-baseline eval-experiment-no-rerank \
        eval-compare eval-gate eval-reports eval-all

# ------------------------------------------------------------------------ ajuda

# Texto de ajuda via $(info): nao depende de shell nem do comando echo, que
# nao existe fora do sh (o make do Windows executa as receitas sem shell).
define HELP_TEXT
RAG Knowledge Chat - alvos por funcionalidade

CAMINHO RECOMENDADO: make quickstart ; depois make chat ou make api
Ordem completa e explicacoes: GUIA_EXECUCAO.md

[1] AMBIENTE
  setup                 venv + dependencias + .env (tudo da etapa 1)
  venv / install / env  as tres partes do setup, separadas

[2] INFRAESTRUTURA (Docker)
  infra-up              sobe so o Postgres+pgvector (porta 5433)
  infra-observability   Postgres + Langfuse completo (UI em localhost:3000)
  infra-jaeger          Postgres + Jaeger (UI em localhost:16686)
  infra-status          mostra os containers
  infra-logs            segue os logs dos containers
  infra-down            para os containers (mantem os dados)
  infra-reset           para e APAGA os volumes (banco e Langfuse)

[3] PIPELINE DE DADOS
  db-check              testa a conexao e habilita a extensao pgvector
  ingest                le knowledge_base/ e gera data/chunks.jsonl
  index                 indexa os chunks no pgvector (incremental)
  index-force           apaga o indice e reindexa tudo
  prepare               ingest + index
  retrieve              busca isolada. Q="pergunta" ARGS="--plan enterprise --top-k 5"

[4] USO
  chat                  chat RAG no terminal
  chat-debug            idem, mostrando plano de busca e chunks
  chat-no-rerank        idem, sem rerank
  chat-no-rag           chat sem base de conhecimento (comparacao didatica)
  chat-document         chat com UM documento inteiro no prompt. DOC=arquivo.md
  api                   API HTTP (uvicorn --reload). HOST= PORT=
  api-health            chama GET /health da API em execucao
  agent                 Support Triage Agent no terminal
  agent-debug           idem, mostrando as chamadas de ferramenta
  agent-tools           testa as ferramentas locais, sem modelo
  agent-tools-rag       idem, mais a ferramenta de RAG (gasta tokens)

[5] QUALIDADE (LIMIT= CASE= ARGS= valem nas evaluations)
  test                  pytest: contrato da API, datasets, relatorios (custo zero)
  eval-datasets-validate valida os JSONL sem enviar nada (custo zero)
  eval-datasets         sincroniza os dois datasets com o Langfuse
  eval-components       planner, retrieval e rerank
  eval-ragas            fidelidade da resposta (Ragas)
  eval-judge            LLM-as-a-judge contra a rubrica
  eval-judge-calibrate  testa o proprio juiz com respostas ruins conhecidas
  eval-agent            trajetoria do agente
  eval-experiment-baseline    experiment: pipeline com rerank
  eval-experiment-no-rerank   experiment: pipeline sem rerank
  eval-compare          compara os dois experiments mais recentes
  eval-reports          lista os relatorios que o gate enxerga
  eval-gate             le os relatorios e decide PASS/FAIL (custo zero)
  eval-all              datasets + 4 evaluations + gate (~20 min, gasta tokens)
endef

help:
	@$(info $(HELP_TEXT))

# ------------------------------------------------------------ [1] ambiente

$(VENV_PY):
	$(SYS_PY) -m venv .venv

venv: $(VENV_PY)

install: $(VENV_PY)
	$(VENV_PY) -m pip install -r requirements.txt

# Copia .env.example para .env apenas se .env ainda nao existir.
env:
	$(SYS_PY) -c "import pathlib, shutil; p = pathlib.Path('.env'); print('.env ja existe, mantido.' if p.exists() else 'Criado .env a partir de .env.example - preencha OPENAI_API_KEY.'); p.exists() or shutil.copy('.env.example', p)"

setup: env venv install

# --------------------------------------------------------- [2] infraestrutura

# --wait bloqueia ate o healthcheck do Postgres ficar verde.
infra-up:
	docker compose up -d --wait postgres

infra-observability:
	docker compose --profile observability up -d

infra-jaeger:
	docker compose --profile jaeger up -d

infra-status:
	docker compose --profile observability --profile jaeger ps

infra-logs:
	docker compose --profile observability --profile jaeger logs -f --tail 50

infra-down:
	docker compose --profile observability --profile jaeger down

# Destrutivo: remove os volumes, ou seja, o indice pgvector e tudo do Langfuse
# (datasets, traces, scores). Depois disso e preciso refazer `make prepare`.
infra-reset:
	docker compose --profile observability --profile jaeger down -v

# ------------------------------------------------------ [3] pipeline de dados

db-check:
	$(PY) -m app.main

ingest:
	$(PY) -m app.ingest $(ARGS)

index:
	$(PY) -m app.index $(ARGS)

index-force:
	$(PY) -m app.index --force

prepare: ingest index

retrieve:
	$(PY) -m app.retrieve $(if $(Q),"$(Q)") $(ARGS)

# ------------------------------------------------------------------- [4] uso

chat:
	$(PY) -m app.rag_chat $(ARGS)

chat-debug:
	$(PY) -m app.rag_chat --debug $(ARGS)

chat-no-rerank:
	$(PY) -m app.rag_chat --no-rerank $(ARGS)

chat-no-rag:
	$(PY) -m app.chat

chat-document:
	$(PY) -m app.context_chat $(DOC)

api:
	$(PY) -m uvicorn app.api:app --reload --host $(HOST) --port $(PORT)

api-health:
	$(PY) -c "import urllib.request; print(urllib.request.urlopen('http://$(HOST):$(PORT)/health').read().decode())"

agent:
	$(PY) -m app.support_agent $(ARGS)

agent-debug:
	$(PY) -m app.support_agent --debug

agent-tools:
	$(PY) -m app.support_tools

agent-tools-rag:
	$(PY) -m app.support_tools --include-rag-tool

# ---------------------------------------------------------------- [5] qualidade

test:
	$(PY) -m pytest $(ARGS)

eval-datasets-validate:
	$(PY) -m app.eval_dataset --validate-only
	$(PY) -m app.eval_agent_dataset --validate-only

eval-datasets:
	$(PY) -m app.eval_dataset
	$(PY) -m app.eval_agent_dataset

eval-components:
	$(PY) -m app.eval_components $(EVAL_FLAGS)

eval-ragas:
	$(PY) -m app.eval_ragas $(EVAL_FLAGS)

eval-judge:
	$(PY) -m app.eval_judge $(EVAL_FLAGS)

eval-judge-calibrate:
	$(PY) -m app.eval_judge --calibrate

eval-agent:
	$(PY) -m app.eval_agent $(EVAL_FLAGS)

eval-experiment-baseline:
	$(PY) -m app.eval_experiment --variant baseline $(EVAL_FLAGS)

eval-experiment-no-rerank:
	$(PY) -m app.eval_experiment --variant no-rerank $(EVAL_FLAGS)

eval-compare:
	$(PY) -m app.eval_experiment --compare baseline no-rerank

eval-reports:
	$(PY) -m app.eval_gate --list-reports

eval-gate:
	$(PY) -m app.eval_gate $(ARGS)

# Sub-makes, em ordem: o gate so roda no fim, lendo os relatorios que as
# evaluations acabaram de salvar. Se uma evaluation falhar, a cadeia para.
eval-all:
	$(MAKE) eval-datasets
	$(MAKE) eval-components
	$(MAKE) eval-ragas
	$(MAKE) eval-judge
	$(MAKE) eval-agent
	$(MAKE) eval-gate

# -------------------------------------------------------------------- atalho

# Do zero ao sistema pronto para usar (nao inclui a stack Langfuse, que so as
# evaluations precisam; para ela: make infra-observability).
quickstart: setup infra-up db-check prepare test
	@$(info Pronto. Agora: make chat  ou  make api  ou  make agent)
