<#
================================================================
 CAPTURA da configuracao do TSplus
 Rodar UMA VEZ no servidor QUE JA ESTA FUNCIONANDO.

 NAO altera nada. Localiza e copia os arquivos/chaves onde o TSplus
 guarda as duas configuracoes que precisamos replicar:
   (a) a publicacao apontando para C:\DOCSYS\iniciar.vbs
   (b) a opcao "daughter process handler"

 Gera:  C:\DOCSYS\captura-tsplus\  (pasta com o material)
        C:\DOCSYS\captura-tsplus.zip

 ATENCAO: revise o conteudo antes de compartilhar - arquivos de
 configuracao do TSplus PODEM conter chave de licenca. O script
 avisa se encontrar algo com cara de licenca.

 Uso (como Administrador):
   powershell -ExecutionPolicy Bypass -File .\descobrir-config-tsplus.ps1
================================================================
#>
$ErrorActionPreference = "SilentlyContinue"

$saidaDir = "C:\DOCSYS\captura-tsplus"
$relat    = Join-Path $saidaDir "RELATORIO.txt"
Remove-Item $saidaDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $saidaDir -Force | Out-Null
New-Item -ItemType Directory -Path "$saidaDir\arquivos" -Force | Out-Null

$L = @()
$L += "=== CAPTURA CONFIG TSPLUS ==="
$L += "Servidor : $env:COMPUTERNAME"
$L += "Data     : $(Get-Date)"
$L += ""

# --- Raiz do TSplus ----------------------------------------------
$raiz = @("C:\Program Files (x86)\TSplus","C:\Program Files\TSplus") |
        Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $raiz) {
    $L += "TSplus NAO encontrado. Abortando."
    $L | Set-Content $relat -Encoding UTF8
    Write-Host "TSplus nao encontrado." -ForegroundColor Red
    exit 1
}
$L += "Raiz TSplus: $raiz"
$L += ""

# --- 1. Arquivos que citam o lancador ou 'daughter' --------------
$padroes  = @("iniciar\.vbs", "wscript", "daughter", "DOCSYS")
$achados  = @()

Get-ChildItem -Path $raiz -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -lt 5MB } |
    ForEach-Object {
        $arq = $_
        foreach ($p in $padroes) {
            $hits = Select-String -Path $arq.FullName -Pattern $p -ErrorAction SilentlyContinue
            if ($hits) {
                $achados += [pscustomobject]@{
                    Arquivo = $arq.FullName
                    Padrao  = $p
                    Linhas  = ($hits | ForEach-Object { "L$($_.LineNumber): $($_.Line.Trim())" }) -join " | "
                }
                break
            }
        }
    }

$L += "--- [1] ARQUIVOS RELEVANTES ---"
if ($achados) {
    foreach ($a in ($achados | Sort-Object Arquivo -Unique)) {
        $L += ""
        $L += "ARQUIVO: $($a.Arquivo)"
        $L += "  match : $($a.Padrao)"
        $L += "  trecho: $($a.Linhas)"
        # copia o arquivo para analise
        $nome = ($a.Arquivo -replace [regex]::Escape($raiz), "" -replace "[\\/:]", "_").TrimStart("_")
        Copy-Item $a.Arquivo "$saidaDir\arquivos\$nome" -Force -ErrorAction SilentlyContinue
    }
} else {
    $L += "(nenhum arquivo citou iniciar.vbs / daughter - a config pode estar no registro)"
}

# --- 2. Registro --------------------------------------------------
$L += ""
$L += "--- [2] REGISTRO ---"
$chaves = @(
    "HKLM:\SOFTWARE\WOW6432Node\Digital River",
    "HKLM:\SOFTWARE\Digital River",
    "HKLM:\SOFTWARE\WOW6432Node\TSplus",
    "HKLM:\SOFTWARE\TSplus"
)
foreach ($c in $chaves) {
    if (Test-Path $c) {
        $L += ""
        $L += "[$c]"
        Get-ChildItem -Path $c -Recurse -ErrorAction SilentlyContinue |
          ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p) {
                $cam = $_.PSPath -replace "Microsoft.PowerShell.Core\\Registry::",""
                $vals = $p.PSObject.Properties |
                        Where-Object { $_.Name -notlike "PS*" }
                if ($vals) {
                    $L += "  $cam"
                    $vals | ForEach-Object { $L += "      $($_.Name) = $($_.Value)" }
                }
            }
          }
        # exporta a chave inteira
        $nomeReg = ($c -replace "[:\\]", "_") + ".reg"
        & reg export ($c -replace "HKLM:","HKLM") "$saidaDir\arquivos\$nomeReg" /y 2>&1 | Out-Null
    }
}

# --- 3. Estado atual do lancador ---------------------------------
$L += ""
$L += "--- [3] ESTADO DO LANCADOR ---"
$L += "iniciar.vbs presente : $(Test-Path 'C:\DOCSYS\iniciar.vbs')"
if (Test-Path "C:\DOCSYS\iniciar.vbs") {
    $c = Get-Content "C:\DOCSYS\iniciar.vbs" -Raw -Encoding Default
    if ($c -match '(?m)^Const MS_TRAVA\s*=\s*(\d+)')      { $L += "MS_TRAVA             : $($Matches[1])" }
    if ($c -match '(?m)^Const MAX_TENTATIVAS\s*=\s*(\d+)'){ $L += "MAX_TENTATIVAS       : $($Matches[1])" }
}
$L += "App DeMaria presente : $(Test-Path 'C:\DeMaria\DOC-Windows\DOC-Windows.exe')"

# --- 4. Alerta de dado sensivel ----------------------------------
$L += ""
$L += "--- [4] REVISAO ANTES DE COMPARTILHAR ---"
$suspeitos = Get-ChildItem "$saidaDir\arquivos" -File -ErrorAction SilentlyContinue |
             ForEach-Object {
                 $h = Select-String -Path $_.FullName -Pattern "licen|serial|key|activation" -ErrorAction SilentlyContinue
                 if ($h) { $_.Name }
             } | Select-Object -Unique
if ($suspeitos) {
    $L += "ATENCAO: os arquivos abaixo citam licenca/serial. REVISE antes de enviar:"
    $suspeitos | ForEach-Object { $L += "  - $_" }
} else {
    $L += "Nenhum indicio de chave de licenca nos arquivos capturados."
}

$L | Set-Content $relat -Encoding UTF8

# --- Empacota -----------------------------------------------------
$zip = "C:\DOCSYS\captura-tsplus.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path "$saidaDir\*" -DestinationPath $zip -Force

Write-Host ""
Write-Host "Captura concluida." -ForegroundColor Green
Write-Host "  Relatorio : $relat"
Write-Host "  Pacote    : $zip"
Write-Host ""
Write-Host "REVISE o RELATORIO.txt (secao 4) antes de compartilhar o zip." -ForegroundColor Yellow
Write-Host ""
