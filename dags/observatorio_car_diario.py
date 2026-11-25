"""DAG do Observatório do Ciclo de Vida do CAR.

Fluxo medalhão em quatro etapas:

    bronze  -> ingestão fiel das fontes (shapefiles do Sicar, camadas de
               restrição, módulo fiscal, painel da regularização)
    prata   -> saneamento geométrico, tipagem e eventos de ciclo de vida
    ouro    -> métricas de gargalo e sinais de anomalia
    amostra -> sorteio reproduzível para auditoria manual

Idempotência: bronze insere com hash de linha; prata faz upsert por chave
natural; ouro usa delete+insert escopado na data de referência e ON CONFLICT
DO NOTHING nos sinais. Rodar duas vezes produz o mesmo estado.

A ingestão NÃO baixa arquivos automaticamente. O download público do Sicar é
disponibilizado por município com validação a cada requisição, e automatizar
a quebra dessa validação está fora de questão neste projeto. O operador
deposita os arquivos em dados_brutos/<fonte>/<uf>/ e o DAG consome de lá.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta

from airflow.decorators import dag, task, task_group
from airflow.providers.postgres.operators.postgres import PostgresOperator

from medalhao.config import DIR_DADOS, detectores_ativos, ufs_piloto
from medalhao.detectores import (
    executar_detector,
    executar_sql_parametrizado,
    sortear_amostra_validacao,
)
from medalhao.ingestao_geo import descobrir_arquivos, ingerir_camada_geo
from medalhao.ingestao_tabular import ingerir_csv_jsonb

CONN_BRONZE = "postgres_dados_bronze"
CONN_PRATA = "postgres_dados_prata"
CONN_OURO = "postgres_dados_ouro"

DEFAULT_ARGS = {
    "owner": "observatorio-car",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=30),
    "email_on_failure": False,
}


@dag(
    dag_id="observatorio_car_diario",
    description="Pipeline medalhão do Observatório do Ciclo de Vida do CAR",
    schedule="0 4 * * *",
    start_date=datetime(2026, 11, 1),
    catchup=False,
    max_active_runs=1,
    default_args=DEFAULT_ARGS,
    tags=["car", "sicar", "medalhao", "inovacar"],
    doc_md=__doc__,
)
def observatorio_car_diario():

    # -------------------------------------------------------------------------
    # BRONZE
    # -------------------------------------------------------------------------
    @task_group(group_id="bronze")
    def grupo_bronze():

        @task
        def ingerir_imoveis() -> list[dict]:
            """Shapefiles de perímetro de imóvel, por UF do recorte piloto."""
            resultados = []
            for uf in ufs_piloto():
                diretorio = DIR_DADOS / "sicar" / uf.lower()
                arquivos = [
                    arq for arq in descobrir_arquivos(diretorio)
                    if "AREA_IMOVEL" in arq.name.upper()
                ]
                if not arquivos:
                    raise FileNotFoundError(
                        f"Nenhum shapefile de área de imóvel em {diretorio}. "
                        "Baixe os municípios da UF e deposite os arquivos lá."
                    )
                for arquivo in arquivos:
                    resultados.append(
                        ingerir_camada_geo(
                            arquivo,
                            "bronze.sicar__area_imovel",
                            CONN_BRONZE,
                            colunas_extra={"uf": uf},
                            fonte="sicar_area_imovel",
                        )
                    )
            return resultados

        @task
        def ingerir_restricoes() -> list[dict]:
            """Camadas de restrição territorial, normalizadas por categoria."""
            mapa = {
                "embargos": "embargo",
                "unidades_conservacao": "unidade_conservacao",
                "terras_indigenas": "terra_indigena",
                "florestas_publicas": "floresta_publica",
            }
            resultados = []
            for pasta, categoria in mapa.items():
                for arquivo in descobrir_arquivos(DIR_DADOS / "restricoes" / pasta):
                    resultados.append(
                        ingerir_camada_geo(
                            arquivo,
                            "bronze.restricoes__areas",
                            CONN_BRONZE,
                            colunas_extra={"fonte": pasta, "categoria": categoria},
                            fonte=pasta,
                        )
                    )
            return resultados

        @task
        def ingerir_referencias() -> list[dict]:
            """Malha municipal do IBGE e módulo fiscal do Incra."""
            resultados = []
            for arquivo in descobrir_arquivos(DIR_DADOS / "ibge"):
                resultados.append(
                    ingerir_camada_geo(
                        arquivo,
                        "bronze.ibge__municipios",
                        CONN_BRONZE,
                        fonte="ibge_municipios",
                    )
                )
            for arquivo in descobrir_arquivos(DIR_DADOS / "incra", padrao="*.csv"):
                resultados.append(
                    ingerir_csv_jsonb(
                        arquivo,
                        "bronze.incra__modulo_fiscal",
                        CONN_BRONZE,
                        fonte="incra_modulo_fiscal",
                    )
                )
            return resultados

        [ingerir_imoveis(), ingerir_restricoes(), ingerir_referencias()]

    # -------------------------------------------------------------------------
    # PRATA
    # -------------------------------------------------------------------------
    @task_group(group_id="prata")
    def grupo_prata():
        referencias = PostgresOperator(
            task_id="referencias",
            postgres_conn_id=CONN_PRATA,
            sql="prata/01_referencias.sql",
        )
        imoveis = PostgresOperator(
            task_id="imoveis",
            postgres_conn_id=CONN_PRATA,
            sql="prata/02_imoveis.sql",
        )
        eventos = PostgresOperator(
            task_id="eventos_ciclo_vida",
            postgres_conn_id=CONN_PRATA,
            sql="prata/03_eventos_ciclo_vida.sql",
        )
        referencias >> imoveis >> eventos

    # -------------------------------------------------------------------------
    # OURO
    # -------------------------------------------------------------------------
    @task_group(group_id="ouro")
    def grupo_ouro():

        @task
        def gargalos(ds: str | None = None) -> int:
            """Linha do tempo de gargalos por etapa, UF e faixa de tamanho."""
            return executar_sql_parametrizado(
                "ouro/02_gargalos.sql",
                CONN_OURO,
                {"data_referencia": ds, "execucao_id": str(uuid.uuid4())},
            )

        @task
        def detectar(nome_detector: str) -> dict:
            """Roda um detector com os limiares de contracts/detectores.yml."""
            return executar_detector(nome_detector, CONN_OURO)

        @task
        def amostrar() -> int:
            """Sorteia a amostra reproduzível para auditoria manual."""
            return sortear_amostra_validacao(CONN_OURO)

        # Um task por detector dá observabilidade individual, mas com
        # concorrência 1: d3 (sobreposição CAR x CAR) é a consulta mais
        # pesada do pipeline e competir por I/O só aumenta o tempo total.
        sinais = detectar.override(
            max_active_tis_per_dagrun=1
        ).expand(nome_detector=sorted(detectores_ativos()))
        gargalos() >> sinais >> amostrar()

    grupo_bronze() >> grupo_prata() >> grupo_ouro()


observatorio_car_diario()
