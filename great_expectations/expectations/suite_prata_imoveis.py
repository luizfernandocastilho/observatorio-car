"""Suíte Great Expectations da camada PRATA — prata.car__imoveis.

A prata é onde as regras de qualidade mordem. O que esta suíte protege:

  - cod_imovel único e não nulo (é a chave de tudo no observatório)
  - geometria presente e área positiva
  - compacidade dentro do intervalo matematicamente possível (0 a 1)
  - fração aceitável de imóveis sem módulo fiscal — acima disso o detector
    de fatiamento perde sentido e o pipeline deve falhar, não seguir

Rodar uma vez para criar/atualizar a suíte:
    python great_expectations/expectations/suite_prata_imoveis.py
"""
from __future__ import annotations

import great_expectations as gx
from great_expectations import expectations as gxe
from great_expectations.core.expectation_suite import ExpectationSuite

NOME_SUITE = "prata_car__imoveis"

COLUNAS_ESPERADAS = [
    "cod_imovel", "uf", "cod_municipio", "nome_municipio",
    "area_declarada_ha", "tipo_imovel", "condicao_cadastro", "status_cadastro",
    "data_inscricao", "data_ultima_retificacao",
    "geom", "geom_era_invalida", "area_calculada_ha", "perimetro_m",
    "compacidade", "modulos_fiscais", "divergencia_area_pct",
    "_hash_linha", "_processamento_id", "_processamento_timestamp",
    "_versao_registro", "_valido_de", "_valido_ate",
]


def construir_suite() -> ExpectationSuite:
    """Monta a suíte de qualidade da tabela central do observatório."""
    contexto = gx.get_context()

    try:
        contexto.suites.delete(NOME_SUITE)
    except Exception:
        pass

    suite = contexto.suites.add(ExpectationSuite(name=NOME_SUITE))

    # A carga não pode estar vazia
    suite.add_expectation(
        gxe.ExpectTableRowCountToBeBetween(min_value=1)
    )

    # Estrutura
    suite.add_expectation(
        gxe.ExpectTableColumnsToMatchSet(column_set=COLUNAS_ESPERADAS)
    )

    # Chave natural
    suite.add_expectation(gxe.ExpectColumnValuesToNotBeNull(column="cod_imovel"))
    suite.add_expectation(gxe.ExpectColumnValuesToBeUnique(column="cod_imovel"))

    # Geometria e área
    suite.add_expectation(gxe.ExpectColumnValuesToNotBeNull(column="geom"))
    suite.add_expectation(
        gxe.ExpectColumnValuesToBeBetween(
            column="area_calculada_ha", min_value=0.0001, max_value=5_000_000.0
        )
    )

    # Compacidade: Polsby-Popper é matematicamente limitado a (0, 1].
    # Valor fora disso significa erro de cálculo, não imóvel estranho.
    suite.add_expectation(
        gxe.ExpectColumnValuesToBeBetween(
            column="compacidade", min_value=0.0, max_value=1.0, mostly=0.999
        )
    )

    # UF dentro do recorte piloto declarado no contrato
    suite.add_expectation(
        gxe.ExpectColumnValueLengthsToEqual(column="uf", value=2)
    )

    # Cobertura de módulo fiscal: sem ele o detector d1 não existe.
    # 80% é o piso aceitável; abaixo disso é falha de join com o Incra.
    suite.add_expectation(
        gxe.ExpectColumnValuesToNotBeNull(column="modulos_fiscais", mostly=0.80)
    )

    return suite


if __name__ == "__main__":
    construida = construir_suite()
    print(f"Suíte '{construida.name}' criada com "
          f"{len(construida.expectations)} expectativas.")
