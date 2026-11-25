-- =============================================================================
-- d2_incidencia_area_protegida.sql — versão 1.0.0
--
-- Hipótese: imóvel declarado com sobreposição relevante a área embargada,
-- unidade de conservação, terra indígena, território quilombola ou floresta
-- pública.
--
-- Este é o detector de maior precisão esperada, porque o cruzamento é
-- geométrico e as camadas de restrição são oficiais. A ressalva honesta: as
-- camadas de restrição têm escalas de mapeamento diferentes, e discrepância
-- de borda produz sobreposição falsa — por isso há limiar mínimo em hectares
-- além do percentual.
--
-- Parâmetros: percentual_sobreposicao_min, area_sobreposta_min_ha,
--             confianca, execucao_id
-- =============================================================================

WITH sobreposicoes AS (
    SELECT
        i.cod_imovel,
        i.uf,
        i.cod_municipio,
        i.area_calculada_ha,
        r.categoria,
        r.nome                                              AS nome_restricao,
        r.fonte,
        ST_Area(
            ST_Intersection(i.geom, r.geom)::geography
        ) / 10000.0                                         AS area_sobreposta_ha,
        ST_Multi(ST_CollectionExtract(
            ST_Intersection(i.geom, r.geom), 3
        ))                                                  AS geom_sobreposicao
    FROM prata.car__imoveis i
    JOIN prata.ref__restricoes r
      ON ST_Intersects(i.geom, r.geom)
    WHERE i.geom IS NOT NULL
),
agregado AS (
    SELECT
        cod_imovel,
        uf,
        cod_municipio,
        area_calculada_ha,
        categoria,
        SUM(area_sobreposta_ha)                             AS area_sobreposta_ha,
        100.0 * SUM(area_sobreposta_ha)
            / NULLIF(area_calculada_ha, 0)                  AS pct_sobreposto,
        jsonb_agg(DISTINCT jsonb_build_object(
            'nome',  nome_restricao,
            'fonte', fonte
        ))                                                  AS restricoes,
        ST_Multi(ST_Union(geom_sobreposicao))               AS geom_sobreposicao
    FROM sobreposicoes
    GROUP BY cod_imovel, uf, cod_municipio, area_calculada_ha, categoria
)
INSERT INTO ouro.car__sinais_anomalia (
    detector, versao_detector,
    cod_imovel, uf, cod_municipio,
    confianca, regra_aplicada, limiares, evidencia,
    geom_evidencia, _hash_evidencia, _execucao_id
)
SELECT
    'd2_incidencia_area_protegida',
    '1.0.0',
    a.cod_imovel,
    a.uf,
    a.cod_municipio,
    %(confianca)s::NUMERIC,
    'Sobreposição de ' || ROUND(a.pct_sobreposto, 1) || '% da área do imóvel ('
        || ROUND(a.area_sobreposta_ha, 2) || ' ha) com categoria '
        || a.categoria,
    jsonb_build_object(
        'percentual_sobreposicao_min', %(percentual_sobreposicao_min)s,
        'area_sobreposta_min_ha',      %(area_sobreposta_min_ha)s
    ),
    jsonb_build_object(
        'categoria',            a.categoria,
        'area_imovel_ha',       ROUND(a.area_calculada_ha, 2),
        'area_sobreposta_ha',   ROUND(a.area_sobreposta_ha, 2),
        'percentual_sobreposto', ROUND(a.pct_sobreposto, 2),
        'restricoes_incidentes', a.restricoes,
        'ressalva_tecnica', 'Camadas de restrição têm escalas de mapeamento '
            || 'distintas; sobreposição de borda pode ser artefato cartográfico.'
    ),
    a.geom_sobreposicao,
    encode(digest(
        a.cod_imovel || a.categoria || ROUND(a.area_sobreposta_ha, 2)::TEXT,
        'sha256'
    ), 'hex'),
    %(execucao_id)s::UUID
FROM agregado a
WHERE a.pct_sobreposto     >= %(percentual_sobreposicao_min)s
  AND a.area_sobreposta_ha >= %(area_sobreposta_min_ha)s
ON CONFLICT (detector, cod_imovel, _hash_evidencia) DO NOTHING;
