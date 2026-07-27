<#
================================================================
 IMPLANTACAO EM MASSA - Lancador DOC-Windows
 Roda de UMA maquina (sua estacao ou um servidor de gerencia) e
 instala em todos os servidores da lista.

 Uso:
   # 1) edite servidores.txt (um servidor por linha)
   # 2) rode como usuario com direito de admin nos servidores:
   powershell -ExecutionPolicy Bypass -File .\deploy-multi.ps1

 Opcoes:
   -Lista      caminho do arquivo com os servidores (padrao servidores.txt)
   -MsTrava    valor a gravar em MS_TRAVA (0 = mantem o do arquivo)
   -Verificar  nao instala, so faz diagnostico dos servidores
   -Paralelo   quantos servidores em paralelo (padrao 5)

 Requisitos nos servidores: WinRM habilitado (padrao em dominio via
 GPO). Se nao houver WinRM, use o modo alternativo descrito no
 LEIA-ME (copia por \\servidor\C$ + execucao manual).
================================================================
#>
param(
    [string] $Lista     = (Join-Path $PSScriptRoot "servidores.txt"),
    [int]    $MsTrava   = 0,
    [switch] $Verificar,
    [int]    $Paralelo  = 5,
    [System.Management.Automation.PSCredential] $Credencial
)

$ErrorActionPreference = "Stop"

# --- Lista de servidores -----------------------------------------
if (-not (Test-Path $Lista)) { throw "Arquivo de lista nao encontrado: $Lista" }
$servidores = Get-Content $Lista |
              ForEach-Object { $_.Trim() } |
              Where-Object { $_ -and -not $_.StartsWith("#") }
if (-not $servidores) { throw "Nenhum servidor na lista." }

Write-Host ""
Write-Host "=== Lancador DOC-Windows - implantacao em $($servidores.Count) servidor(es) ===" -ForegroundColor Cyan
Write-Host ""

# --- Credencial ---------------------------------------------------
if (-not $Credencial) {
    $Credencial = Get-Credential -Message "Usuario ADMIN dos servidores (ex.: MEUDOMINIO\administrator)"
}

# --- Arquivos a enviar --------------------------------------------
$arquivos = @("iniciar.vbs", "instalar.ps1") |
            ForEach-Object { Join-Path $PSScriptRoot $_ }
foreach ($a in $arquivos) {
    if (-not (Test-Path $a)) { throw "Arquivo do pacote nao encontrado: $a" }
}

$resultados = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

