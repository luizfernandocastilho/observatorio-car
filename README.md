# Observatório do Ciclo de Vida do CAR

Pipeline e interface que mostram **onde cada cadastro do Cadastro Ambiental
Rural empaca** e **sinalizam padrões anômalos para triagem**, a partir de
dados públicos.

Proposta para o **Desafio 3** do InovaCAR — Ciclo 1 (MGI, FBDS, Enap, Impact
Hub Brasil). Código aberto, licença Apache 2.0, sem dependência proprietária.

## O que faz, e o que não faz

**Faz:**

- Reconstrói a linha do tempo do ciclo de vida de cada cadastro (inscrição,
  análise, notificação, retificação, validação, PRA) e mostra em que etapa os
  imóveis estão parados, por UF, município e faixa de módulos fiscais.
- Gera sinais para triagem com cinco detectores auditáveis, cada um com
  regra, limiares, evidência e hipóteses alternativas explícitas.
- Mede a própria precisão: cada detector tem a taxa de acerto apurada em
  auditoria manual de amostra aleatória reproduzível.

**Não faz, deliberadamente:**

- Não é outro painel de consulta pública ao CAR. Essa plataforma já existe
  (`consulta.car.gov.br`) e o briefing do desafio veta redesign de interface
  sem ganho de backend.
- Não afirma irregularidade. Produz hipótese com evidência; a decisão é do
  analista do órgão gestor.
- Não processa dado pessoal. Os sinais apontam imóveis e geometrias.
- Não contorna a validação por requisição do download público do Sicar.

## Arquitetura

Medalhão sobre PostGIS, orquestrado por Airflow.

```
fontes públicas
      |
   BRONZE   espelho fiel, atributos em JSONB, hash por linha
      |
   PRATA    saneamento geométrico, tipagem, eventos de ciclo de vida
      |
    OURO    gargalos por etapa + sinais para triagem + amostra de validação
      |
  dashboard (Streamlit, somente leitura)
```

Dados só fluem para cima. Toda carga é idempotente.

## Subindo o projeto

Pré-requisitos: Docker com Compose v2, Python 3.11+ para rodar os testes
localmente, e cerca de 10 GB livres para o banco das três UFs piloto.

```bash
git clone <url-do-repo> observatorio-car
cd observatorio-car
cp .env.example .env        # ajuste as senhas
make up
```

- Dashboard: http://localhost:8502
- Airflow: http://localhost:8088 (airflow/airflow)
- Banco: `make psql`

`make ajuda` lista todos os comandos.

### Portas do host

As portas padrão estavam ocupadas na máquina de desenvolvimento, então o
Compose publica tudo em portas deslocadas. Dentro dos containers os serviços
seguem nas portas-padrão; o remapeamento é só do lado do host.

| Serviço | Dentro do container | No host |
|---|---|---|
| Banco de dados (PostGIS) | 5432 | **5442** |
| Metadados do Airflow | 5432 | **5434** |
| Airflow (UI) | 8080 | **8088** |
| Dashboard (Streamlit) | 8501 | **8502** |

> ⚠️ **Armadilha:** há um PostgreSQL nativo escutando na **5432** desta
> máquina. `psql -h localhost -p 5432 ...` cai no banco errado, não no banco do
> projeto. Use `make psql` (que entra pelo container) ou aponte explicitamente
> para a porta 5442: `psql -h localhost -p 5442 -U etl_admin -d dados`.

## Depositando os dados

O pipeline **não baixa** os dados automaticamente. Estrutura esperada:

```
dados_brutos/
  sicar/{pa,mg,ce}/            shapefiles de AREA_IMOVEL por município
  restricoes/embargos/
  restricoes/unidades_conservacao/
  restricoes/terras_indigenas/
  restricoes/florestas_publicas/
  ibge/                        malha municipal
  incra/                       módulo fiscal por município (CSV)
```

As URLs, licenças e versões de cada fonte estão em `contracts/fontes.yml`.
O download do Sicar é por município, com validação a cada requisição — é
trabalho manual por decisão de projeto, não por limitação técnica.

Com os arquivos no lugar, ative o DAG `observatorio_car_diario` no Airflow.

## Como ler os sinais

Cada linha em `ouro.car__sinais_anomalia` é uma **hipótese**, não uma
conclusão. Antes de agir sobre qualquer sinal, veja:

| Campo | O que diz |
|---|---|
| `regra_aplicada` | a regra em português, com os valores do caso |
| `limiares` | os limiares vigentes quando o sinal foi gerado |
| `evidencia` | os dados que sustentam o sinal, incluindo hipóteses alternativas |
| `confianca` | precisão medida do detector; `null` = ainda não auditado |

Um sinal com `confianca` nula não deve ser usado para priorizar nada. Veja
`ouro.car__precisao_detector` para o estado da auditoria.

## Os cinco detectores

| Detector | Hipótese |
|---|---|
| `d1_fatiamento` | imóveis contíguos logo abaixo de 4 módulos fiscais, inscritos em janela curta |
| `d2_incidencia_area_protegida` | sobreposição relevante com embargo, UC, terra indígena ou floresta pública |
| `d3_sobreposicao_car_car` | dois imóveis declarando a mesma área |
| `d4_geometria_improvavel` | assinatura de erro de desenho: compacidade, divergência de área, polígono reaproveitado |
| `d5_padrao_cadastral_atipico` | lotes de cadastros em bloco fora da distribuição do município |

Limiares em `contracts/detectores.yml`. Método detalhado em
`docs/nota_tecnica.md`.

## Testes

```bash
make testar                   # contratos: SQL x YAML, idempotência, linguagem
make verificar-idempotencia   # roda prata+ouro duas vezes e compara estado
make suites                   # (re)cria as suítes Great Expectations
```

Os testes de contrato rodam sem banco e sem Airflow. Eles pegam o erro mais
comum do projeto: renomear um limiar no YAML e esquecer o placeholder no SQL.

## Contribuindo

Leia `CLAUDE.md` antes de qualquer alteração — ele traz as onze regras
inegociáveis do projeto, incluindo a proibição de linguagem acusatória e de
dado pessoal, que são testadas automaticamente.

Backlog em `TASKS.md`.

## Licença

Apache 2.0.
