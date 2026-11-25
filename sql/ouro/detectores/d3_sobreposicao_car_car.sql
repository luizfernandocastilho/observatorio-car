-- =============================================================================
-- d3_sobreposicao_car_car.sql — versão 1.0.0
--
-- Hipótese: dois ou mais imóveis declarando a mesma área.
--
-- Causas prováveis, em ordem de frequência observada na literatura do CAR:
-- erro de digitalização do perímetro, divisa declarada em duplicidade por
-- vizinhos, desmembramento não refletido no cadastro, e conflito de posse
-- real. O detector NÃO distingue entre elas — classificar a causa é o
-- Desafio 1 (conciliação territorial), não este.
--
-- Cuidado de implementação: o self-join espacial é a consulta mais cara do
-- pipeline. O filtro a.cod_imovel < b.cod_imovel evita contar cada par duas
-- vezes, e o índice GIST em (uf, geom) é o que torna isso viável.
--
-- Parâmetros: percentual_sobreposicao_min, area_sobreposta_min_ha,
--             confianca, execucao_id
-- =============================================================================

WITH pares AS (
    SELECT
        a.cod_imovel                                        AS cod_a,
        b.cod_imovel                                        AS cod_b,
        a.uf,
        a.cod_municipio,
        a.area_calculada_ha                                 AS area_a_ha,
        b.area_calculada_ha                                 AS area_b_ha,
        ST_Area(
            ST_Intersection(a.geom, b.geom)::geography
        ) / 10000.0                                         AS area_sobreposta_ha,
        ST_Multi(ST_CollectionExtract(
            ST_Intersection(a.geom, b.geom), 3
        ))                                                  AS geom_sobreposicao
    FROM prata.car__imoveis a
    JOIN prata.car__imoveis b
      ON a.uf = b.uf
     AND a.cod_imovel < b.cod_imovel
     AND ST_Intersects(a.geom, b.geom)
    WHERE a.geom IS NOT NULL
      AND b.geom IS NOT NULL
),
qualificados AS (
    SELECT
        p.*,
        gen_random_uuid()                                   AS grupo_id,
        100.0 * p.area_sobreposta_ha
            / NULLIF(LEAST(p.area_a_ha, p.area_b_ha), 0)    AS pct_do_menor
    FROM pares p
    WHERE p.area_sobreposta_ha >= %(area_sobreposta_min_ha)s
      AND 100.0 * p.area_sobreposta_ha
          / NULLIF(LEAST(p.area_a_ha, p.area_b_ha), 0)
          >= %(percentual_sobreposicao_min)s
)
INSERT INTO ouro.car__sinais_anomalia (
    detector, versao_detector, grupo_id,
    cod_imovel, uf, cod_municipio,
    confianca, regra_aplicada, limiares, evidencia,
    geom_evidencia, _hash_evidencia, _execucao_id
)
-- Um sinal para cada lado do par, compartilhando grupo_id: o analista precisa
-- ver o caso ao abrir qualquer um dos dois imóveis.
SELECT
    'd3_sobreposicao_car_car',
    '1.0.0',
    q.grupo_id,
    lado.cod_imovel,
    q.uf,
    q.cod_municipio,
    %(confianca)s::NUMERIC,
    'Sobreposição de ' || ROUND(q.area_sobreposta_ha, 2) || ' ha com o imóvel '
        || lado.cod_contraparte || ' (' || ROUND(q.pct_do_menor, 1)
        || '% do menor dos dois)',
    jsonb_build_object(
        'percentual_sobreposicao_min', %(percentual_sobreposicao_min)s,
        'area_sobreposta_min_ha',      %(area_sobreposta_min_ha)s
    ),
    jsonb_build_object(
        'contraparte',          lado.cod_contraparte,
        'area_imovel_ha',       ROUND(lado.area_propria, 2),
        'area_contraparte_ha',  ROUND(lado.area_contraparte, 2),
        'area_sobreposta_ha',   ROUND(q.area_sobreposta_ha, 2),
        'pct_do_menor',         ROUND(q.pct_do_menor, 2),
        'causas_possiveis', to_jsonb(ARRAY[
            'erro de digitalização do perímetro',
            'divisa declarada em duplicidade pelos vizinhos',
            'desmembramento não refletido no cadastro',
            'conflito de posse real'
        ])
    ),
    q.geom_sobreposicao,
    encode(digest(q.cod_a || q.cod_b || ROUND(q.area_sobreposta_ha, 2)::TEXT
                  || lado.cod_imovel, 'sha256'), 'hex'),
    %(execucao_id)s::UUID
FROM qualificados q
CROSS JOIN LATERAL (
    VALUES
        (q.cod_a, q.cod_b, q.area_a_ha, q.area_b_ha),
        (q.cod_b, q.cod_a, q.area_b_ha, q.area_a_ha)
) AS lado(cod_imovel, cod_contraparte, area_propria, area_contraparte)
ON CONFLICT (detector, cod_imovel, _hash_evidencia) DO NOTHING;
