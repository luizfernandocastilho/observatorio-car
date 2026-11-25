# TASKS.md — Observatório do CAR, caminho até a inscrição

Backlog ordenado até a submissão no InovaCAR. Cada tarefa traz **objetivo**,
**critério de aceite** e um **prompt pronto** para colar no Claude Code dentro
do VSCode.

Hoje: **25/11/2026**. Submissão-alvo: **15/01/2027** (prazo final 22/01).

Marque `[x]` ao concluir. A próxima tarefa é sempre a primeira não concluída.

---

## Semana 1 — 25/11 a 01/12: fundação e dados

### [ ] T-01 — Subir o ambiente e validar o setup

**Objetivo.** Ter PostGIS, Airflow e dashboard rodando, com os três schemas
criados e o DAG aparecendo sem erro de import.

**Critério de aceite.** `make up` sobe sem erro; `psql` mostra os schemas
bronze/prata/ouro e a extensão postgis; o DAG `observatorio_car_diario`
aparece no Airflow sem "Broken DAG"; `make testar` passa.

```
Suba o ambiente deste projeto e valide o setup ponta a ponta. Leia CLAUDE.md
primeiro. Rode `make up`, aguarde os healthchecks, e então verifique:
(1) as extensões postgis e btree_gist existem no banco `dados`;
(2) os schemas bronze, prata e ouro existem com as roles etl_bronze,
    etl_prata, etl_ouro e bi_leitura;
(3) as tabelas de bronze foram criadas pelo initdb;
(4) o DAG observatorio_car_diario carrega sem erro de import no Airflow;
(5) `make testar` passa.
Corrija o que estiver quebrado — provavelmente caminho de volume, permissão de
diretório para o AIRFLOW_UID, ou dependência faltando no
_PIP_ADDITIONAL_REQUIREMENTS. Ao final, me diga exatamente o que falhou e o
que você mudou, e atualize o README se o procedimento de subida mudou.
```

### [ ] T-02 — Confirmar o schema real das fontes

**Objetivo.** Trocar o mapeamento defensivo com `COALESCE` por um mapeamento
exato, conferido contra os arquivos de verdade. Esta é a tarefa que mais
previne retrabalho — tudo depois dela depende dos nomes de atributo.

**Critério de aceite.** `contracts/fontes.yml` com `versao` preenchida e lista
de atributos reais por fonte; `sql/prata/01_referencias.sql` e
`02_imoveis.sql` sem `COALESCE` especulativo; um teste que falha se a fonte
mudar de schema.

```
Preciso fechar o mapeamento das fontes contra os arquivos reais. Já baixei
amostras em dados_brutos/. Leia CLAUDE.md e use a skill
etl-medallion-postgres-ptbr.
1. Para cada arquivo em dados_brutos/, liste os nomes e tipos reais dos
   atributos (use pyogrio/geopandas para os vetoriais, pandas para os CSV) e
   registre o resultado em contracts/fontes.yml, junto com a versão/data do
   arquivo.
2. Reescreva os blocos de extração em sql/prata/01_referencias.sql e
   sql/prata/02_imoveis.sql usando os nomes exatos, SEM COALESCE
   especulativo — quero que uma mudança de schema na fonte quebre de forma
   visível, não que passe silenciosamente.
3. Crie um teste em tests/ que leia contracts/fontes.yml e valide que os
   atributos esperados existem nos arquivos de dados_brutos/, para pegar
   mudança de fonte antes do pipeline rodar.
Se algum atributo que o pipeline espera (data de inscrição, status do
cadastro, código do município) simplesmente não existir no dado público, me
diga — isso muda o desenho da linha do tempo e eu preciso saber agora, não na
semana 4.
```

### [ ] T-03 — Baixar e organizar os dados das UFs piloto

**Objetivo.** Ter os dados de PA, MG e CE organizados em `dados_brutos/`, com
procedência registrada.

**Critério de aceite.** Estrutura de diretórios preenchida; hash de cada
arquivo registrado; `contracts/fontes.yml` com URL e data de cada download.

> **Nota.** O download do Sicar é por município, com validação a cada
> requisição. Isso é trabalho manual, e o projeto não automatiza a quebra
> dessa validação. Comece por poucos municípios de cada UF para destravar o
> pipeline, e amplie depois.

