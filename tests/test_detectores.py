"""Testes dos contratos e dos SQL dos detectores.

Rodam sem banco e sem Airflow: validam que contrato e SQL estão coerentes
entre si. É o teste que pega o erro mais comum do projeto — renomear um limiar
no YAML e esquecer o placeholder no SQL, ou o contrário.

    pytest tests/ -v
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

RAIZ = Path(__file__).resolve().parent.parent
DIR_DETECTORES = RAIZ / "sql" / "ouro" / "detectores"

# Placeholders injetados pelo runner, não pelo contrato
PARAMETROS_DO_RUNNER = {"execucao_id", "confianca"}


@pytest.fixture(scope="module")
def contrato() -> dict:
    with (RAIZ / "contracts" / "detectores.yml").open(encoding="utf-8") as arq:
        return yaml.safe_load(arq)


def placeholders(sql: str) -> set[str]:
    """Extrai os nomes de %(nome)s de um SQL."""
    return set(re.findall(r"%\((\w+)\)s", sql))


def test_todo_detector_do_contrato_tem_sql(contrato):
    """Cada detector declarado no YAML tem arquivo SQL correspondente."""
    for nome in contrato["detectores"]:
        assert (DIR_DETECTORES / f"{nome}.sql").exists(), (
            f"Detector '{nome}' está no contrato mas não tem "
            f"sql/ouro/detectores/{nome}.sql"
        )


def test_todo_sql_tem_detector_no_contrato(contrato):
    """Nenhum SQL órfão: SQL sem contrato roda sem limiar controlado."""
    for caminho in DIR_DETECTORES.glob("*.sql"):
        assert caminho.stem in contrato["detectores"], (
            f"{caminho.name} não tem entrada em contracts/detectores.yml"
        )


def test_placeholders_batem_com_limiares(contrato):
    """Todo %(param)s do SQL existe no contrato, e todo limiar é usado."""
    for nome, config in contrato["detectores"].items():
        sql = (DIR_DETECTORES / f"{nome}.sql").read_text(encoding="utf-8")
        usados = placeholders(sql) - PARAMETROS_DO_RUNNER
        declarados = set(config["limiares"])

        faltando = usados - declarados
        assert not faltando, (
            f"{nome}: SQL usa parâmetros ausentes do contrato: {sorted(faltando)}"
        )

        nao_usados = declarados - usados
        assert not nao_usados, (
            f"{nome}: contrato declara limiares que o SQL ignora: "
            f"{sorted(nao_usados)} — limiar não usado é limiar que engana"
        )


def test_detector_registra_versao_e_evidencia():
    """Todo detector grava versão, regra, limiares e evidência."""
    for caminho in DIR_DETECTORES.glob("*.sql"):
        sql = caminho.read_text(encoding="utf-8")
        for obrigatorio in (
            "versao_detector", "regra_aplicada", "limiares",
            "evidencia", "_hash_evidencia",
        ):
            assert obrigatorio in sql, (
                f"{caminho.name} não grava '{obrigatorio}' — sinal sem isso "
                "não é auditável"
            )


def test_detector_e_idempotente():
    """Todo detector tem ON CONFLICT: rodar duas vezes não duplica sinal."""
    for caminho in DIR_DETECTORES.glob("*.sql"):
        sql = caminho.read_text(encoding="utf-8").upper()
        assert "ON CONFLICT" in sql, (
            f"{caminho.name} não é idempotente — Airflow reexecuta em retry"
        )


def test_linguagem_nao_acusatoria():
    """Nenhum SQL usa linguagem que afirma irregularidade.

    Regra de projeto, não preferência estética: a ferramenta produz sinal para
    triagem. Um órgão público rejeita por instinto institucional qualquer
    ferramenta que pareça acusar produtor sem devido processo.
    """
    proibidas = ("fraude", "fraudulento", "irregularidade", "infrator",
                 "culpado", "denuncia", "denúncia", "criminoso")
    for caminho in list(DIR_DETECTORES.glob("*.sql")) + [
        RAIZ / "sql" / "ouro" / "01_sinais_anomalia.sql"
    ]:
        texto = caminho.read_text(encoding="utf-8").lower()
        for palavra in proibidas:
            # A própria regra pode citar o termo ao explicar que o evita
            ocorrencias = [
                linha for linha in texto.splitlines()
                if palavra in linha and "não" not in linha and "nem" not in linha
            ]
            assert not ocorrencias, (
                f"{caminho.name} usa linguagem acusatória ('{palavra}'): "
                f"{ocorrencias[:1]}"
            )
