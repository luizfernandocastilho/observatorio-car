"""Descoberta de arquivos-fonte para a ingestão bronze.

Isolado num módulo só-stdlib (sem Airflow, sem psycopg2, sem geopandas) de
propósito: a regra "carga vazia é falha, não sucesso" precisa ser testável
nos testes de contrato, que rodam sem banco. Por isso a lógica de descoberta
mora aqui, e não em `ingestao_geo.py` (que puxa dependências pesadas).
"""
from __future__ import annotations

from pathlib import Path


def descobrir_arquivos(
    diretorio: str | Path, padrao: str = "*.shp"
) -> list[Path]:
    """Lista arquivos a ingerir, recursivamente e em ordem estável.

    Usado pelos extratores para percorrer dados_brutos/<fonte>/<uf>/. Não
    levanta quando não acha nada: devolve lista vazia. Para fontes onde a
    ausência de arquivo é falha, use `descobrir_arquivos_obrigatorio`.
    """
    return sorted(Path(diretorio).rglob(padrao))


def descobrir_arquivos_obrigatorio(
    diretorio: str | Path,
    padrao: str = "*.shp",
    *,
    descricao: str | None = None,
) -> list[Path]:
    """Igual a `descobrir_arquivos`, mas exige pelo menos um arquivo.

    Levanta `FileNotFoundError` quando o diretório não contém nenhum arquivo
    que case com `padrao`. É o mecanismo de "falha visível" das tarefas de
    ingestão: uma fonte esperada que vem vazia trava o pipeline com mensagem
    explícita, em vez de "passar" ingerindo zero feições e mascarar a lacuna.

    Args:
        diretorio: Pasta a varrer (recursivamente).
        padrao: Glob dos arquivos esperados (ex.: '*.shp', '*.csv').
        descricao: Rótulo da fonte para a mensagem de erro, orientando o
            operador sobre o que depositar. Quando omitido, cita o padrão.

    Returns:
        Lista ordenada e não vazia de caminhos.

    Raises:
        FileNotFoundError: Nenhum arquivo casando com `padrao` no diretório.
    """
    arquivos = descobrir_arquivos(diretorio, padrao)
    if not arquivos:
        rotulo = descricao or f"arquivo '{padrao}'"
        raise FileNotFoundError(
            f"Nenhum {rotulo} em {diretorio}. Baixe a fonte e deposite os "
            "arquivos lá — carga vazia é falha de ingestão, não sucesso."
        )
    return arquivos
