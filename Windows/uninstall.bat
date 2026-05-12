@echo off
title Portable AI - Uninstaller
color 0C

echo ===================================================
echo     PORTABLE AI - UNINSTALLER
echo ===================================================
echo.
echo  This removes installed models and downloaded data
echo  while keeping your base project files intact.
echo.
pause

powershell -ExecutionPolicy Bypass -File "%~dp0uninstall-core.ps1"

echo.
echo ===================================================
echo     UNINSTALL FLOW COMPLETE
echo ===================================================
echo.
pause
