-- =============================================================================
-- d4_geometria_improvavel.sql — versão 1.0.0
--
-- Hipótese: a geometria declarada carrega assinatura de erro de desenho, não
-- de realidade fundiária. Três ramos independentes:
--
--   (a) compacidade fora da distribuição — polígono filamentar
--   (b) área declarada divergindo da área calculada
--   (c) polígono com mesma área e mesmo perímetro de outro no município, sem
--       interseção: assinatura de "mesmo desenho reaproveitado e deslocado"
--
-- O ramo (c) é o mais interessante e o menos óbvio: quem redesenha um imóvel
-- a partir de outro produz dois polígonos geometricamente idênticos em
-- lugares diferentes, o que não acontece por acidente na natureza.
--
-- Parâmetros: compacidade_min, divergencia_area_declarada_pct,
--             tolerancia_deslocamento_m, confianca, execucao_id
-- =============================================================================

WITH ramo_compacidade AS (
    SELECT
        i.cod_imovel, i.uf, i.cod_municipio,
        'compacidade'::TEXT                                 AS ramo,
        jsonb_build_object(
            'compacidade',        ROUND(i.compacidade, 6),
            'area_calculada_ha',  ROUND(i.area_calculada_ha, 2),
            'perimetro_m',        ROUND(i.perimetro_m, 1),
            'geometria_era_invalida', i.geom_era_invalida,
            'interpretacao', 'Polígono anormalmente filamentar para a área '
                || 'que declara; típico de traçado manual impreciso.'
        )                                                   AS evidencia,
        i.geom
    FROM prata.car__imoveis i
    WHERE i.compacidade IS NOT NULL
      AND i.compacidade < %(compacidade_min)s
),
ramo_divergencia AS (
    SELECT
        i.cod_imovel, i.uf, i.cod_municipio,
        'divergencia_area'::TEXT                            AS ramo,
        jsonb_build_object(
            'area_declarada_ha',  ROUND(i.area_declarada_ha, 2),
            'area_calculada_ha',  ROUND(i.area_calculada_ha, 2),
            'divergencia_pct',    ROUND(i.divergencia_area_pct, 2),
            'interpretacao', 'A área declarada no cadastro não corresponde à '
                || 'área do polígono desenhado.'
        )                                                   AS evidencia,
        i.geom
    FROM prata.car__imoveis i
    WHERE i.divergencia_area_pct IS NOT NULL
      AND i.divergencia_area_pct > %(divergencia_area_declarada_pct)s
),
ramo_duplicado_deslocado AS (
    SELECT
        a.cod_imovel, a.uf, a.cod_municipio,
        'duplicado_deslocado'::TEXT                         AS ramo,
        jsonb_build_object(
            'gemeo',              b.cod_imovel,
            'area_ha',            ROUND(a.area_calculada_ha, 2),
            'perimetro_m',        ROUND(a.perimetro_m, 1),
            'distancia_entre_m',  ROUND(ST_Distance(
                                      a.geom::geography, b.geom::geography), 1),
            'interpretacao', 'Mesma área e mesmo perímetro de outro imóvel do '
                || 'município, sem interseção: assinatura de desenho '
                || 'reaproveitado.'
        )                                                   AS evidencia,
        a.geom
    FROM prata.car__imoveis a
    JOIN prata.car__imoveis b
      ON a.cod_municipio = b.cod_municipio
     AND a.cod_imovel <> b.cod_imovel
     AND ROUND(a.area_calculada_ha, 2) = ROUND(b.area_calculada_ha, 2)
     AND ROUND(a.perimetro_m, 0)       = ROUND(b.perimetro_m, 0)
     AND NOT ST_Intersects(a.geom, b.geom)
    WHERE a.area_calculada_ha > 0
      AND ST_Distance(a.geom::geography, b.geom::geography)
          > %(tolerancia_deslocamento_m)s
),
unificado AS (
    SELECT * FROM ramo_compacidade
    UNION ALL SELECT * FROM ramo_divergencia
    UNION ALL SELECT * FROM ramo_duplicado_deslocado
)
INSERT INTO ouro.car__sinais_anomalia (
    detector, versao_detector,
    cod_imovel, uf, cod_municipio,
    confianca, regra_aplicada, limiares, evidencia,
    geom_evidencia, _hash_evidencia, _execucao_id
)
SELECT
    'd4_geometria_improvavel',
    '1.0.0',
    u.cod_imovel,
    u.uf,
    u.cod_municipio,
    %(confianca)s::NUMERIC,
    'Geometria com assinatura de erro de desenho — ramo: ' || u.ramo,
    jsonb_build_object(
        'compacidade_min',                %(compacidade_min)s,
        'divergencia_area_declarada_pct', %(divergencia_area_declarada_pct)s,
        'tolerancia_deslocamento_m',      %(tolerancia_deslocamento_m)s,
        'ramo_acionado',                  u.ramo
    ),
    u.evidencia,
    u.geom,
    encode(digest(u.cod_imovel || u.ramo || u.evidencia::TEXT, 'sha256'), 'hex'),
    %(execucao_id)s::UUID
FROM unificado u
ON CONFLICT (detector, cod_imovel, _hash_evidencia) DO NOTHING;
