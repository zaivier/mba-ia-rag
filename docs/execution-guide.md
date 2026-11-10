# Guia de execução

Qual comando do `make` rodar, em que ordem, e por quê. Cada passo diz se **gasta token da
OpenAI** (💰) ou se é grátis.

`make` sem argumentos lista todos os comandos. O Makefile precisa de um shell POSIX
(Linux, macOS ou Git Bash no Windows) e do Docker.

## O que a aplicação faz, em uma página

É um chat que responde perguntas **somente** com base nos documentos de
`knowledge_base/` (a documentação fictícia da FCAI) e cita as fontes. Se o contexto não
sustenta a resposta, diz que não encontrou.

```
knowledge_base/*.md ──ingest──▶ data/chunks.jsonl ──index──▶ Postgres + pgvector
                                                                    │
pergunta ─▶ planner ─▶ busca vetorial (top 8) ─▶ rerank (top 4) ─▶ resposta + fontes
              │ ambígua? pede esclarecimento
```

| Peça | O que é | Onde |
| --- | --- | --- |
| Preparação da base | lê e valida os Markdown, quebra em chunks, gera embeddings e grava no pgvector | `ingest`, `index` |
| Pipeline RAG | planner → retrieval → rerank → resposta (3 chamadas ao modelo de chat) | `app/rag_pipeline.py` |
| Dois clientes | chat no terminal e API HTTP | `chat`, `api` |
| Ferramentas de laboratório | busca isolada, chat sem RAG, chat com documento inteiro | `retrieve`, `chat-no-rag`, `chat-context` |
| Observabilidade | spans OpenTelemetry → Langfuse (ou Jaeger) | opcional, `observability-up` |
| Avaliação | 5 camadas: contract tests, componentes, Ragas, judge, experiments | `test`, `eval-*` |

O que depende do quê:

| Para rodar… | Precisa de |
| --- | --- |
| `test`, `eval-validate`, `eval-compare` | só o venv — nem banco nem chave |
| `ingest` | só o venv |
| `check`, `index`, `retrieve`, `chat`, `api` | Postgres no ar **e** `OPENAI_API_KEY` |
| `eval-ragas`, `eval-judge` | Postgres, índice pronto e `OPENAI_API_KEY` |
| `eval-calibrate` | `OPENAI_API_KEY` (não toca banco nem pipeline) |
| `eval-dataset`, `eval-components`, `eval-baseline`, `eval-no-rerank` | tudo acima **e** o Langfuse no ar, com as chaves no `.env` |

---

## Sequência recomendada

### Etapa 1 — Ambiente Python (uma vez)

```bash
make setup
```

Cria o `.env` (a partir do `.env.example`), o `.venv` e instala o `requirements.txt`.
**Abra o `.env` e preencha `OPENAI_API_KEY`.** O resto do `.env.example` já funciona.
No Linux/macOS: `make setup BOOTSTRAP_PYTHON=python3`.

Confirme que está tudo certo, sem custo e sem banco:

```bash
make test             # 33 contract tests, ~2 s
make eval-validate    # valida o dataset de 37 casos
```

### Etapa 2 — Banco de dados

```bash
make db-up            # Postgres + pgvector em localhost:5433, espera ficar saudável
make check            # valida .env, conexão e extensão pgvector
```

### Etapa 3 — Preparar a base de conhecimento

```bash
make prepare          # = make ingest + make index
```

- `ingest` valida o front matter dos 8 documentos e gera `data/chunks.jsonl`. Grátis.
- `index` gera os embeddings e grava no pgvector. 💰 (centavos, só embeddings)

O `index` é incremental: rodar de novo não duplica nem gasta nada se nada mudou. Use
`make index-force` para recriar o índice do zero. Depois de editar um documento, basta
`make prepare` de novo.

> A API e o chat **nunca** indexam. Sem esta etapa, eles respondem com a base vazia.

### Etapa 4 — Usar o sistema

Escolha um dos dois (ou ambos):

```bash
make chat                         # chat no terminal 💰
make chat DEBUG=1                 # + query plan, chunks recuperados/selecionados, tempos, tokens
make chat SHOW_PROMPT=1           # + os três prompts enviados ao modelo
make chat NORERANK=1              # pula o reranking

make api                          # API em http://127.0.0.1:8000 (com --reload)
```

Com a API no ar, abra o [test.http](../test.http) no VS Code (extensão **REST Client**) e
clique em *Send Request*. Ele traz um exemplo de **cada rota**:

| Rota | Para quê | Exemplos no `test.http` |
| --- | --- | --- |
| `GET /health` | a API está viva | 1 |
| `POST /chat` | roda o pipeline completo | resposta, `debug`, sem rerank, sem plano, ambígua, fora da base, `400`, `422` |
| `GET /docs`, `/redoc`, `/openapi.json` | documentação gerada pelo FastAPI | 3 |

Perguntas que mostram cada comportamento (rode com `make chat DEBUG=1`):

| Pergunta | O que acontece |
| --- | --- |
| Qual é o SLA para incidentes P1 no plano Enterprise? | responde e cita as fontes |
| Como funciona o suporte no plano da empresa? | ambígua → pede esclarecimento |
| O que acontece se eu ultrapassar a cota de ingestão? | não nomeia plano → cobre os três |
| Qual é a capital da França? | fora da base → "não encontrei" |

### Etapa 5 — Ferramentas de inspeção (opcionais)

```bash
make retrieve Q="Qual o SLA do P1?"                       # só a busca vetorial, sem chat 💰 (embedding)
make retrieve Q="Qual o SLA do P1?" DOC_TYPE=policy       # o filtro é eliminatório: esconde a resposta
make chat-no-rag                                          # linha de base: modelo sem a base 💰
make chat-context DOC=product-support-sla.md              # um documento inteiro no prompt 💰
```

