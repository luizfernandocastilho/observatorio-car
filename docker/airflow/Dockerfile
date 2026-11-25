FROM apache/airflow:2.9.3-python3.11

COPY requirements.txt /tmp/requirements-observatorio.txt

USER airflow
# --timeout e --retries porque wheels grandes (pyogrio tem 22 MB) estouram
# o limite padrão em conexões lentas.
RUN pip install --no-cache-dir \
      --timeout 120 --retries 10 \
      -r /tmp/requirements-observatorio.txt \
      --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-2.9.3/constraints-3.11.txt"
