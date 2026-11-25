-- =============================================================================
-- d1_fatiamento.sql — versão 1.0.0
--
-- Hipótese: conjuntos de imóveis contíguos, todos imediatamente abaixo do
-- limite de 4 módulos fiscais, inscritos em janela curta de tempo, podem
-- indicar desmembramento para acessar tratamento diferenciado.
--
-- Hipótese alternativa igualmente provável: partilha familiar, herança,
-- assentamento, ou simples adensamento de minifúndios numa região. Por isso
-- isto é um SINAL PARA TRIAGEM e a evidência inclui tudo o que o analista
-- precisa para descartar o caso em trinta segundos.
--
-- Clusterização em EPSG:5880 (SIRGAS 2000 / Polycônica do Brasil) porque o
-- eps do DBSCAN precisa estar em metros; em 4674 estaria em graus.
--
-- Parâmetros: faixa_inferior_modulos, faixa_superior_modulos,
--             min_imoveis_cluster, janela_dias_inscricao,
--             distancia_contiguidade_m, confianca, execucao_id
-- =============================================================================

WITH candidatos AS (
    SELECT
        i.cod_imovel,
        i.uf,
        i.cod_municipio,
        i.modulos_fiscais,
        i.area_calculada_ha,
        i.data_inscricao,
        i.geom,
        -- Argumentos posicionais obrigatoriamente: o PostgreSQL não aceita
        -- notação nomeada em chamada de função de janela. A ordem é
        -- (geometria, eps em metros, mínimo de pontos).
        ST_ClusterDBSCAN(
            ST_Transform(i.geom, 5880),
            %(distancia_contiguidade_m)s::float8,
            %(min_imoveis_cluster)s::int
        ) OVER (PARTITION BY i.cod_municipio) AS cluster_local
    FROM prata.car__imoveis i
    WHERE i.modulos_fiscais BETWEEN %(faixa_inferior_modulos)s
                                AND %(faixa_superior_modulos)s
      AND i.geom IS NOT NULL
),
clusters AS (
    SELECT
        cod_municipio,
        cluster_local,
        MIN(uf)                                     AS uf,
        COUNT(*)                                    AS qtd_imoveis,
        SUM(area_calculada_ha)                      AS area_total_ha,
        AVG(modulos_fiscais)                        AS modulos_medio,
        MIN(data_inscricao)                         AS primeira_inscricao,
        MAX(data_inscricao)                         AS ultima_inscricao,
        MAX(data_inscricao) - MIN(data_inscricao)   AS span_dias,
        array_agg(cod_imovel ORDER BY cod_imovel)   AS imoveis,
        ST_Multi(ST_Union(geom))                    AS geom_cluster
    FROM candidatos
    WHERE cluster_local IS NOT NULL
    GROUP BY cod_municipio, cluster_local
),
qualificados AS (
    SELECT
        c.*,
        gen_random_uuid() AS grupo_id,
        -- Área total do cluster convertida em módulos do próprio município:
        -- é o número que mostra se o conjunto, somado, passaria do limite.
        CASE WHEN m.modulo_fiscal_ha > 0
             THEN c.area_total_ha / m.modulo_fiscal_ha END AS modulos_do_cluster,
        m.modulo_fiscal_ha,
        m.nome                                             AS nome_municipio
    FROM clusters c
    LEFT JOIN prata.ref__municipios m ON m.cod_ibge = c.cod_municipio
    WHERE c.qtd_imoveis >= %(min_imoveis_cluster)s
      AND (
            c.span_dias IS NULL
            OR c.span_dias <= %(janela_dias_inscricao)s
          )
)
INSERT INTO ouro.car__sinais_anomalia (
    detector, versao_detector, grupo_id,
    cod_imovel, uf, cod_municipio,
    confianca, regra_aplicada, limiares, evidencia,
    geom_evidencia, _hash_evidencia, _execucao_id
)
SELECT
    'd1_fatiamento',
    '1.0.0',
    q.grupo_id,
    imovel.cod_imovel,
    q.uf,
    q.cod_municipio,
    %(confianca)s::NUMERIC,
    'Imóvel pertence a cluster de ' || q.qtd_imoveis || ' imóveis contíguos '
        || 'na faixa de ' || %(faixa_inferior_modulos)s || ' a '
        || %(faixa_superior_modulos)s || ' módulos fiscais, inscritos em '
        || COALESCE(q.span_dias::TEXT, 'data desconhecida') || ' dias',
    jsonb_build_object(
        'faixa_inferior_modulos',   %(faixa_inferior_modulos)s,
        'faixa_superior_modulos',   %(faixa_superior_modulos)s,
        'min_imoveis_cluster',      %(min_imoveis_cluster)s,
        'janela_dias_inscricao',    %(janela_dias_inscricao)s,
        'distancia_contiguidade_m', %(distancia_contiguidade_m)s
    ),
    jsonb_build_object(
        'municipio',             q.nome_municipio,
        'modulo_fiscal_ha',      q.modulo_fiscal_ha,
        'qtd_imoveis_cluster',   q.qtd_imoveis,
        'area_total_cluster_ha', ROUND(q.area_total_ha, 2),
        'modulos_do_cluster',    ROUND(q.modulos_do_cluster, 2),
        'modulos_medio_imovel',  ROUND(q.modulos_medio, 2),
        'primeira_inscricao',    q.primeira_inscricao,
        'ultima_inscricao',      q.ultima_inscricao,
        'span_dias',             q.span_dias,
        'imoveis_do_cluster',    to_jsonb(q.imoveis),
        'hipoteses_alternativas', to_jsonb(ARRAY[
            'partilha familiar ou herança',
            'assentamento ou projeto de reforma agrária',
            'adensamento histórico de minifúndios na região'
        ])
    ),
    q.geom_cluster,
    encode(digest(q.grupo_id::TEXT || imovel.cod_imovel, 'sha256'), 'hex'),
    %(execucao_id)s::UUID
FROM qualificados q
CROSS JOIN LATERAL unnest(q.imoveis) AS imovel(cod_imovel)
ON CONFLICT (detector, cod_imovel, _hash_evidencia) DO NOTHING;
