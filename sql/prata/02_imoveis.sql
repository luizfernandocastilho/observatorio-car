-- =============================================================================
-- sql/prata/02_imoveis.sql
--
-- Camada PRATA — imóveis do CAR tipados, saneados e deduplicados.
--
-- Esta é a tabela central do observatório. Três coisas acontecem aqui, e a
-- ordem importa:
--
--   1. Mapeamento JSONB -> colunas tipadas (falha visível se a fonte mudar)
--   2. Saneamento geométrico: sem ST_MakeValid, todo cruzamento espacial
--      posterior estoura ou devolve resultado errado em silêncio. Dados do
--      CAR trazem autointerseções e anéis duplicados com frequência.
--   3. Métricas derivadas: área calculada, módulos fiscais e compacidade,
--      que os detectores consomem sem recalcular.
--
-- Dedup: o mesmo cod_imovel pode vir em cargas de municípios diferentes ou em
-- versões distintas. Mantemos a linha de ingestão mais recente.
-- =============================================================================

SET search_path TO prata, bronze, public;

CREATE TABLE IF NOT EXISTS prata.car__imoveis (
    cod_imovel              TEXT        PRIMARY KEY,
    uf                      CHAR(2)     NOT NULL,
    cod_municipio           CHAR(7),
    nome_municipio          TEXT,

    -- Declarado pela fonte
    area_declarada_ha       NUMERIC(14,4),
    tipo_imovel             TEXT,
    condicao_cadastro       TEXT,
    status_cadastro         TEXT,
    data_inscricao          DATE,
    data_ultima_retificacao DATE,

    -- Derivado no saneamento
    geom                    GEOMETRY(MultiPolygon, 4674),
    geom_era_invalida       BOOLEAN     NOT NULL DEFAULT FALSE,
    area_calculada_ha       NUMERIC(14,4),
    perimetro_m             NUMERIC(14,2),
    compacidade             NUMERIC(8,6),
    modulos_fiscais         NUMERIC(10,4),
    divergencia_area_pct    NUMERIC(8,2),

    -- Controle
    _hash_linha             TEXT        NOT NULL,
    _processamento_id       UUID        NOT NULL,
    _processamento_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _versao_registro        INT         NOT NULL DEFAULT 1,
    _valido_de              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    _valido_ate             TIMESTAMPTZ
);

COMMENT ON TABLE prata.car__imoveis IS
    'Imóveis do CAR tipados e com geometria saneada. Tabela central do '
    'observatório: todos os detectores leem daqui.';
COMMENT ON COLUMN prata.car__imoveis.geom_era_invalida IS
    'TRUE quando ST_IsValid falhou no dado bruto e a geometria foi corrigida. '
    'Não é anomalia por si — é metadado de qualidade que entra no detector d4.';
COMMENT ON COLUMN prata.car__imoveis.compacidade IS
    'Índice de Polsby-Popper: 4*pi*area/perimetro^2. Vale 1 no círculo e '
    'tende a 0 em polígonos filamentares, típicos de erro de digitalização.';
COMMENT ON COLUMN prata.car__imoveis.divergencia_area_pct IS
    'Diferença percentual entre a área declarada pelo proprietário e a área '
    'calculada da geometria. Divergência alta é sinal de erro de desenho.';

CREATE INDEX IF NOT EXISTS idx_prata_imoveis_geom
    ON prata.car__imoveis USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_prata_imoveis_uf_geom
    ON prata.car__imoveis USING GIST (uf, geom);
CREATE INDEX IF NOT EXISTS idx_prata_imoveis_municipio
    ON prata.car__imoveis (cod_municipio);
CREATE INDEX IF NOT EXISTS idx_prata_imoveis_modulos
    ON prata.car__imoveis (cod_municipio, modulos_fiscais);
CREATE INDEX IF NOT EXISTS idx_prata_imoveis_inscricao
    ON prata.car__imoveis (data_inscricao);