Servem para entender **por que** o RAG existe: compare a mesma pergunta nos três modos.

### Etapa 6 — Observabilidade (opcional para o chat; obrigatória para parte da Etapa 7)

O Langfuse é necessário para `eval-dataset`, `eval-components` (sem `NOLANGFUSE=1`) e os
experiments.

```bash
make observability-up      # 6 containers; UI em http://localhost:3000
```

Login: `admin@fcai.local` / `langfuse123`. Na primeira subida ele cria as chaves; leva
cerca de um minuto para ficar pronto. No `.env`:

```bash
OBSERVABILITY_ENABLED=true
OTEL_TRACES_EXPORTER=otlp
LANGFUSE_PUBLIC_KEY=pk-lf-fcai-rag-local
LANGFUSE_SECRET_KEY=sk-lf-fcai-rag-local
LANGFUSE_HOST=http://localhost:3000
```

Reinicie a API (`make api`) e faça uma pergunta: cada requisição vira um trace
`ai.rag.pipeline` em **Tracing → Traces**.

Quer só ver os spans sem os 6 containers? `make jaeger-up` (UI em
http://localhost:16686); no `.env`, `OTEL_TRACES_EXPORTER=otlp` e
`OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`, chaves do Langfuse vazias.

### Etapa 7 — Avaliar a qualidade (da mais barata à mais cara)

Rode **depois** da Etapa 3 (índice pronto). Todas aceitam `LIMIT=n` e `CASE=id` para
reduzir custo — **comece sempre por `LIMIT=3`**.

| # | Comando | Pergunta que responde | Custo | Precisa do Langfuse |
| --- | --- | --- | --- | --- |
| 1 | `make test` | a API cumpre o contrato? | grátis | não |
| 2 | `make eval-calibrate` | o judge discrimina respostas ruins? | 💰 pouco | não |
| 3 | `make eval-dataset` | (sincroniza o dataset de 37 casos) | grátis | **sim** |
| 4 | `make eval-components` | em qual etapa a informação se perdeu? ~5 min | 💰 | sim* |
| 5 | `make eval-ragas` | a resposta é fiel ao contexto? ~6 min | 💰💰 | não |
| 6 | `make eval-judge` | atende à rubrica deste produto? ~5 min | 💰 | não |
| 7 | `make eval-ab` | está melhor ou pior sem o rerank? ~6 min | 💰💰 | **sim** |

\* `make eval-components NOLANGFUSE=1` lê o dataset local e dispensa o Langfuse.

Sequência de uma primeira avaliação, barata:

```bash
make eval-dataset                  # 1. sincroniza o dataset (uma vez, e a cada mudança em evals/)
make eval-calibrate                # 2. confere o próprio juiz antes de confiar nele
make eval-components LIMIT=3       # 3. diagnóstico por etapa
make eval-ragas LIMIT=3
make eval-judge LIMIT=3
```

Depois, rodando os 37 casos, o experimento A/B:

```bash
make eval-ab                       # baseline (com rerank) + no-rerank + o diff
# ou, em passos:
make eval-baseline
make eval-no-rerank
make eval-compare                  # sem custo: compara os últimos relatórios salvos
```

`eval-compare` falha com `no report found` se os dois experimentos ainda não rodaram.
Ele também recusa comparar rodadas com conjuntos de casos diferentes (por exemplo, uma
com `LIMIT=3` e outra completa).

Os relatórios ficam em `data/eval_runs/` (fora do git). `eval-components` exige
`RUN_COMPONENT_EVALS=true`, que o Makefile já define — é a confirmação de que a rodada
gasta token.

### Etapa 8 — Encerrar

```bash
make down              # para os containers, mantém o índice e os traces
make infra-reset       # DESTRUTIVO: apaga também os volumes (índice e Langfuse)
```

Depois de um `infra-reset`, refaça a partir da Etapa 2 (o `index` detecta o banco vazio
e reconstrói a tabela).

---

## Receitas rápidas

| Quero… | Faça |
| --- | --- |
| Conversar com a base pela primeira vez | `make setup` → preencher `OPENAI_API_KEY` → `make db-up` → `make prepare` → `make chat` |
| Testar a API | o mesmo, mas `make api` no lugar de `make chat`, e abrir o `test.http` |
| Rodar só o que não custa nada | `make test`, `make eval-validate`, `make eval-compare` |
| Depois de editar um `.md` da base | `make prepare` |
| Ver os traces | `make observability-up`, ajustar o `.env`, `make api` ou `make chat` |
| Saber se uma mudança piorou o pipeline | `make eval-ab`, e antes de mudar, `make eval-baseline` |

## Problemas comuns

| Sintoma | Causa | Solução |
| --- | --- | --- |
| `Ambiente virtual nao encontrado` | falta o `.venv` | `make setup` |
| `No module named pytest` / `langfuse` | `.venv` sem as dependências | `make install` |
| `Collection 'fcai_knowledge_base' is missing or empty` | índice não criado | `make prepare` |
| `connection refused` na porta 5433 | Postgres parado | `make db-up` |
| `RUN_COMPONENT_EVALS=true is required` | rodou o módulo direto, fora do `make` | use `make eval-components` |
| `Esta solicitação não pode ser processada…` na API | política operacional bloqueou (modelo fora de `AI_ALLOWED_MODELS` ou `AI_MONTHLY_BUDGET_USD` esgotado) | ajuste o `.env`; o uso fica em `data/ai_usage.jsonl` |
| Erros de Langfuse em `eval-dataset` / experiments | Langfuse parado ou chaves vazias no `.env` | `make observability-up` e Etapa 6 |
| `make eval-compare`: `no report found` | o experimento ainda não rodou | `make eval-baseline eval-no-rerank` |