```
Prepare a estrutura de dados_brutos/ e um script auxiliar de organização.
Leia CLAUDE.md, em especial a regra 9.
1. Crie a árvore dados_brutos/{sicar/{pa,mg,ce},restricoes/{embargos,
   unidades_conservacao,terras_indigenas,florestas_publicas},ibge,incra} com
   um README em cada pasta dizendo exatamente qual arquivo vai ali, de qual
   URL, e em que formato.
2. Escreva scripts/organizar_downloads.py que recebe uma pasta de downloads
   brutos (zips como vieram da fonte), descompacta cada um em seu lugar na
   árvore acima, calcula SHA-256, e grava um inventário em
   dados_brutos/INVENTARIO.csv com arquivo, fonte, UF, bytes, hash e data.
3. NÃO escreva nenhum código que baixe automaticamente do Sicar contornando a
   validação por requisição. Para as fontes que têm download aberto e direto
   (IBGE, dados abertos do Ibama, dados.florestal.gov.br), pode automatizar o
   download normalmente.
```

### [ ] T-04 — Agendar a validação externa

**Objetivo.** Garantir que alguém que opera o CAR na ponta veja o protótipo
antes da inscrição. Entra na semana 1 porque agenda de terceiro tem prazo de
antecedência, não porque o protótipo está pronto.

**Critério de aceite.** Dois contatos confirmados: um analista de órgão
estadual gestor do CAR e um pesquisador da área, com data marcada para a
primeira semana de janeiro.

```
Me ajude a preparar o contato para validação externa do protótipo. Quero
mostrar a ferramenta para (a) um analista de órgão estadual gestor do CAR e
(b) um pesquisador que trabalhe com dados do CAR, na primeira semana de
janeiro de 2027.
Escreva dois e-mails curtos, em português, sem jargão de startup, explicando:
o que é o projeto em duas frases, que é código aberto, que não processa dado
pessoal, o que eu peço exatamente (40 minutos olhando a tela e dizendo onde o
sinal é inútil), e que eu gostaria de citar a opinião na inscrição — pedindo
autorização explícita para isso. Deixe um espaço claro para eu preencher nome
e instituição. Nada de anexo pesado, nada de promessa de resultado.
```

---

## Semana 2 — 02/12 a 08/12: bronze e prata rodando

### [ ] T-05 — Primeira carga bronze → prata com medição de qualidade

**Objetivo.** Dado real atravessando as duas primeiras camadas, com números de
qualidade geométrica na mão.

**Critério de aceite.** `prata.car__imoveis` populada; relatório com
percentual de geometrias inválidas corrigidas, percentual sem módulo fiscal,
distribuição de compacidade e de divergência de área; suíte Great Expectations
da prata rodando e passando.

```
Rode a carga bronze -> prata com os dados reais e me entregue um diagnóstico
de qualidade. Leia CLAUDE.md e use a skill etl-medallion-postgres-ptbr.
1. Dispare o grupo bronze e depois o grupo prata do DAG (ou execute os SQL
   diretamente, se for mais rápido para iterar).
2. Rode a suíte great_expectations/expectations/suite_prata_imoveis.py e
   conserte o que falhar — mas se a falha for do DADO e não do código, me
   diga em vez de relaxar a expectativa.
3. Gere notebooks/01_qualidade_prata.ipynb com: contagem por UF, percentual
   de geom_era_invalida, percentual sem modulos_fiscais, histograma de
   compacidade, histograma de divergencia_area_pct, e os 20 casos mais
   extremos de cada.
4. Com base nos histogramas, me proponha limiares calibrados para o detector
   d4 (compacidade_min e divergencia_area_declarada_pct) em vez dos valores
   provisórios que estão em contracts/detectores.yml. Quero o percentil que
   você usou como justificativa, não um número redondo.
```

### [ ] T-06 — Eventos de ciclo de vida com dado real

**Objetivo.** A linha do tempo só vale se os marcos temporais forem honestos.
Esta tarefa descobre quanto da linha do tempo é medição e quanto é derivação.

**Critério de aceite.** `prata.car__eventos_ciclo_vida` populada, com
percentual de cada `origem` documentado; mapa status→etapa revisado contra a
documentação do Sicar; Painel da Regularização integrado onde o marco
individual não existir.

