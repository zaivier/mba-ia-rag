# Guia de execução

Como colocar o projeto de pé e usar cada funcionalidade com o `Makefile`, na ordem
recomendada. Para o porquê de cada decisão de arquitetura, veja o [README](README.md).

Rode `make` (sem argumentos) a qualquer momento para ver o catálogo de alvos.

## O que a aplicação faz

Um assistente de perguntas e respostas sobre os documentos Markdown de `knowledge_base/`
(a documentação de uma SaaS fictícia, a FCAI). Ele responde **só** com o que está
indexado, cita as fontes e diz "não encontrei" quando o contexto não sustenta a resposta.

```
knowledge_base/*.md ──ingest──▶ data/chunks.jsonl ──index──▶ Postgres + pgvector
                                                                  │
pergunta ─▶ [governança] ─▶ planner ─▶ busca (top 8) ─▶ rerank (top 4) ─▶ resposta + fontes
                                                                  │
                                              terminal (make chat)  ou  API (make api)
```

São duas fases bem separadas:

| Fase | Quando | Alvos | Chama o quê |
| --- | --- | --- | --- |
| **Preparar a base** | uma vez, e de novo sempre que editar um documento | `ingest`, `index` | só o modelo de **embeddings** |
| **Usar** | sempre que quiser perguntar | `chat*`, `api` | o modelo de **chat** (3 chamadas por pergunta: planner, reranker, resposta) |

O uso **nunca** indexa: se a base não foi construída, o chat não tem o que consultar.

## Pré-requisitos

- Python 3.11+
- Docker Desktop rodando
- GNU Make (no Windows: `choco install make`)
- Uma chave da OpenAI

---

## Sequência recomendada — primeira vez

### 1. Preparar o ambiente

```bash
make setup
```

Faz, em ordem: cria o `.env` (a partir do `.env.example`, se não existir), cria o `.venv`,
instala as dependências, sobe o Postgres com pgvector e valida tudo. Equivale a rodar
`env → venv → install → db-up → check`, e cada um desses também existe como alvo
separado se você precisar repetir só um passo.

### 2. Preencher o `.env`

Abra o `.env` e coloque a `OPENAI_API_KEY`. Confira também que o `DATABASE_URL` usa a
porta **5433**, que é a que o `docker-compose.yml` publica:

```
DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5433/rag_db
```

### 3. Validar a conexão

```bash
make check
```

Esperado: `Environment loaded.` → `Database connection ok.` → `pgvector extension enabled.`
→ `Project setup completed.` Se travar por muito tempo, é quase sempre a porta errada do
`DATABASE_URL` (veja "Problemas comuns").

### 4. Construir a base de conhecimento

```bash
make build-index
```

É `ingest` + `index`:

- **`ingest`** lê e valida os 8 documentos (o front matter YAML é obrigatório), quebra em
  chunks respeitando seções e grava `data/chunks.jsonl` (134 chunks na base de exemplo).
- **`index`** gera os embeddings e grava no pgvector. É incremental: só o que é novo ou
  mudou é embedado, então rodar de novo não duplica nada nem gasta embeddings.

Custo: a base de exemplo inteira são centavos de embedding, uma única vez.

### 5. Perguntar

Terminal:

```bash
make chat-debug
```

Use `chat-debug` na primeira vez: mostra o query plan, os chunks recuperados e
selecionados, os tempos, os tokens e a decisão de política. Digite `exit` para sair.
Perguntas que mostram cada comportamento do pipeline:

| Pergunta | O que acontece |
| --- | --- |
| Qual é o SLA para incidentes P1 no plano Enterprise? | responde e cita as fontes |
| Como funciona o suporte no plano da empresa? | ambígua → pede esclarecimento |
| O que acontece se eu ultrapassar a cota de ingestão? | não nomeia plano → cobre os três |
| Qual é a capital da França? | fora da base → "não encontrei" |

API:

```bash
make api            # sobe em http://127.0.0.1:8000 (Ctrl+C para parar)
```

