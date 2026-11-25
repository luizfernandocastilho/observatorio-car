# =============================================================================
# Observatório do Ciclo de Vida do CAR
# =============================================================================
SHELL := /bin/bash
COMPOSE := docker compose
PSQL := $(COMPOSE) exec -T postgres-dados psql -U etl_admin -d dados

.DEFAULT_GOAL := ajuda
.PHONY: ajuda up down logs ps testar psql suites verificar-idempotencia \
        reset-ouro limpar

ajuda:  ## Lista os comandos disponíveis
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}'

up:  ## Sobe PostGIS, Airflow e dashboard
	@test -f .env || (echo "Crie o .env: cp .env.example .env" && exit 1)
	$(COMPOSE) up -d
	@echo ""
	@echo "Dashboard: http://localhost:8502"
	@echo "Airflow:   http://localhost:8088  (airflow/airflow)"

down:  ## Derruba os serviços preservando os volumes
	$(COMPOSE) down

ps:  ## Status dos serviços
	$(COMPOSE) ps

logs:  ## Logs do scheduler do Airflow
	$(COMPOSE) logs -f airflow-scheduler

psql:  ## Abre um psql no banco de dados
	$(COMPOSE) exec postgres-dados psql -U etl_admin -d dados

testar:  ## Testes de contrato (não precisam de banco)
	python3 -m pytest tests/ -v

suites:  ## (Re)cria as suítes Great Expectations
	python3 great_expectations/expectations/suite_prata_imoveis.py
	python3 great_expectations/expectations/suite_ouro_sinais.py

verificar-idempotencia:  ## Roda prata+ouro duas vezes e compara o estado
	@echo "== Primeira execução =="
	@$(MAKE) --no-print-directory _rodar-camadas
	@$(PSQL) -At -c "SELECT md5(string_agg(t, '|' ORDER BY t)) FROM ( \
		SELECT cod_imovel || detector || _hash_evidencia AS t \
		FROM ouro.car__sinais_anomalia) s" > /tmp/obs_hash_1
	@echo "== Segunda execução =="
	@$(MAKE) --no-print-directory _rodar-camadas
	@$(PSQL) -At -c "SELECT md5(string_agg(t, '|' ORDER BY t)) FROM ( \
		SELECT cod_imovel || detector || _hash_evidencia AS t \
		FROM ouro.car__sinais_anomalia) s" > /tmp/obs_hash_2
	@if diff -q /tmp/obs_hash_1 /tmp/obs_hash_2 > /dev/null; then \
		echo "OK: estado idêntico nas duas execuções"; \
	else \
		echo "FALHA: o pipeline não é idempotente"; exit 1; \
	fi

_rodar-camadas:
	@$(PSQL) -f /sql/prata/01_referencias.sql > /dev/null
	@$(PSQL) -f /sql/prata/02_imoveis.sql > /dev/null
	@$(PSQL) -f /sql/prata/03_eventos_ciclo_vida.sql > /dev/null
	@$(COMPOSE) exec -T airflow-scheduler python -c \
		"from medalhao.detectores import executar_todos_detectores; \
		 print(executar_todos_detectores('postgres_dados_ouro'))"

reset-ouro:  ## Limpa a camada ouro preservando bronze e prata
	$(PSQL) -c "TRUNCATE ouro.car__sinais_anomalia CASCADE;"
	$(PSQL) -c "TRUNCATE ouro.car__gargalos_etapa;"
	@echo "Camada ouro limpa. Bronze e prata preservadas."

limpar:  ## Derruba tudo e APAGA os volumes (perde o banco)
	$(COMPOSE) down -v
