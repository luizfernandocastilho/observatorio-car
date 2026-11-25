-- =============================================================================
-- 00_setup_schemas.sql
--
-- Setup inicial do banco: schemas bronze/prata/ouro, usuários por camada,
-- extensões úteis, e tabelas de controle.
--
-- Rodar como superuser (ou role com CREATEROLE + CREATEDB) uma vez por
-- ambiente (dev/staging/prod). Em Docker Compose este arquivo é montado em
-- /docker-entrypoint-initdb.d/ e roda automaticamente no primeiro boot.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Extensões
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
-- btree_gist permite índices combinando coluna escalar + geometria,
-- usado nas consultas por UF nos cruzamentos espaciais.
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- -----------------------------------------------------------------------------
-- Schemas
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS prata;
CREATE SCHEMA IF NOT EXISTS ouro;

COMMENT ON SCHEMA bronze IS
    'Camada raw: cópia fiel das fontes externas, sem transformação. '
    'Preserva evidência para auditoria e reprocessamento.';

COMMENT ON SCHEMA prata IS
    'Camada cleansed: dados tipados, deduplicados, validados. '
    'Aqui vivem as regras de qualidade e a normalização de chaves.';

COMMENT ON SCHEMA ouro IS
    'Camada curated: modelos dimensionais e agregados para consumo '
    'por BI, ML e APIs. Orientada a casos de uso de negócio.';

-- -----------------------------------------------------------------------------
-- Usuários por camada (princípio do menor privilégio)
--
-- IMPORTANTE: em produção, as senhas vêm de variáveis de ambiente / secret
-- manager. Os DO $$ abaixo protegem de CREATE duplicado em reruns.
-- -----------------------------------------------------------------------------

-- etl_bronze: lê e escreve em bronze
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'etl_bronze') THEN
        CREATE ROLE etl_bronze WITH LOGIN PASSWORD 'etl_bronze_dev';
    END IF;
END $$;

GRANT USAGE, CREATE ON SCHEMA bronze TO etl_bronze;
ALTER DEFAULT PRIVILEGES IN SCHEMA bronze
    GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO etl_bronze;
ALTER DEFAULT PRIVILEGES IN SCHEMA bronze
    GRANT USAGE, SELECT ON SEQUENCES TO etl_bronze;

-- etl_prata: lê bronze, escreve em prata
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'etl_prata') THEN
        CREATE ROLE etl_prata WITH LOGIN PASSWORD 'etl_prata_dev';
    END IF;
END $$;

GRANT USAGE ON SCHEMA bronze TO etl_prata;
GRANT USAGE, CREATE ON SCHEMA prata TO etl_prata;
ALTER DEFAULT PRIVILEGES IN SCHEMA bronze
    GRANT SELECT ON TABLES TO etl_prata;
ALTER DEFAULT PRIVILEGES IN SCHEMA prata
    GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO etl_prata;
ALTER DEFAULT PRIVILEGES IN SCHEMA prata
    GRANT USAGE, SELECT ON SEQUENCES TO etl_prata;

-- etl_ouro: lê prata, escreve em ouro
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'etl_ouro') THEN
        CREATE ROLE etl_ouro WITH LOGIN PASSWORD 'etl_ouro_dev';
    END IF;
END $$;

GRANT USAGE ON SCHEMA prata TO etl_ouro;
GRANT USAGE, CREATE ON SCHEMA ouro TO etl_ouro;
ALTER DEFAULT PRIVILEGES IN SCHEMA prata
    GRANT SELECT ON TABLES TO etl_ouro;
ALTER DEFAULT PRIVILEGES IN SCHEMA ouro
    GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO etl_ouro;
ALTER DEFAULT PRIVILEGES IN SCHEMA ouro
    GRANT USAGE, SELECT ON SEQUENCES TO etl_ouro;

-- bi_leitura: somente leitura em ouro (para consumo por BI/analistas)
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bi_leitura') THEN
        CREATE ROLE bi_leitura WITH LOGIN PASSWORD 'bi_leitura_dev';
    END IF;
END $$;

GRANT USAGE ON SCHEMA ouro TO bi_leitura;
ALTER DEFAULT PRIVILEGES IN SCHEMA ouro
    GRANT SELECT ON TABLES TO bi_leitura;

-- -----------------------------------------------------------------------------
-- Tabelas de controle (genéricas, não ligadas a domínio específico)
-- -----------------------------------------------------------------------------

-- Controle de ingestão: cursor incremental por fonte
CREATE TABLE IF NOT EXISTS bronze._controle_ingestao (
    fonte              TEXT        NOT NULL,
    tabela_destino     TEXT        NOT NULL,
    ultimo_cursor      TEXT,
    ultima_execucao    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status             TEXT        NOT NULL
                                    CHECK (status IN ('sucesso', 'falha', 'em_andamento')),
    linhas_processadas BIGINT,
    mensagem_erro      TEXT,
    PRIMARY KEY (fonte, tabela_destino)
);

COMMENT ON TABLE bronze._controle_ingestao IS
    'Controle de ingestão incremental. Uma linha por (fonte, tabela_destino). '
    'Usado por extratores para retomar do último cursor com sucesso.';

-- Registros rejeitados em qualquer camada
CREATE TABLE IF NOT EXISTS prata._rejeitados (
    id                  BIGSERIAL   PRIMARY KEY,
    tabela_origem       TEXT        NOT NULL,
    payload             JSONB       NOT NULL,
    motivo              TEXT        NOT NULL,
    _processamento_id   UUID        NOT NULL,
    _rejeitado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE prata._rejeitados IS
    'Registros que falharam validações de qualidade ao ir para prata. '
    'Inspecionar periodicamente; picos indicam problemas upstream.';

CREATE INDEX IF NOT EXISTS idx_rejeitados_processamento
    ON prata._rejeitados (_processamento_id);
CREATE INDEX IF NOT EXISTS idx_rejeitados_tabela_origem
    ON prata._rejeitados (tabela_origem, _rejeitado_em DESC);

-- -----------------------------------------------------------------------------
-- Função utilitária: gerar _hash_linha a partir de colunas arbitrárias
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bronze.hash_linha(VARIADIC cols TEXT[])
RETURNS TEXT
LANGUAGE SQL IMMUTABLE AS $$
    SELECT encode(
        digest(
            array_to_string(cols, '|'),
            'sha256'
        ),
        'hex'
    );
$$;

COMMENT ON FUNCTION bronze.hash_linha IS
    'Gera hash SHA-256 a partir de colunas (passadas como variadic). '
    'Uso: INSERT ... SELECT bronze.hash_linha(col_a::text, col_b::text, ...)';

-- -----------------------------------------------------------------------------
-- Verificação — roda ao final para confirmar que tudo foi criado
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    n_schemas INT;
    n_roles INT;
BEGIN
    SELECT COUNT(*) INTO n_schemas
    FROM information_schema.schemata
    WHERE schema_name IN ('bronze', 'prata', 'ouro');

    SELECT COUNT(*) INTO n_roles
    FROM pg_roles
    WHERE rolname IN ('etl_bronze', 'etl_prata', 'etl_ouro', 'bi_leitura');

    IF n_schemas = 3 AND n_roles = 4 THEN
        RAISE NOTICE 'Setup concluído: 3 schemas, 4 roles criados.';
    ELSE
        RAISE WARNING 'Setup incompleto: % schemas, % roles', n_schemas, n_roles;
    END IF;
END $$;
