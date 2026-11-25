-- =============================================================================
-- sql/ouro/02_gargalos.sql
--
-- Camada OURO — linha do tempo de gargalos do ciclo de vida.
--
-- Responde a pergunta de negócio do gestor do Sicar: onde a regularização
-- está travando, em que etapa, em que lugar, e há quanto tempo.
--
-- Esta é a lacuna que o briefing do Desafio 3 nomeia e que a plataforma
-- pública de consulta não cobre.
-- =============================================================================

SET search_path TO ouro, prata, public;

CREATE TABLE IF NOT EXISTS ouro.car__gargalos_etapa (
    id                      BIGSERIAL   PRIMARY KEY,
    data_referencia         DATE        NOT NULL,
    uf                      CHAR(2)     NOT NULL,
    cod_municipio           CHAR(7),
    etapa                   TEXT        NOT NULL,
    faixa_tamanho           TEXT        NOT NULL,

    imoveis_na_etapa        BIGINT      NOT NULL,
    area_na_etapa_ha        NUMERIC(16,2),
    dias_mediano_na_etapa   NUMERIC(10,1),
    dias_p90_na_etapa       NUMERIC(10,1),

    -- Transparência de qualidade: que fração dos imóveis desta linha tem
    -- marco temporal de verdade. Sem isso, a mediana engana.
    pct_com_data_confiavel  NUMERIC(5,2),

    _execucao_id            UUID        NOT NULL,
    _criado_em              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (data_referencia, uf, cod_municipio, etapa, faixa_tamanho)
);

COMMENT ON COLUMN ouro.car__gargalos_etapa.faixa_tamanho IS
    'Faixa de módulos fiscais. A política trata até 4 módulos de forma '
    'diferenciada, então o agregado tem que separar por faixa ou esconde o '
    'problema do pequeno produtor dentro da média.';
COMMENT ON COLUMN ouro.car__gargalos_etapa.pct_com_data_confiavel IS
    'Percentual das linhas cuja etapa tem origem fonte_direta. Abaixo de ~50% '
    'a mediana de dias deve ser exibida como estimativa frágil.';

CREATE INDEX IF NOT EXISTS idx_ouro_gargalos_etapa
    ON ouro.car__gargalos_etapa (data_referencia, uf, etapa);

-- -----------------------------------------------------------------------------
-- Carga idempotente: delete+insert escopado na data de referência
-- -----------------------------------------------------------------------------
DELETE FROM ouro.car__gargalos_etapa
WHERE data_referencia = %(data_referencia)s;

INSERT INTO ouro.car__gargalos_etapa (
    data_referencia, uf, cod_municipio, etapa, faixa_tamanho,
    imoveis_na_etapa, area_na_etapa_ha,
    dias_mediano_na_etapa, dias_p90_na_etapa,
    pct_com_data_confiavel, _execucao_id
)
SELECT
    %(data_referencia)s::DATE                               AS data_referencia,
    i.uf,
    i.cod_municipio,
    e.etapa,
    CASE
        WHEN i.modulos_fiscais IS NULL       THEN 'indefinido'
        WHEN i.modulos_fiscais <= 1          THEN 'ate_1_modulo'
        WHEN i.modulos_fiscais <= 4          THEN 'de_1_a_4_modulos'
        WHEN i.modulos_fiscais <= 15         THEN 'de_4_a_15_modulos'
        ELSE 'acima_de_15_modulos'
    END                                                     AS faixa_tamanho,
    COUNT(*)                                                AS imoveis_na_etapa,
    SUM(i.area_calculada_ha)                                AS area_na_etapa_ha,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY (%(data_referencia)s::DATE - e.entrou_em)
    ) FILTER (WHERE e.entrou_em IS NOT NULL)                AS dias_mediano,
    PERCENTILE_CONT(0.9) WITHIN GROUP (
        ORDER BY (%(data_referencia)s::DATE - e.entrou_em)
    ) FILTER (WHERE e.entrou_em IS NOT NULL)                AS dias_p90,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE e.origem = 'fonte_direta')
        / NULLIF(COUNT(*), 0),
        2
    )                                                       AS pct_confiavel,
    %(execucao_id)s::UUID
FROM prata.car__imoveis i
JOIN prata.car__eventos_ciclo_vida e ON e.cod_imovel = i.cod_imovel
WHERE e.saiu_em IS NULL          -- etapa ainda aberta = onde o imóvel está parado
GROUP BY i.uf, i.cod_municipio, e.etapa, 5;
