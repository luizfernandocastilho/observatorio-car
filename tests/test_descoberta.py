"""Testes da descoberta de arquivos-fonte da ingestão bronze.

Rodam sem banco e sem Airflow: `medalhao.descoberta` só usa a stdlib, de
propósito, para que a regra "carga vazia é falha" seja testável aqui.

A regra de projeto por trás destes testes: nenhuma tarefa de ingestão pode
"passar" silenciosamente quando não há arquivo para ingerir. Falha visível é
melhor que carga vazia silenciosa (ver CLAUDE.md).
"""
from __future__ import annotations

import pytest

from medalhao.descoberta import (
    descobrir_arquivos,
    descobrir_arquivos_obrigatorio,
)


def test_descobrir_arquivos_vazio_retorna_lista_vazia(tmp_path):
    """A variante não-obrigatória não levanta: devolve lista vazia."""
    assert descobrir_arquivos(tmp_path) == []


def test_descobrir_arquivos_ordena_resultado(tmp_path):
    """Ordem estável: ingestão idempotente depende disso."""
    (tmp_path / "b.shp").touch()
    (tmp_path / "a.shp").touch()
    sub = tmp_path / "sub"
    sub.mkdir()
    (sub / "c.shp").touch()

    nomes = [p.name for p in descobrir_arquivos(tmp_path)]
    assert nomes == ["a.shp", "b.shp", "c.shp"]


def test_obrigatorio_levanta_quando_nao_ha_arquivo(tmp_path):
    """Pasta sem shapefile é falha de ingestão, não sucesso vazio."""
    with pytest.raises(FileNotFoundError) as exc:
        descobrir_arquivos_obrigatorio(tmp_path)
    assert str(tmp_path) in str(exc.value)


def test_obrigatorio_respeita_o_padrao(tmp_path):
    """Com padrão de CSV, um .shp presente não satisfaz a exigência."""
    (tmp_path / "ignorado.shp").touch()
    with pytest.raises(FileNotFoundError):
        descobrir_arquivos_obrigatorio(tmp_path, padrao="*.csv")


def test_obrigatorio_usa_a_descricao_na_mensagem(tmp_path):
    """A mensagem orienta o operador sobre qual fonte falta."""
    with pytest.raises(FileNotFoundError) as exc:
        descobrir_arquivos_obrigatorio(
            tmp_path, descricao="shapefile de restrição 'embargos'"
        )
    assert "embargos" in str(exc.value)


def test_obrigatorio_devolve_arquivos_quando_existem(tmp_path):
    """Com arquivos presentes, devolve a mesma lista ordenada."""
    (tmp_path / "a.shp").touch()
    (tmp_path / "b.shp").touch()
    resultado = descobrir_arquivos_obrigatorio(tmp_path)
    assert [p.name for p in resultado] == ["a.shp", "b.shp"]
