@echo off
setlocal
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  echo WebUI environment is missing. Run install.ps1 first.
  exit /b 1
)
".venv\Scripts\python.exe" app.py
