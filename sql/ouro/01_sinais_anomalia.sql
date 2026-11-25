-- =============================================================================
-- sql/ouro/01_sinais_anomalia.sql
--
-- Camada OURO — tabela única de sinais para triagem.
--
-- Todos os detectores escrevem aqui, no mesmo formato. Isso é deliberado: um
-- órgão público precisa de uma fila única de casos, não de cinco relatórios.
--
-- REGRA DO PROJETO, sem exceção: um sinal não afirma irregularidade. Toda
-- linha carrega a regra aplicada, os limiares usados e a evidência bruta,
-- para que um analista possa discordar com base no mesmo dado. Nenhuma coluna
-- aqui se chama "fraude", "infração" ou "irregularidade" — nem deve passar a
-- se chamar.
--
-- Nenhum dado pessoal entra nesta tabela. Os sinais apontam imóveis e
-- geometrias; identificar pessoas é competência do órgão gestor, não nossa.
-- =============================================================================

SET search_path TO ouro, prata, public;

CREATE TABLE IF NOT EXISTS ouro.car__sinais_anomalia (
    id                  BIGSERIAL   PRIMARY KEY,

    detector            TEXT        NOT NULL,
    versao_detector     TEXT        NOT NULL,
    grupo_id            UUID,

    cod_imovel          TEXT        NOT NULL,
    uf                  CHAR(2),
    cod_municipio       CHAR(7),

    -- Confiança declarada: vem da precisão medida em auditoria manual do
    -- detector (contracts/detectores.yml). NULL significa "ainda não
    -- auditado" e a interface precisa dizer isso ao usuário.
    confianca           NUMERIC(4,3)
                                    CHECK (confianca IS NULL
                                           OR (confianca >= 0 AND confianca <= 1)),

    regra_aplicada      TEXT        NOT NULL,
    limiares            JSONB       NOT NULL,
    evidencia           JSONB       NOT NULL,

    geom_evidencia      GEOMETRY(MultiPolygon, 4674),

    _hash_evidencia     TEXT        NOT NULL,
    _execucao_id        UUID        NOT NULL,
    _criado_em          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (detector, cod_imovel, _hash_evidencia)
);

COMMENT ON TABLE ouro.car__sinais_anomalia IS
    'Fila única de sinais para triagem, alimentada por todos os detectores. '
    'Cada linha é uma hipótese auditável, não uma conclusão.';
COMMENT ON COLUMN ouro.car__sinais_anomalia.grupo_id IS
    'Agrupa sinais que só fazem sentido em conjunto, como os imóveis de um '
    'mesmo cluster de fatiamento.';
COMMENT ON COLUMN ouro.car__sinais_anomalia.evidencia IS
    'Dados que sustentam o sinal, no formato do detector. É o que o analista '
    'lê para decidir — se não der para decidir com isso, o detector está mal '
    'feito.';
COMMENT ON COLUMN ouro.car__sinais_anomalia._hash_evidencia IS
    'Hash da evidência. Garante idempotência: rodar o detector duas vezes '
    'sobre o mesmo dado não duplica sinal.';

CREATE INDEX IF NOT EXISTS idx_ouro_sinais_detector
    ON ouro.car__sinais_anomalia (detector, _criado_em DESC);
CREATE INDEX IF NOT EXISTS idx_ouro_sinais_imovel
    ON ouro.car__sinais_anomalia (cod_imovel);
CREATE INDEX IF NOT EXISTS idx_ouro_sinais_municipio
    ON ouro.car__sinais_anomalia (cod_municipio);
CREATE INDEX IF NOT EXISTS idx_ouro_sinais_grupo
    ON ouro.car__sinais_anomalia (grupo_id);

-- -----------------------------------------------------------------------------
-- Desfecho da triagem: o que o analista decidiu sobre o sinal.
--
-- Sem esta tabela o observatório é um gerador de ruído. Com ela, cada rodada
-- de triagem recalibra a precisão do detector — e a precisão medida é o
-- argumento central da proposta.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ouro.car__triagem_desfecho (
    id                  BIGSERIAL   PRIMARY KEY,
    sinal_id            BIGINT      NOT NULL
                                    REFERENCES ouro.car__sinais_anomalia (id)
                                    ON DELETE CASCADE,
    desfecho            TEXT        NOT NULL
                                    CHECK (desfecho IN (
                                        'procede',
                                        'nao_procede',
                                        'inconclusivo'
                                    )),
    justificativa       TEXT,
    -- Identificador funcional de quem avaliou, NUNCA nome ou CPF
    avaliador_ref       TEXT,
    avaliado_em         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (sinal_id)
);

