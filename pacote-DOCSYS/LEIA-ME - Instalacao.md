# Lançador DOC-Windows v3 — Instalação

**Ambiente de referência:** Windows Server 2022 + TSplus Enterprise 12.30,
~40 usuários por servidor.

## O que é

Lançador publicado no TSplus (`C:\DOCSYS\iniciar.vbs`) que:

1. **Serializa a abertura** do DOC-Windows entre as ~40 sessões (evita o erro
   "Várias tentativas de abertura detectadas" e a colisão no `log_license.txt`);
2. **Mantém a sessão RDP viva** enquanto o sistema estiver aberto;
3. **Desloga automaticamente** quando o usuário fecha o sistema.

## Configuração do TSplus (ESSENCIAL — sem isto não funciona)

Estas configurações no AdminTool do TSplus são obrigatórias:

1. **Aplicação publicada (Applications → DOWIN → Edit Application):**
   - Caminho/nome do arquivo: `C:\Windows\System32\wscript.exe`
   - Diretório Inicial: `C:\DOCSYS`
   - Opção de linha de comando: `"C:\DOCSYS\iniciar.vbs"`

2. **Advanced → Session → "Disable the daughter process handler" = Yes.**
   Sem isto o TSplus rastreia um processo-filho interno do lançador (um
   `cmd` de curta duração) e desliga a sessão quando ele morre (~8-12s
   depois de abrir). Com o handler desligado, o TSplus rastreia só o
   `wscript`, e quem controla o logoff é o nosso vigia.

3. **Advanced → Session → "Force logoff if no assigned application" = No.**

4. **Sessions → Session Management → reconexão = "Apenas uma sessão por
   usuário: a segunda sessão pegará a primeira".** Evita o mesmo usuário
   abrir um 2º DOC-Windows.

5. **NÃO** marcar "Todos os usuários têm um Desktop completo" (o usuário
   deve ver só a tela do DeMaria).

## Por que a v3 (mudanças estruturais)

A v3 passou por revisão adversarial multi-agente. Principais correções:

| Problema das versões anteriores | Solução v3 |
|---|---|
| Trava órfã: sessão caía segurando a fila e todos esperavam 10 min; o "destravamento forçado" podia apagar trava de dono vivo (furava a fila no pico das 08h) | Lock agora é um **arquivo aberto em modo exclusivo**. Se a sessão morre, o Windows fecha o handle e a fila anda sozinha. Trava órfã deixou de existir |
| Liberação da fila por um 2º processo (`/LIBERAR`) com relógio desacoplado do app → podia liberar cedo e deixar 2 instâncias na fase crítica | Liberação **no próprio processo**, depois do lançamento, ancorada no **nascimento real** do processo do app |
| Se o WMI falhasse, o script deslogava o usuário 20s depois do login (com o app aberto!) | Estado desconhecido **nunca** gera logoff; vigia principal usa handle local do processo (sem WMI) |
| A sonda do `log_license.txt` abria o arquivo para escrita e podia ELA MESMA causar o erro de licença | Sonda de **leitura** (não interfere no app) |
| Vigia por nome de processo podia grudar em `AppLauncher.exe` de outro software | Filtro por **caminho** `C:\DeMaria\` |
| `C:\DOCSYS` com Everyone-Controle Total: qualquer usuário podia trocar o script que roda no logon de todos (escalação de privilégio) | `instalar.bat` aplica ACLs corretas: usuários só leem o script; gravam apenas em `\fila` e `\logs` |
| Reexecução do lançador na mesma sessão criava fila/instância duplicada | Singleton por sessão (com desempate determinístico) + idempotência re-checada após pegar o lock |
| Falha momentânea do WMI podia ser lida como "app fechou" → logoff de sessão ativa | Vigia conservador: erro de consulta conta como "app vivo" + confirmação em 3 leituras antes de encerrar |
| Erro de permissão era indistinguível de "fila ocupada" (30 min preso) | Sonda de escritabilidade na pasta da fila desambigua em ~60s e registra no log |
| Sonda de licença podia não detectar o lock do app dependendo do modo de compartilhamento | Sonda dupla: leitura + toque de append (detecta os dois modos) |
| Quando a colisão acontecia, o app travava numa tela de erro e a sessão ficava presa (não deslogava) | Auto-recuperação: detecta a janela "Programa em Execução / Várias tentativas", mata a instância travada e tenta de novo (até 3×). Persistindo, limpa e desloga em vez de travar |

## Calibração do MS_TRAVA (tempo da fila)

O `MS_TRAVA` (topo do `iniciar.vbs`) é o tempo que cada usuário segura a fila
enquanto o app "assenta". É o único número a calibrar:

- Deve ser o **menor valor que abre sem NENHUM erro** com várias máquinas juntas.
- Testes no ambiente: 12s falhou com 3; 15s falhou só na última de 8; 25s ok
  porém lento. Valor de partida recomendado: **20000 (20s)**, validando com
  8 máquinas juntas 2-3 vezes (olhar sempre a última a abrir).
- A auto-recuperação cobre colisões raras que escaparem, mas o objetivo é
  calibrar para que quase não aconteçam.

## Instalação (2 minutos)

1. Copie a pasta deste pacote para o servidor (ex.: `C:\Temp\pacote-DOCSYS`).
2. Clique com o direito em **instalar.bat** → **Executar como administrador**.
   Ele faz backup do script atual, instala o novo, cria `C:\DOCSYS\fila` e
   `C:\DOCSYS\logs` e aplica as permissões.
3. Nada muda no console do TSplus nem no atalho DOC-LOCAL (mesmo caminho publicado).
4. AdminTool do TSplus → aplicação **DOWIN** → **Test**.

## Testes de aceite

- [ ] 1 usuário sozinho: abre imediato (fila não atrasa quem está só).
- [ ] 3 máquinas clicando juntas: aberturas espaçadas, **sem** erro de licença
      nem "várias tentativas". Nenhuma janela/aviso aparece (fila invisível).
- [ ] Fechar o sistema → sessão desloga em segundos.
- [ ] Sistema aberto 10+ min → sessão NÃO cai sozinha.
- [ ] Derrubar (reset) uma sessão no meio da fila → os demais destravam em
      segundos (lock auto-libera).
- [ ] Conferir `C:\DOCSYS\logs\USUARIO_AAAAMMDD.log`: linhas INICIO/FILA/
      LANCADO/SPAWN/LIC/FILA LIBERADA/FIM.

## Configurações recomendadas no servidor (uma vez)

1. **AV/Defender**: excluir de escaneamento `C:\DOCSYS\fila` e
   `C:\DeMaria\DOC-Windows\logs` (evita handle preso e atraso na sonda).
2. **Sessão única por usuário** (TSplus/GPO `fSingleSessionPerUser=1`):
   impede o mesmo usuário de abrir 2ª sessão com 2º DOC-Windows.
3. **Timeout de sessão desconectada** (15–30 min → encerrar): libera a
   estação/licença de quem derruba a conexão sem fechar o sistema.
4. **Windows Search**: desabilitar no session host ou excluir `C:\DOCSYS`.

## Diagnóstico

- KPI de saúde: ocorrências de `AVISO` nos logs de `C:\DOCSYS\logs`
  (fila estourada, WMI indisponível, vigia 12h). Zero é o normal.
- Cruzar horários com o log de eventos
  `TerminalServices-LocalSessionManager/Operational` (eventos 21/23/24/25).
- Erro de licença voltou? Ver no log se `LIC pos-lancamento` está estourando
  90000 ms — indica instância presa em outra sessão segurando o arquivo.

## Limitações conhecidas e correção definitiva

- A fila é serial: no pior caso teórico (40 cliques no mesmo segundo), o último
  espera ~40 × (spawn + MS_TRAVA + licença). Na prática os logons não são
  simultâneos e a fila drena durante os logons.
- A fila é um **contorno**. A correção definitiva é da DeMaria: homologação da
  versão 4.94.1 para Terminal Server, forma de alocação do nº de estação, e
  versão/parâmetro que fixe a estação por sessão (eliminaria a fila).
- VBScript está deprecado pela Microsoft (no Server 2025 vira Feature on
  Demand). Em migração futura de servidor, portar para PowerShell.
