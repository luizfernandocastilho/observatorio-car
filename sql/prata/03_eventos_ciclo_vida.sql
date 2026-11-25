-- =============================================================================
-- sql/prata/03_eventos_ciclo_vida.sql
--
-- Camada PRATA — eventos do ciclo de vida do cadastro.
--
-- É daqui que sai a linha do tempo de gargalos, que é a lacuna nomeada no
-- briefing do Desafio 3 e que a plataforma pública atual não oferece.
--
-- Modelo: uma linha por (cod_imovel, etapa), com entrada e saída. A duração
-- em cada etapa é calculada, não armazenada, para não desatualizar.
--
-- Limitação honesta: o dado público pode não trazer todos os marcos
-- temporais. Quando o marco não existe, `origem` registra 'derivado_status'
-- e a etapa fica sem data de entrada — e isso tem que aparecer na interface
-- como lacuna, não ser preenchido com estimativa.
-- =============================================================================

SET search_path TO prata, bronze, public;

CREATE TABLE IF NOT EXISTS prata.car__eventos_ciclo_vida (
    id                      BIGSERIAL   PRIMARY KEY,
    cod_imovel              TEXT        NOT NULL
                                        REFERENCES prata.car__imoveis (cod_imovel)
                                        ON DELETE CASCADE,
    etapa                   TEXT        NOT NULL
                                        CHECK (etapa IN (
                                            'inscricao',
                                            'analise',
                                            'notificacao',
                                            'retificacao',
                                            'validacao',
                                            'pra'
                                        )),
    entrou_em               DATE,
    saiu_em                 DATE,
    origem                  TEXT        NOT NULL
                                        CHECK (origem IN (
                                            'fonte_direta',
                                            'derivado_status',
                                            'derivado_painel'
                                        )),
    _processamento_id       UUID        NOT NULL,
    _processamento_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (cod_imovel, etapa)
);

COMMENT ON TABLE prata.car__eventos_ciclo_vida IS
    'Entrada e saída de cada imóvel em cada etapa da regularização. Base da '
    'linha do tempo de gargalos da camada ouro.';
COMMENT ON COLUMN prata.car__eventos_ciclo_vida.origem IS
    'fonte_direta: marco temporal veio no dado. derivado_status: inferido do '
    'status atual, sem data confiável. derivado_painel: data agregada do '
    'Painel da Regularização, válida para o grupo e não para o imóvel.';

CREATE INDEX IF NOT EXISTS idx_prata_eventos_etapa
    ON prata.car__eventos_ciclo_vida (etapa, entrou_em);
CREATE INDEX IF NOT EXISTS idx_prata_eventos_imovel
    ON prata.car__eventos_ciclo_vida (cod_imovel);

-- -----------------------------------------------------------------------------
-- Derivação a partir do status declarado
--
-- O mapeamento status -> etapas percorridas é a única regra de negócio desta
-- transformação. Mantida explícita numa CTE para poder ser revisada por quem
-- conhece o fluxo do Sicar sem ler o resto do SQL.
-- -----------------------------------------------------------------------------
WITH mapa_status AS (
    SELECT * FROM (VALUES
        -- (status na fonte, etapa alcançada, ordem)
        ('AT',        'inscricao',    1),
        ('ATIVO',     'inscricao',    1),
        ('PE',        'analise',      2),
        ('PENDENTE',  'analise',      2),
        ('AN',        'analise',      2),
        ('ANALISE',   'analise',      2),
        ('NO',        'notificacao',  3),
        ('NOTIFICADO','notificacao',  3),
        ('RE',        'retificacao',  4),
        ('RETIFICADO','retificacao',  4),
        ('VA',        'validacao',    5),
        ('VALIDADO',  'validacao',    5),
        ('AP',        'validacao',    5),
        ('APROVADO',  'validacao',    5)
    ) AS t(status_fonte, etapa, ordem)
),
eventos AS (
    -- Inscrição: todo imóvel passou por ela
    SELECT
        i.cod_imovel,
        'inscricao'::TEXT                                   AS etapa,
        i.data_inscricao                                    AS entrou_em,
        i.data_ultima_retificacao                           AS saiu_em,
        CASE WHEN i.data_inscricao IS NOT NULL
             THEN 'fonte_direta' ELSE 'derivado_status' END AS origem
    FROM prata.car__imoveis i

    UNION ALL

    -- Etapa corrente derivada do status
    SELECT
        i.cod_imovel,
        m.etapa,
        i.data_ultima_retificacao                           AS entrou_em,
        NULL::DATE                                          AS saiu_em,
        CASE WHEN i.data_ultima_retificacao IS NOT NULL
             THEN 'fonte_direta' ELSE 'derivado_status' END AS origem
    FROM prata.car__imoveis i
    JOIN mapa_status m
      ON upper(trim(i.status_cadastro)) = m.status_fonte
    WHERE m.etapa <> 'inscricao'
)
INSERT INTO prata.car__eventos_ciclo_vida (
    cod_imovel, etapa, entrou_em, saiu_em, origem, _processamento_id
)
SELECT
    cod_imovel, etapa, entrou_em, saiu_em, origem, gen_random_uuid()
FROM eventos
ON CONFLICT (cod_imovel, etapa) DO UPDATE SET
    entrou_em                = EXCLUDED.entrou_em,
    saiu_em                  = EXCLUDED.saiu_em,
    origem                   = EXCLUDED.origem,
    _processamento_timestamp = NOW();
