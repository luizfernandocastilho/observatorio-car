"""Ingestão de fontes tabulares (CSV) para bronze, com atributos em JSONB.

Usado pelo Painel da Regularização Ambiental do SFB e pela tabela de módulo
fiscal do Incra. Volume baixo (dezenas de milhares de linhas), então pandas
resolve sem precisar de COPY.
"""
from __future__ import annotations

import hashlib
import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from airflow.providers.postgres.hooks.postgres import PostgresHook
from psycopg2.extras import execute_values

logger = logging.getLogger(__name__)


def ingerir_csv_jsonb(
    caminho: str | Path,
    tabela_destino: str,
    conn_id: str,
    *,
    sep: str = ";",
    encoding: str = "utf-8",
    fonte: str | None = None,
) -> dict[str, Any]:
    """Ingere um CSV para uma tabela bronze com coluna `atributos` JSONB.

    Args:
        caminho: Arquivo CSV.
        tabela_destino: Tabela bronze (ex: 'bronze.incra__modulo_fiscal').
        conn_id: Airflow Connection do Postgres.
        sep: Separador. Fontes públicas brasileiras usam ';' com frequência.
        encoding: Encoding do arquivo. Tente 'latin-1' se utf-8 falhar.
        fonte: Nome em contracts/fontes.yml para o registro de linhagem.

    Returns:
        Contagens e UUID da execução.
    """
    import pandas as pd

    caminho = Path(caminho)
    if not caminho.exists():
        raise FileNotFoundError(f"Arquivo não encontrado: {caminho}")

    ingestao_id = uuid.uuid4()
    agora = datetime.now(timezone.utc)

    df = pd.read_csv(caminho, sep=sep, encoding=encoding, dtype=str)
    if df.empty:
        raise ValueError(f"{caminho} está vazio — carga vazia é falha.")

    linhas = []
    for registro in df.to_dict(orient="records"):
        payload = json.dumps(registro, sort_keys=True, ensure_ascii=False)
        linhas.append((
            payload,
            str(ingestao_id),
            agora,
            str(caminho),
            hashlib.sha256(payload.encode("utf-8")).hexdigest(),
        ))

    sql = (
        f"INSERT INTO {tabela_destino} "
        "(atributos, _ingestao_id, _ingestao_timestamp, _fonte_arquivo, _hash_linha) "
        "VALUES %s"
    )

    hook = PostgresHook(postgres_conn_id=conn_id)
    with hook.get_conn() as conexao:
        with conexao.cursor() as cursor:
            execute_values(cursor, sql, linhas, page_size=5_000)
            inseridas = cursor.rowcount
        conexao.commit()

    logger.info("Ingeridas %s linhas em %s", inseridas, tabela_destino)
    return {
        "ingestao_id": str(ingestao_id),
        "linhas_lidas": len(df),
        "linhas_inseridas": inseridas,
        "fonte": fonte or caminho.stem,
    }
