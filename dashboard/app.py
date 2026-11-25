"""Observatório do Ciclo de Vida do CAR — interface de leitura da camada ouro.

Três visões, nesta ordem de importância:

  1. Linha do tempo de gargalos — onde a regularização está travando.
     É a lacuna nomeada no briefing do Desafio 3 do InovaCAR e o que a
     plataforma pública de consulta não oferece hoje.
  2. Fila de triagem — sinais com evidência, para o analista decidir.
  3. Precisão dos detectores — quanto cada regra acerta, medido em auditoria
     manual. Sem esta tela o resto é ruído estatístico.

Conecta com o usuário bi_leitura, que só tem SELECT em ouro. A interface não
escreve no banco exceto o desfecho da triagem, que é a razão de existir da
tabela ouro.car__triagem_desfecho.

ATENÇÃO (T-11): este é o esqueleto funcional. O refino visual é tarefa
separada — o default do Streamlit denuncia protótipo improvisado, e o vídeo
de 3 minutos da inscrição mostra esta tela.
"""
from __future__ import annotations

import os

import pandas as pd
import streamlit as st
from sqlalchemy import create_engine, text

TITULO = "Observatório do Ciclo de Vida do CAR"

ROTULO_ETAPA = {
    "inscricao": "Inscrição",
    "analise": "Análise",
    "notificacao": "Notificação",
    "retificacao": "Retificação",
    "validacao": "Validação",
    "pra": "PRA",
}

ROTULO_FAIXA = {
    "ate_1_modulo": "Até 1 módulo fiscal",
    "de_1_a_4_modulos": "1 a 4 módulos fiscais",
    "de_4_a_15_modulos": "4 a 15 módulos fiscais",
    "acima_de_15_modulos": "Acima de 15 módulos",
    "indefinido": "Módulo fiscal indisponível",
}

ROTULO_DESFECHO = {
    "procede": "Procede — merece verificação",
    "nao_procede": "Não procede — sinal falso",
    "inconclusivo": "Inconclusivo — falta informação",
}


@st.cache_resource
def obter_engine():
    """Conexão com a camada ouro, usuário somente leitura."""
    usuario = os.environ.get("OBSERVATORIO_DB_USER", "bi_leitura")
    senha = os.environ.get("OBSERVATORIO_DB_PASSWORD", "bi_leitura_dev")
    host = os.environ.get("OBSERVATORIO_DB_HOST", "localhost")
    porta = os.environ.get("OBSERVATORIO_DB_PORT", "5432")
    banco = os.environ.get("OBSERVATORIO_DB_NAME", "dados")
    return create_engine(
        f"postgresql+psycopg2://{usuario}:{senha}@{host}:{porta}/{banco}",
        pool_pre_ping=True,
    )


@st.cache_data(ttl=300)
def consultar(sql: str, parametros: dict | None = None) -> pd.DataFrame:
    """Executa uma consulta e devolve DataFrame, com cache de 5 minutos."""
    with obter_engine().connect() as conexao:
        return pd.read_sql(text(sql), conexao, params=parametros or {})


def visao_gargalos() -> None:
    """Onde a regularização está travando, por etapa e faixa de tamanho."""
    st.subheader("Onde a regularização está travando")

    dados = consultar(
        """
        SELECT uf, etapa, faixa_tamanho,
               SUM(imoveis_na_etapa)                    AS imoveis,
               SUM(area_na_etapa_ha)                    AS area_ha,
               MAX(dias_mediano_na_etapa)               AS dias_mediano,
               MAX(dias_p90_na_etapa)                   AS dias_p90,
               MIN(pct_com_data_confiavel)              AS pct_confiavel
        FROM ouro.car__gargalos_etapa
        WHERE data_referencia = (
            SELECT MAX(data_referencia) FROM ouro.car__gargalos_etapa
        )
        GROUP BY uf, etapa, faixa_tamanho
        ORDER BY imoveis DESC
        """
    )

    if dados.empty:
        st.info(
            "Sem dados de gargalo ainda. Rode o DAG `observatorio_car_diario` "
            "no Airflow (http://localhost:8080) após depositar os arquivos "
            "das fontes em `dados_brutos/`."
        )
        return

    colunas = st.columns(3)
    colunas[0].metric("Imóveis represados", f"{int(dados['imoveis'].sum()):,}"
                      .replace(",", "."))
    etapa_critica = dados.groupby("etapa")["imoveis"].sum().idxmax()
    colunas[1].metric("Etapa mais represada",
                      ROTULO_ETAPA.get(etapa_critica, etapa_critica))
    colunas[2].metric("Dias medianos (p90)",
                      f"{dados['dias_mediano'].median():.0f} "
                      f"({dados['dias_p90'].max():.0f})")

    # Transparência de qualidade: mediana sobre data derivada engana
    confiavel_min = dados["pct_confiavel"].min()
    if pd.notna(confiavel_min) and confiavel_min < 50:
        st.warning(
            f"Parte das etapas tem menos de 50% de marcos temporais vindos "
            f"direto da fonte (mínimo observado: {confiavel_min:.0f}%). "
            "As medianas de dias nessas linhas são estimativas frágeis, não "
            "medições — veja a coluna de confiabilidade na tabela."
        )

    dados["etapa"] = dados["etapa"].map(lambda e: ROTULO_ETAPA.get(e, e))
    dados["faixa_tamanho"] = dados["faixa_tamanho"].map(
        lambda f: ROTULO_FAIXA.get(f, f)
    )

    st.bar_chart(
        dados.pivot_table(
            index="etapa", columns="faixa_tamanho",
            values="imoveis", aggfunc="sum",
        ),
        height=320,
    )

    st.dataframe(
        dados.rename(columns={
            "uf": "UF", "etapa": "Etapa", "faixa_tamanho": "Faixa",
            "imoveis": "Imóveis", "area_ha": "Área (ha)",
            "dias_mediano": "Dias (mediana)", "dias_p90": "Dias (p90)",
            "pct_confiavel": "% com data da fonte",
        }),
        use_container_width=True, hide_index=True,
    )


