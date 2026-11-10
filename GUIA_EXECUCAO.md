# Guia de execução

Em que ordem rodar os alvos do [Makefile](Makefile) para sair de um clone vazio e chegar
ao chat, à API, ao agente e às avaliações. `make help` lista todos os alvos.

## O que a aplicação faz

Um chat de perguntas e respostas (RAG) sobre uma base de oito documentos Markdown de uma
empresa fictícia, a FCAI, que ficam em `knowledge_base/`. O fluxo é:

```
knowledge_base/*.md --ingest--> data/chunks.jsonl --index--> Postgres + pgvector
                                                                  |
pergunta --> planner --> busca filtrada --> rerank --> LLM --> resposta + fontes
```

- Só responde com base nos documentos. Se o contexto não sustenta a resposta, diz que não
  encontrou. Se a pergunta é ambígua, pergunta de volta (`needs_clarification`).
- Existe em três formas: **chat no terminal**, **API HTTP** (`POST /chat`) e um
  **agente de triagem** que escolhe entre três ferramentas (consultar a base, ler o
  consumo do cliente, abrir chamado).
- O resto do repositório mede se isso está certo: contract tests, avaliação por etapa,
  Ragas, LLM-as-a-judge, experiments, avaliação do agente e, no fim, um *quality gate* que
  lê os relatórios e responde PASS ou FAIL.

## O que cada peça exige

| Peça | Precisa de |
| --- | --- |
| `test`, `agent-tools`, `eval-*-validate`, `eval-gate`, `eval-reports` | só Python. Sem Docker, sem chave, sem custo. |
| `ingest` | só Python. |
| `index`, `retrieve`, `chat*`, `api`, `agent` | Postgres (`infra-up`) + `OPENAI_API_KEY`. Gastam tokens. |
| `eval-datasets`, `eval-components`, `eval-agent`, `eval-experiment-*` | tudo acima + **Langfuse** (`infra-observability`) com as chaves no `.env`. |
| `eval-ragas`, `eval-judge` | Postgres + `OPENAI_API_KEY`. Gastam tokens. |
| `chat-no-rag`, `chat-document` | só `OPENAI_API_KEY`: não usam o banco. |

## Roteiro recomendado

### 1. Preparar o ambiente — uma vez

```bash
make setup          # cria .env, a venv e instala o requirements.txt
```

Abra o `.env` e preencha `OPENAI_API_KEY`. O resto do `.env.example` já funciona.

### 2. Subir o banco e indexar — uma vez, e de novo quando a base mudar

```bash
make infra-up       # Postgres + pgvector na porta 5433, espera ficar saudável
make db-check       # confirma a conexão e habilita a extensão pgvector
make prepare        # ingest + index
```

`make index` é incremental: só gera embedding do que é novo ou mudou. Depois de editar
um arquivo em `knowledge_base/`, rode `make prepare` de novo. `make index-force` apaga
tudo e reindexa do zero.

Atalho que faz os passos 1 e 2 e ainda roda os testes: `make quickstart`.

### 3. Usar

Escolha o que quiser, em qualquer ordem:

```bash
make chat           # chat no terminal (digite "exit" para sair)
make chat-debug     # idem, mostrando o plano de busca e os chunks
make api            # API em http://127.0.0.1:8000  (deixe rodando)
make agent          # agente de triagem (make agent-debug mostra as ferramentas)
```

Para a API: com ela rodando, abra o [test.http](test.http) no VS Code (extensão REST
Client) e clique em *Send Request* em cada exemplo, ou rode `make api-health` num segundo
terminal. O arquivo cobre todas as rotas: `GET /health`, `POST /chat` (resposta, debug,
sem rerank, ambígua, fora da base, vazia → 400, campo ausente → 422), o `405` de `GET
/chat` e as rotas que o FastAPI gera sozinho (`/docs`, `/redoc`, `/openapi.json`,
`/docs/oauth2-redirect`).

Para investigar sem gerar resposta: `make retrieve Q="SLA do P1" ARGS="--plan enterprise --top-k 5"`.

### 4. Verificar a qualidade

**4a. Sem custo, rode sempre:**

```bash
make test                      # 33 testes: contrato da API, datasets, matemática dos relatórios
make eval-datasets-validate    # valida os dois JSONL de casos
make agent-tools               # exercita as ferramentas do agente, sem modelo
```

**4b. Com custo (OpenAI + Langfuse).** Suba o Langfuse:

```bash
make infra-observability       # seis containers; UI em http://localhost:3000
```

Entre em http://localhost:3000 (`admin@fcai.local` / `langfuse123`) para conferir que
subiu. As chaves de desenvolvimento já são criadas na primeira subida; coloque no `.env`:

```
LANGFUSE_PUBLIC_KEY=pk-lf-fcai-rag-local
LANGFUSE_SECRET_KEY=sk-lf-fcai-rag-local
LANGFUSE_HOST=http://localhost:3000
```

Opcional, para ver os traces: `OBSERVABILITY_ENABLED=true` e `OTEL_TRACES_EXPORTER=otlp`.
Se preferir só o Jaeger (um container), use `make infra-jaeger`, com
`OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`; a UI fica em http://localhost:16686.

Depois, **nesta ordem** (o dataset precisa estar no Langfuse antes de quem o lê):

```bash
make eval-datasets             # 1. sincroniza os datasets com o Langfuse
make eval-components LIMIT=3   # 2. teste curto antes de gastar com a rodada inteira
make eval-components           #    planner, retrieval, rerank (~5 min)
make eval-ragas                #    fidelidade da resposta (~6 min)
make eval-judge                #    rubrica do produto (~5 min)
make eval-agent                #    trajetória do agente (~4 min)
make eval-gate                 # 3. lê os relatórios e decide
```

Ou tudo de uma vez: `make eval-all` (cerca de 20 min). A cadeia para na primeira falha.

**Regras do gate (`make eval-gate`):**

- Ele só lê `data/eval_runs/`; não chama modelo, banco ou Langfuse.
- `component` e `agent` são **obrigatórios**: sem relatório deles o resultado é `FAILED`
  (foi o que aconteceu ao testá-lo aqui, antes de rodar essas duas).
- Rodada com `LIMIT` ou `CASE` deixa métricas sem caso aplicável, e o gate as marca
  `MISSING`. Use `LIMIT` para testar; para o gate, rode a rodada completa.
- `make eval-reports` mostra quais relatórios ele encontra.

**4c. Comparar duas versões do pipeline (opcional):**

```bash
make eval-experiment-baseline      # pipeline como roda hoje, com rerank
make eval-experiment-no-rerank     # a variante sem rerank
make eval-compare                  # tabela dos dois relatórios mais recentes
```

**4d. Calibrar o juiz (opcional):** `make eval-judge-calibrate` dá notas a respostas
sabidamente ruins para conferir que o juiz as reprova.

### 5. Desligar

```bash
make infra-down      # para os containers, mantém os dados
make infra-reset     # para E APAGA os volumes: índice pgvector, datasets e traces do Langfuse
```

Depois de `infra-reset`, volte ao passo 2.

## Receitas por objetivo

| Quero… | Rode |
| --- | --- |
| Só conversar com a base | `make setup` → `make infra-up` → `make prepare` → `make chat` |
| Expor a API | os mesmos três primeiros → `make api` → `test.http` |
| Testar o agente sem gastar nada | `make setup` → `make agent-tools` |
| Usar o agente de verdade | passos 1–2 → `make agent` |
| Validar uma mudança no código, de graça | `make test` e `make eval-datasets-validate` |
| Decidir se um build sobe | `make infra-observability` → `make eval-all` |
| Mudei um documento da base | `make prepare` |
| Algo no índice ficou estranho | `make index-force` |

## Parâmetros

| Parâmetro | Vale em | Exemplo |
| --- | --- | --- |
| `LIMIT=N` | `eval-components`, `eval-ragas`, `eval-judge`, `eval-agent`, `eval-experiment-*` | `make eval-ragas LIMIT=3` |
| `CASE=id` | idem | `make eval-components CASE=company_email_financeiro` |
| `ARGS="..."` | quase todos; repassa flags ao comando | `make eval-components ARGS="--no-langfuse"` |
| `Q="..."` | `retrieve` | `make retrieve Q="forma de pagamento"` |
| `DOC=arquivo.md` | `chat-document` | `make chat-document DOC=billing-policy.md` |
| `HOST`, `PORT` | `api`, `api-health` | `make api PORT=9000` |
| `PY=...` | todos | `make test PY=python` (usa outro interpretador, sem a `.venv`) |

## Problemas comuns

- **`failed to connect to the docker API`**: o Docker Desktop não está aberto.
- **`Collection ... is missing or empty`**: faltou `make prepare`.
- **`ValidationError` ao iniciar**: `OPENAI_API_KEY` vazia no `.env`.
- **Porta 5433 ou 3000 ocupada**: outro Postgres/Langfuse rodando; pare-o ou mude a porta no
  `docker-compose.yml` e no `DATABASE_URL`.
- **`eval-components`/`eval-agent` não acham o dataset**: faltou `make eval-datasets`, ou as
  chaves do Langfuse no `.env` estão vazias.
- **Gate `FAILED (required report not found)`**: faltam as rodadas completas de
  `eval-components` e `eval-agent`.
- **`make` não existe no Windows**: `choco install make`.