Com a API no ar, abra o `test.http` no VS Code (extensão REST Client) e clique em
**Send Request** em cada bloco. Ele cobre todas as rotas: `GET /health`, `POST /chat`
(com e sem `debug`/`use_rerank`, ambígua, sem resposta, bloqueada por política, erros 400,
405 e 422) e as rotas geradas pelo FastAPI (`/docs`, `/redoc`, `/openapi.json`). Num
terminal à parte, `make api-health` confirma que ela está respondendo. Também dá para
explorar pelo navegador em <http://127.0.0.1:8000/docs>.

**Resumo da primeira vez:**

```bash
make setup
# editar .env (OPENAI_API_KEY; DATABASE_URL na porta 5433)
make check
make build-index
make chat-debug      # ou: make api
```

---

## No dia a dia

| Situação | Comando |
| --- | --- |
| Subir o banco depois de reiniciar a máquina | `make db-up` |
| Editei ou adicionei documentos em `knowledge_base/` | `make build-index` (só o que mudou é reprocessado) |
| Quero perguntar | `make chat` ou `make api` |
| Terminei | `make down` (mantém os dados) |

Se o documento novo tem um `doc_type` ou `plan` que o planner não conhece, atualize antes
os `Literal`s e o catálogo do prompt em `app/query_planner.py` — senão o sistema recusa
subir (de propósito). Detalhes em "Adicionando documentos à base" no README.

---

## Explorando as demais funcionalidades

Todas assumem que os passos 1 a 4 já foram feitos.

### Variações do chat

| Comando | Para quê |
| --- | --- |
| `make chat` | o chat normal |
| `make chat-debug` | + diagnóstico de cada etapa |
| `make chat-prompt` | + os três prompts enviados ao modelo (recurso local, não vai para telemetria) |
| `make chat-no-rerank` | pula o reranking; compare a resposta com a do `chat` normal |

### Observabilidade (OpenTelemetry) — modificador `TRACE=`

`TRACE` vale para qualquer alvo de execução e sobrepõe o `.env` só naquela chamada:

```bash
make chat-debug TRACE=console      # spans impressos no terminal; não sobe nada
```

Para ver os traces numa interface:

```bash
make jaeger-up                     # 1 container, UI em http://localhost:16686
make chat TRACE=jaeger             # faça uma pergunta; serviço "fcai-rag-api" no Jaeger
make jaeger-down
```

```bash
make langfuse-up                   # 6 containers, UI em http://localhost:3000
                                   # login: admin@fcai.local / langfuse123
make chat TRACE=langfuse           # precisa de LANGFUSE_PUBLIC_KEY/SECRET_KEY no .env
make langfuse-down
```

A primeira subida do Langfuse demora (imagens grandes + migrações). As chaves locais de
desenvolvimento estão na seção "Langfuse via OTLP" do README. `TRACE=off` desliga a
telemetria mesmo que o `.env` ligue. Os modificadores se combinam com a API:
`make api TRACE=jaeger`.

### Governança — modificador `POLICY=` e `make ledger`

```bash
make chat-debug POLICY=model       # modelo fora de AI_ALLOWED_MODELS → bloqueado
make chat-debug POLICY=budget      # AI_MONTHLY_BUDGET_USD=0 → bloqueado
make api POLICY=budget             # idem na API: POST /chat devolve 200, has_answer=false
make ledger                        # histórico de uso estimado (data/ai_usage.jsonl)
```

O bloqueio acontece antes do planner e dos embeddings, então estas demos **não gastam
nenhuma chamada ao modelo**. O `ledger` só ganha linhas quando uma pergunta realmente
chega ao modelo; é ele que a próxima requisição lê para saber o gasto do mês. Os preços
são fictícios (simulação, não billing).

### Ferramentas de laboratório

Chamam o modelo/embeddings direto e **não passam pela governança**, de propósito:

```bash
make retrieve Q="SLA incidentes P1 Enterprise"
make retrieve Q="SLA incidentes P1" RETRIEVE_ARGS="--plan enterprise --top-k 5"
make retrieve Q="SLA incidentes P1" RETRIEVE_ARGS="--doc-type company"   # filtro errado esconde a resposta
make chat-baseline                 # chat SEM RAG: a linha de base de comparação
make chat-context                  # um documento inteiro no prompt (padrão: product-support-sla.md)
make chat-context DOC=enterprise-plan.md
```

`retrieve` é a forma mais barata de ver o filtro eliminatório na prática (só embedding,
sem modelo de chat). Filtros: `--tenant`, `--product`, `--plan`, `--doc-type`, `--status`.
Valores de `--doc-type`: `sla`, `policy`, `product`, `plan`, `company`.

### Comparar chunking com e sem cabeçalho de contexto

```bash
make ingest-no-header index-force  # reconstrói sem o cabeçalho
make chat-debug                    # compare os chunks recuperados
make rebuild-index                 # volta ao padrão
```

Use `index-force` (ou `rebuild-index`) aqui: o `index` incremental decide pelo hash do
**documento**, que não mudou, e portanto não reindexaria os chunks novos.

---

## Referência rápida dos alvos

| Grupo | Alvos |
| --- | --- |
| Preparação | `setup`, `env`, `venv`, `install`, `check` |
| Infraestrutura | `db-up`, `db-down`, `jaeger-up`, `jaeger-down`, `langfuse-up`, `langfuse-down`, `ps`, `down` |
| Base | `ingest`, `ingest-no-header`, `index`, `index-force`, `build-index`, `rebuild-index` |
| Uso | `chat`, `chat-debug`, `chat-prompt`, `chat-no-rerank`, `api`, `api-health` |
| Laboratório | `retrieve`, `chat-baseline`, `chat-context` |
| Governança | `ledger` |
| Modificadores | `TRACE=console\|jaeger\|langfuse\|off`, `POLICY=model\|budget` |
| Parâmetros | `Q`, `DOC`, `RETRIEVE_ARGS`, `API_HOST`, `API_PORT` |

## Dependências entre os passos

```
setup ──▶ build-index ──▶ chat / api / retrieve
              │
              └─ ingest ─▶ index          (index exige o chunks.jsonl do ingest
                                           e o Postgres no ar: db-up)
chat/api TRACE=jaeger    exige  jaeger-up
chat/api TRACE=langfuse  exige  langfuse-up + chaves no .env
```

---

## Problemas comuns

| Sintoma | Causa e solução |
| --- | --- |
| `make check` (ou qualquer alvo) fica minutos sem responder | O `DATABASE_URL` do `.env` aponta para a porta errada. O compose publica o Postgres na **5433**; confira `localhost:5433` no `.env`. |
| `ModuleNotFoundError: No module named 'opentelemetry.exporter'` (ou outro módulo) | O `.venv` está desatualizado em relação ao `requirements.txt`. Rode `make install`. |
| Chat responde "não encontrei" para tudo | A base não foi indexada neste banco (ex.: volume novo). Rode `make build-index`. Se o banco foi recriado, `make rebuild-index`. |
| `Psycopg cannot use the 'ProactorEventLoop'` (Windows) | Corrigido em `app/db.py`, que força o event loop compatível no Windows. Se aparecer, confirme que está com esse arquivo atualizado. |
| `Invalid observability policy: ...` | `OBSERVABILITY_CAPTURE_CONTENT=true` só é aceito com `APP_ENV=development`. |
| Subiu um container Jaeger sem pedir | O `.env` tem `COMPOSE_PROFILES=jaeger`, o que inclui o Jaeger em todo `docker compose up`. `make db-up` sobe só o Postgres. |
| `make: command not found` / `python` não encontrado | Instale o GNU Make. Se o Python do sistema tem outro nome: `make setup SYS_PY=py`. |
| Acentos quebrados no terminal Windows | Terminal fora de UTF-8. No PowerShell: `$env:PYTHONUTF8=1` antes do `make`. |

## Encerrando

```bash
make down          # para Postgres, Jaeger e Langfuse; os dados ficam nos volumes
```

Para parar só uma parte: `make db-down`, `make jaeger-down`, `make langfuse-down`.
