"""Execução dos detectores de anomalia e das cargas parametrizadas da ouro.

Os SQL ficam em sql/ouro/ e sql/ouro/detectores/ com placeholders no formato
%(parametro)s. Este módulo injeta os limiares de contracts/detectores.yml e
executa cada arquivo numa transação única.

Princípio do projeto: nenhum detector afirma irregularidade. A `confianca`
gravada em cada sinal é a precisão MEDIDA em auditoria manual — quando ainda
não houve auditoria, o valor é NULL e a interface precisa dizer isso ao
usuário em vez de exibir um número inventado.
"""
from __future__ import annotations

import logging
import uuid
from pathlib import Path
from typing import Any

from airflow.providers.postgres.hooks.postgres import PostgresHook

from medalhao.config import DIR_SQL, detectores_ativos, parametros_validacao

logger = logging.getLogger(__name__)


def executar_sql_parametrizado(
    caminho_sql: str | Path,
    conn_id: str,
    parametros: dict[str, Any],
) -> int:
    """Executa um arquivo SQL com parâmetros nomeados, em transação única.

    Args:
        caminho_sql: Caminho do .sql (absoluto ou relativo a DIR_SQL).
        conn_id: Airflow Connection do Postgres.
        parametros: Valores para os placeholders %(nome)s.

    Returns:
        Número de linhas afetadas pelo último comando do arquivo.

    Raises:
        FileNotFoundError: SQL inexistente.
        KeyError: Placeholder sem valor correspondente — falha explícita, para
            não rodar detector com limiar faltando.
    """
    caminho = Path(caminho_sql)
    if not caminho.is_absolute():
        caminho = DIR_SQL / caminho
    if not caminho.exists():
        raise FileNotFoundError(f"SQL não encontrado: {caminho}")

    sql = caminho.read_text(encoding="utf-8")
    hook = PostgresHook(postgres_conn_id=conn_id)

    with hook.get_conn() as conexao:
        with conexao.cursor() as cursor:
            cursor.execute(sql, parametros)
            afetadas = cursor.rowcount
        conexao.commit()

    logger.info("%s executado: %s linhas afetadas", caminho.name, afetadas)
    return afetadas


def executar_detector(
    nome: str,
    conn_id: str,
    execucao_id: str | None = None,
) -> dict[str, Any]:
    """Roda um detector com os limiares do contrato.

    Args:
        nome: Chave do detector em contracts/detectores.yml
            (ex: 'd1_fatiamento').
        conn_id: Airflow Connection do Postgres (camada ouro).
        execucao_id: UUID da execução; gerado quando omitido.

    Returns:
        Resumo com sinais gerados e limiares aplicados.
    """
    ativos = detectores_ativos()
    if nome not in ativos:
        raise KeyError(
            f"Detector '{nome}' não está ativo em contracts/detectores.yml. "
            f"Ativos: {sorted(ativos)}"
        )

    config = ativos[nome]
    execucao_id = execucao_id or str(uuid.uuid4())

    parametros: dict[str, Any] = dict(config["limiares"])
    parametros["execucao_id"] = execucao_id
    # Confiança = precisão medida. None até a primeira auditoria.
    parametros["confianca"] = config.get("precisao_medida")

    sinais = executar_sql_parametrizado(
        Path("ouro") / "detectores" / f"{nome}.sql", conn_id, parametros
    )

    return {
        "detector": nome,
        "sinais_gerados": sinais,
        "execucao_id": execucao_id,
        "limiares": config["limiares"],
        "precisao_medida": config.get("precisao_medida"),
    }


def executar_todos_detectores(
    conn_id: str, execucao_id: str | None = None
) -> list[dict[str, Any]]:
    """Roda todos os detectores ativos em sequência.

    Em sequência e não em paralelo de propósito: d3 (sobreposição CAR x CAR) é
    a consulta mais pesada do pipeline e competir por I/O com as outras só
    aumenta o tempo total.
    """
    execucao_id = execucao_id or str(uuid.uuid4())
    return [
        executar_detector(nome, conn_id, execucao_id)
        for nome in detectores_ativos()
    ]


def sortear_amostra_validacao(
    conn_id: str, execucao_id: str | None = None
) -> int:
    """Sorteia a amostra reproduzível para auditoria manual."""
    parametros = dict(parametros_validacao())
    parametros["execucao_id"] = execucao_id or str(uuid.uuid4())
    return executar_sql_parametrizado(
        Path("ouro") / "03_amostra_validacao.sql", conn_id, parametros
    )
