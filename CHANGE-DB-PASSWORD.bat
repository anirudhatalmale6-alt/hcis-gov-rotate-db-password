@echo off
REM ============================================================
REM  Change the database password on this machine.
REM
REM  Run CHECK-FIRST.bat before this if you want to see what it
REM  would do without changing anything.
REM ============================================================
setlocal
set HERE=%~dp0
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%rotate-db-password.ps1"
