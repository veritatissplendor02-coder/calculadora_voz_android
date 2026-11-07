@echo off
chcp 65001 >nul
title Calculadora por Voz - GERADOR V2.2 HISTORICO COMPLETO
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GERAR_APK_V22_HISTORICO_COMPLETO.ps1"
echo.
if errorlevel 1 (
  echo O processo terminou com erro. Tire uma foto desta janela e me envie.
) else (
  echo Processo finalizado.
)
pause