```
Construa a linha do tempo do ciclo de vida com o dado real e me diga quanto
dela é medição de verdade. Leia CLAUDE.md e sql/prata/03_eventos_ciclo_vida.sql.
1. Confira o mapa status -> etapa contra os valores de status que realmente
   aparecem no dado (a CTE mapa_status foi escrita a partir de convenções
   prováveis, não de documentação). Me mostre os status encontrados e a
   frequência de cada, e ajuste o mapa.
2. Ingira o Painel da Regularização Ambiental do SFB em bronze e use-o para
   preencher etapas com origem 'derivado_painel' onde não há marco individual.
3. Me dê o percentual de registros por origem (fonte_direta /
   derivado_status / derivado_painel) por etapa.
4. Se o percentual de fonte_direta for baixo (digamos abaixo de 30%), pare e
   me avise: nesse caso a linha do tempo precisa ser apresentada como
   distribuição de volume por etapa, e não como tempo de permanência, e isso
   muda o roteiro do vídeo.
```

---

## Semana 3 — 09/12 a 15/12: detectores

### [ ] T-07 — Rodar e calibrar os cinco detectores

**Objetivo.** Sinais gerados em volume administrável, com limiares
justificados por distribuição e não por chute.

**Critério de aceite.** Os cinco detectores rodam; volume de sinais por
detector documentado; limiares em `contracts/detectores.yml` atualizados com
justificativa estatística em comentário; nenhum detector gerando mais de ~2%
da base (acima disso o sinal perdeu significado).

```
Rode os cinco detectores com o dado real e calibre os limiares. Leia
CLAUDE.md, contracts/detectores.yml e sql/ouro/detectores/.
1. Execute a camada ouro inteira (gargalos + os cinco detectores) e me dê o
   volume de sinais por detector, em números absolutos e como percentual da
   base de imóveis.
2. Para cada detector cujo volume passe de 2% da base, proponha limiar mais
   estrito com base na distribuição observada, e explique a escolha.
3. Para cada detector com volume zero, investigue se é ausência real de
   anomalia ou bug de limiar/join, e me diga qual.
4. Atualize contracts/detectores.yml com os novos limiares e um comentário por
   limiar dizendo de qual percentil ou observação ele saiu. Rode `make testar`
   ao final — os testes de contrato precisam continuar passando.
Não mexa em precisao_medida: ela só se preenche com auditoria manual (T-09).
```

### [ ] T-08 — Otimizar o self-join espacial do detector d3

**Objetivo.** d3 (sobreposição CAR × CAR) é a consulta mais cara do pipeline.
Precisa rodar em tempo apresentável nas três UFs.

**Critério de aceite.** d3 completa nas três UFs em tempo aceitável, com
`EXPLAIN ANALYZE` registrado antes e depois; nenhuma mudança no resultado.

```
Otimize sql/ouro/detectores/d3_sobreposicao_car_car.sql. Use a skill
postgre-senior-ptbr.
1. Rode EXPLAIN (ANALYZE, BUFFERS) na consulta atual e me mostre o plano.
2. Otimize mantendo o resultado idêntico. Considere: índice GIST adequado,
   ST_Subdivide nas geometrias grandes antes do join (polígonos com milhares
   de vértices destroem o índice), particionamento do processamento por
   município, e ajuste de work_mem para a sessão.
3. Prove que o resultado não mudou: compare a contagem e o hash agregado dos
   sinais antes e depois.
4. Documente o ganho no cabeçalho do arquivo e registre os dois planos em
   docs/performance_d3.md.
```

---

## Semana 4 — 16/12 a 22/12: a tela e o número

### [ ] T-09 — Auditoria manual da amostra e precisão medida

**Objetivo.** O argumento central da proposta. Sem este número, o resto é
ruído estatístico.

**Critério de aceite.** 50 casos auditados por detector; precisão por detector
registrada em `contracts/detectores.yml` e visível na view
`ouro.car__precisao_detector`; protocolo de auditoria documentado.

```
Monte a infraestrutura da auditoria manual e me prepare para executá-la. Leia
CLAUDE.md, regra 4.
1. Sorteie a amostra (sql/ouro/03_amostra_validacao.sql) e confirme que ela é
   reproduzível: rode duas vezes com a mesma semente e verifique que os
   sinal_id sorteados são os mesmos.
2. Gere docs/protocolo_auditoria.md: o que o auditor olha, em que ordem, e o
   critério objetivo para marcar procede / não procede / inconclusivo em cada
   detector. Precisa ser específico o suficiente para duas pessoas diferentes
   chegarem à mesma conclusão na maioria dos casos.
3. Exporte a fila de auditoria (view ouro.car__fila_auditoria) para uma
   planilha de trabalho com uma linha por caso, as colunas de evidência já
   desdobradas, e colunas vazias para desfecho e justificativa.
4. Escreva scripts/importar_auditoria.py que lê a planilha preenchida e grava
   em ouro.car__triagem_desfecho, de forma idempotente.
5. Depois que eu preencher e você importar, atualize precisao_medida em
   contracts/detectores.yml com o valor da view — e nada além do valor da view.
```

