@echo off
:: ==============================================================
::  Instalacao do Lancador DOC-Windows v3 - executar como ADMIN
::  Cria as pastas de trabalho e aplica as permissoes corretas.
::  (SIDs usados no lugar de nomes por causa de servidor PT-BR)
::   S-1-5-18     = SYSTEM
::   S-1-5-32-544 = Administradores
::   S-1-5-32-545 = Usuarios
:: ==============================================================
chcp 65001 >nul

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERRO] Execute este arquivo como ADMINISTRADOR.
    pause
    exit /b 1
)

echo.
echo [1/5] Criando pastas...
if not exist "C:\DOCSYS"      mkdir "C:\DOCSYS"
if not exist "C:\DOCSYS\fila" mkdir "C:\DOCSYS\fila"
if not exist "C:\DOCSYS\logs" mkdir "C:\DOCSYS\logs"

echo [2/5] Backup do script atual (se existir)...
if exist "C:\DOCSYS\iniciar.vbs" copy /y "C:\DOCSYS\iniciar.vbs" "C:\DOCSYS\iniciar_OLD.vbs" >nul

echo [3/5] Copiando o novo iniciar.vbs...
copy /y "%~dp0iniciar.vbs" "C:\DOCSYS\iniciar.vbs" >nul
if %errorlevel% neq 0 (
    echo [ERRO] Falha ao copiar iniciar.vbs. O arquivo esta na mesma pasta deste .bat?
    pause
    exit /b 1
)

echo [4/5] Aplicando permissoes...
:: Raiz: usuarios apenas leem/executam (ninguem troca o script)
icacls "C:\DOCSYS" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" >nul

:: fila: usuarios podem criar/gravar/apagar o arquivo de lock
icacls "C:\DOCSYS\fila" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)M" >nul

:: logs: usuarios criam e escrevem seus logs
icacls "C:\DOCSYS\logs" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)M" >nul

echo [5/5] Conferindo...
if not exist "C:\DOCSYS\iniciar.vbs" (
    echo [ERRO] iniciar.vbs nao foi instalado.
    pause
    exit /b 1
)

echo.
echo ==============================================================
echo  Instalacao concluida.
echo  - Script:  C:\DOCSYS\iniciar.vbs  (publicacao TSplus inalterada)
echo  - Lock:    C:\DOCSYS\fila\fila.lock
echo  - Logs:    C:\DOCSYS\logs\USUARIO_AAAAMMDD.log
echo.
echo  Recomendado (uma vez, no AV/Defender): excluir de escaneamento
echo    C:\DOCSYS\fila  e  C:\DeMaria\DOC-Windows\logs
echo  Teste agora no AdminTool do TSplus: aplicacao DOWIN ^> Test
echo ==============================================================
pause
