-- =============================================================================
-- sql/bronze/01_tabelas_bronze.sql
--
-- Camada BRONZE: espelho fiel das fontes. Nenhuma transformação aqui.
--
-- Decisão de projeto: os atributos das fontes geoespaciais são guardados em
-- JSONB (`atributos`), não em colunas tipadas. Motivo: os nomes de campo dos
-- shapefiles do Sicar e das camadas de cruzamento variam entre versões e
-- entre UFs, e descobrir isso no meio de uma carga é o que quebra pipeline em
-- produção. Bronze aceita o que vier; o mapeamento explícito acontece na
-- prata, onde a falha é visível e testável.
--
-- SRID 4674 = SIRGAS 2000, o datum oficial das bases do CAR.
-- =============================================================================

SET search_path TO bronze, public;

-- -----------------------------------------------------------------------------
-- Macro de colunas de controle (replicada em cada tabela por clareza):
--   _ingestao_id        UUID da execução que inseriu a linha
--   _ingestao_timestamp quando a linha chegou
--   _fonte_arquivo      caminho/URL de origem
--   _hash_linha         SHA-256 do payload original (detecta mudança)
-- -----------------------------------------------------------------------------

-- =============================================================================
-- SICAR — perímetros dos imóveis
-- =============================================================================
CREATE TABLE IF NOT EXISTS bronze.sicar__area_imovel (
    id                  BIGSERIAL   PRIMARY KEY,
    uf                  CHAR(2)     NOT NULL,
    geom                GEOMETRY(MultiPolygon, 4674),
    atributos           JSONB       NOT NULL,
    _ingestao_id        UUID        NOT NULL,
    _ingestao_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _fonte_arquivo      TEXT        NOT NULL,
    _hash_linha         TEXT        NOT NULL
);

COMMENT ON TABLE bronze.sicar__area_imovel IS
    'Perímetros declarados dos imóveis rurais, como vêm do Módulo de Consulta '
    'Pública do Sicar. Atributos preservados em JSONB sem renomeação.';
COMMENT ON COLUMN bronze.sicar__area_imovel.atributos IS
    'Atributos do shapefile exatamente como na fonte, incluindo o código do '
    'imóvel. O mapeamento para colunas tipadas está em sql/prata/01_imoveis.sql.';

CREATE INDEX IF NOT EXISTS idx_bronze_imovel_uf
    ON bronze.sicar__area_imovel (uf);
CREATE INDEX IF NOT EXISTS idx_bronze_imovel_hash
    ON bronze.sicar__area_imovel (_hash_linha);
CREATE INDEX IF NOT EXISTS idx_bronze_imovel_geom
    ON bronze.sicar__area_imovel USING GIST (geom);