### [ ] T-10 — Registro de desfecho pela interface

**Objetivo.** Fechar o ciclo: o analista decide na tela, não na planilha.

**Critério de aceite.** Botões de desfecho funcionando na aba de triagem;
escrita restrita à tabela de desfecho; precisão atualizando ao vivo.

```
Implemente o registro de desfecho na aba de triagem do dashboard. Leia
CLAUDE.md e use a skill frontend-python-ptbr.
1. Em cada item da fila, três ações: procede / não procede / inconclusivo,
   mais um campo de justificativa opcional.
2. A escrita vai apenas para ouro.car__triagem_desfecho. O usuário bi_leitura
   é somente leitura, então crie um usuário de aplicação com INSERT/UPDATE
   restrito a essa tabela e use-o só para esta ação. Não dê escrita ampla ao
   dashboard.
3. Grave avaliador_ref como identificador funcional (ex: "analista_01"),
   nunca nome ou CPF — regra 2 do CLAUDE.md.
4. Após registrar, a aba de precisão reflete o novo número sem reiniciar o
   app (invalide o cache).
```

### [ ] T-11 — Refino visual do dashboard

**Objetivo.** O vídeo de 3 minutos mostra esta tela. O default do Streamlit
denuncia protótipo improvisado.

**Critério de aceite.** Linha do tempo legível em tela cheia; mapa do caso
sinalizado; identidade visual sóbria e consistente; carrega em menos de 3s.

```
Refine o dashboard visualmente. Use a skill frontend-python-ptbr e leia
dashboard/app.py.
Prioridades, nesta ordem:
1. A aba de gargalos tem que comunicar "onde trava" em 5 segundos de olhar.
   Hoje é um bar_chart genérico. Quero uma visualização de linha do tempo por
   etapa, com volume e tempo de permanência, e destaque na etapa mais
   represada.
2. Adicione mapa ao item da fila de triagem: a geometria do imóvel e a
   geom_evidencia (sobreposição ou cluster) sobre um basemap, usando pydeck.
   Sem isso o analista não consegue decidir.
3. Tipografia, espaçamento e paleta sóbrios — é ferramenta de governo, não
   landing page. Sem emoji na interface.
4. Exiba sempre o aviso de confiança não medida quando precisao_medida for
   null, e a ressalva de qualidade temporal quando pct_com_data_confiavel for
   baixo. Esses dois avisos são requisito, não enfeite.
```

---

## Semana 5 — 23/12 a 29/12: método e blindagem

### [ ] T-12 — Nota técnica de método e privacidade

**Objetivo.** O documento que um órgão público lê antes de confiar na
ferramenta. Também é a base das respostas do formulário.

**Critério de aceite.** `docs/nota_tecnica.md` com fontes e versões, método de
cada detector, precisão medida, limitações declaradas, e tratamento de dados
pessoais com base legal.

```
Escreva docs/nota_tecnica.md. Leia CLAUDE.md, contracts/, sql/ouro/detectores/
e os resultados da auditoria.
Estrutura:
1. O problema, em números do próprio dado que processamos.
2. Fontes utilizadas, com URL, versão, licença e data de acesso (puxe de
   contracts/fontes.yml e bronze._versoes_fonte).
3. Método: uma seção por detector, com hipótese, regra, limiares, e as
   hipóteses alternativas que o sinal NÃO descarta.
4. Precisão medida por detector, com tamanho de amostra e protocolo.
5. Limitações declaradas, sem maquiagem: cobertura de marco temporal,
   diferença de escala entre camadas de restrição, recorte de três UFs.
6. Tratamento de dados pessoais: o que não processamos e por quê, base legal
   da LGPD para o uso de dado público com finalidade pública, e por que o
   produto sinaliza imóveis e não pessoas.
Tom técnico e sóbrio. Nenhuma palavra acusatória. Se algum número não tiver
respaldo no banco, deixe lacuna explícita em vez de preencher.
```