# --- Bloco executado por servidor ---------------------------------
$trabalho = {
    param($srv, $cred, $arquivos, $msTrava, $somenteVerificar)

    $r = [ordered]@{
        Servidor = $srv; Conexao = "-"; Script = "-"; MsTrava = "-"
        App = "-"; TSplus = "-"; Status = "ERRO"; Detalhe = ""
    }
    try {
        if (-not (Test-Connection -ComputerName $srv -Count 1 -Quiet)) {
            $r.Conexao = "sem ping"; $r.Detalhe = "servidor inacessivel"
            return [pscustomobject]$r
        }
        $r.Conexao = "ok"

        $sess = New-PSSession -ComputerName $srv -Credential $cred -ErrorAction Stop

        try {
            # pasta de trabalho remota
            Invoke-Command -Session $sess -ScriptBlock {
                if (-not (Test-Path "C:\Temp\pacote-DOCSYS")) {
                    New-Item -ItemType Directory -Path "C:\Temp\pacote-DOCSYS" -Force | Out-Null
                }
            }

            if (-not $somenteVerificar) {
                foreach ($a in $arquivos) {
                    Copy-Item -Path $a -Destination "C:\Temp\pacote-DOCSYS\" -ToSession $sess -Force
                }
            }

            $saida = Invoke-Command -Session $sess -ArgumentList $msTrava, $somenteVerificar -ScriptBlock {
                param($mt, $soVer)
                if ($soVer) {
                    # diagnostico sem instalar
                    $vbs = "C:\DOCSYS\iniciar.vbs"
                    $o = [ordered]@{ Script="ausente"; MsTrava="-"; App="-" }
                    if (Test-Path $vbs) {
                        $c = Get-Content $vbs -Raw -Encoding Default
                        $o.Script = if ($c -match "MAX_TENTATIVAS") { "atual" } else { "ANTIGO" }
                        if ($c -match '(?m)^Const MS_TRAVA\s*=\s*(\d+)') { $o.MsTrava = $Matches[1] }
                    }
                    $o.App = if (Test-Path "C:\DeMaria\DOC-Windows\DOC-Windows.exe") { "ok" } else { "ausente" }
                    [pscustomobject]$o
                } else {
                    & powershell -ExecutionPolicy Bypass -File "C:\Temp\pacote-DOCSYS\instalar.ps1" `
                        -Origem "C:\Temp\pacote-DOCSYS" -MsTrava $mt
                }
            }

            if ($somenteVerificar) {
                $r.Script  = $saida.Script
                $r.MsTrava = $saida.MsTrava
                $r.App     = $saida.App
                $r.Status  = "VERIFICADO"
            } else {
                $r.Script  = $saida.Script
                $r.MsTrava = $saida.MsTrava
                $r.App     = $saida.AppEncontr
                $r.TSplus  = $saida.TSplusPath
                $r.Status  = $saida.Status
                $r.Detalhe = $saida.Detalhe
            }
        } finally {
            Remove-PSSession $sess -ErrorAction SilentlyContinue
        }
    } catch {
        $r.Detalhe = $_.Exception.Message
    }
    [pscustomobject]$r
}

# --- Execucao (em lotes paralelos) --------------------------------
$jobs = @()
foreach ($srv in $servidores) {
    while (@(Get-Job -State Running).Count -ge $Paralelo) { Start-Sleep -Milliseconds 500 }
    Write-Host ("-> {0}" -f $srv)
    $jobs += Start-Job -ScriptBlock $trabalho `
             -ArgumentList $srv, $Credencial, $arquivos, $MsTrava, $Verificar.IsPresent
}

Write-Host ""
Write-Host "Aguardando conclusao..." -ForegroundColor DarkGray
$jobs | Wait-Job | Out-Null
$saidas = $jobs | Receive-Job
$jobs | Remove-Job -Force

# --- Relatorio ----------------------------------------------------
Write-Host ""
Write-Host "=== RESULTADO ===" -ForegroundColor Cyan
$saidas | Format-Table Servidor, Conexao, Script, MsTrava, App, Status, Detalhe -AutoSize -Wrap

$falhas = @($saidas | Where-Object { $_.Status -eq "ERRO" })
$aten   = @($saidas | Where-Object { $_.Status -eq "ATENCAO" })

Write-Host ""
Write-Host ("OK: {0}   Atencao: {1}   Erro: {2}" -f `
    (@($saidas).Count - $falhas.Count - $aten.Count), $aten.Count, $falhas.Count)

$csv = Join-Path $PSScriptRoot ("resultado-deploy_{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmm"))
$saidas | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host "Relatorio salvo em: $csv" -ForegroundColor DarkGray

if ($falhas.Count -gt 0) {
    Write-Host ""
    Write-Host "Servidores com ERRO (reprocessar):" -ForegroundColor Yellow
    $falhas | ForEach-Object { Write-Host ("  {0}  - {1}" -f $_.Servidor, $_.Detalhe) }
}

Write-Host ""
Write-Host "LEMBRETE: o script e' metade do trabalho. Em cada servidor" -ForegroundColor Yellow
Write-Host "confira tambem a config do TSplus (ver LEIA-ME, secao TSplus):" -ForegroundColor Yellow
Write-Host "  1) Aplicacao publicada -> wscript.exe + \"C:\DOCSYS\iniciar.vbs\""
Write-Host "  2) Advanced > Session > Disable the daughter process handler = Yes"
Write-Host ""
