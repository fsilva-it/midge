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
    [string]$Origem   = $PSScriptRoot,  # pasta com o iniciar.vbs
    [string]$AppPath  = "",             # vazio = DETECTA sozinho (ver abaixo)
    [int]   $MsTrava  = 0               # 0 = mantem o valor do arquivo
)

# O caminho do app VARIA entre servidores (ex.: "C:\DeMaria\..." x
# "C:\DeMaria - Nuvem\..."). Quando -AppPath nao e' informado, o
# instalador descobre lendo a publicacao do TSplus (AppControl.ini)
# e ajusta o iniciar.vbs de acordo.
function DetectarAppPath {
    $raiz = @("C:\Program Files (x86)\TSplus","C:\Program Files\TSplus") |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($raiz) {
        $ini = Join-Path $raiz "UserDesktop\files\AppControl.ini"
        if (Test-Path $ini) {
            $achados = Get-Content $ini -ErrorAction SilentlyContinue |
                       Select-String -Pattern '^\s*path\s*=\s*(.+DOC-Windows\.exe)\s*$'
            foreach ($a in $achados) {
                $p = $a.Matches[0].Groups[1].Value.Trim().Trim('"')
                if (Test-Path $p) { return $p }
            }
        }
    }
    # varredura curta nos locais tipicos
    foreach ($base in (Get-ChildItem "C:\" -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -like "DeMaria*" })) {
        $c = Join-Path $base.FullName "DOC-Windows\DOC-Windows.exe"
        if (Test-Path $c) { return $c }
    }
    return ""
}

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
    AppPath     = "-"
    AppOrigem   = "-"
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

# --- 3. Ajustes no script instalado ------------------------------
$conteudo = Get-Content $destVbs -Raw -Encoding Default

# 3a) MS_TRAVA (opcional)
if ($MsTrava -gt 0) {
    $conteudo = [regex]::Replace($conteudo,
        '(?m)^(Const MS_TRAVA\s*=\s*)\d+', "`${1}$MsTrava")
}
if ($conteudo -match '(?m)^Const MS_TRAVA\s*=\s*(\d+)') {
    $resultado.MsTrava = $Matches[1]
}

# 3b) CAMINHO DO APP - varia entre servidores; detecta se nao informado
if (-not $AppPath) {
    $AppPath = DetectarAppPath
    if ($AppPath) { $resultado.AppOrigem = "detectado" }
} else {
    $resultado.AppOrigem = "informado"
}

if ($AppPath) {
    $appDir  = Split-Path $AppPath -Parent          # ...\DOC-Windows
    $appBase = Split-Path $appDir  -Parent          # ...\DeMaria(...)
    $licFile = Join-Path $appDir "logs\log_license.txt"
    $wql     = ($appBase -replace '\\', '\\') + '\\%'   # escape p/ WQL

    $conteudo = [regex]::Replace($conteudo, '(?m)^Const APP_PATH\s*=.*$', "Const APP_PATH   = ""$AppPath""")
    $conteudo = [regex]::Replace($conteudo, '(?m)^Const APP_DIR\s*=.*$',  "Const APP_DIR    = ""$appDir""")
    $conteudo = [regex]::Replace($conteudo, '(?m)^Const APP_WQL\s*=.*$',  "Const APP_WQL    = ""$wql""")
    $conteudo = [regex]::Replace($conteudo, '(?m)^Const LIC_FILE\s*=.*$', "Const LIC_FILE   = ""$licFile""")
    $resultado.AppPath = $AppPath
}

Set-Content $destVbs -Value $conteudo -Encoding Default -NoNewline

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
if ($AppPath -and (Test-Path $AppPath)) {
    $resultado.AppEncontr = "ok"
} else {
    $resultado.AppEncontr = "NAO ENCONTRADO"
    $resultado.Status = "ATENCAO"
    $resultado.Detalhe = "Nao localizei o DOC-Windows.exe neste servidor. " +
        "Rode de novo com -AppPath ""<caminho completo do exe>""."
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
