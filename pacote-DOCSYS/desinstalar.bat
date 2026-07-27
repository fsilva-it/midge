@echo off
:: ==============================================================
::  Rollback do Lancador DOC-Windows v3 - executar como ADMIN
::  Restaura o iniciar_OLD.vbs (backup feito pelo instalar.bat).
::  NAO apaga C:\DOCSYS\logs (mantem historico para diagnostico).
:: ==============================================================
chcp 65001 >nul

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERRO] Execute este arquivo como ADMINISTRADOR.
    pause
    exit /b 1
)

echo.
if not exist "C:\DOCSYS\iniciar_OLD.vbs" (
    echo [ERRO] Backup C:\DOCSYS\iniciar_OLD.vbs nao encontrado.
    echo Nada foi alterado. Restaure o script manualmente se necessario.
    pause
    exit /b 1
)

echo [1/3] Guardando a versao v3 atual como iniciar_v3.vbs...
if exist "C:\DOCSYS\iniciar.vbs" copy /y "C:\DOCSYS\iniciar.vbs" "C:\DOCSYS\iniciar_v3.vbs" >nul

echo [2/3] Restaurando o script anterior (iniciar_OLD.vbs)...
copy /y "C:\DOCSYS\iniciar_OLD.vbs" "C:\DOCSYS\iniciar.vbs" >nul
if %errorlevel% neq 0 (
    echo [ERRO] Falha ao restaurar. Verifique permissoes em C:\DOCSYS.
    pause
    exit /b 1
)

echo [3/3] Limpando lock residual (se houver)...
if exist "C:\DOCSYS\fila\fila.lock" del /f "C:\DOCSYS\fila\fila.lock" >nul 2>&1

echo.
echo ==============================================================
echo  Rollback concluido.
echo  - Restaurado:  C:\DOCSYS\iniciar.vbs  (versao anterior)
echo  - v3 guardada: C:\DOCSYS\iniciar_v3.vbs  (para reinstalar depois)
echo  - Logs preservados em C:\DOCSYS\logs
echo.
echo  Teste no AdminTool do TSplus: aplicacao DOWIN ^> Test
echo ==============================================================
pause
