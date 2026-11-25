# CLAUDE.md — Observatório do Ciclo de Vida do CAR

Memória de projeto para o Claude Code. Leia antes de qualquer alteração.

## O que é este projeto

Pipeline e interface que mostram **onde cada cadastro do CAR empaca** e
**sinalizam padrões anômalos para triagem**, a partir de dados públicos.

Essa frase é a definição canônica do produto. Ela aparece igual no pitch, no
formulário de inscrição e no README. Se uma mudança no código não couber mais
nessa frase, a mudança está errada ou a frase precisa ser renegociada com o
time — nunca silenciosamente.

### Contexto externo (importa para decisões técnicas)

Inscrição no **InovaCAR — Ciclo 1**, chamada de inovação aberta do MGI, FBDS,
Enap e Impact Hub para o Cadastro Ambiental Rural. Concorremos ao **Desafio
3** (ampliar o acesso aos dados do CAR).

- Inscrições até **22/01/2027**. Submissão-alvo: **15/01/2027**.
- Entregáveis: vídeo de protótipo (mp4, 3 min) e vídeo de pitch (mp4, 3 min).
- Exige solução **já funcionando**, demonstrável em ambiente real.
- Aceleração de 22/03 a 25/06/2027, com Demoday.

Critérios de avaliação e pesos: aderência ao desafio (2), capacidade de
desenvolvimento (2), criatividade e inovação (1), potencial de escala (1),
viabilidade financeira (1).

### O que já existe lá fora, e por que isso define nosso recorte

O MGI já publicou uma plataforma de consulta a dados públicos do CAR
(`consulta.car.gov.br`) com mapas, painéis analíticos e download filtrado.
**Não construímos outro painel de consulta.** O briefing do Desafio 3 veta
explicitamente redesign de interface sem ganho real de backend.

Nosso recorte é o que não existe: a **linha do tempo do ciclo de vida** do
cadastro (nomeada no briefing como dashboard gerencial de gargalos) e a
**camada de detecção de anomalias auditáveis**.

## Regras inegociáveis

Estas regras valem mais que elegância de código. Quebrar qualquer uma delas
invalida o projeto como proposta para um órgão público.

### 1. Linguagem não acusatória

A ferramenta produz **sinal para triagem**, nunca afirmação de
irregularidade. Proibido em código, SQL, interface, commit e documentação:
"fraude", "irregularidade", "infrator", "denúncia", "criminoso".

Use: "sinal para triagem", "caso prioritário para verificação", "divergência
a apurar", "hipótese".

Isso é testado automaticamente em `tests/test_detectores.py::test_linguagem_nao_acusatoria`.

### 2. Nenhum dado pessoal

Trabalhamos só com dado público, e mesmo nele não exibimos nem agrupamos por
nome, CPF ou responsável técnico. Os sinais apontam **imóveis e geometrias**.
Identificar pessoas é competência do órgão gestor.

Se uma ideia de detector precisar de dado pessoal para funcionar, a ideia é
descartada — foi o que aconteceu com a versão original do detector d5.

### 3. Todo sinal é auditável

Cada linha em `ouro.car__sinais_anomalia` carrega regra aplicada, limiares
usados, evidência bruta e hipóteses alternativas. Se um analista não consegue
discordar do sinal lendo a evidência, o detector está mal feito.

### 4. Confiança é medida, não estimada

A coluna `confianca` vem da **precisão apurada em auditoria manual de amostra
aleatória** (`contracts/detectores.yml` → `precisao_medida`). Enquanto for
`null`, a interface diz que não há precisão medida. **Nunca** preencher com
palpite, e nunca apresentar número de acerto em vídeo ou documento sem
auditoria por trás.

### 5. Limiares moram em contrato, não em código

Todo limiar de detector vive em `contracts/detectores.yml`. O SQL usa
placeholders `%(nome)s`. Mudar limiar nunca é mudar SQL.

### 6. Dados só fluem para cima

bronze → prata → ouro. Ouro não lê bronze. Prata não escreve em bronze.
Bronze não transforma nada: é espelho fiel da fonte, com atributos em JSONB.

### 7. Idempotência

Toda carga roda duas vezes com o mesmo resultado. Bronze usa hash de linha;
prata faz upsert por chave natural; ouro usa delete+insert escopado na data
de referência e `ON CONFLICT DO NOTHING` nos sinais. Testado em
`test_detector_e_idempotente`.

