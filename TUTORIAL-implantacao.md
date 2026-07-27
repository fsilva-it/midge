# Tutorial completo de implantação

> **Os servidores NÃO precisam de git.** Git é apenas onde o código fica
> versionado. Você baixa o pacote em **uma** máquina e ela distribui para os
> servidores por cópia de arquivo. Nenhum servidor precisa de internet,
> conta no GitHub ou git instalado.

```
   GitHub  ──baixar──▶  SUA MÁQUINA  ──deploy-multi.ps1──▶  20 SERVIDORES
   (1 vez)              (a que você usa)                    (só recebem arquivos)
```

---

## Passo 1 — Baixar o pacote (sem git)

Na sua estação de trabalho (ou num servidor de gerência com acesso aos demais).

### Opção A — pelo navegador (mais simples)

1. Abrir https://github.com/fsilva-it/midge
2. Botão verde **Code** → **Download ZIP**
3. Extrair, por exemplo, em `C:\Deploy\midge`

### Opção B — por PowerShell (sem abrir navegador)

```powershell
$dest = "C:\Deploy"
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Invoke-WebRequest -Uri "https://github.com/fsilva-it/midge/archive/refs/heads/main.zip" `
                  -OutFile "$dest\midge.zip"
Expand-Archive "$dest\midge.zip" -DestinationPath $dest -Force
Rename-Item "$dest\midge-main" "$dest\midge" -ErrorAction SilentlyContinue
```

### **Passo 1.1 — DESBLOQUEAR os arquivos (não pule)**

Arquivos baixados da internet vêm marcados pelo Windows e o PowerShell
**recusa executá-los**. Rode uma vez:

```powershell
Get-ChildItem -Path "C:\Deploy\midge" -Recurse | Unblock-File
```

Sintoma de quem pula este passo: *"não é assinado digitalmente"* ou
*"execução de scripts foi desabilitada"* ao rodar o deploy.

---

## Passo 2 — Montar a lista de servidores

```powershell
cd C:\Deploy\midge\pacote-DOCSYS
Copy-Item servidores.exemplo.txt servidores.txt
notepad servidores.txt
```

Coloque **um servidor por linha** (nome ou IP), apagando os exemplos:

```
SRV-TS01
SRV-TS02
SRV-TS03
```

> O `servidores.txt` fica fora do git de propósito: é o inventário da sua
> infraestrutura. Não commite esse arquivo.

---

## Passo 3 — Testar o acesso aos servidores

O deploy usa **WinRM** (padrão em ambiente de domínio). Teste antes:

```powershell
Get-Content servidores.txt |
  Where-Object { $_ -and -not $_.StartsWith("#") } |
  ForEach-Object {
      $ok = Test-WSMan -ComputerName $_ -ErrorAction SilentlyContinue
      "{0,-20} {1}" -f $_, $(if ($ok) { "OK" } else { "SEM WinRM" })
  }
```

- Todos **OK** → siga para o Passo 4.
- Algum **SEM WinRM** → habilite nele (como admin, no próprio servidor):
  `Enable-PSRemoting -Force`
  Ou use o **modo manual** (Apêndice A) só para esses.

---

## Passo 4 — Diagnóstico antes de mexer (não altera nada)

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1 -Verificar
```

Pede a credencial de administrador do domínio e mostra a situação de cada
servidor: se já tem o lançador, qual versão, qual `MS_TRAVA`, se o DeMaria
está no caminho esperado. É a sua fotografia inicial — guarde o CSV.

---

## Passo 5 — Piloto: instalar em UM servidor

Escolha um servidor de menor movimento. Crie uma lista temporária:

```powershell
"SRV-TS02" | Set-Content piloto.txt
powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1 -Lista .\piloto.txt
```

Isso cria `C:\DOCSYS` (com `fila` e `logs`), copia o `iniciar.vbs`, aplica as
permissões e faz backup de qualquer versão anterior.

> Os valores `MS_TRAVA = 20000` e `MAX_TENTATIVAS = 3` já vêm no arquivo.
> Só use `-MsTrava <valor>` se quiser sobrescrever.

---

## Passo 6 — Configurar o TSplus no piloto (essencial)

Sem isto o lançador não é chamado, ou a sessão cai sozinha. No **AdminTool do
TSplus** do servidor piloto:

**6.1 — Publicação da aplicação**
`APPLICATIONS` → selecione a aplicação → **Edit Application**:

| Campo | Valor |
|---|---|
| Caminho/nome do arquivo | `C:\Windows\System32\wscript.exe` |
| Diretório Inicial | `C:\DOCSYS` |
| Opção de linha de comando | `"C:\DOCSYS\iniciar.vbs"` |

**6.2 — Rastreamento de processo (o que fazia a sessão cair)**
`ADVANCED` → `Session` → **"Disable the daughter process handler" = Yes**

**6.3 — Confirmar**
- `ADVANCED` → `Session` → "Force logoff if no assigned application" = **No**
- `SESSIONS` → Session Management → **"Apenas uma sessão por usuário"**
- **NÃO** marcar "Todos os usuários têm um Desktop completo"