### [ ] T-13 — Custo de operação e transferência de tecnologia

**Objetivo.** Responder ao critério 5 com número, não com adjetivo.

**Critério de aceite.** `docs/custo_operacao.md` com custo mensal em reais por
cenário, e plano de transferência de tecnologia.

```
Escreva docs/custo_operacao.md com o custo real de operar isto.
1. Meça o consumo efetivo: tamanho do banco após a carga das três UFs, tempo
   de CPU de cada etapa do DAG, pico de memória. Extrapole para 27 UFs com a
   premissa explícita que você usar.
2. Monte três cenários de infraestrutura com custo mensal em reais:
   (a) auto-hospedado em infraestrutura própria do órgão,
   (b) VM única em nuvem pública,
   (c) nuvem com banco gerenciado.
   Use preços públicos de tabela e cite a fonte e a data de cada preço.
3. Liste todas as dependências do projeto com suas licenças, provando que não
   há custo recorrente de licenciamento.
4. Escreva o plano de transferência de tecnologia: o que o órgão recebe
   (código, modelo de dados, documentação, protocolo de auditoria), como
   assume a operação, e o que precisaria ser integrado ao Sicar.
```

### [ ] T-14 — Licença, repositório público e instalação limpa

**Objetivo.** Código aberto de verdade, instalável por terceiro sem ajuda.

**Critério de aceite.** Apache 2.0 aplicada; README que funciona em máquina
limpa; teste de instalação feito do zero.

```
Prepare o repositório para ser público. Use a skill git-github-senior-ptbr.
1. Aplique a licença Apache 2.0: arquivo LICENSE com o texto oficial completo
   e cabeçalho SPDX nos arquivos de código.
2. Varra o repositório em busca de segredo commitado (senhas em .env,
   credencial em notebook, token em histórico) e me avise se encontrar algo —
   inclusive no histórico do git.
3. Reescreva o README para que alguém que nunca viu o projeto consiga subir em
   15 minutos: pré-requisitos, passo a passo, onde depositar os dados, como
   rodar o DAG, como ler o dashboard, e como interpretar os sinais.
4. Teste a instalação do zero: clone em diretório novo, siga o próprio README
   ao pé da letra, e corrija cada passo que não funcionar exatamente como
   escrito.
5. Configure CI no GitHub Actions rodando `make testar` em cada push.
```

---

## Semana 6 — 30/12 a 05/01: os vídeos

### [ ] T-15 — Vídeo de protótipo (3 min)

**Objetivo.** Mostrar a ferramenta funcionando com dado real. Sem slide.

**Critério de aceite.** mp4 com menos de 3 minutos, gravação de tela, dado
real, narração calma, terminando no número de precisão.

```
Monte o roteiro do vídeo de protótipo e me prepare o ambiente para gravar.
Leia CLAUDE.md para o contexto do edital.
1. Roteiro minuto a minuto, com o que aparece na tela e o que eu digo. Arco
   proposto: pergunta de gestor ("onde a regularização está travando no
   estado X?") -> linha do tempo revelando a etapa represada -> drill-down no
   município -> abertura de um caso sinalizado com a evidência na tela ->
   fecho no número de precisão daquele detector. Ajuste se você tiver arco
   melhor, e me diga por quê.
2. Prepare o ambiente de gravação: um estado com dado bom, um caso sinalizado
   que seja didático e verdadeiro (não escolha o caso mais escandaloso, escolha
   o mais representativo), e um script de reset para eu poder regravar do
   mesmo estado.
3. Revise o roteiro contra as vedações do briefing: nada que pareça acusação,
   nada que pareça redesign de painel existente, nada de número sem respaldo.
4. Sem slide, sem música, sem efeito. Narração em português, calma.
```

### [ ] T-16 — Vídeo de pitch (3 min)

**Objetivo.** Problema, lacuna, solução, evidência, escala, custo, equipe.

**Critério de aceite.** mp4 com menos de 3 minutos, dentro da divisão de tempo
planejada, com todos os números vindos do banco.

