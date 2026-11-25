"""Organiza os downloads brutos das fontes na árvore `dados_brutos/`.

Tarefa T-03. Recebe uma pasta com os arquivos como vieram da fonte (zips do
Sicar por município, shapefiles das restrições, CSV do Incra, etc.) e, guiado
por um **manifesto**, deposita cada um no lugar certo da árvore, calcula o
SHA-256 e registra tudo em `dados_brutos/INVENTARIO.csv`.

Por que um manifesto, e não adivinhação pelo nome do arquivo:
    A regra 9 do CLAUDE.md proíbe automatizar a quebra da validação por
    requisição do Sicar — o download é manual. E o projeto não inventa
    procedência: de qual fonte e de qual UF veio cada zip é uma decisão do
    operador, registrada de forma explícita e auditável no manifesto, não
    deduzida de um padrão frágil de nome de arquivo. O manifesto carrega ainda
    a URL e a data de cada download, que é o que o critério de aceite pede para
    alimentar `contracts/fontes.yml`.

Segurança: os arquivos baixados são dados não confiáveis. A extração dos zips
é feita com guarda contra *zip-slip* (entradas com `..` que escapariam da
pasta de destino). Nada é executado a partir deles.

Uso:
    python scripts/organizar_downloads.py --downloads <pasta_com_os_zips>

    # manifesto é, por padrão, <pasta_com_os_zips>/manifesto.yml
    # veja o modelo em scripts/manifesto_downloads.exemplo.yml

NÃO baixa nada automaticamente do Sicar. Para as fontes de download aberto e
direto (IBGE, dados abertos do Ibama, dados.florestal.gov.br) a automação do
download é permitida, mas depende de fixar a URL exata do arquivo em
`contracts/fontes.yml` primeiro — enquanto isso não existe, baixe manualmente e
descreva no manifesto.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import shutil
import sys
import zipfile
from pathlib import Path
from typing import Any

import yaml

RAIZ_PROJETO = Path(__file__).resolve().parent.parent

# Roteamento fonte -> subpasta dentro de dados_brutos/. `{uf}` é preenchido com
# a UF em minúsculas. Toda chave aqui PRECISA existir em contracts/fontes.yml
# (garantido por tests/test_organizar_downloads.py).
ROTAS: dict[str, str] = {
    "sicar_area_imovel": "sicar/{uf}",
    "sicar_app": "sicar/{uf}",
    "sicar_area_consolidada": "sicar/{uf}",
    "sicar_reserva_legal": "sicar/{uf}",
    "ibama_embargos": "restricoes/embargos",
    "mma_unidades_conservacao": "restricoes/unidades_conservacao",
    "funai_terras_indigenas": "restricoes/terras_indigenas",
    "sfb_florestas_publicas": "restricoes/florestas_publicas",
    "ibge_municipios": "ibge",
    "incra_modulo_fiscal": "incra",
}

# Cabeçalho do inventário. A ordem é fixa para que o CSV seja determinístico.
CAMPOS_INVENTARIO = [
    "arquivo",
    "fonte",
    "uf",
    "bytes",
    "sha256",
    "data_download",
    "url",
    "destino",
]


def calcular_sha256(caminho: Path, bloco: int = 1 << 20) -> str:
    """Calcula o SHA-256 de um arquivo, lendo em blocos para não carregar tudo
    na memória (shapefiles e zips de município passam de centenas de MB).

    Args:
        caminho: Arquivo a ler.
        bloco: Tamanho do bloco de leitura em bytes.

    Returns:
        Hash SHA-256 em hexadecimal.
    """
    h = hashlib.sha256()
    with Path(caminho).open("rb") as arq:
        for pedaco in iter(lambda: arq.read(bloco), b""):
            h.update(pedaco)
    return h.hexdigest()


def resolver_destino(fonte: str, uf: str | None, raiz_dados: Path) -> Path:
    """Decide em que pasta de `dados_brutos/` o artefato de uma fonte entra.

    Args:
        fonte: Chave da fonte (precisa estar em ROTAS e em fontes.yml).
        uf: Sigla da UF, obrigatória para as fontes do Sicar.
        raiz_dados: Raiz da árvore (ex: `dados_brutos/`).

    Returns:
        Caminho da subpasta de destino.

    Raises:
        ValueError: Fonte sem rota, ou fonte que exige UF e não a recebeu.
    """
    try:
        template = ROTAS[fonte]
    except KeyError:
        raise ValueError(
            f"Fonte '{fonte}' sem rota definida em ROTAS. "
            f"Rotas conhecidas: {sorted(ROTAS)}."
        ) from None
    if "{uf}" in template:
        if not uf:
            raise ValueError(
                f"A fonte '{fonte}' exige a UF para rotear o arquivo, "
                "mas o manifesto não a informou."
            )
        template = template.format(uf=uf.lower())
    return raiz_dados / template


def extrair_zip_seguro(caminho_zip: Path, destino: Path) -> list[Path]:
    """Extrai um zip em `destino` barrando entradas que escapariam da pasta.

    Os arquivos baixados são dados não confiáveis; um zip malicioso pode conter
    entradas com `..` ou caminho absoluto (ataque *zip-slip*). Toda entrada é
    validada antes de ser escrita.

    Args:
        caminho_zip: Zip a extrair.
        destino: Pasta onde o conteúdo deve ficar.

    Returns:
        Lista dos arquivos efetivamente extraídos.

    Raises:
        ValueError: Alguma entrada apontaria para fora de `destino`.
    """
    destino = Path(destino)
    destino.mkdir(parents=True, exist_ok=True)
    destino_resolvido = destino.resolve()
    extraidos: list[Path] = []
    with zipfile.ZipFile(caminho_zip) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            alvo = (destino / info.filename).resolve()
            if alvo != destino_resolvido and destino_resolvido not in alvo.parents:
                raise ValueError(
                    f"Entrada '{info.filename}' aponta para fora do destino "
                    f"(zip inseguro): {caminho_zip}"
                )
            alvo.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as origem, alvo.open("wb") as saida:
                shutil.copyfileobj(origem, saida)
            extraidos.append(alvo)
    return extraidos


def carregar_manifesto(caminho: Path) -> list[dict[str, Any]]:
    """Lê o manifesto YAML e devolve a lista de downloads declarados.

    Raises:
        FileNotFoundError: Manifesto inexistente.
        ValueError: Sem a lista `downloads`, ou entrada sem `arquivo`/`fonte`.
    """
    caminho = Path(caminho)
    if not caminho.exists():
        raise FileNotFoundError(
            f"Manifesto não encontrado: {caminho}. "
            "Veja o modelo em scripts/manifesto_downloads.exemplo.yml."
        )
    with caminho.open(encoding="utf-8") as arq:
        dados = yaml.safe_load(arq) or {}
    entradas = dados.get("downloads")
    if not entradas:
        raise ValueError(f"Manifesto {caminho} não tem a lista 'downloads'.")
    for entrada in entradas:
        if "arquivo" not in entrada or "fonte" not in entrada:
            raise ValueError(
                f"Entrada de manifesto precisa de 'arquivo' e 'fonte': {entrada}"
            )
    return entradas


def _fontes_e_ufs(raiz_projeto: Path) -> tuple[set[str], set[str]]:
    """Fontes declaradas e UFs piloto, lidos de contracts/fontes.yml."""
    caminho = raiz_projeto / "contracts" / "fontes.yml"
    with caminho.open(encoding="utf-8") as arq:
        contrato = yaml.safe_load(arq)
    return set(contrato.get("fontes", {})), {
        uf.upper() for uf in contrato.get("ufs_piloto", [])
    }


def processar(
    pasta_downloads: Path,
    manifesto: Path,
    raiz_dados: Path,
    *,
    caminho_inventario: Path | None = None,
    raiz_projeto: Path | None = None,
    dry_run: bool = False,
) -> list[dict[str, Any]]:
    """Processa todos os downloads do manifesto: roteia, extrai, calcula hash.

    Idempotente: rodar duas vezes com os mesmos downloads deposita os mesmos
    arquivos e gera o mesmo inventário (ordenado e sem timestamp de execução).

    Args:
        pasta_downloads: Pasta com os arquivos brutos.
        manifesto: Caminho do manifesto YAML.
        raiz_dados: Raiz de `dados_brutos/`.
        caminho_inventario: Onde gravar o CSV. Se None, não grava (só devolve).
        raiz_projeto: Raiz do repositório (para achar contracts/). Default: o
            repositório deste script.
        dry_run: Se True, não escreve nada em disco; só calcula e devolve.

    Returns:
        Lista de registros do inventário, ordenada por (fonte, uf, arquivo).

    Raises:
        FileNotFoundError: Download listado não existe na pasta.
        ValueError: Fonte não declarada no contrato, ou UF fora do piloto.
    """
    pasta_downloads = Path(pasta_downloads)
    raiz_dados = Path(raiz_dados)
    raiz_projeto = Path(raiz_projeto) if raiz_projeto else RAIZ_PROJETO
    fontes_declaradas, ufs_piloto = _fontes_e_ufs(raiz_projeto)
    entradas = carregar_manifesto(manifesto)

    registros: list[dict[str, Any]] = []
    for entrada in entradas:
        arquivo = entrada["arquivo"]
        fonte = entrada["fonte"]
        uf = entrada.get("uf")

        origem = pasta_downloads / arquivo
        if not origem.exists():
            raise FileNotFoundError(
                f"Download '{arquivo}' não encontrado em {pasta_downloads}."
            )
        if fonte not in fontes_declaradas:
            raise ValueError(
                f"Fonte '{fonte}' (arquivo {arquivo}) não está declarada em "
                "contracts/fontes.yml. Declare a fonte antes de ingerir."
            )
        if uf and uf.upper() not in ufs_piloto:
            raise ValueError(
                f"UF '{uf}' (arquivo {arquivo}) fora das UFs piloto "
                f"{sorted(ufs_piloto)}."
            )

        destino = resolver_destino(fonte, uf, raiz_dados)
        sha = calcular_sha256(origem)
        tamanho = origem.stat().st_size

        # Zip entra numa subpasta própria, nomeada pelo arquivo. O Sicar
        # distribui um zip por município com nomes internos IGUAIS
        # (AREA_IMOVEL.shp em todos); sem a subpasta, um município sobrescreve
        # o outro. A ingestão (ingestao_geo.descobrir_arquivos) usa rglob, então
        # acha os shapefiles em qualquer profundidade.
        e_zip = origem.suffix.lower() == ".zip"
        destino_final = destino / origem.stem if e_zip else destino

        if not dry_run:
            if e_zip:
                extrair_zip_seguro(origem, destino_final)
            else:
                destino.mkdir(parents=True, exist_ok=True)
                shutil.copy2(origem, destino / origem.name)

        registros.append(
            {
                "arquivo": arquivo,
                "fonte": fonte,
                "uf": uf.upper() if uf else "",
                "bytes": tamanho,
                "sha256": sha,
                "data_download": entrada.get("data_download", ""),
                "url": entrada.get("url", ""),
                "destino": str(destino_final.relative_to(raiz_dados)),
            }
        )

    registros.sort(key=lambda r: (r["fonte"], r["uf"], r["arquivo"]))
    if caminho_inventario and not dry_run:
        escrever_inventario(registros, caminho_inventario)
    return registros


def escrever_inventario(
    registros: list[dict[str, Any]], caminho: Path
) -> None:
    """Grava o inventário em CSV, com cabeçalho fixo e ordem determinística."""
    caminho = Path(caminho)
    caminho.parent.mkdir(parents=True, exist_ok=True)
    with caminho.open("w", encoding="utf-8", newline="") as arq:
        escritor = csv.DictWriter(arq, fieldnames=CAMPOS_INVENTARIO)
        escritor.writeheader()
        for registro in registros:
            escritor.writerow(registro)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Organiza downloads brutos das fontes na árvore "
        "dados_brutos/, com hash e inventário (tarefa T-03)."
    )
    parser.add_argument(
        "--downloads",
        required=True,
        type=Path,
        help="Pasta com os arquivos brutos (zips como vieram da fonte).",
    )
    parser.add_argument(
        "--manifesto",
        type=Path,
        default=None,
        help="Manifesto YAML. Padrão: <downloads>/manifesto.yml.",
    )
    parser.add_argument(
        "--dados-brutos",
        type=Path,
        default=RAIZ_PROJETO / "dados_brutos",
        help="Raiz da árvore de destino. Padrão: dados_brutos/ do repositório.",
    )
    parser.add_argument(
        "--inventario",
        type=Path,
        default=None,
        help="CSV de saída. Padrão: <dados-brutos>/INVENTARIO.csv.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Não escreve nada; só valida o manifesto e calcula os hashes.",
    )
    args = parser.parse_args(argv)

    manifesto = args.manifesto or (args.downloads / "manifesto.yml")
    inventario = args.inventario or (args.dados_brutos / "INVENTARIO.csv")

    registros = processar(
        args.downloads,
        manifesto,
        args.dados_brutos,
        caminho_inventario=None if args.dry_run else inventario,
        dry_run=args.dry_run,
    )

    print(f"{len(registros)} download(s) processado(s):")
    for r in registros:
        alvo = f"{r['fonte']}" + (f"/{r['uf']}" if r["uf"] else "")
        print(f"  - {r['arquivo']:<32} -> {alvo:<36} {r['sha256'][:12]}…")
    if args.dry_run:
        print("\n[dry-run] Nada foi escrito em disco.")
    else:
        print(f"\nInventário gravado em: {inventario}")
        print(
            "Lembrete: registre a URL e a data de cada download em "
            "contracts/fontes.yml (campo 'versao')."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
