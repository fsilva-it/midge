'==================================================================
'  LANCADOR DO DOC-Windows  -  Terminal Service / TSplus  -  v3
'  Serializa a abertura simultanea (erro "Varias tentativas de
'  abertura detectadas" / colisao no log_license.txt) e mantem a
'  sessao RDP viva enquanto o sistema estiver aberto.
'
'  Publicar no TSplus:  C:\DOCSYS\iniciar.vbs
'  Diretorio inicial :  C:\DOCSYS
'  Requer: instalar.bat executado uma vez (pastas + permissoes)
'
'  Desenho v3 (revisao multi-agente):
'   - Lock = ARQUIVO aberto em modo exclusivo e mantido aberto.
'     Se a sessao cair, o SO fecha o handle e a fila anda sozinha
'     (nao existe mais "trava orfa" nem forca de 10 minutos).
'   - Liberacao INLINE apos o lancamento, ancorada no processo
'     real do app (sem segundo wscript /LIBERAR).
'   - Sessao detectada por filho do proprio wscript com marcador
'     unico + fallback "query session". Estado desconhecido NUNCA
'     gera logoff.
'   - Vigia hibrido: handle local do processo (custo zero) e WMI
'     por caminho C:\DeMaria\ somente quando o exe faz spawn-e-sai.
'==================================================================
Option Explicit

' ------------------------- CONFIGURACAO -------------------------
Const APP_PATH   = "C:\DeMaria\DOC-Windows\DOC-Windows.exe"
Const APP_DIR    = "C:\DeMaria\DOC-Windows"
Const APP_WQL    = "C:\\DeMaria\\%"          ' filtro de caminho no WMI
Const LIC_FILE   = "C:\DeMaria\DOC-Windows\logs\log_license.txt"

Const BASE_DIR   = "C:\DOCSYS"
Const LOCK_FILE  = "C:\DOCSYS\fila\fila.lock"   ' arquivo-mutex (handle exclusivo)
Const LOG_DIR    = "C:\DOCSYS\logs"

' Fase critica: tempo minimo com a fila travada APOS o app nascer.
' Deve cobrir a leitura de licenca + checagem de estacao (ate a
' tela de login aparecer). Calibrar: comecar em 12s; reduzir com teste.
' Tempo de trava usado APENAS como plano B, quando nao for possivel
' medir o CPU do app (WMI indisponivel). No caminho normal quem manda
' e' a fila adaptativa (ver MS_CARGA_* abaixo).
Const MS_TRAVA      = 20000

' Auto-recuperacao de colisao: se aparecer a janela de erro do app
' "Programa em Execucao / Varias tentativas...", o lancador mata a
' instancia travada e tenta de novo (ate MAX_TENTATIVAS). Assim uma
' colisao rara nao trava a sessao - o usuario so espera um pouco mais.
Const MAX_TENTATIVAS = 4
Const TITULO_ERRO    = "Programa em Execu"   ' prefixo do titulo da janela de erro

' Espera entre tentativas. As tentativas antigas (7s) caiam TODAS
' dentro da mesma janela critica do app - nao tinham chance. Agora
' a nova tentativa so ocorre depois que a janela passou.
Const MS_RETENTATIVA = 40000

' FILA ADAPTATIVA: em vez de segurar a fila por um tempo fixo, o
' lancador mede o CPU do app. Enquanto carrega, ele consome CPU;
' ao chegar na tela de login, fica ocioso. Assim a fila custa o
' tempo real de carga (rapido quando o servidor esta leve) e nunca
' menos que o necessario (quando esta pesado).
Const MS_CARGA_MIN  = 6000     ' piso: nunca liberar antes disso
Const MS_CARGA_MAX  = 75000    ' teto: nunca prender a fila alem disso
Const MS_CPU_POLL   = 1000     ' intervalo de medicao
Const CPU_OCIOSO    = 1500000  ' 100ns por segundo (~15% de um core)
Const QUIETOS_OK    = 3        ' medicoes ociosas seguidas p/ considerar carregado
Const MS_SPAWN_MAX  = 45000    ' teto p/ o processo do app aparecer apos o Run
Const MS_LIC_MAX    = 90000    ' teto de espera pelo log_license.txt livre
Const MS_LIC_POLL   = 500      ' intervalo da sonda de licenca (leitura)

