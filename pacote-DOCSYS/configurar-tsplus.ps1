<#
================================================================
 CONFIGURA O TSPLUS para usar o lancador  -  execucao LOCAL
 Aplica as duas configuracoes obrigatorias, sem AdminTool:

  1) [Security] no-daughter-process = yes
     (o "Disable the daughter process handler"; sem isso o TSplus
      derruba a sessao ~10s depois de abrir)

  2) A aplicacao publicada passa a apontar para o lancador:
        path    = C:\Windows\System32\wscript.exe
        startup = C:\DOCSYS
        cmdline = "C:\DOCSYS\iniciar.vbs"

 COMO AGE: edita cirurgicamente o AppControl.ini. Se ja existir uma
 aplicacao publicada apontando para o app (DOC-Windows.exe /
 AppLauncher.exe), ela e' CONVERTIDA - preservando nome e grupos
 atribuidos. Caso contrario, cria uma nova entrada.

 NAO copia o AppControl.ini de outro servidor de proposito: o
 arquivo contem valores proprios da maquina (ex.: ip_html_pages).

 Faz backup antes de qualquer alteracao.

 Uso (como Administrador):
   powershell -ExecutionPolicy Bypass -File .\configurar-tsplus.ps1
   powershell -ExecutionPolicy Bypass -File .\configurar-tsplus.ps1 -Simular
================================================================
#>
param(
    [string] $Grupos   = "",       # ex.: "MEUDOMINIO\Domain Users" (vazio = mantem o atual)
    [string] $AppNome  = "",       # nome exibido (vazio = mantem o atual)
    [switch] $Simular              # mostra o que faria, sem gravar
)

$ErrorActionPreference = "Stop"

$r = [ordered]@{
    Servidor   = $env:COMPUTERNAME
    AppControl = "-"
    Daughter   = "-"
    Publicacao = "-"
    PorUsuario = "-"
    Backup     = "-"
    Status     = "OK"
    Detalhe    = ""
}
function Terminar($msg) {
    $r.Status = "ERRO"; $r.Detalhe = $msg
    [pscustomobject]$r
    exit 1
}

# --- Admin --------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Terminar "Precisa executar como Administrador."
}

# --- Localiza o AppControl.ini ------------------------------------
$raiz = @("C:\Program Files (x86)\TSplus","C:\Program Files\TSplus") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $raiz) { Terminar "TSplus nao encontrado." }

$ini = Join-Path $raiz "UserDesktop\files\AppControl.ini"
if (-not (Test-Path $ini)) { Terminar "AppControl.ini nao encontrado em $ini" }
$r.AppControl = $ini

# --- Le preservando a codificacao (UTF-16 no TSplus) --------------
$bytes = [IO.File]::ReadAllBytes($ini)
$ehUtf16 = ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE)
$enc = if ($ehUtf16) { [Text.Encoding]::Unicode } else { [Text.Encoding]::Default }
$texto = $enc.GetString($bytes)
# Remove o BOM: se ficar, a 1a linha vira "<BOM>[Security]" e nao e'
# reconhecida como cabecalho de secao.
if ($texto.Length -gt 0 -and [int][char]$texto[0] -eq 0xFEFF) { $texto = $texto.Substring(1) }
$linhas = [Collections.Generic.List[string]]($texto -split "`r?`n")

# --- Backup -------------------------------------------------------
$bkp = "$ini.bkp_" + (Get-Date -Format "yyyyMMdd-HHmmss")
if (-not $Simular) { Copy-Item $ini $bkp -Force; $r.Backup = $bkp } else { $r.Backup = "(simulacao)" }

# --- Helpers ------------------------------------------------------
function EhCabecalho($l) { $l.Trim() -match '^\[.+\]$' }
function NomeSecao($l)   { $l.Trim().Trim('[',']') }

