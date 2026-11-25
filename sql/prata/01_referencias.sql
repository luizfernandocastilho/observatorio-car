-- =============================================================================
-- sql/prata/01_referencias.sql
--
-- Camada PRATA — tabelas de referência: municípios com módulo fiscal e
-- camadas de restrição territorial saneadas.
--
-- Roda ANTES de 02_imoveis.sql: o módulo fiscal por município é o que permite
-- converter hectares em módulos, e sem isso o detector de fatiamento não
-- existe.
--
-- Idempotente por upsert na chave natural.
-- =============================================================================

SET search_path TO prata, bronze, public;

CREATE TABLE IF NOT EXISTS prata.ref__municipios (
    cod_ibge                CHAR(7)     PRIMARY KEY,
    nome                    TEXT        NOT NULL,
    uf                      CHAR(2)     NOT NULL,
    modulo_fiscal_ha        NUMERIC(10,2),
    limite_4_modulos_ha     NUMERIC(10,2) GENERATED ALWAYS AS
                                (modulo_fiscal_ha * 4) STORED,
    geom                    GEOMETRY(MultiPolygon, 4674),
    _processamento_id       UUID        NOT NULL,
    _processamento_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON COLUMN prata.ref__municipios.limite_4_modulos_ha IS
    'Limite de 4 módulos fiscais em hectares. Varia de ~20 a ~440 ha entre '
    'municípios — é por isso que "pequeno imóvel" não é um número nacional.';

CREATE INDEX IF NOT EXISTS idx_prata_municipios_uf
    ON prata.ref__municipios (uf);
CREATE INDEX IF NOT EXISTS idx_prata_municipios_geom
    ON prata.ref__municipios USING GIST (geom);

-- -----------------------------------------------------------------------------
-- Carga: malha municipal do IBGE enriquecida com o módulo fiscal do Incra.
--
-- ATENÇÃO (T-02): as chaves JSONB abaixo cobrem as grafias mais comuns das
-- fontes. Confira contra o arquivo real e REMOVA os COALESCE que não se
-- aplicam — COALESCE defensivo é útil na primeira carga e perigoso depois,
-- porque esconde mudança de schema na fonte.
-- -----------------------------------------------------------------------------
WITH municipios AS (
    SELECT
        COALESCE(
            atributos->>'CD_MUN',
            atributos->>'cd_mun',
            atributos->>'CD_GEOCMU',
            atributos->>'cod_ibge'
        )                                           AS cod_ibge,
        COALESCE(
            atributos->>'NM_MUN',
            atributos->>'nm_mun',
            atributos->>'nome'
        )                                           AS nome,
        COALESCE(
            atributos->>'SIGLA_UF',
            atributos->>'sigla_uf',
            atributos->>'uf'
        )                                           AS uf,
        ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)) AS geom
    FROM bronze.ibge__municipios
    WHERE geom IS NOT NULL
),
modulos AS (
    SELECT
        COALESCE(
            atributos->>'cod_ibge',
            atributos->>'CD_MUN',
            atributos->>'codigo_municipio'
        )                                           AS cod_ibge,
        NULLIF(
            replace(
                COALESCE(
                    atributos->>'modulo_fiscal',
                    atributos->>'MODULO_FISCAL',
                    atributos->>'modulo_fiscal_ha'
                ),
                ',', '.'
            ),
            ''
        )::NUMERIC                                  AS modulo_fiscal_ha
    FROM bronze.incra__modulo_fiscal
)
INSERT INTO prata.ref__municipios AS destino (
    cod_ibge, nome, uf, modulo_fiscal_ha, geom, _processamento_id
)
SELECT
    m.cod_ibge,
    m.nome,
    m.uf,
    mf.modulo_fiscal_ha,
    m.geom,
    gen_random_uuid()
FROM municipios m
LEFT JOIN modulos mf USING (cod_ibge)
WHERE m.cod_ibge IS NOT NULL
ON CONFLICT (cod_ibge) DO UPDATE SET
    nome                     = EXCLUDED.nome,
    uf                       = EXCLUDED.uf,
    modulo_fiscal_ha         = COALESCE(EXCLUDED.modulo_fiscal_ha,
                                        destino.modulo_fiscal_ha),
    geom                     = EXCLUDED.geom,
    _processamento_id        = EXCLUDED._processamento_id,
    _processamento_timestamp = NOW();

-- =============================================================================
-- Camadas de restrição territorial, saneadas e com área calculada
-- =============================================================================
CREATE TABLE IF NOT EXISTS prata.ref__restricoes (
    id                      BIGSERIAL   PRIMARY KEY,
    fonte                   TEXT        NOT NULL,
    categoria               TEXT        NOT NULL,
    nome                    TEXT,
    geom                    GEOMETRY(MultiPolygon, 4674) NOT NULL,
    area_ha                 NUMERIC(14,4),
    _hash_linha             TEXT        NOT NULL,
    _processamento_id       UUID        NOT NULL,
    _processamento_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (fonte, _hash_linha)
);

CREATE INDEX IF NOT EXISTS idx_prata_restricoes_geom
    ON prata.ref__restricoes USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_prata_restricoes_cat
    ON prata.ref__restricoes (categoria);

INSERT INTO prata.ref__restricoes (
    fonte, categoria, nome, geom, area_ha, _hash_linha, _processamento_id
)
SELECT
    r.fonte,
    r.categoria,
    r.nome,
    ST_Multi(ST_CollectionExtract(ST_MakeValid(r.geom), 3))      AS geom,
    ST_Area(ST_MakeValid(r.geom)::geography) / 10000.0           AS area_ha,
    r._hash_linha,
    gen_random_uuid()
FROM bronze.restricoes__areas r
WHERE r.geom IS NOT NULL
  AND NOT ST_IsEmpty(ST_MakeValid(r.geom))
ON CONFLICT (fonte, _hash_linha) DO UPDATE SET
    categoria                = EXCLUDED.categoria,
    nome                     = EXCLUDED.nome,
    geom                     = EXCLUDED.geom,
    area_ha                  = EXCLUDED.area_ha,
    _processamento_timestamp = NOW();