Const MS_FILA_POLL  = 400      ' intervalo de tentativa do lock
Const MS_FILA_MAX   = 1800000  ' 30 min - teto absoluto de fila; ao estourar,
                               ' abre assim mesmo (registrado em log). Com o
                               ' lock por handle nao existe trava orfa, entao
                               ' so chega aqui em fila real gigante ou defeito.

Const MS_GRACA      = 60000    ' vigia: teto p/ o app aparecer via WMI
Const MS_POLL_EXEC  = 2000     ' vigia: poll do handle local (custo zero)
Const MS_POLL_WMI   = 10000    ' vigia: poll WMI (so no modo spawn-e-sai)
Const MS_VIGIA_MAX  = 43200000 ' 12h - teto anti-sessao-zumbi

Dim PROCESSOS_APP
PROCESSOS_APP = Array("DOC-Windows.exe", "AppLauncher.exe")
' ----------------------------------------------------------------

Dim fso, sh, wmi, lockHandle, gSessao, gMeuPid, logPath
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
Set lockHandle = Nothing
gSessao = -1
gMeuPid = -1
Randomize

'=================================================================
' INFRA: pastas de trabalho e log (nunca deixam o script morrer)
'=================================================================
GarantirPasta BASE_DIR
GarantirPasta BASE_DIR & "\fila"
GarantirPasta LOG_DIR

logPath = LOG_DIR & "\" & NomeUsuario() & "_" & _
          Year(Date) & Zero2(Month(Date)) & Zero2(Day(Date)) & ".log"

'=================================================================
' WMI com retry; se indisponivel, seguimos em MODO DEGRADADO
' (sem idempotencia/vigia WMI - mas NUNCA logoff cego).
'=================================================================
Dim tentWmi
Set wmi = Nothing
On Error Resume Next
For tentWmi = 1 To 3
    Err.Clear
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number = 0 Then Exit For
    Set wmi = Nothing
    WScript.Sleep 2000
Next
On Error GoTo 0
If wmi Is Nothing Then Log "AVISO: WMI indisponivel - modo degradado"

'=================================================================
' VERIFICACOES INICIAIS
'=================================================================
If Not fso.FileExists(APP_PATH) Then
    Log "ERRO: executavel nao encontrado: " & APP_PATH
    sh.Popup "Executavel nao encontrado:" & vbCrLf & vbCrLf & APP_PATH, _
             30, "Lancador DOC-Windows", vbCritical
    WScript.Quit 1
End If

DescobrirSessao   ' preenche gSessao e gMeuPid (ou deixa -1)
Log "INICIO sessao=" & gSessao & " pid=" & gMeuPid & " nome=" & NomeSessao()

' Nunca rodar como servico/agendador (sessao 0): abriria o app
' invisivel segurando licenca/estacao sem ninguem ver.
If gSessao = 0 Then
    Log "ABORTADO: executado em sessao 0 (servico/agendador)"
    WScript.Quit 2
End If

'=================================================================
' SINGLETON POR SESSAO
' Se ja existe outro wscript rodando ESTE script nesta sessao
' (reexecucao pelo TSplus, clique duplo), este sai em silencio.
'=================================================================
If SouDuplicado() Then
    ' So cede ao lancador mais antigo se o app estiver mesmo de pe;
    ' senao (vigia antigo prestes a sair apos o usuario fechar e
    ' reabrir), este assume o lugar.
    If AppNaSessao() Then
        Log "SAIDA: outra instancia do lancador + app aberto nesta sessao"
        WScript.Quit 0
    Else
        Log "AVISO: lancador antigo em vigia sem app - prosseguindo"
    End If
End If

