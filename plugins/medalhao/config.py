"""Carregamento dos contratos YAML do projeto.

Os limiares dos detectores e o catálogo de fontes moram em `contracts/`, não
no código. Motivo: a calibragem muda a cada rodada de auditoria manual e
precisa ser versionada junto com a precisão medida, sem alterar SQL.
"""
from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml

# Dentro do container do Airflow os contratos ficam montados em /opt/airflow
DIR_CONTRATOS = Path(
    os.environ.get("OBSERVATORIO_DIR_CONTRATOS", "/opt/airflow/contracts")
)
DIR_SQL = Path(os.environ.get("OBSERVATORIO_DIR_SQL", "/opt/airflow/sql"))
DIR_DADOS = Path(
    os.environ.get("OBSERVATORIO_DIR_DADOS", "/opt/airflow/dados_brutos")
)


@lru_cache(maxsize=None)
def carregar_contrato(nome: str) -> dict[str, Any]:
    """Lê um YAML de `contracts/` e devolve o dicionário.

    Args:
        nome: Nome do arquivo sem extensão (ex: 'detectores', 'fontes').

    Returns:
        Conteúdo do YAML.

    Raises:
        FileNotFoundError: Quando o contrato não existe — falha explícita é
            melhor que default silencioso em limiar de detector.
    """
    caminho = DIR_CONTRATOS / f"{nome}.yml"
    if not caminho.exists():
        raise FileNotFoundError(
            f"Contrato '{nome}' não encontrado em {caminho}. "
            "Os limiares dos detectores não têm valor padrão de propósito."
        )
    with caminho.open(encoding="utf-8") as arq:
        return yaml.safe_load(arq)


def ufs_piloto() -> list[str]:
    """UFs do recorte piloto, conforme contracts/fontes.yml."""
    return list(carregar_contrato("fontes")["ufs_piloto"])


def detectores_ativos() -> dict[str, dict[str, Any]]:
    """Detectores marcados como ativos, com seus limiares e precisão medida."""
    todos = carregar_contrato("detectores")["detectores"]
    return {nome: cfg for nome, cfg in todos.items() if cfg.get("ativo")}


def parametros_validacao() -> dict[str, Any]:
    """Tamanho de amostra e semente para a auditoria manual."""
    return carregar_contrato("detectores")["validacao"]
