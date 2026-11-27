"""Configuração de testes do projeto.

Põe `plugins/` no sys.path para que os testes possam importar `medalhao.*`
sem Airflow — do mesmo jeito que o Airflow expõe a pasta de plugins em tempo
de execução. Só módulos de dependências leves (stdlib) são importáveis assim;
`ingestao_geo`/`ingestao_tabular` puxam Airflow e psycopg2 e seguem fora do
alcance dos testes de contrato, por isso a lógica testável mora em módulos
sem dependência pesada (ex.: `medalhao.descoberta`).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "plugins"))
