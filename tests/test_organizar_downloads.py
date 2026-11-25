"""Testes do organizador de downloads brutos (scripts/organizar_downloads.py).

Rodam sem rede e sem banco: montam uma pasta de downloads de mentira com um
zip real em tmp_path, rodam o organizador e conferem o resultado — árvore
preenchida, hash correto, inventário coerente e idempotente.

É o teste que protege a procedência: se o roteamento por fonte, o hash ou a
extração segura quebrarem, um dado entra na bronze sem rastro ou no lugar
errado, e o critério de aceite da T-03 deixa de valer.

    pytest tests/test_organizar_downloads.py -v
"""
from __future__ import annotations

import hashlib
import io
import sys
import zipfile
from pathlib import Path

import pytest
import yaml

RAIZ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ / "scripts"))

import organizar_downloads as org  # noqa: E402


# ---------------------------------------------------------------------------
# Auxiliares de montagem
# ---------------------------------------------------------------------------

def _zip_com(arquivos: dict[str, bytes]) -> bytes:
    """Devolve os bytes de um zip contendo os pares nome->conteúdo dados."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as zf:
        for nome, conteudo in arquivos.items():
            zf.writestr(nome, conteudo)
    return buffer.getvalue()


def _escrever(caminho: Path, conteudo: bytes) -> Path:
    caminho.parent.mkdir(parents=True, exist_ok=True)
    caminho.write_bytes(conteudo)
    return caminho


# ---------------------------------------------------------------------------
# Hash
# ---------------------------------------------------------------------------

def test_calcular_sha256_bate_com_hashlib(tmp_path: Path) -> None:
    conteudo = b"perimetro do imovel declarado\n" * 1000
    arq = _escrever(tmp_path / "x.bin", conteudo)
    assert org.calcular_sha256(arq) == hashlib.sha256(conteudo).hexdigest()


# ---------------------------------------------------------------------------
# Roteamento
# ---------------------------------------------------------------------------

def test_rota_sicar_usa_subpasta_da_uf(tmp_path: Path) -> None:
    destino = org.resolver_destino("sicar_area_imovel", "PA", tmp_path)
    assert destino == tmp_path / "sicar" / "pa"


def test_rota_restricao_ignora_uf(tmp_path: Path) -> None:
    destino = org.resolver_destino("ibama_embargos", None, tmp_path)
    assert destino == tmp_path / "restricoes" / "embargos"


def test_fonte_desconhecida_falha(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="sem rota"):
        org.resolver_destino("fonte_que_nao_existe", None, tmp_path)


def test_sicar_sem_uf_falha(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="UF"):
        org.resolver_destino("sicar_area_imovel", None, tmp_path)


def test_toda_rota_existe_no_contrato_de_fontes() -> None:
    """Regra de projeto: não inventar fonte. Toda chave de ROTAS tem de estar
    declarada em contracts/fontes.yml."""
    with (RAIZ / "contracts" / "fontes.yml").open(encoding="utf-8") as arq:
        fontes = set(yaml.safe_load(arq)["fontes"])
    assert set(org.ROTAS) <= fontes, (
        f"ROTAS referencia fonte não declarada: {set(org.ROTAS) - fontes}"
    )


# ---------------------------------------------------------------------------
# Extração segura
# ---------------------------------------------------------------------------

def test_extrair_zip_normal(tmp_path: Path) -> None:
    zip_path = _escrever(
        tmp_path / "dl" / "mun.zip",
        _zip_com({"AREA_IMOVEL.shp": b"geom", "AREA_IMOVEL.dbf": b"attr"}),
    )
    destino = tmp_path / "arvore" / "sicar" / "pa"
    extraidos = org.extrair_zip_seguro(zip_path, destino)
    assert (destino / "AREA_IMOVEL.shp").read_bytes() == b"geom"
    assert {p.name for p in extraidos} == {"AREA_IMOVEL.shp", "AREA_IMOVEL.dbf"}


def test_extrair_zip_slip_e_bloqueado(tmp_path: Path) -> None:
    """Um zip malicioso com '../' não pode escapar do destino."""
    zip_path = _escrever(
        tmp_path / "dl" / "mau.zip",
        _zip_com({"../../fora.txt": b"invasao"}),
    )
    destino = tmp_path / "arvore" / "ibge"
    with pytest.raises(ValueError, match="fora do destino|inseguro"):
        org.extrair_zip_seguro(zip_path, destino)
    assert not (tmp_path / "fora.txt").exists()


# ---------------------------------------------------------------------------
# Fluxo completo
# ---------------------------------------------------------------------------

def _cenario(tmp_path: Path) -> tuple[Path, Path, Path]:
    """Monta downloads/ com dois artefatos e um manifesto; devolve
    (pasta_downloads, manifesto, raiz_dados)."""
    downloads = tmp_path / "downloads"
    raiz_dados = tmp_path / "dados_brutos"
    bytes_sicar = _zip_com({"AREA_IMOVEL.shp": b"poligonos", "leia.prj": b"4674"})
    _escrever(downloads / "sicar_pa_0001.zip", bytes_sicar)
    _escrever(downloads / "modulo_fiscal.csv", b"municipio;modulo_ha\nBelem;75\n")
    manifesto = downloads / "manifesto.yml"
    manifesto.write_text(
        yaml.safe_dump(
            {
                "downloads": [
                    {
                        "arquivo": "sicar_pa_0001.zip",
                        "fonte": "sicar_area_imovel",
                        "uf": "PA",
                        "url": "https://consultapublica.car.gov.br/publico/",
                        "data_download": "2026-11-25",
                    },
                    {
                        "arquivo": "modulo_fiscal.csv",
                        "fonte": "incra_modulo_fiscal",
                        "url": "https://www.gov.br/incra/",
                        "data_download": "2026-11-25",
                    },
                ]
            },
            allow_unicode=True,
        ),
        encoding="utf-8",
    )
    return downloads, manifesto, raiz_dados


def test_processar_preenche_arvore_e_inventario(tmp_path: Path) -> None:
    downloads, manifesto, raiz_dados = _cenario(tmp_path)
    registros = org.processar(downloads, manifesto, raiz_dados)

    # Zip extraído numa subpasta própria (evita colisão entre municípios);
    # CSV copiado direto na pasta da fonte.
    shp = raiz_dados / "sicar" / "pa" / "sicar_pa_0001" / "AREA_IMOVEL.shp"
    assert shp.read_bytes() == b"poligonos"
    assert (raiz_dados / "incra" / "modulo_fiscal.csv").exists()

    por_arquivo = {r["arquivo"]: r for r in registros}
    r = por_arquivo["sicar_pa_0001.zip"]
    assert r["fonte"] == "sicar_area_imovel"
    assert r["uf"] == "PA"
    assert r["data_download"] == "2026-11-25"
    esperado = hashlib.sha256((downloads / "sicar_pa_0001.zip").read_bytes()).hexdigest()
    assert r["sha256"] == esperado
    assert int(r["bytes"]) == (downloads / "sicar_pa_0001.zip").stat().st_size


def test_inventario_csv_escrito_e_idempotente(tmp_path: Path) -> None:
    downloads, manifesto, raiz_dados = _cenario(tmp_path)
    csv_saida = raiz_dados / "INVENTARIO.csv"

    org.processar(downloads, manifesto, raiz_dados, caminho_inventario=csv_saida)
    primeiro = csv_saida.read_text(encoding="utf-8")
    # Cabeçalho exigido pelo critério de aceite
    cabecalho = primeiro.splitlines()[0]
    for col in ("arquivo", "fonte", "uf", "bytes", "sha256", "data_download"):
        assert col in cabecalho

    # Rodar de novo produz exatamente o mesmo inventário (idempotência)
    org.processar(downloads, manifesto, raiz_dados, caminho_inventario=csv_saida)
    assert csv_saida.read_text(encoding="utf-8") == primeiro


def test_dois_municipios_sicar_nao_colidem(tmp_path: Path) -> None:
    """Dois zips do Sicar com o MESMO nome interno (AREA_IMOVEL.shp) não podem
    se sobrescrever: cada um vai para a sua subpasta."""
    downloads = tmp_path / "downloads"
    raiz_dados = tmp_path / "dados_brutos"
    _escrever(downloads / "mun_a.zip", _zip_com({"AREA_IMOVEL.shp": b"A"}))
    _escrever(downloads / "mun_b.zip", _zip_com({"AREA_IMOVEL.shp": b"B"}))
    manifesto = downloads / "manifesto.yml"
    manifesto.write_text(
        yaml.safe_dump(
            {
                "downloads": [
                    {"arquivo": "mun_a.zip", "fonte": "sicar_area_imovel", "uf": "PA"},
                    {"arquivo": "mun_b.zip", "fonte": "sicar_area_imovel", "uf": "PA"},
                ]
            }
        ),
        encoding="utf-8",
    )
    org.processar(downloads, manifesto, raiz_dados)
    assert (raiz_dados / "sicar" / "pa" / "mun_a" / "AREA_IMOVEL.shp").read_bytes() == b"A"
    assert (raiz_dados / "sicar" / "pa" / "mun_b" / "AREA_IMOVEL.shp").read_bytes() == b"B"


def test_manifesto_com_fonte_nao_declarada_falha(tmp_path: Path) -> None:
    downloads = tmp_path / "downloads"
    raiz_dados = tmp_path / "dados_brutos"
    _escrever(downloads / "qualquer.zip", _zip_com({"a.txt": b"x"}))
    manifesto = downloads / "manifesto.yml"
    manifesto.write_text(
        yaml.safe_dump(
            {"downloads": [{"arquivo": "qualquer.zip", "fonte": "inventada"}]}
        ),
        encoding="utf-8",
    )
    with pytest.raises(ValueError):
        org.processar(downloads, manifesto, raiz_dados)