-- -----------------------------------------------------------------------------
-- Transformação
--
-- ATENÇÃO (T-02): confira os nomes de atributo contra o shapefile real antes
-- de rodar em produção. O bloco `extraido` é o único lugar do projeto que
-- conhece a grafia da fonte — mantenha assim.
-- -----------------------------------------------------------------------------
WITH extraido AS (
    SELECT
        b.uf,
        COALESCE(
            b.atributos->>'cod_imovel',
            b.atributos->>'COD_IMOVEL',
            b.atributos->>'codigo'
        )                                                   AS cod_imovel,
        COALESCE(
            b.atributos->>'cod_municipio',
            b.atributos->>'COD_MUNICIPIO',
            b.atributos->>'cd_mun'
        )                                                   AS cod_municipio,
        COALESCE(
            b.atributos->>'nom_munici',
            b.atributos->>'NOM_MUNICI',
            b.atributos->>'municipio'
        )                                                   AS nome_municipio,
        NULLIF(replace(COALESCE(
            b.atributos->>'num_area',
            b.atributos->>'NUM_AREA',
            b.atributos->>'area_ha'
        ), ',', '.'), '')::NUMERIC                          AS area_declarada_ha,
        COALESCE(
            b.atributos->>'ind_tipo',
            b.atributos->>'IND_TIPO',
            b.atributos->>'tipo_imovel'
        )                                                   AS tipo_imovel,
        COALESCE(
            b.atributos->>'des_condic',
            b.atributos->>'DES_CONDIC',
            b.atributos->>'condicao'
        )                                                   AS condicao_cadastro,
        COALESCE(
            b.atributos->>'ind_status',
            b.atributos->>'IND_STATUS',
            b.atributos->>'status'
        )                                                   AS status_cadastro,
        -- Datas: a fonte pública pode não trazer marco temporal. Quando não
        -- vier, fica NULL e a linha do tempo usa o Painel da Regularização.
        NULLIF(COALESCE(
            b.atributos->>'dat_criacao',
            b.atributos->>'DAT_CRIACAO',
            b.atributos->>'data_inscricao'
        ), '')::DATE                                        AS data_inscricao,
        NULLIF(COALESCE(
            b.atributos->>'dat_atualiz',
            b.atributos->>'DAT_ATUALIZ',
            b.atributos->>'data_retificacao'
        ), '')::DATE                                        AS data_ultima_retificacao,
        NOT ST_IsValid(b.geom)                              AS geom_era_invalida,
        ST_Multi(ST_CollectionExtract(
            ST_MakeValid(ST_RemoveRepeatedPoints(b.geom, 0.00001)), 3
        ))                                                  AS geom,
        b._hash_linha,
        b._ingestao_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY COALESCE(
                b.atributos->>'cod_imovel',
                b.atributos->>'COD_IMOVEL',
                b.atributos->>'codigo'
            )
            ORDER BY b._ingestao_timestamp DESC, b.id DESC
        )                                                   AS rn
    FROM bronze.sicar__area_imovel b
    WHERE b.geom IS NOT NULL
),
calculado AS (
    SELECT
        e.*,
        ST_Area(e.geom::geography) / 10000.0                AS area_calculada_ha,
        ST_Perimeter(e.geom::geography)                     AS perimetro_m
    FROM extraido e
    WHERE e.rn = 1
      AND e.cod_imovel IS NOT NULL
      AND NOT ST_IsEmpty(e.geom)
)
INSERT INTO prata.car__imoveis AS destino (
    cod_imovel, uf, cod_municipio, nome_municipio,
    area_declarada_ha, tipo_imovel, condicao_cadastro, status_cadastro,
    data_inscricao, data_ultima_retificacao,
    geom, geom_era_invalida, area_calculada_ha, perimetro_m,
    compacidade, modulos_fiscais, divergencia_area_pct,
    _hash_linha, _processamento_id
)
SELECT
    c.cod_imovel,
    c.uf,
    c.cod_municipio,
    c.nome_municipio,
    c.area_declarada_ha,
    c.tipo_imovel,
    c.condicao_cadastro,
    c.status_cadastro,
    c.data_inscricao,
    c.data_ultima_retificacao,
    c.geom,
    c.geom_era_invalida,
    c.area_calculada_ha,
    c.perimetro_m,
    CASE
        WHEN c.perimetro_m > 0
        THEN (4 * pi() * (c.area_calculada_ha * 10000.0))
             / (c.perimetro_m * c.perimetro_m)
    END                                                     AS compacidade,
    CASE
        WHEN mun.modulo_fiscal_ha > 0
        THEN c.area_calculada_ha / mun.modulo_fiscal_ha
    END                                                     AS modulos_fiscais,
    CASE
        WHEN c.area_declarada_ha > 0
        THEN abs(c.area_calculada_ha - c.area_declarada_ha)
             / c.area_declarada_ha * 100.0
    END                                                     AS divergencia_area_pct,
    c._hash_linha,
    gen_random_uuid()
FROM calculado c
LEFT JOIN prata.ref__municipios mun
       ON mun.cod_ibge = c.cod_municipio
ON CONFLICT (cod_imovel) DO UPDATE SET
    uf                       = EXCLUDED.uf,
    cod_municipio            = EXCLUDED.cod_municipio,
    nome_municipio           = EXCLUDED.nome_municipio,
    area_declarada_ha        = EXCLUDED.area_declarada_ha,
    tipo_imovel              = EXCLUDED.tipo_imovel,
    condicao_cadastro        = EXCLUDED.condicao_cadastro,
    status_cadastro          = EXCLUDED.status_cadastro,
    data_inscricao           = EXCLUDED.data_inscricao,
    data_ultima_retificacao  = EXCLUDED.data_ultima_retificacao,
    geom                     = EXCLUDED.geom,
    geom_era_invalida        = EXCLUDED.geom_era_invalida,
    area_calculada_ha        = EXCLUDED.area_calculada_ha,
    perimetro_m              = EXCLUDED.perimetro_m,
    compacidade              = EXCLUDED.compacidade,
    modulos_fiscais          = EXCLUDED.modulos_fiscais,
    divergencia_area_pct     = EXCLUDED.divergencia_area_pct,
    _hash_linha              = EXCLUDED._hash_linha,
    _processamento_id        = EXCLUDED._processamento_id,
    _processamento_timestamp = NOW(),
    _versao_registro         = destino._versao_registro + 1
WHERE destino._hash_linha <> EXCLUDED._hash_linha;