function IndiceSecao($nome) {
    for ($i = 0; $i -lt $linhas.Count; $i++) {
        if ((EhCabecalho $linhas[$i]) -and (NomeSecao $linhas[$i]) -ieq $nome) { return $i }
    }
    return -1
}
function FimSecao($ini2) {
    for ($i = $ini2 + 1; $i -lt $linhas.Count; $i++) {
        if (EhCabecalho $linhas[$i]) { return $i - 1 }
    }
    return $linhas.Count - 1
}
function ValorChave($ini2, $fim, $chave) {
    for ($i = $ini2 + 1; $i -le $fim; $i++) {
        if ($linhas[$i] -match "^\s*$([regex]::Escape($chave))\s*=(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}
function DefinirChave($ini2, $fim, $chave, $valor) {
    for ($i = $ini2 + 1; $i -le $fim; $i++) {
        if ($linhas[$i] -match "^\s*$([regex]::Escape($chave))\s*=") {
            $linhas[$i] = "$chave=$valor"
            return $true      # substituida
        }
    }
    $linhas.Insert($fim + 1, "$chave=$valor")
    return $false             # inserida
}

# --- 1) no-daughter-process = yes ---------------------------------
$iSec = IndiceSecao "Security"
if ($iSec -lt 0) { Terminar "Secao [Security] nao encontrada no AppControl.ini" }
$fSec = FimSecao $iSec
$atual = ValorChave $iSec $fSec "no-daughter-process"

if ($atual -ieq "yes") {
    $r.Daughter = "ja estava yes"
} else {
    [void](DefinirChave $iSec $fSec "no-daughter-process" "yes")
    $r.Daughter = "definido yes (antes: $(if ($atual) { $atual } else { 'ausente' }))"
}

# --- 2) Publicacao apontando para o lancador ----------------------
$ALVO_PATH  = "C:\Windows\System32\wscript.exe"
$ALVO_START = "C:\DOCSYS"
$ALVO_CMD   = '"C:\DOCSYS\iniciar.vbs"'

# mapeia todos os blocos [AppN]
$apps = @()
for ($i = 0; $i -lt $linhas.Count; $i++) {
    if ((EhCabecalho $linhas[$i]) -and ((NomeSecao $linhas[$i]) -match '^App(\d+)$')) {
        $apps += [pscustomobject]@{ Num = [int]$Matches[1]; Inicio = $i; Fim = (FimSecao $i) }
    }
}

$alvo = $null; $motivo = ""
foreach ($a in $apps) {
    $p = ValorChave $a.Inicio $a.Fim "path"
    $c = ValorChave $a.Inicio $a.Fim "cmdline"
    if ($p -and $p -match 'wscript\.exe' -and $c -match 'iniciar\.vbs') {
        $alvo = $a; $motivo = "ja apontava para o lancador"; break
    }
}
if (-not $alvo) {
    foreach ($a in $apps) {
        $p = ValorChave $a.Inicio $a.Fim "path"
        if ($p -and ($p -match 'DOC-Windows\.exe' -or $p -match 'AppLauncher\.exe' -or $p -match '\\DeMaria\\')) {
            $alvo = $a; $motivo = "convertida (apontava direto para o app)"; break
        }
    }
}

if ($alvo) {
    $nomeAtual  = ValorChave $alvo.Inicio $alvo.Fim "appname"
    $grupoAtual = ValorChave $alvo.Inicio $alvo.Fim "groups"
    [void](DefinirChave $alvo.Inicio $alvo.Fim "path"    $ALVO_PATH)
    $alvo.Fim = FimSecao $alvo.Inicio
    [void](DefinirChave $alvo.Inicio $alvo.Fim "startup" $ALVO_START)
    $alvo.Fim = FimSecao $alvo.Inicio
    [void](DefinirChave $alvo.Inicio $alvo.Fim "cmdline" $ALVO_CMD)
    if ($AppNome) { $alvo.Fim = FimSecao $alvo.Inicio; [void](DefinirChave $alvo.Inicio $alvo.Fim "appname" $AppNome) }
    if ($Grupos)  { $alvo.Fim = FimSecao $alvo.Inicio; [void](DefinirChave $alvo.Inicio $alvo.Fim "groups"  $Grupos)  }
    $r.Publicacao = "[App$($alvo.Num)] $motivo (nome='$nomeAtual', grupos='$grupoAtual')"
} else {
    # cria um bloco novo no fim
    $novo = 1
    if ($apps) { $novo = ($apps | Measure-Object Num -Maximum).Maximum + 1 }
    if (-not $Grupos) {
        $r.Status  = "ATENCAO"
        $r.Detalhe = "Nenhuma aplicacao existente para converter e -Grupos nao informado: ninguem vera o app. Rode de novo com -Grupos 'DOMINIO\Domain Users'."
    }
    $linhas.Add("")
    $linhas.Add("[App$novo]")
    $linhas.Add("appname=$(if ($AppNome) { $AppNome } else { 'DOC-Windows' })")
    $linhas.Add("path=$ALVO_PATH")
    $linhas.Add("startup=$ALVO_START")
    $linhas.Add("cmdline=$ALVO_CMD")
    $linhas.Add("groups=$Grupos")
    $linhas.Add("users=")
    $linhas.Add("maximized=no")
    $linhas.Add("minimized=no")
    $linhas.Add("hide=no")
    $linhas.Add("all_users=no")
    $r.Publicacao = "[App$novo] criada"
}

# --- Grava --------------------------------------------------------
if (-not $Simular) {
    $texto = ($linhas -join "`r`n")
    [IO.File]::WriteAllBytes($ini, $enc.GetPreamble() + $enc.GetBytes($texto))
} else {
    $r.Publicacao += "  [SIMULACAO - nada gravado]"
}

# --- 3) Arquivos por usuario (se existirem, ficam coerentes) ------
$dirUsr = Join-Path $raiz "UserDesktop\themes\UserApplication"
$ajust = 0
if (Test-Path $dirUsr) {
    Get-ChildItem $dirUsr -Filter "*_MyRemoteApp.ini" -File -ErrorAction SilentlyContinue | ForEach-Object {
        $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($c -and ($c -match 'DOC-Windows\.exe' -or $c -match 'AppLauncher\.exe')) {
            if (-not $Simular) {
                Copy-Item $_.FullName "$($_.FullName).bkp" -Force -ErrorAction SilentlyContinue
                $c2 = $c -replace '(?m)^path=.*(DOC-Windows|AppLauncher)\.exe.*$', "path=$ALVO_PATH"
                $c2 = $c2 -replace '(?m)^startup=.*$', "startup=$ALVO_START"
                $c2 = $c2 -replace '(?m)^cmdline=.*$', "cmdline=C:\DOCSYS\iniciar.vbs"
                Set-Content $_.FullName -Value $c2 -NoNewline -ErrorAction SilentlyContinue
            }
            $ajust++
        }
    }
    $r.PorUsuario = if ($ajust -gt 0) { "$ajust arquivo(s) ajustado(s)" } else { "nada a ajustar" }
} else {
    $r.PorUsuario = "pasta nao existe (normal em servidor novo)"
}

[pscustomobject]$r

Write-Host ""
Write-Host "Config aplicada. Teste um logon antes de seguir para o proximo servidor." -ForegroundColor Green
if ($r.Backup -notlike "(simul*") {
    Write-Host "Backup do AppControl.ini: $($r.Backup)" -ForegroundColor DarkGray
}
Write-Host ""