```
Escreva o roteiro do vídeo de pitch. Leia CLAUDE.md, docs/nota_tecnica.md e
docs/custo_operacao.md.
Divisão de tempo: 30s problema em números; 30s o que já existe
(consulta.car.gov.br) e o que falta; 60s solução e evidência de que funciona;
30s escala (27 UFs e replicabilidade como bem público digital, que é objetivo
declarado do projeto CAR DPG); 30s custo, equipe e o que faríamos nos três
meses de aceleração.
Regras: todo número citado tem que vir do nosso banco ou de fonte citável —
marque cada um com a origem entre colchetes para eu conferir antes de gravar.
Nenhuma palavra acusatória. Nenhuma promessa que a aceleração não cubra.
Me entregue também a lista dos números a conferir, separada do roteiro.
```

---

## Semana 7 — 06/01 a 12/01: formulário

### [ ] T-17 — Respostas do formulário, critério por critério

**Objetivo.** Um parágrafo por critério, no vocabulário do critério.

**Critério de aceite.** Cinco respostas em `docs/inscricao_respostas.md`, cada
uma com a evidência correspondente apontada.

```
Escreva as respostas do formulário de inscrição em
docs/inscricao_respostas.md. Leia CLAUDE.md, docs/nota_tecnica.md,
docs/custo_operacao.md e os resultados da auditoria.
Um bloco por critério, usando o vocabulário do próprio critério:
1. Aderência ao desafio (peso 2) — tem que demonstrar que conhecemos
   consulta.car.gov.br e que preenchemos uma lacuna nomeada no briefing.
2. Capacidade para o desenvolvimento (peso 2) — componentes prontos, equipe,
   e disponibilidade declarada para 22/03 a 25/06/2027 com 60% de presença e
   100% das entregas.
3. Criatividade e inovação (peso 1) — a camada de sinais auditáveis com
   precisão medida, não o dashboard.
4. Potencial de escala (peso 1) — validado em três UFs de perfis distintos,
   pipeline replicável, custo que cresce devagar.
5. Viabilidade financeira (peso 1) — custo mensal em reais, licença aberta,
   zero licenciamento recorrente.
Para cada resposta, aponte a evidência no repositório que a sustenta. Se
alguma resposta não tiver evidência, me diga em vez de escrever bonito.
```

---

## Semana 8 — 13/01 a 15/01: submissão

### [ ] T-18 — Revisão final e submissão

**Objetivo.** Submeter com uma semana de folga.

**Critério de aceite.** Inscrição enviada na Plataforma Desafios; comprovante
guardado; datas de recurso no calendário.

```
Faça a revisão final antes da submissão. Leia CLAUDE.md.
Checklist, e me diga o status de cada item com evidência:
1. Os dois vídeos estão em mp4 e abaixo de 3 minutos (verifique a duração real
   com ffprobe, não confie no editor).
2. Nenhum número em vídeo, formulário ou documento sem respaldo no banco ou
   fonte citável.
3. Nenhuma palavra acusatória em nenhum artefato que vai na inscrição —
   incluindo nomes de arquivo e títulos.
4. Nenhum dado pessoal em nenhum artefato, incluindo o que aparece na tela dos
   vídeos. Confira frame a frame as telas gravadas.
5. Repositório público, licença aplicada, CI verde, README testado em máquina
   limpa.
6. `make testar` e `make verificar-idempotencia` passando.
7. Elegibilidade formal: CNPJ/CPF regular, equipe ciente do compromisso de
   presença na aceleração.
Ao final, me monte o calendário pós-submissão: resultado preliminar 19/02,
recurso em até 5 dias úteis para desafios.car@enap.gov.br, prazo 26/02,
resultado final 19/03, onboarding 22 a 26/03.
```

---

## Backlog pós-inscrição

### [ ] T-19 — Plano dos três meses de aceleração

```
Escreva docs/plano_aceleracao.md cobrindo 22/03 a 25/06/2027: o que entregamos
em cada uma das seis etapas da jornada do participante, com qual marco
verificável, e o que precisamos do MGI/SFB em cada uma (em especial acesso aos
marcos temporais que faltam no dado público). Inclua o que vamos apresentar no
Demoday e qual métrica estará pronta até lá.
```

### [ ] T-20 — API de consulta aos sinais

```
Projete e implemente uma API REST de leitura dos sinais e dos gargalos, com
OGC API Features para as geometrias, paginação, filtros por UF/município/
detector e cache. Leia CLAUDE.md. Isto é o tema 8 da análise original do
edital e transforma o observatório em infraestrutura consumível por outros
sistemas — mas só depois da inscrição, porque não é o que estamos propondo
agora.
```