---

## Passo 7 — Testar o piloto

- [ ] Um usuário sozinho: abre imediato, só a tela do sistema (sem desktop).
- [ ] Sistema aberto 10+ min: a sessão **não** cai sozinha.
- [ ] Fechar o sistema: a sessão desloga em poucos segundos.
- [ ] Várias máquinas juntas: abrem espaçadas, sem erro de "várias tentativas".

Conferir o log de um teste (no servidor piloto):

```
type C:\DOCSYS\logs\USUARIO_AAAAMMDD.log
```

Sequência esperada:
`INICIO → FILA → LANCADO → SPAWN → LIC pos-lancamento → FILA LIBERADA → FIM`

---

## Passo 8 — Replicar nos demais

Com o piloto aprovado:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1
```

Instala em todos da lista, 5 em paralelo, e salva um CSV com o resultado.
É **idempotente** — se algum já estiver atualizado, ele só informa.

Deu erro em alguns? Coloque só eles numa lista e rode de novo:

```powershell
"SRV-TS07","SRV-TS12" | Set-Content refazer.txt
powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1 -Lista .\refazer.txt
```

**Depois, repita o Passo 6 (TSplus) em cada servidor.** Essa parte não é
coberta pelo script — veja as estratégias no
[LEIA-ME de implantação](pacote-DOCSYS/LEIA-ME%20-%20Implantacao%20em%2020%20servidores.md)
(o TSplus tem Backup/Restore de parâmetros, que pode acelerar).

---

## Passo 9 — Conferência final

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1 -Verificar
```

Todos devem aparecer com script `atual` e o mesmo `MS_TRAVA`.

---

## Passo 10 — Monitoramento (rodar de vez em quando)

Varre os logs de todos os servidores procurando problemas:

```powershell
Get-Content servidores.txt |
  Where-Object { $_ -and -not $_.StartsWith("#") } |
  ForEach-Object {
      $p = "\\$_\C$\DOCSYS\logs"
      if (Test-Path $p) {
          $n = @(Select-String -Path "$p\*.log" -Pattern "COLISAO|AVISO|FALHA" `
                 -ErrorAction SilentlyContinue).Count
          "{0,-20} ocorrencias: {1}" -f $_, $n
      } else { "{0,-20} sem logs" -f $_ }
  }
```

Como interpretar:
- `COLISAO detectada` → aumentar o `MS_TRAVA` **daquele** servidor
- `AVISO:` → infraestrutura (permissão, WMI, fila) — abrir o log e ler
- Zero ocorrências → saudável

---

## Passo 11 — Atualizações futuras

Quando sair uma versão nova do lançador:

```powershell
cd C:\Deploy\midge
# baixar de novo (Passo 1) OU, se usar git:  git pull
Get-ChildItem -Recurse | Unblock-File
cd pacote-DOCSYS
powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1
```

O deploy faz backup automático (`iniciar_OLD.vbs`) em cada servidor.
Para voltar atrás num servidor específico, rode lá o `desinstalar.bat`.

---

## Apêndice A — Servidor sem WinRM (modo manual)

Por servidor, ~2 minutos:

1. Copie a pasta do pacote para o servidor:
   ```powershell
   Copy-Item C:\Deploy\midge\pacote-DOCSYS -Destination "\\SRV-TS05\C$\Temp\" -Recurse -Force
   ```
2. Conecte no servidor, abra `C:\Temp\pacote-DOCSYS`
3. Botão direito em **instalar.bat** → **Executar como administrador**
4. Faça o Passo 6 (TSplus) normalmente

---

## Apêndice B — Erros comuns

| Sintoma | Causa / solução |
|---|---|
| "execução de scripts foi desabilitada" | Faltou o `Unblock-File` (Passo 1.1), ou use `-ExecutionPolicy Bypass` |
| "servidor inacessível" no relatório | Sem ping/firewall. Testar `Test-WSMan` (Passo 3) |
| "Acesso negado" | A credencial precisa ser admin **local** naquele servidor |
| App abre e a sessão desloga em ~10s | Faltou `Disable the daughter process handler = Yes` (Passo 6.2) |
| Nada acontece / não há logs em `C:\DOCSYS\logs` | A publicação do TSplus não aponta para o `iniciar.vbs` (Passo 6.1) |
| Erro "várias tentativas" persiste | Aumentar `MS_TRAVA` naquele servidor e testar |
| App não encontrado no relatório | O DeMaria está em caminho diferente — ajustar `APP_PATH` no topo do `iniciar.vbs` |

---

## Apêndice C — Usar git na máquina de deploy (opcional)

Só se você quiser receber atualizações com `git pull` em vez de baixar o ZIP.
**Continua não sendo necessário nos servidores.**

```powershell
winget install --id Git.Git -e     # instala o git (uma vez)
git clone https://github.com/fsilva-it/midge.git C:\Deploy\midge
cd C:\Deploy\midge
# atualizar depois:
git pull
```

Ao clonar, o `servidores.txt` não vem junto (está no `.gitignore`) — copie do
`servidores.exemplo.txt` como no Passo 2.
