"""Suíte Great Expectations da camada OURO — ouro.car__sinais_anomalia.

O que esta suíte protege é menos a integridade do dado e mais a integridade do
método. Um sinal sem regra aplicada, sem limiar registrado ou sem evidência é
uma acusação sem prova — exatamente o que este projeto não entrega.

Rodar uma vez:
    python great_expectations/expectations/suite_ouro_sinais.py
"""
from __future__ import annotations

import great_expectations as gx
from great_expectations import expectations as gxe
from great_expectations.core.expectation_suite import ExpectationSuite

NOME_SUITE = "ouro_car__sinais_anomalia"

DETECTORES_CONHECIDOS = [
    "d1_fatiamento",
    "d2_incidencia_area_protegida",
    "d3_sobreposicao_car_car",
    "d4_geometria_improvavel",
    "d5_padrao_cadastral_atipico",
]


def construir_suite() -> ExpectationSuite:
    """Monta a suíte que garante auditabilidade de cada sinal."""
    contexto = gx.get_context()

    try:
        contexto.suites.delete(NOME_SUITE)
    except Exception:
        pass

    suite = contexto.suites.add(ExpectationSuite(name=NOME_SUITE))

    # Todo sinal aponta um imóvel existente e nomeia seu detector
    suite.add_expectation(gxe.ExpectColumnValuesToNotBeNull(column="cod_imovel"))
    suite.add_expectation(
        gxe.ExpectColumnValuesToBeInSet(
            column="detector", value_set=DETECTORES_CONHECIDOS
        )
    )

    # Rastreabilidade do método: sem regra, limiar e evidência não há triagem
    suite.add_expectation(gxe.ExpectColumnValuesToNotBeNull(column="regra_aplicada"))
    suite.add_expectation(gxe.ExpectColumnValuesToNotBeNull(column="limiares"))
    suite.add_expectation(gxe.ExpectColumnValuesToNotBeNull(column="evidencia"))
    suite.add_expectation(gxe.ExpectColumnValuesToNotBeNull(column="_hash_evidencia"))

    # Confiança, quando preenchida, é uma probabilidade
    suite.add_expectation(
        gxe.ExpectColumnValuesToBeBetween(
            column="confianca", min_value=0.0, max_value=1.0
        )
    )

    # Versionamento do detector: necessário para comparar precisão entre versões
    suite.add_expectation(
        gxe.ExpectColumnValuesToMatchRegex(
            column="versao_detector", regex=r"^\d+\.\d+\.\d+$"
        )
    )

    return suite


if __name__ == "__main__":
    construida = construir_suite()
    print(f"Suíte '{construida.name}' criada com "
          f"{len(construida.expectations)} expectativas.")