### 8. Código aberto sem dependência proprietária

Licença permissiva (Apache 2.0 — mais amigável à adoção por governo que AGPL).
Nada de biblioteca com licenciamento recorrente, nada de serviço gerenciado
sem alternativa auto-hospedada. O critério 5 do edital fala em custos
compatíveis com a realidade orçamentária pública: responder com número, nunca
com adjetivo.

### 9. Não automatizar a quebra de validação da fonte

O download público do Sicar é por município, com validação a cada
requisição. **Não** escrever scraper que contorne isso. Os arquivos são
baixados manualmente (ou via download filtrado de `consulta.car.gov.br`) e
depositados em `dados_brutos/<fonte>/<uf>/`. O pipeline consome de lá.

### 10. Português do Brasil em tudo

Código, docstrings, comentários, nomes de coluna, commits, documentação.
Schemas são `bronze`/`prata`/`ouro`, não `silver`/`gold`.

### 11. Dependência do Airflow sempre com o constraints oficial

Toda dependência instalada na imagem do Airflow é resolvida com o arquivo de
constraints oficial **da versão exata do Airflow** (ex.: Airflow 2.9.3 +
Python 3.11 → `constraints-2.9.3/constraints-3.11.txt`). Sem o constraints, o
pip tenta atualizar o próprio Airflow e desencadeia backtracking que arrasta
centenas de pacotes — e pode subir o SQLAlchemy para 2.x, que o Airflow 2.9.3
não suporta.

Decorre disso: em `docker/airflow/requirements.txt` listam-se **só** as libs
adicionais que a imagem não traz. Não fixe `pandas`, `sqlalchemy`, `pyyaml`,
`httpx`, `tenacity` nem `psycopg2` ali — já vêm na imagem nas versões certas, e
refixá-las quebra em tempo de execução. Bump de versão do Airflow = trocar a
imagem base **e** a URL do constraints juntos, no mesmo commit.

## Mapa do repositório

```
contracts/          Contratos YAML — fontes e limiares dos detectores
  fontes.yml        Catálogo das fontes: url, licença, SRID, versão usada
  detectores.yml    Limiares, precisão medida, parâmetros de amostragem
dags/               Orquestração Airflow (só orquestra; lógica fica em plugins)
plugins/medalhao/   Lógica testável sem Airflow
  config.py         Leitura dos contratos
  ingestao_geo.py   Camadas vetoriais -> bronze
  ingestao_tabular.py  CSV -> bronze
  detectores.py     Execução parametrizada dos detectores
sql/
  00_setup_schemas.sql      Schemas, roles, extensões (PostGIS)
  bronze/                   DDL da camada bronze
  prata/                    Saneamento, tipagem, eventos de ciclo de vida
  ouro/                     Sinais, gargalos, amostra de validação
  ouro/detectores/          Um .sql por detector
dashboard/          Streamlit de leitura da camada ouro
great_expectations/ Suítes de qualidade por camada
tests/              Testes de contrato (rodam sem banco)
dados_brutos/       Arquivos baixados das fontes (fora do git)
```

## Como rodar

```bash
cp .env.example .env          # ajuste as senhas
make up                       # sobe PostGIS + Airflow + dashboard
make testar                   # testes de contrato, sem banco
make verificar-idempotencia   # roda prata+ouro duas vezes e compara
```

- Dashboard: http://localhost:8502
- Airflow: http://localhost:8088 (airflow/airflow)
- Banco: `make psql` (entra pelo container) ou
  `psql -h localhost -p 5442 -U etl_admin -d dados`

> **Portas deslocadas e armadilha da 5432.** As portas-padrão estavam ocupadas
> na máquina de desenvolvimento; o Compose publica em portas deslocadas (banco
> **5442**, metadados do Airflow **5434**, Airflow UI **8088**, dashboard
> **8502**). Dentro dos containers os serviços seguem nas portas-padrão.
> Há um **PostgreSQL nativo escutando na 5432** desta máquina: `psql -h
> localhost -p 5432` cai no banco errado. Sempre use `make psql` ou a porta
> **5442** explícita. Ver `docker-compose.yml` e `.env.example`.

O DAG `observatorio_car_diario` só roda depois que os arquivos das fontes
estiverem em `dados_brutos/`. Ele falha com mensagem explícita se faltar
arquivo — falha visível é melhor que carga vazia silenciosa.