def visao_triagem() -> None:
    """Fila de sinais com evidência, e registro do desfecho da verificação."""
    st.subheader("Fila de triagem")
    st.caption(
        "Cada item é uma hipótese com evidência, não uma conclusão. "
        "A decisão é do analista."
    )

    detectores = consultar(
        "SELECT DISTINCT detector FROM ouro.car__sinais_anomalia ORDER BY 1"
    )
    if detectores.empty:
        st.info("Nenhum sinal gerado ainda.")
        return

    escolhido = st.selectbox("Detector", detectores["detector"])

    fila = consultar(
        """
        SELECT sinal_id, cod_imovel, uf, cod_municipio,
               regra_aplicada, evidencia, desfecho
        FROM ouro.car__fila_auditoria
        WHERE detector = :detector
        ORDER BY ordem_na_amostra
        LIMIT 200
        """,
        {"detector": escolhido},
    )

    if fila.empty:
        st.info(
            "Sinais existem, mas a amostra de auditoria ainda não foi "
            "sorteada para este detector."
        )
        return

    pendentes = int(fila["desfecho"].isna().sum())
    st.metric("Pendentes de verificação", pendentes)

    for _, linha in fila.iterrows():
        rotulo = f"{linha['cod_imovel']} — {linha['regra_aplicada'][:90]}"
        with st.expander(rotulo, expanded=False):
            st.json(linha["evidencia"])
            if pd.notna(linha["desfecho"]):
                st.success(
                    f"Já verificado: "
                    f"{ROTULO_DESFECHO.get(linha['desfecho'], linha['desfecho'])}"
                )
            else:
                st.caption(
                    "Registro do desfecho pela interface: tarefa T-10. "
                    "Até lá, a auditoria é registrada por SQL em "
                    "ouro.car__triagem_desfecho."
                )


def visao_precisao() -> None:
    """Quanto cada detector acerta, medido — não estimado."""
    st.subheader("Precisão medida por detector")
    st.caption(
        "Calculada apenas sobre sinais efetivamente auditados por uma pessoa. "
        "Inconclusivos ficam fora do denominador."
    )

    dados = consultar("SELECT * FROM ouro.car__precisao_detector ORDER BY detector")

    if dados.empty:
        st.warning(
            "Nenhum detector tem precisão medida ainda. Enquanto este quadro "
            "estiver vazio, a ferramenta não deve ser apresentada com números "
            "de acerto — nem no vídeo da inscrição."
        )
        return

    st.dataframe(
        dados.rename(columns={
            "detector": "Detector", "versao_detector": "Versão",
            "sinais_auditados": "Auditados", "procedem": "Procedem",
            "nao_procedem": "Não procedem", "inconclusivos": "Inconclusivos",
            "precisao": "Precisão",
        }),
        use_container_width=True, hide_index=True,
    )


def main() -> None:
    st.set_page_config(page_title=TITULO, page_icon="🗺️", layout="wide")
    st.title(TITULO)
    st.caption(
        "Sinais para triagem a partir de dados públicos do CAR. "
        "Nenhum dado pessoal é processado ou exibido."
    )

    aba_gargalos, aba_triagem, aba_precisao = st.tabs(
        ["Gargalos", "Triagem", "Precisão"]
    )
    with aba_gargalos:
        visao_gargalos()
    with aba_triagem:
        visao_triagem()
    with aba_precisao:
        visao_precisao()


if __name__ == "__main__":
    main()
