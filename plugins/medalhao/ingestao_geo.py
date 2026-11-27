"""Ingestão de camadas geoespaciais para a camada bronze.

Estratégia: ler o arquivo com pyogrio (mais rápido e com menos dependências
que o GDAL via fiona), converter cada feição em (geometria WKB, atributos
JSONB, hash) e inserir em lote com execute_values.

Por que os atributos vão para JSONB e não para colunas tipadas: os nomes de
campo dos shapefiles do Sicar variam entre versões e entre UFs. Bronze aceita
o que vier; o mapeamento explícito acontece em sql/prata/, onde uma mudança de
schema na fonte falha de forma visível e testável.
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

# Reexportado por compatibilidade: a descoberta mora em módulo só-stdlib para
# ser testável sem Airflow. Ver medalhao/descoberta.py.
from medalhao.descoberta import (  # noqa: F401
    descobrir_arquivos,
    descobrir_arquivos_obrigatorio,
)

logger = logging.getLogger(__name__)

SRID_CAR = 4674  # SIRGAS 2000, datum oficial das bases do CAR
TAMANHO_LOTE = 5_000  # page_size do execute_values (quantas linhas por INSERT)
LOTE_LEITURA = 500  # feições lidas por vez; limita o pico de memória.
# 500 é conservador de propósito: fontes como o CNFP têm feições enormes
# (~2,5 mi de vértices a cada 500), então o limite é vértice/memória, não linha.


def _hash_feicao(atributos: dict[str, Any], wkb_hex: str | None) -> str:
    """SHA-256 estável de uma feição (atributos ordenados + geometria)."""
    payload = json.dumps(atributos, sort_keys=True, ensure_ascii=False, default=str)
    return hashlib.sha256(
        f"{payload}|{wkb_hex or ''}".encode("utf-8")
    ).hexdigest()


def _linhas_do_lote(
    gdf,
    colunas_extra: dict[str, Any],
    nomes_extra: list[str],
    ingestao_id: uuid.UUID,
    agora: datetime,
    caminho: Path,
) -> list[tuple]:
    """Converte um GeoDataFrame (um lote) em tuplas prontas para execute_values."""
    coluna_geom = gdf.geometry.name
    linhas: list[tuple] = []
    for _, feicao in gdf.iterrows():
        geometria = feicao[coluna_geom]
        wkb_hex = geometria.wkb_hex if geometria is not None else None
        atributos = {
            chave: valor
            for chave, valor in feicao.items()
            if chave != coluna_geom
        }
        linhas.append(
            tuple(colunas_extra[nome] for nome in nomes_extra)
            + (
                wkb_hex,
                json.dumps(atributos, ensure_ascii=False, default=str),
                str(ingestao_id),
                agora,
                str(caminho),
                _hash_feicao(atributos, wkb_hex),
            )
        )
    return linhas


def ingerir_camada_geo(
    caminho: str | Path,
    tabela_destino: str,
    conn_id: str,
    *,
    colunas_extra: dict[str, Any] | None = None,
    fonte: str | None = None,
    camada: str | None = None,
) -> dict[str, Any]:
    """Ingere um arquivo vetorial em uma tabela bronze.

    Args:
        caminho: Shapefile, GeoPackage ou qualquer formato lido por pyogrio.
        tabela_destino: Tabela bronze completa (ex: 'bronze.sicar__area_imovel').
            Precisa ter as colunas geom, atributos e as quatro de controle,
            além das chaves de `colunas_extra`.
        conn_id: Airflow Connection do Postgres.
        colunas_extra: Colunas fixas adicionais, iguais para todas as linhas
            do arquivo (ex: {'uf': 'PA'} ou {'categoria': 'embargo'}).
        fonte: Nome da fonte em contracts/fontes.yml, para o registro de
            versão. Quando omitido, usa o nome do arquivo.
        camada: Nome da camada, para arquivos multi-camada (GeoPackage).

    Returns:
        Dicionário com contagens e o UUID da execução.

    Raises:
        FileNotFoundError: Arquivo inexistente.
        ValueError: Arquivo sem feições — carga vazia é erro, não sucesso.
    """
    from pyogrio import read_dataframe, read_info

    caminho = Path(caminho)
    if not caminho.exists():
        raise FileNotFoundError(f"Arquivo não encontrado: {caminho}")

    ingestao_id = uuid.uuid4()
    agora = datetime.now(timezone.utc)
    colunas_extra = colunas_extra or {}
    nomes_extra = list(colunas_extra.keys())

    # Conta as feições sem carregar geometria nenhuma na memória. Carga vazia
    # é falha de ingestão, não sucesso — falha visível antes de abrir conexão.
    total = int(read_info(caminho, layer=camada)["features"])
    if total == 0:
        raise ValueError(
            f"{caminho} não tem feições. Carga vazia é falha de ingestão, "
            "não resultado válido — confira o download."
        )

    colunas_sql = nomes_extra + [
        "geom", "atributos",
        "_ingestao_id", "_ingestao_timestamp", "_fonte_arquivo", "_hash_linha",
    ]
    # ST_Multi garante que polígonos simples caibam na coluna MultiPolygon;
    # ST_Force2D remove a dimensão Z de fontes 3D (ex.: o CNFP vem com Z), que
    # a coluna geometry(MultiPolygon, 4674) — bidimensional — não aceita. A
    # geometria de verdade é tratada na prata; o Z aqui é descartável.
    placeholder_geom = (
        "ST_Force2D(ST_Multi(ST_CollectionExtract("
        f"ST_SetSRID(ST_GeomFromWKB(decode(%s, 'hex')), {SRID_CAR}), 3)))"
    )
    template = (
        "("
        + ", ".join(["%s"] * len(nomes_extra) + [placeholder_geom] + ["%s"] * 5)
        + ")"
    )
    sql = (
        f"INSERT INTO {tabela_destino} ({', '.join(colunas_sql)}) VALUES %s"
    )

    inseridas = 0
    hook = PostgresHook(postgres_conn_id=conn_id)
    # Uma transação por arquivo: ou o arquivo entra inteiro, ou nada entra.
    with hook.get_conn() as conexao:
        with conexao.cursor() as cursor:
            # Lê e insere em lotes. O pico de memória fica no tamanho do lote,
            # não no arquivo inteiro: shapefiles grandes (ex.: o CNFP, ~800 MB
            # de polígonos 3D) estouravam a RAM do container quando carregados
            # de uma vez (OOM, SIGKILL -9). Ler por faixa de feições resolve.
            for inicio in range(0, total, LOTE_LEITURA):
                fim = min(inicio + LOTE_LEITURA, total)
                logger.info("Lendo %s [%s..%s de %s] (camada=%s)",
                            caminho, inicio, fim, total, camada)
                gdf = read_dataframe(
                    caminho,
                    layer=camada,
                    skip_features=inicio,
                    max_features=LOTE_LEITURA,
                )
                # Reprojeta para o SRID do CAR quando a origem declara outro CRS
                if gdf.crs is not None and gdf.crs.to_epsg() != SRID_CAR:
                    gdf = gdf.to_crs(epsg=SRID_CAR)

                linhas = _linhas_do_lote(
                    gdf, colunas_extra, nomes_extra, ingestao_id, agora, caminho
                )
                if not linhas:
                    continue
                execute_values(
                    cursor, sql, linhas, template=template, page_size=TAMANHO_LOTE
                )
                inseridas += cursor.rowcount

            # Linhagem: registra qual versão da fonte entrou (uma vez por arquivo)
            cursor.execute(
                """
                INSERT INTO bronze._versoes_fonte (
                    fonte, versao, arquivo_local, sha256_arquivo, _ingestao_id
                )
                VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT (fonte, versao) DO UPDATE SET
                    ingerido_em = NOW(),
                    _ingestao_id = EXCLUDED._ingestao_id
                """,
                (
                    fonte or caminho.stem,
                    agora.date().isoformat(),
                    str(caminho),
                    _hash_arquivo(caminho),
                    str(ingestao_id),
                ),
            )
        conexao.commit()

    logger.info("Ingeridas %s feições em %s", inseridas, tabela_destino)
    return {
        "ingestao_id": str(ingestao_id),
        "feicoes_lidas": total,
        "linhas_inseridas": inseridas,
        "tabela_destino": tabela_destino,
        "arquivo": str(caminho),
    }


def _hash_arquivo(caminho: Path, bloco: int = 1 << 20) -> str:
    """SHA-256 do arquivo, para provar qual versão foi usada."""
    digest = hashlib.sha256()
    with caminho.open("rb") as arq:
        while pedaco := arq.read(bloco):
            digest.update(pedaco)
    return digest.hexdigest()