## Decisões de infraestrutura

Decisões tomadas durante a instalação real, quando o ambiente divergiu do que
estava documentado no esqueleto. Ficam aqui com a justificativa para não serem
revertidas por engano.

1. **Portas do host deslocadas.** As portas-padrão estavam ocupadas na máquina
   de desenvolvimento. O Compose publica banco **5442** (→5432), metadados do
   Airflow **5434** (→5432), Airflow UI **8088** (→8080) e dashboard **8502**
   (→8501). Armadilha documentada acima: a 5432 é de um PostgreSQL nativo, não
   do projeto.

2. **Imagem própria do Airflow em `docker/airflow/`.** Construída a partir de
   `apache/airflow:2.9.3-python3.11` com o constraints oficial (ver regra 11).
   Substituiu o `_PIP_ADDITIONAL_REQUIREMENTS`, que reinstalava as dependências
   a cada boot do container — lento e não reprodutível. Com a imagem, a
   instalação acontece uma vez, no build.

3. **Só três dependências extras do Airflow.** `apache-airflow-providers-postgres
   ==5.11.2`, `geopandas==1.0.1`, `pyogrio==0.9.0`. O resto (`pandas`,
   `sqlalchemy`, `pyyaml`, `httpx`, `tenacity`, `psycopg2`) já vem na imagem;
   fixá-los quebra em tempo de execução, em especial o SQLAlchemy — o Airflow
   2.9.3 usa a série 1.4, não 2.x. Detalhe e motivo na regra 11.

4. **Great Expectations fora do container.** Saiu da imagem e foi para
   `requirements-qualidade.txt`, instalado em um venv na máquina. As suítes
   rodam fora do Docker (`make suites`), contra o banco publicado na 5442.
   Mantém a imagem do Airflow enxuta e evita arrastar as dependências pesadas
   do GE para dentro do runtime de orquestração.

5. **`curl` na imagem do dashboard.** O `HEALTHCHECK` do serviço usa `curl`
   contra `/_stcore/health`; sem o binário instalado, o healthcheck falha
   sempre e o container nunca fica `healthy`.

## Convenções

- Tabelas: `bronze.{fonte}__{entidade}`, `prata.{dominio}__{entidade}`,
  `ouro.{dominio}__{artefato}`. Separador duplo underscore.
- SRID **4674** (SIRGAS 2000) em todas as geometrias. Clusterização métrica
  em **5880** (Polycônica do Brasil). Áreas via `::geography`, em hectares.
- Colunas de controle obrigatórias: bronze tem `_ingestao_id`,
  `_ingestao_timestamp`, `_fonte_arquivo`, `_hash_linha`; prata tem
  `_processamento_id`, `_processamento_timestamp`, `_versao_registro`,
  `_valido_de`, `_valido_ate`.
- Detectores versionam em semver (`1.0.0`) dentro do próprio SQL. Mudança de
  regra que altere resultado exige bump de versão, porque a precisão medida é
  por versão.
- Commits em português, imperativo: "adiciona detector de sobreposição".

## O que NÃO fazer

- Não criar um painel de consulta pública ao CAR (já existe, e o edital veta).
- Não transformar dado na bronze.
- Não fazer JOIN entre camadas não adjacentes.
- Não usar `SELECT *` em transformação de produção.
- Não colocar credencial em código ou em `default_args` do DAG.
- Não colocar lógica de negócio no DAG.
- Não preencher `precisao_medida` sem auditoria manual.
- Não adicionar dependência proprietária ou com custo recorrente.
- Não usar `TRUNCATE` em tabela de histórico.
- Não inventar nome de atributo de fonte: confira contra o arquivo real
  (tarefa T-02) e documente em `contracts/fontes.yml`.

## Skills a usar neste repositório

- `etl-medallion-postgres-ptbr` — qualquer mudança em pipeline, DAG, camadas
  ou qualidade de dados.
- `postgre-senior-ptbr` — modelagem, DDL, índices, migrations.
- `frontend-python-ptbr` — qualquer trabalho no `dashboard/`.
- `test-django-ptbr` — estratégia de testes (vale para pytest em geral).
- `git-github-senior-ptbr` — fluxo de branches, PR, proteção de segredos.

## Estado atual

Esqueleto completo e testado nos contratos; **ainda não rodado contra dado
real**. A próxima tarefa é sempre a primeira não concluída em `TASKS.md`.