COMMENT ON TABLE ouro.car__triagem_desfecho IS
    'Resultado da verificação humana de cada sinal. Alimenta o cálculo de '
    'precisão por detector.';

-- -----------------------------------------------------------------------------
-- Amostra reproduzível para auditoria manual
--
-- DDL aqui e não em 03_amostra_validacao.sql porque aquele arquivo usa
-- placeholders parametrizados e não pode rodar no initdb do Postgres.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ouro.car__amostra_validacao (
    id                  BIGSERIAL   PRIMARY KEY,
    sinal_id            BIGINT      NOT NULL
                                    REFERENCES ouro.car__sinais_anomalia (id)
                                    ON DELETE CASCADE,
    detector            TEXT        NOT NULL,
    ordem_na_amostra    INT         NOT NULL,
    semente             BIGINT      NOT NULL,
    _execucao_id        UUID        NOT NULL,
    _criado_em          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (sinal_id, semente)
);

COMMENT ON TABLE ouro.car__amostra_validacao IS
    'Amostra aleatória reproduzível de sinais para auditoria manual. '
    'A semente fixa permite que terceiros refaçam a mesma seleção.';

-- -----------------------------------------------------------------------------
-- Precisão medida por detector — o número que a proposta precisa mostrar
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW ouro.car__precisao_detector AS
SELECT
    s.detector,
    s.versao_detector,
    COUNT(*)                                            AS sinais_auditados,
    COUNT(*) FILTER (WHERE d.desfecho = 'procede')      AS procedem,
    COUNT(*) FILTER (WHERE d.desfecho = 'nao_procede')  AS nao_procedem,
    COUNT(*) FILTER (WHERE d.desfecho = 'inconclusivo') AS inconclusivos,
    ROUND(
        COUNT(*) FILTER (WHERE d.desfecho = 'procede')::NUMERIC
        / NULLIF(COUNT(*) FILTER (WHERE d.desfecho <> 'inconclusivo'), 0),
        3
    )                                                   AS precisao
FROM ouro.car__sinais_anomalia s
JOIN ouro.car__triagem_desfecho d ON d.sinal_id = s.id
GROUP BY s.detector, s.versao_detector;

COMMENT ON VIEW ouro.car__precisao_detector IS
    'Precisão por detector, calculada só sobre sinais efetivamente auditados. '
    'Inconclusivos saem do denominador: não sabemos se acertamos.';

-- -----------------------------------------------------------------------------
-- Planilha de trabalho do auditor: tudo que ele precisa numa linha
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW ouro.car__fila_auditoria AS
SELECT
    a.id                            AS item_amostra,
    a.ordem_na_amostra,
    s.id                            AS sinal_id,
    s.detector,
    s.versao_detector,
    s.cod_imovel,
    s.uf,
    s.cod_municipio,
    s.regra_aplicada,
    s.evidencia,
    d.desfecho,
    d.justificativa
FROM ouro.car__amostra_validacao a
JOIN ouro.car__sinais_anomalia s ON s.id = a.sinal_id
LEFT JOIN ouro.car__triagem_desfecho d ON d.sinal_id = s.id
ORDER BY s.detector, a.ordem_na_amostra;

GRANT SELECT ON ALL TABLES IN SCHEMA ouro TO bi_leitura;

-- -----------------------------------------------------------------------------
-- Permissão de leitura para o dashboard. Necessário explicitamente porque
-- estas tabelas são criadas pelo etl_admin no initdb, e ALTER DEFAULT
-- PRIVILEGES só alcança tabelas criadas depois, pelo papel que o concedeu.
-- -----------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA ouro TO bi_leitura;
GRANT USAGE ON SCHEMA ouro TO bi_leitura;
