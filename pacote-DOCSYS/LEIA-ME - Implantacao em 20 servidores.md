# Implantação em massa — 20+ servidores

A implantação tem **duas partes**. A primeira é 100% automatizável; a segunda
depende do TSplus e tem duas estratégias.

| Parte | O que é | Automatizável? |
|---|---|---|
| 1. Script + pastas + permissões | `C:\DOCSYS\` (iniciar.vbs, fila, logs) | **Sim** — `deploy-multi.ps1` faz tudo |
| 2. Config do TSplus | publicação apontando p/ o lançador + daughter handler | Sim, via **Backup/Restore** ou automação (ver abaixo) |

---

## Parte 1 — Script em todos os servidores (automático)

### Preparação (uma vez)

1. Copie a pasta `pacote-DOCSYS` para a sua estação de trabalho ou um servidor
   de gerência (que tenha acesso administrativo aos 20 servidores).
2. Edite **`servidores.txt`**: um servidor por linha (nome ou IP).
3. Requisito: **WinRM** habilitado nos servidores (padrão em domínio).
   Testar rapidamente: `Test-WSMan -ComputerName NOMEDOSERVIDOR`

### Executar

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1
```

Ele pede a credencial de admin do domínio e então, em cada servidor:
cria `C:\DOCSYS\fila` e `\logs`, faz backup do script antigo, copia o
`iniciar.vbs` novo, aplica as permissões e confere se o DeMaria existe.

No fim mostra uma tabela e salva um **CSV** com o resultado por servidor.

### Opções úteis

```powershell
# Só diagnosticar (não instala nada) — ver o que tem em cada servidor
powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1 -Verificar

# Instalar já com um MS_TRAVA específico (ex.: 20s)
powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1 -MsTrava 20000

# Reprocessar só os que falharam: edite servidores.txt com esses e rode de novo
```

É **idempotente**: rodar de novo é seguro. Se o script já estiver igual, ele
apenas informa "já atualizado".

### Se não houver WinRM

Alternativa manual por servidor (2 min cada): copie a pasta para
`\\SERVIDOR\C$\Temp\pacote-DOCSYS` e rode lá dentro, como admin:

```
powershell -ExecutionPolicy Bypass -File C:\Temp\pacote-DOCSYS\instalar.ps1
```

(ou o `instalar.bat`, que faz o mesmo com duplo clique)

---

## Parte 2 — Configuração do TSplus

Em **cada** servidor o TSplus precisa de duas configurações (senão o script
não é chamado, ou a sessão cai sozinha):

1. **Applications → aplicação → Edit:**
   - Caminho: `C:\Windows\System32\wscript.exe`
   - Diretório inicial: `C:\DOCSYS`
   - Linha de comando: `"C:\DOCSYS\iniciar.vbs"`
2. **Advanced → Session → "Disable the daughter process handler" = Yes**

Recomendadas: sessão única por usuário; **não** marcar "Desktop completo".

### Estratégia A — Backup/Restore do TSplus (mais rápida)

O AdminTool tem **Advanced → "Backup / Restore your Server Parameters"**.

1. No servidor já configurado (SERVIDOR-TS01): **Backup**.
2. Num servidor de teste: **Restore** apontando para esse backup.
3. **Conferir com atenção** antes de replicar nos outros: o backup pode
   trazer junto itens que você não quer clonar — licença, usuários/grupos
   atribuídos, nome/IP, impressoras. Se o restore trouxer algo indesejado,
   use a Estratégia B.

Regra: valide em **um** servidor antes de aplicar nos 20.

### Estratégia B — Automatizar via arquivos de configuração

Para automatizar sem o Backup/Restore, precisamos saber onde o TSplus 12.30
grava essas duas opções. Rode **uma vez** no servidor que já funciona:

```powershell
powershell -ExecutionPolicy Bypass -File .\descobrir-config-tsplus.ps1
```

Ele gera `C:\DOCSYS\config-tsplus-descoberta.txt` (não altera nada) apontando
os arquivos/chaves que contêm `iniciar.vbs` e `daughter`. Com esse relatório
dá para escrever o script que replica a config nos 20 servidores.

### Estratégia C — Manual (fallback)

São ~2 minutos por servidor. Para 20, cerca de 40 minutos — viável se as
outras não servirem.

---

## Ordem recomendada

1. `deploy-multi.ps1 -Verificar` → fotografia de como estão os 20 servidores.
2. `deploy-multi.ps1 -MsTrava 20000` → script em todos.
3. Config do TSplus em **um** servidor piloto (Estratégia A ou C) → **testar**.
4. Validado o piloto, replicar nos demais.
5. `deploy-multi.ps1 -Verificar` de novo → confirmar que está tudo igual.

---

## Calibração por servidor

O `MS_TRAVA` depende de quantos usuários e da carga de cada servidor.
Sugestão: começar com **20000** em todos e ajustar onde aparecer colisão.

Para descobrir se algum servidor está com problema, verifique os logs
(`C:\DOCSYS\logs\*.log`). Procure por:
- `COLISAO detectada` → aumentar o `MS_TRAVA` daquele servidor
- `AVISO:` → problema de infraestrutura (permissão, WMI, fila)

Comando para varrer os logs de todos os servidores de uma vez:

```powershell
$srv = Get-Content .\servidores.txt | Where-Object { $_ -and -not $_.StartsWith("#") }
foreach ($s in $srv) {
    $p = "\\$s\C$\DOCSYS\logs"
    if (Test-Path $p) {
        $n = (Select-String -Path "$p\*.log" -Pattern "COLISAO|AVISO|FALHA" -ErrorAction SilentlyContinue).Count
        "{0,-20} ocorrencias: {1}" -f $s, $n
    } else { "{0,-20} sem logs" -f $s }
}
```

---

## Atenção — servidores que compartilham o banco do DeMaria

A fila é **local de cada servidor** (`C:\DOCSYS\fila\fila.lock`). Isso está
correto quando cada servidor tem sua própria instalação do DOC-Windows.

**Se vários servidores compartilharem a mesma base** e o número de estação
for alocado globalmente, colisões podem ocorrer *entre* servidores — e aí a
fila precisa ser compartilhada (o `LOCK_FILE` apontando para uma pasta de
rede comum, ex.: `\\servidor-arquivos\docsys$\fila.lock`). Confirmar com a
DeMaria antes de assumir.
