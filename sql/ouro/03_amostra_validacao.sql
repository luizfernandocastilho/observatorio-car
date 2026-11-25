-- =============================================================================
-- sql/ouro/03_amostra_validacao.sql
--
-- Amostra aleatória estratificada por detector, para auditoria manual.
--
-- Este arquivo é o coração do argumento da proposta. Sem precisão medida,
-- "detectamos 20 mil casos" não significa nada; com precisão medida por
-- detector, a ferramenta passa a ser defensável por um órgão público.
--
-- A semente fixa (contracts/detectores.yml) torna a amostra reproduzível:
-- quem auditar a proposta pode refazer exatamente a mesma seleção.
--
-- Parâmetros: casos_por_detector, semente_aleatoria, execucao_id
-- =============================================================================

SET search_path TO ouro, public;

SELECT setseed(%(semente_aleatoria)s::FLOAT / 2147483647.0);

INSERT INTO ouro.car__amostra_validacao (
    sinal_id, detector, ordem_na_amostra, semente, _execucao_id
)
SELECT
    sinal_id, detector, ordem, %(semente_aleatoria)s::BIGINT, %(execucao_id)s::UUID
FROM (
    SELECT
        s.id                                        AS sinal_id,
        s.detector,
        ROW_NUMBER() OVER (
            PARTITION BY s.detector ORDER BY random()
        )                                           AS ordem
    FROM ouro.car__sinais_anomalia s
    -- Não re-amostra o que já foi auditado
    LEFT JOIN ouro.car__triagem_desfecho d ON d.sinal_id = s.id
    WHERE d.id IS NULL
) sorteio
WHERE ordem <= %(casos_por_detector)s
ON CONFLICT (sinal_id, semente) DO NOTHING;
