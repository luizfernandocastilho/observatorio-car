-- =============================================================================
-- d5_padrao_cadastral_atipico.sql — versão 1.0.0
--
-- Hipótese: lotes de cadastros feitos em bloco, com assinatura comum, em
-- volume fora da distribuição do próprio município.
--
-- NOTA DE PRIVACIDADE, importante: a versão original desta ideia agrupava por
-- responsável técnico. O dado público do CAR não expõe esse campo, e não
-- deveria — é dado pessoal. Este detector usa apenas a assinatura observável
-- no dado aberto: data de inscrição, município e área arredondada. Nenhum
-- dado pessoal entra no agrupamento nem na evidência.
--
-- O z-score é calculado contra a própria distribuição diária do município:
-- um município que cadastra 300 imóveis por dia não é anômalo por isso, mas
-- um que cadastra 4 por dia e de repente cadastra 80 iguais, é.
--
-- Parâmetros: z_score_min, min_cadastros_grupo, confianca, execucao_id
-- =============================================================================

WITH grupos AS (
    SELECT
        i.cod_municipio,
        MIN(i.uf)                                           AS uf,
        i.data_inscricao,
        ROUND(i.area_calculada_ha, 1)                       AS area_arredondada,
        COUNT(*)                                            AS qtd,
        array_agg(i.cod_imovel ORDER BY i.cod_imovel)       AS imoveis
    FROM prata.car__imoveis i
    WHERE i.data_inscricao IS NOT NULL
      AND i.cod_municipio IS NOT NULL
    GROUP BY i.cod_municipio, i.data_inscricao, ROUND(i.area_calculada_ha, 1)
),
distribuicao_municipio AS (
    SELECT
        cod_municipio,
        AVG(qtd)                                            AS media_qtd,
        COALESCE(STDDEV_SAMP(qtd), 0)                       AS desvio_qtd,
        COUNT(*)                                            AS grupos_no_municipio
    FROM grupos
    GROUP BY cod_municipio
),
qualificados AS (
    SELECT
        g.*,
        gen_random_uuid()                                   AS grupo_id,
        d.media_qtd,
        d.desvio_qtd,
        CASE WHEN d.desvio_qtd > 0
             THEN (g.qtd - d.media_qtd) / d.desvio_qtd
        END                                                 AS z_score,
        m.nome                                              AS nome_municipio
    FROM grupos g
    JOIN distribuicao_municipio d USING (cod_municipio)
    LEFT JOIN prata.ref__municipios m ON m.cod_ibge = g.cod_municipio
    WHERE g.qtd >= %(min_cadastros_grupo)s
      AND d.desvio_qtd > 0
      AND (g.qtd - d.media_qtd) / d.desvio_qtd >= %(z_score_min)s
      -- Municípios com pouquíssimos grupos têm distribuição instável;
      -- o z-score ali não significa nada.
      AND d.grupos_no_municipio >= 10
)
INSERT INTO ouro.car__sinais_anomalia (
    detector, versao_detector, grupo_id,
    cod_imovel, uf, cod_municipio,
    confianca, regra_aplicada, limiares, evidencia,
    geom_evidencia, _hash_evidencia, _execucao_id
)
SELECT
    'd5_padrao_cadastral_atipico',
    '1.0.0',
    q.grupo_id,
    imovel.cod_imovel,
    q.uf,
    q.cod_municipio,
    %(confianca)s::NUMERIC,
    'Imóvel pertence a lote de ' || q.qtd || ' cadastros com mesma data de '
        || 'inscrição e mesma área aproximada no município (z-score '
        || ROUND(q.z_score, 1) || ')',
    jsonb_build_object(
        'z_score_min',         %(z_score_min)s,
        'min_cadastros_grupo', %(min_cadastros_grupo)s
    ),
    jsonb_build_object(
        'municipio',            q.nome_municipio,
        'data_inscricao',       q.data_inscricao,
        'area_arredondada_ha',  q.area_arredondada,
        'qtd_no_lote',          q.qtd,
        'media_municipio',      ROUND(q.media_qtd, 2),
        'desvio_municipio',     ROUND(q.desvio_qtd, 2),
        'z_score',              ROUND(q.z_score, 2),
        'imoveis_do_lote',      to_jsonb(q.imoveis),
        'hipoteses_alternativas', to_jsonb(ARRAY[
            'mutirão de cadastramento promovido por órgão ou cooperativa',
            'projeto de assentamento com lotes de tamanho padronizado',
            'ação de regularização coletiva legítima'
        ])
    ),
    NULL::geometry,
    encode(digest(q.grupo_id::TEXT || imovel.cod_imovel, 'sha256'), 'hex'),
    %(execucao_id)s::UUID
FROM qualificados q
CROSS JOIN LATERAL unnest(q.imoveis) AS imovel(cod_imovel)
ON CONFLICT (detector, cod_imovel, _hash_evidencia) DO NOTHING;