'=================================================================
' IDEMPOTENCIA
' App (DOC-Windows.exe, caminho C:\DeMaria\) ja aberto NESTA
' sessao -> nao abre de novo; vai direto vigiar.
'=================================================================
Dim jaAberto, exApp
jaAberto = False
Set exApp = Nothing
If (gSessao >= 0) And (Not wmi Is Nothing) Then
    If AppNaSessao() Then
        jaAberto = True
        Log "IDEMPOTENCIA: app ja aberto nesta sessao"
    End If
End If

If Not jaAberto Then

    '=============================================================
    ' FILA: adquire o arquivo-mutex (open exclusivo)
    '=============================================================
    ' Lock com atributo somente-leitura daria erro 70 eterno: limpa.
    On Error Resume Next
    If fso.FileExists(LOCK_FILE) Then
        Dim atrLock
        atrLock = fso.GetFile(LOCK_FILE).Attributes
        If (atrLock And 1) = 1 Then fso.GetFile(LOCK_FILE).Attributes = atrLock And (Not 1)
    End If
    On Error GoTo 0

    Dim esperou, comLock, errLock, errosDuros, desde70, infraOk
    esperou = 0
    comLock = False
    errosDuros = 0
    desde70 = 0      ' ms acumulados recebendo erro 70 sem validar a infra
    infraOk = False  ' ja provamos que conseguimos gravar em \fila?
    Do
        On Error Resume Next
        Err.Clear
        Set lockHandle = fso.OpenTextFile(LOCK_FILE, 2, True)  ' 2=ForWriting
        errLock = Err.Number
        On Error GoTo 0
        If errLock = 0 Then comLock = True

        If comLock Then Exit Do

        If errLock = 70 Then
            ' 70 = tanto "fila ocupada" (normal) quanto ACL negada.
            ' Desambiguar: a cada 60s, provar que conseguimos criar um
            ' arquivo proprio em \fila. Se nao conseguimos, e' defeito
            ' de instalacao - nao ficar 30min preso.
            errosDuros = 0
            desde70 = desde70 + MS_FILA_POLL
            If (Not infraOk) And (desde70 >= 60000) Then
                If PastaFilaGravavel() Then
                    infraOk = True
                Else
                    Log "AVISO: sem permissao em \fila (erro 70 de ACL)" & _
                        " - abrindo sem fila. Rodar instalar.bat?"
                    Exit Do
                End If
            End If
        Else
            ' 76 = pasta \fila inexistente; outros = disco/config.
            errosDuros = errosDuros + 1
            If errosDuros >= 10 Then
                Log "AVISO: lock inacessivel (erro " & errLock & _
                    ") - abrindo sem fila. Rodar instalar.bat?"
                Exit Do
            End If
        End If

        If esperou >= MS_FILA_MAX Then
            Log "AVISO: fila estourou " & (MS_FILA_MAX \ 60000) & _
                "min - abrindo sem lock"
            Exit Do
        End If
        ' Poll com jitter: evita 40 sessoes tentando em fase sincronizada
        WScript.Sleep MS_FILA_POLL + Int(Rnd * 300)
        esperou = esperou + MS_FILA_POLL
    Loop
    Log "FILA: esperei " & esperou & "ms (lock=" & comLock & ")"

    ' Caminho de excecao (sem lock): espalha os lancamentos no tempo
    ' para nao virar estampida sincronizada de 40 sessoes.
    If Not comLock Then WScript.Sleep Int(Rnd * 15000)

    If comLock Then
        On Error Resume Next
        lockHandle.WriteLine Now & " sessao=" & gSessao & " user=" & NomeUsuario()
        On Error GoTo 0
    End If

    ' Re-checa idempotencia ja com o lock (janela do duplo clique)
    If (gSessao >= 0) And (Not wmi Is Nothing) Then
        If AppNaSessao() Then
            jaAberto = True
            Log "IDEMPOTENCIA pos-lock: app ja aberto"
            LiberarLock
        End If
    End If

    If Not jaAberto Then
        '=========================================================
        ' Espera a licenca livre (sonda de LEITURA - nao interfere)
        '=========================================================
        Dim tl
        tl = EsperarLicencaLivre()
        Log "LIC pre-lancamento: " & tl & "ms"

        '=========================================================
        ' LANCA O APP com AUTO-RECUPERACAO de colisao.
        ' A cada tentativa: lanca -> espera nascer -> vigia a fase
        ' critica (adaptativa) procurando a janela de erro. Se o erro
        ' "Varias tentativas" aparecer, mata a instancia travada e
        ' refaz. So libera a fila no fim (sucesso ou desistencia).
        '=========================================================
        Dim tentativa, abriuOk
        abriuOk = False

        For tentativa = 1 To MAX_TENTATIVAS
            On Error Resume Next
            Err.Clear
            sh.CurrentDirectory = APP_DIR
            Set exApp = sh.Exec("""" & APP_PATH & """")
            If Err.Number <> 0 Then
                Set exApp = Nothing
                Err.Clear
                sh.Run """" & APP_PATH & """", 1, False   ' fallback
            Else
                exApp.StdIn.Close
                exApp.StdOut.Close
                exApp.StdErr.Close
            End If
            On Error GoTo 0
            Log "LANCADO tentativa " & tentativa & " (exec=" & (Not (exApp Is Nothing)) & ")"

            ' Espera o processo real do app aparecer
            Dim tSpawn, nasceu
            tSpawn = 0
            nasceu = False
            Do While tSpawn < MS_SPAWN_MAX
                If AppNaSessao() Then nasceu = True : Exit Do
                If (wmi Is Nothing Or gSessao < 0) And (Not exApp Is Nothing) Then nasceu = True : Exit Do
                WScript.Sleep 1000
                tSpawn = tSpawn + 1000
            Loop
            Log "SPAWN: " & tSpawn & "ms (nasceu=" & nasceu & ")"

            ' FASE CRITICA ADAPTATIVA: espera o app terminar de
            ' carregar (CPU ocioso = tela de login), vigiando a
            ' janela de erro o tempo todo. Devolve os ms gastos,
            ' ou -1 se colidiu.
            Dim tCarga
            tCarga = EsperarCargaConcluida()

            If tCarga >= 0 Then
                Log "CARGA: " & tCarga & "ms (app pronto)"
                abriuOk = True
                Exit For
            End If

            ' Colisao: mata a instancia travada desta sessao e espera
            ' a janela critica passar antes de tentar de novo.
            Log "COLISAO detectada (tentativa " & tentativa & ")"
            MatarAppNaSessao
            Set exApp = Nothing
            If tentativa < MAX_TENTATIVAS Then
                Log "aguardando " & (MS_RETENTATIVA \ 1000) & "s para nova tentativa"
                WScript.Sleep MS_RETENTATIVA
            End If
        Next

        ' Libera a fila (segurou o lock durante todas as tentativas)
        If comLock Then
            Dim tl2
            tl2 = EsperarLicencaLivre()
            Log "LIC pos-lancamento: " & tl2 & "ms (ok=" & abriuOk & ")"
            LiberarLock
            Log "FILA LIBERADA"
        End If

        ' Colisao persistiu: NAO desloga o usuario (isso o expulsava e
        ' recomecava o ciclo). Deixa uma ultima instancia aberta para
        ' ele decidir, e segue vigiando normalmente.
        If Not abriuOk Then
            Log "FALHA: colisao persistiu apos " & MAX_TENTATIVAS & " tentativas"
            On Error Resume Next
            sh.CurrentDirectory = APP_DIR
            Set exApp = sh.Exec("""" & APP_PATH & """")
            If Err.Number = 0 Then
                exApp.StdIn.Close
                exApp.StdOut.Close
                exApp.StdErr.Close
            Else
                Set exApp = Nothing
            End If
            On Error GoTo 0
            Log "ultima instancia entregue ao usuario (sem logoff)"
        End If
    End If

End If   ' Not jaAberto

'=================================================================
' VIGIA: segura a sessao enquanto o sistema estiver aberto.
' 1) Handle local (exApp.Status) - custo zero, sem WMI.
' 2) Se o exe fez spawn-e-sai (ou nao ha handle), WMI por caminho.
' Termina -> TSplus desloga; logoff explicito como rede de
' seguranca (nunca no console, nunca em estado desconhecido).
'=================================================================
Dim vigiei, appVisto, viaHandle
vigiei    = 0
appVisto  = False
viaHandle = False

' 1) PRIMARIO: enquanto o processo lancado (DOC-Windows) viver, segura
' a sessao. exApp.Status e' instantaneo e NAO depende de WMI - detecta
' o fechamento na hora.
If Not exApp Is Nothing Then
    viaHandle = True
    On Error Resume Next
    Do While exApp.Status = 0
        appVisto = True
        WScript.Sleep MS_POLL_EXEC
        vigiei = vigiei + MS_POLL_EXEC
        If vigiei > MS_VIGIA_MAX Then Exit Do
    Loop
    On Error GoTo 0

    ' Handle fechou = app encerrou. Confirmacao CURTA de sucessor (caso
    ' o exe passe o bastao p/ AppLauncher). Checagem NAO conservadora:
    ' falha de WMI conta como "encerrado", para uma pane de WMI nao
    ' prender a sessao aberta apos o fechamento real.
    If appVisto Then
        Dim c
        For c = 1 To 3
            If Not AppNaSessao() Then Exit For
            WScript.Sleep 3000
        Next
    End If
End If

' 2) SECUNDARIO: so quando NAO houve handle (caminho jaAberto, ou o
' fallback sh.Run). Vigia por WMI, conservador (falha de WMI = "vivo").
If (Not viaHandle) And (gSessao >= 0) And (Not wmi Is Nothing) Then
    Dim tGraca
    tGraca = 0
    If Not appVisto Then
        Do While tGraca < MS_GRACA
            If AppNaSessaoVigia() Then appVisto = True : Exit Do
            WScript.Sleep 2000
            tGraca = tGraca + 2000
        Loop
    End If
    Dim misses
    misses = 0
    Do
        If AppNaSessaoVigia() Then
            misses = 0
            appVisto = True
        Else
            misses = misses + 1
            If misses >= 3 Then Exit Do
        End If
        WScript.Sleep MS_POLL_WMI
        vigiei = vigiei + MS_POLL_WMI
        If vigiei > MS_VIGIA_MAX Then
            Log "AVISO: vigia estourou 12h - encerrando sessao"
            Exit Do
        End If
    Loop
ElseIf (Not viaHandle) Then
    ' Sem handle e sem WMI/sessao: estado desconhecido, NAO derrubar.
    Log "SAIDA: estado desconhecido, sem logoff"
    WScript.Quit 0
End If

Log "FIM: app fechado (visto=" & appVisto & ", handle=" & viaHandle & ", vigia=" & vigiei & "ms)"

' Logoff explicito: app foi visto, fora do console e com SESSIONNAME
' resolvido. Quando vigiamos pelo handle (viaHandle), o fechamento e'
' certo mesmo sem WMI - por isso o logoff nao exige WMI aqui.
If appVisto And (UCase(NomeSessao()) <> "CONSOLE") _
   And (InStr(NomeSessao(), "%") = 0) Then
    sh.Run sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\logoff.exe", 0, False
End If
WScript.Quit 0


'=================================================================
'                         FUNCOES
'=================================================================

Sub GarantirPasta(p)
    On Error Resume Next
    If Not fso.FolderExists(p) Then fso.CreateFolder p
    On Error GoTo 0
End Sub

Function Zero2(n)
    Zero2 = Right("0" & n, 2)
End Function

Function NomeUsuario()
    NomeUsuario = sh.ExpandEnvironmentStrings("%USERNAME%")
End Function

Function NomeSessao()
    NomeSessao = sh.ExpandEnvironmentStrings("%SESSIONNAME%")
End Function

Sub Log(msg)
    On Error Resume Next
    Dim f
    Set f = fso.OpenTextFile(logPath, 8, True)
    f.WriteLine Now & vbTab & msg
    f.Close
    On Error GoTo 0
End Sub

Sub LiberarLock()
    On Error Resume Next
    If Not lockHandle Is Nothing Then
        lockHandle.Close
        Set lockHandle = Nothing
    End If
    On Error GoTo 0
End Sub

' Sonda DUPLA do arquivo de licenca:
' 1) leitura - detecta lock exclusivo (deny-read) sem interferir;
' 2) se a leitura passou, um toque de append (~1ms) - detecta lock
'    de escrita quando o app compartilha leitura. So roda dentro da
'    serializacao da fila, entao nao colide com outro lancador.
' Arquivo inexistente/sumido = livre.
Function LicencaLivre()
    Dim f
    LicencaLivre = True
    If Not fso.FileExists(LIC_FILE) Then Exit Function
    On Error Resume Next
    Err.Clear
    Set f = fso.OpenTextFile(LIC_FILE, 1, False)   ' 1 = ForReading
    Select Case Err.Number
        Case 0
            f.Close
        Case 53, 76
            On Error GoTo 0
            Exit Function          ' sumiu entre o Exists e o Open: livre
        Case Else
            LicencaLivre = False   ' 70 = preso por outra instancia
            On Error GoTo 0
            Exit Function
    End Select
    Err.Clear
    Set f = fso.OpenTextFile(LIC_FILE, 8, False)   ' 8 = ForAppending
    Select Case Err.Number
        Case 0
            f.Close
        Case 53, 76
            ' livre
        Case Else
            LicencaLivre = False   ' escrita presa pelo app
    End Select
    On Error GoTo 0
End Function

' Prova que conseguimos criar arquivo em \fila (desambigua o erro
' 70 do lock: fila ocupada de verdade x ACL negada)
Function PastaFilaGravavel()
    Dim p, f
    PastaFilaGravavel = False
    p = BASE_DIR & "\fila\probe_" & Int(Rnd * 1000000) & ".tmp"
    On Error Resume Next
    Err.Clear
    Set f = fso.CreateTextFile(p, True)
    If Err.Number = 0 Then
        f.Close
        fso.DeleteFile p, True
        PastaFilaGravavel = True
    End If
    On Error GoTo 0
End Function

' Espera a licenca ficar livre; devolve os ms esperados.
' No teto, segue em frente (fila nao pode prender o usuario).
Function EsperarLicencaLivre()
    Dim t
    t = 0
    Do While (Not LicencaLivre()) And (t < MS_LIC_MAX)
        WScript.Sleep MS_LIC_POLL
        t = t + MS_LIC_POLL
    Loop
    EsperarLicencaLivre = t
End Function

' Descobre SessionId e PID deste wscript: dispara um cmd oculto,
' filho DESTE processo (nasce na mesma sessao por definicao), com
' titulo-marcador unico, e le SessionId/ParentProcessId via WMI.
' Fallback sem WMI: "query session" (linha corrente comeca com >).
Sub DescobrirSessao()
    Dim marca, col, p, t
    gSessao = -1
    gMeuPid = -1
    If Not wmi Is Nothing Then
        marca = "DOCSYS" & Replace(fso.GetTempName, ".", "") & CLng(Timer * 100)
        On Error Resume Next
        sh.Run "cmd.exe /c title " & marca & " & timeout /t 8 /nobreak >nul", 0, False
        For t = 1 To 24    ' ate ~6s de retry
            Err.Clear
            Set col = wmi.ExecQuery( _
                "SELECT SessionId, ParentProcessId FROM Win32_Process " & _
                "WHERE Name='cmd.exe' AND CommandLine LIKE '%" & marca & "%'")
            If Err.Number = 0 Then
                For Each p In col
                    gSessao = p.SessionId
                    gMeuPid = p.ParentProcessId
                Next
            End If
            If gSessao >= 0 Then Exit For
            WScript.Sleep 250
        Next
        On Error GoTo 0
    End If
    If gSessao < 0 Then gSessao = SessaoViaQuery()
End Sub

' Fallback: query session > arquivo temp; a linha da sessao atual
' comeca com ">"; o ID e o ultimo token puramente numerico.
Function SessaoViaQuery()
    Dim tmp, f, linha, tokens, i, tok, achado
    SessaoViaQuery = -1
    tmp = sh.ExpandEnvironmentStrings("%TEMP%") & "\docsys_sess.txt"
    On Error Resume Next
    sh.Run "cmd.exe /c query session > """ & tmp & """", 0, True
    If Not fso.FileExists(tmp) Then Exit Function
    Set f = fso.OpenTextFile(tmp, 1, False)
    Do While Not f.AtEndOfStream
        linha = f.ReadLine
        If Left(LTrim(linha), 1) = ">" Then
            tokens = Split(Trim(Mid(linha, InStr(linha, ">") + 1)))
            achado = -1
            For i = 0 To UBound(tokens)
                tok = Trim(tokens(i))
                If tok <> "" And IsNumeric(tok) Then achado = CLng(tok)
            Next
            SessaoViaQuery = achado
            Exit Do
        End If
    Loop
    f.Close
    fso.DeleteFile tmp, True
    On Error GoTo 0
End Function

' Ha outro lancador (wscript rodando ESTE script) nesta sessao,
' mais antigo que eu? (gMeuPid necessario; sem ele, nao bloqueia)
Function SouDuplicado()
    Dim col, p, minhaData, outraData
    SouDuplicado = False
    If (wmi Is Nothing) Or (gSessao < 0) Or (gMeuPid < 0) Then Exit Function
    On Error Resume Next
    minhaData = ""
    Set col = wmi.ExecQuery( _
        "SELECT CreationDate FROM Win32_Process WHERE ProcessId=" & gMeuPid)
    For Each p In col
        minhaData = p.CreationDate
    Next
    If minhaData = "" Then Exit Function
    Set col = wmi.ExecQuery( _
        "SELECT ProcessId, CreationDate FROM Win32_Process " & _
        "WHERE (Name='wscript.exe' OR Name='cscript.exe') " & _
        "AND SessionId=" & gSessao & _
        " AND CommandLine LIKE '%" & WScript.ScriptName & "%'")
    For Each p In col
        If p.ProcessId <> gMeuPid Then
            outraData = p.CreationDate
            If outraData <> "" Then
                If outraData < minhaData Then
                    SouDuplicado = True
                ElseIf (outraData = minhaData) And (p.ProcessId < gMeuPid) Then
                    ' Empate de tick do kernel: menor PID vence
                    SouDuplicado = True
                End If
            End If
        End If
    Next
    On Error GoTo 0
End Function

' Processo do app vivo NESTA sessao (caminho C:\DeMaria\).
' padraoErro = valor devolvido quando a consulta WMI FALHA (o
' chamador escolhe o lado seguro: idempotencia/spawn = False,
' vigia = True).
Function ProcessoVivoEx(nomeExe, padraoErro)
    Dim col, n
    ProcessoVivoEx = padraoErro
    If (wmi Is Nothing) Or (gSessao < 0) Then Exit Function
    On Error Resume Next
    Err.Clear
    Set col = wmi.ExecQuery( _
        "SELECT ProcessId FROM Win32_Process WHERE Name='" & nomeExe & _
        "' AND SessionId=" & gSessao & _
        " AND ExecutablePath LIKE '" & APP_WQL & "'")
    If Err.Number = 0 Then
        n = col.Count
        If Err.Number = 0 Then ProcessoVivoEx = (n > 0)
    End If
    On Error GoTo 0
End Function

Function ProcessoVivo(nomeExe)
    ProcessoVivo = ProcessoVivoEx(nomeExe, False)
End Function

' Qualquer processo do app vivo nesta sessao.
' Erro de consulta = considera FECHADO (uso: idempotencia/spawn,
' onde o lado seguro e' seguir em frente).
Function AppNaSessao()
    Dim nome
    AppNaSessao = False
    For Each nome In PROCESSOS_APP
        If ProcessoVivoEx(nome, False) Then
            AppNaSessao = True
            Exit Function
        End If
    Next
End Function

' Variante do vigia: erro de consulta = considera VIVO (nunca
' derrubar sessao por falha transitoria de WMI).
Function AppNaSessaoVigia()
    Dim nome
    AppNaSessaoVigia = False
    For Each nome In PROCESSOS_APP
        If ProcessoVivoEx(nome, True) Then
            AppNaSessaoVigia = True
            Exit Function
        End If
    Next
End Function

' Soma o tempo de CPU (unidades de 100ns) dos processos do app nesta
' sessao. Devolve -1 se nao conseguiu medir.
Function CpuAppTotal()
    Dim nome, col, p, t, ok
    t = 0
    ok = False
    CpuAppTotal = -1
    If (wmi Is Nothing) Or (gSessao < 0) Then Exit Function
    On Error Resume Next
    For Each nome In PROCESSOS_APP
        Err.Clear
        Set col = wmi.ExecQuery( _
            "SELECT KernelModeTime,UserModeTime FROM Win32_Process WHERE Name='" & nome & _
            "' AND SessionId=" & gSessao & _
            " AND ExecutablePath LIKE '" & APP_WQL & "'")
        If Err.Number = 0 Then
            For Each p In col
                t = t + CDbl(p.KernelModeTime) + CDbl(p.UserModeTime)
                ok = True
            Next
        End If
    Next
    On Error GoTo 0
    If ok Then CpuAppTotal = t
End Function

' Espera o app terminar de carregar, medindo o CPU: enquanto carrega
' ele consome; na tela de login fica ocioso. Libera a fila assim que
' estabiliza (respeitando piso e teto). Vigia a janela de erro o
' tempo todo. Devolve ms gastos, ou -1 se colidiu.
Function EsperarCargaConcluida()
    Dim t, cpuAnt, cpuAtu, quietos
    t = 0
    quietos = 0
    cpuAnt = CpuAppTotal()
    Do While t < MS_CARGA_MAX
        On Error Resume Next
        If sh.AppActivate(TITULO_ERRO) Then
            On Error GoTo 0
            EsperarCargaConcluida = -1
            Exit Function
        End If
        On Error GoTo 0

        WScript.Sleep MS_CPU_POLL
        t = t + MS_CPU_POLL

        cpuAtu = CpuAppTotal()
        If (cpuAnt >= 0) And (cpuAtu >= 0) Then
            If (cpuAtu - cpuAnt) < CPU_OCIOSO Then
                quietos = quietos + 1
            Else
                quietos = 0
            End If
        Else
            ' sem medicao confiavel: cai no comportamento antigo (tempo fixo)
            If t >= MS_TRAVA Then Exit Do
        End If
        cpuAnt = cpuAtu

        If (t >= MS_CARGA_MIN) And (quietos >= QUIETOS_OK) Then Exit Do
    Loop
    EsperarCargaConcluida = t
End Function

' Mata os processos do app SO nesta sessao (nunca de outros usuarios).
' Usado na auto-recuperacao de colisao. Via WMI Terminate; se WMI
' indisponivel, cai no taskkill filtrado por sessao.
Sub MatarAppNaSessao()
    Dim nome, col, p
    On Error Resume Next
    If (Not wmi Is Nothing) And (gSessao >= 0) Then
        For Each nome In PROCESSOS_APP
            Set col = wmi.ExecQuery( _
                "SELECT * FROM Win32_Process WHERE Name='" & nome & _
                "' AND SessionId=" & gSessao & _
                " AND ExecutablePath LIKE '" & APP_WQL & "'")
            For Each p In col
                p.Terminate
            Next
        Next
    ElseIf gSessao >= 0 Then
        For Each nome In PROCESSOS_APP
            sh.Run "cmd /c taskkill /F /IM " & nome & _
                   " /FI ""SESSION eq " & gSessao & """", 0, True
        Next
    End If
    On Error GoTo 0
End Sub