-- =============================================================================
-- SICAR — camadas temáticas declaradas
-- =============================================================================
CREATE TABLE IF NOT EXISTS bronze.sicar__app (
    id                  BIGSERIAL   PRIMARY KEY,
    uf                  CHAR(2)     NOT NULL,
    tipo_app            TEXT,
    geom                GEOMETRY(MultiPolygon, 4674),
    atributos           JSONB       NOT NULL,
    _ingestao_id        UUID        NOT NULL,
    _ingestao_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _fonte_arquivo      TEXT        NOT NULL,
    _hash_linha         TEXT        NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bronze_app_geom
    ON bronze.sicar__app USING GIST (geom);

CREATE TABLE IF NOT EXISTS bronze.sicar__area_consolidada (
    id                  BIGSERIAL   PRIMARY KEY,
    uf                  CHAR(2)     NOT NULL,
    geom                GEOMETRY(MultiPolygon, 4674),
    atributos           JSONB       NOT NULL,
    _ingestao_id        UUID        NOT NULL,
    _ingestao_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _fonte_arquivo      TEXT        NOT NULL,
    _hash_linha         TEXT        NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bronze_consolidada_geom
    ON bronze.sicar__area_consolidada USING GIST (geom);

CREATE TABLE IF NOT EXISTS bronze.sicar__reserva_legal (
    id                  BIGSERIAL   PRIMARY KEY,
    uf                  CHAR(2)     NOT NULL,
    geom                GEOMETRY(MultiPolygon, 4674),
    atributos           JSONB       NOT NULL,
    _ingestao_id        UUID        NOT NULL,
    _ingestao_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _fonte_arquivo      TEXT        NOT NULL,
    _hash_linha         TEXT        NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bronze_rl_geom
    ON bronze.sicar__reserva_legal USING GIST (geom);

-- =============================================================================
-- SFB — Painel da Regularização Ambiental (tabular)
-- =============================================================================
CREATE TABLE IF NOT EXISTS bronze.sfb__painel_regularizacao (
    id                  BIGSERIAL   PRIMARY KEY,
    atributos           JSONB       NOT NULL,
    _ingestao_id        UUID        NOT NULL,
    _ingestao_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _fonte_arquivo      TEXT        NOT NULL,
    _hash_linha         TEXT        NOT NULL
);

COMMENT ON TABLE bronze.sfb__painel_regularizacao IS
    'Indicadores de volume e status de análise por UF. Sustenta a linha do '
    'tempo de gargalos quando o marco temporal não vem no dado geoespacial.';

-- =============================================================================
-- Camadas de cruzamento (áreas protegidas, embargos, malha fundiária)
--
-- Todas no mesmo formato: uma tabela por fonte, geometria + JSONB. A coluna
-- `categoria` normaliza o tipo de restrição para o detector d2 consumir sem
-- precisar de UNION por tabela.
-- =============================================================================
CREATE TABLE IF NOT EXISTS bronze.restricoes__areas (
    id                  BIGSERIAL   PRIMARY KEY,
    fonte               TEXT        NOT NULL,
    categoria           TEXT        NOT NULL
                                    CHECK (categoria IN (
                                        'embargo',
                                        'unidade_conservacao',
                                        'terra_indigena',
                                        'floresta_publica',
                                        'quilombola',
                                        'assentamento'
                                    )),
    nome                TEXT,
    geom                GEOMETRY(MultiPolygon, 4674),
    atributos           JSONB       NOT NULL,
    _ingestao_id        UUID        NOT NULL,
    _ingestao_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _fonte_arquivo      TEXT        NOT NULL,
    _hash_linha         TEXT        NOT NULL
);

COMMENT ON TABLE bronze.restricoes__areas IS
    'Camadas de restrição territorial de várias fontes, normalizadas por '
    'categoria. Alimenta o detector d2 (incidência em área protegida).';

CREATE INDEX IF NOT EXISTS idx_bronze_restricoes_geom
    ON bronze.restricoes__areas USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_bronze_restricoes_categoria
    ON bronze.restricoes__areas (categoria);

-- =============================================================================
-- Referências municipais: módulo fiscal e malha
--
-- O módulo fiscal é o eixo do detector d1: o limite de 4 módulos varia de 5 a
-- 110 hectares conforme o município, então "pequeno imóvel" é uma grandeza
-- diferente em cada lugar do país.
-- =============================================================================
CREATE TABLE IF NOT EXISTS bronze.incra__modulo_fiscal (
    id                  BIGSERIAL   PRIMARY KEY,
    atributos           JSONB       NOT NULL,
    _ingestao_id        UUID        NOT NULL,
    _ingestao_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _fonte_arquivo      TEXT        NOT NULL,
    _hash_linha         TEXT        NOT NULL
);

CREATE TABLE IF NOT EXISTS bronze.ibge__municipios (
    id                  BIGSERIAL   PRIMARY KEY,
    geom                GEOMETRY(MultiPolygon, 4674),
    atributos           JSONB       NOT NULL,
    _ingestao_id        UUID        NOT NULL,
    _ingestao_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _fonte_arquivo      TEXT        NOT NULL,
    _hash_linha         TEXT        NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bronze_municipios_geom
    ON bronze.ibge__municipios USING GIST (geom);

-- =============================================================================
-- Registro de versões de fonte — linhagem mínima exigida pelo projeto
-- =============================================================================
CREATE TABLE IF NOT EXISTS bronze._versoes_fonte (
    fonte               TEXT        NOT NULL,
    versao              TEXT        NOT NULL,
    url                 TEXT,
    licenca             TEXT,
    arquivo_local       TEXT,
    sha256_arquivo      TEXT,
    ingerido_em         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _ingestao_id        UUID        NOT NULL,
    PRIMARY KEY (fonte, versao)
);

COMMENT ON TABLE bronze._versoes_fonte IS
    'Qual versão de qual fonte entrou no banco, quando e com que hash. '
    'É a tabela que responde "de onde veio esse número" na defesa da proposta.';

GRANT SELECT ON ALL TABLES IN SCHEMA bronze TO etl_prata;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA bronze TO etl_bronze;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA bronze TO etl_bronze;
