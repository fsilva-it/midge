<#
================================================================
 DESCOBERTA da configuracao do TSplus
 Rodar UMA VEZ no servidor QUE JA FUNCIONA (SERVIDOR-TS01).

 Nao altera nada. Apenas localiza ONDE o TSplus guarda:
   (a) o caminho da aplicacao publicada (deve citar iniciar.vbs)
   (b) a opcao "daughter process handler"
 e gera um relatorio para automatizarmos a replicacao nos demais.

 Uso (como Administrador):
   powershell -ExecutionPolicy Bypass -File .\descobrir-config-tsplus.ps1

 Saida: C:\DOCSYS\config-tsplus-descoberta.txt
================================================================
#>
$ErrorActionPreference = "SilentlyContinue"
$saida = "C:\DOCSYS\config-tsplus-descoberta.txt"
if (-not (Test-Path "C:\DOCSYS")) { New-Item -ItemType Directory "C:\DOCSYS" -Force | Out-Null }

$linhas = @()
$linhas += "=== DESCOBERTA CONFIG TSPLUS ==="
$linhas += "Servidor : $env:COMPUTERNAME"
$linhas += "Data     : $(Get-Date)"
$linhas += ""

# --- 1. Raiz do TSplus -------------------------------------------
$raizes = @(
    "C:\Program Files (x86)\TSplus",
    "C:\Program Files\TSplus"
) | Where-Object { Test-Path $_ }

if (-not $raizes) {
    $linhas += "TSplus NAO encontrado nos caminhos padrao."
} else {
    foreach ($raiz in $raizes) {
        $linhas += "--- Raiz: $raiz"

        # (a) arquivos que citam iniciar.vbs / wscript
        $linhas += ""
        $linhas += "[A] Arquivos que citam 'iniciar.vbs' ou 'wscript':"
        Get-ChildItem -Path $raiz -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt 3MB -and $_.Extension -match '\.(ini|txt|xml|json|cfg|conf|dat|lic)$' } |
            ForEach-Object {
                $hits = Select-String -Path $_.FullName -Pattern "iniciar\.vbs|wscript" -ErrorAction SilentlyContinue
                foreach ($h in $hits) {
                    $linhas += ("  {0}" -f $_.FullName)
                    $linhas += ("     linha {0}: {1}" -f $h.LineNumber, $h.Line.Trim())
                }
            }

        # (b) arquivos que citam daughter / DisableDaughter
        $linhas += ""
        $linhas += "[B] Arquivos que citam 'daughter':"
        Get-ChildItem -Path $raiz -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt 3MB } |
            ForEach-Object {
                $hits = Select-String -Path $_.FullName -Pattern "daughter" -ErrorAction SilentlyContinue
                foreach ($h in $hits) {
                    $linhas += ("  {0}" -f $_.FullName)
                    $linhas += ("     linha {0}: {1}" -f $h.LineNumber, $h.Line.Trim())
                }
            }

        # (c) arquivos de config mais provaveis (listagem)
        $linhas += ""
        $linhas += "[C] Arquivos .ini/.json/.xml sob a raiz (candidatos a config):"
        Get-ChildItem -Path $raiz -Recurse -File -Include *.ini,*.json,*.xml -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 40 |
            ForEach-Object { $linhas += ("  {0}  ({1:yyyy-MM-dd HH:mm})" -f $_.FullName, $_.LastWriteTime) }
    }
}

# --- 2. Registro --------------------------------------------------
$linhas += ""
$linhas += "--- Registro (chaves TSplus / Terminal Server) ---"
$chaves = @(
    "HKLM:\SOFTWARE\WOW6432Node\Digital River",
    "HKLM:\SOFTWARE\Digital River",
    "HKLM:\SOFTWARE\WOW6432Node\TSplus",
    "HKLM:\SOFTWARE\TSplus",
    "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
)
foreach ($c in $chaves) {
    if (Test-Path $c) {
        $linhas += ""
        $linhas += "[$c]"
        Get-ChildItem -Path $c -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 60 |
            ForEach-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($props) {
                    $linhas += ("  {0}" -f $_.PSPath.Replace("Microsoft.PowerShell.Core\Registry::",""))
                    $props.PSObject.Properties |
                        Where-Object { $_.Name -notlike "PS*" } |
                        ForEach-Object { $linhas += ("      {0} = {1}" -f $_.Name, $_.Value) }
                }
            }
    }
}

# --- 3. Estado atual relevante ------------------------------------
$linhas += ""
$linhas += "--- Estado atual ---"
$linhas += ("iniciar.vbs presente : {0}" -f (Test-Path "C:\DOCSYS\iniciar.vbs"))
if (Test-Path "C:\DOCSYS\iniciar.vbs") {
    $c = Get-Content "C:\DOCSYS\iniciar.vbs" -Raw -Encoding Default
    if ($c -match '(?m)^Const MS_TRAVA\s*=\s*(\d+)') { $linhas += ("MS_TRAVA             : {0}" -f $Matches[1]) }
    $linhas += ("Auto-recuperacao     : {0}" -f ($c -match "MAX_TENTATIVAS"))
}
$linhas += ("App DeMaria presente : {0}" -f (Test-Path "C:\DeMaria\DOC-Windows\DOC-Windows.exe"))

$linhas | Set-Content -Path $saida -Encoding UTF8
Write-Host ""
Write-Host "Relatorio gerado em: $saida" -ForegroundColor Green
Write-Host "Envie este arquivo para automatizarmos a replicacao da config do TSplus."
Write-Host ""
