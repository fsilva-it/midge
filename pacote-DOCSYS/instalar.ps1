<#
================================================================
 Instalador do Lancador DOC-Windows  -  execucao LOCAL no servidor
 Silencioso e idempotente (pode rodar quantas vezes quiser).

 Uso local:
   powershell -ExecutionPolicy Bypass -File .\instalar.ps1

 E chamado tambem pelo deploy-multi.ps1 (implantacao em massa).
 Requer: executar como Administrador.
================================================================
#>
param(
    [string]$Origem   = $PSScriptRoot,          # pasta com o iniciar.vbs
    [string]$AppPath  = "C:\DeMaria\DOC-Windows\DOC-Windows.exe",
    [int]   $MsTrava  = 0                        # 0 = mantem o valor do arquivo
)

$ErrorActionPreference = "Stop"
$resultado = [ordered]@{
    Servidor    = $env:COMPUTERNAME
    Pastas      = "-"
    Script      = "-"
    Permissoes  = "-"
    AppEncontr  = "-"
    MsTrava     = "-"
    TSplusPath  = "-"
    TSplusDaugh = "-"
    Status      = "OK"
    Detalhe     = ""
}

function Falhar($msg) {
    $resultado.Status  = "ERRO"
    $resultado.Detalhe = $msg
    [pscustomobject]$resultado
    exit 1
}

# --- 0. Admin? ---------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Falhar "Precisa executar como Administrador."
}

# --- 1. Pastas ---------------------------------------------------
foreach ($p in @("C:\DOCSYS", "C:\DOCSYS\fila", "C:\DOCSYS\logs")) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
$resultado.Pastas = "ok"

# --- 2. Backup + copia do script ---------------------------------
$origemVbs = Join-Path $Origem "iniciar.vbs"
if (-not (Test-Path $origemVbs)) { Falhar "iniciar.vbs nao encontrado em $Origem" }

$destVbs = "C:\DOCSYS\iniciar.vbs"
if (Test-Path $destVbs) {
    $hashNovo  = (Get-FileHash $origemVbs -Algorithm SHA256).Hash
    $hashAtual = (Get-FileHash $destVbs   -Algorithm SHA256).Hash
    if ($hashNovo -eq $hashAtual) {
        $resultado.Script = "ja atualizado"
    } else {
        Copy-Item $destVbs "C:\DOCSYS\iniciar_OLD.vbs" -Force
        Copy-Item $origemVbs $destVbs -Force
        $resultado.Script = "atualizado (backup em iniciar_OLD.vbs)"
    }
} else {
    Copy-Item $origemVbs $destVbs -Force
    $resultado.Script = "instalado"
}

# --- 3. Ajuste opcional do MS_TRAVA ------------------------------
$conteudo = Get-Content $destVbs -Raw -Encoding Default
if ($MsTrava -gt 0) {
    $conteudo = [regex]::Replace($conteudo,
        '(?m)^(Const MS_TRAVA\s*=\s*)\d+', "`${1}$MsTrava")
    Set-Content $destVbs -Value $conteudo -Encoding Default -NoNewline
}
if ($conteudo -match '(?m)^Const MS_TRAVA\s*=\s*(\d+)') {
    $resultado.MsTrava = $Matches[1]
}
if ($conteudo -notmatch 'MAX_TENTATIVAS') {
    $resultado.Detalhe = "AVISO: script sem auto-recuperacao (versao antiga?)"
}

# --- 4. Permissoes (SIDs: servidor pode ser PT-BR) ---------------
# S-1-5-18 SYSTEM | S-1-5-32-544 Administradores | S-1-5-32-545 Usuarios
& icacls "C:\DOCSYS" /inheritance:r /grant:r `
    "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" | Out-Null
& icacls "C:\DOCSYS\fila" /inheritance:r /grant:r `
    "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)M" | Out-Null
& icacls "C:\DOCSYS\logs" /inheritance:r /grant:r `
    "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)M" | Out-Null
$resultado.Permissoes = "ok"

# --- 5. Confere o executavel do app ------------------------------
if (Test-Path $AppPath) {
    $resultado.AppEncontr = "ok"
} else {
    $resultado.AppEncontr = "NAO ENCONTRADO"
    $resultado.Status = "ATENCAO"
    $resultado.Detalhe = "$AppPath nao existe neste servidor - ajustar APP_PATH no iniciar.vbs"
}

# --- 6. Diagnostico da config do TSplus --------------------------
# Nao altera nada: apenas relata se a publicacao ja aponta para o
# lancador e se o 'daughter process handler' esta desativado.
try {
    $tsRoot = @("C:\Program Files (x86)\TSplus", "C:\Program Files\TSplus") |
              Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($tsRoot) {
        $achouVbs = Get-ChildItem -Path $tsRoot -Recurse -Include *.ini,*.txt,*.xml,*.json `
                        -ErrorAction SilentlyContinue |
                    Select-String -Pattern "iniciar\.vbs" -SimpleMatch -List -ErrorAction SilentlyContinue
        $resultado.TSplusPath = if ($achouVbs) { "aponta p/ iniciar.vbs" } else { "NAO aponta (ajustar)" }

        $achouDaug = Get-ChildItem -Path $tsRoot -Recurse -Include *.ini,*.txt,*.xml,*.json `
                        -ErrorAction SilentlyContinue |
                     Select-String -Pattern "daughter" -List -ErrorAction SilentlyContinue
        $resultado.TSplusDaugh = if ($achouDaug) { ($achouDaug | Select-Object -First 1).Line.Trim() } else { "nao localizado" }
    } else {
        $resultado.TSplusPath = "TSplus nao encontrado"
    }
} catch {
    $resultado.TSplusPath = "erro ao inspecionar"
}

[pscustomobject]$resultado
