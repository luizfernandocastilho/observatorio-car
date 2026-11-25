"""Módulos do pipeline medalhão do Observatório do CAR.

Organização:
    config            — leitura dos contratos YAML (fontes e limiares)
    ingestao_geo      — camadas vetoriais (shapefile, GeoPackage) -> bronze
    ingestao_tabular  — CSV -> bronze com atributos em JSONB
    detectores        — execução parametrizada dos detectores e cargas ouro

A lógica de negócio mora aqui, não no DAG: o DAG orquestra, estes módulos são
testáveis sem Airflow rodando.
"""
