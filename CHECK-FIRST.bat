@echo off
REM ============================================================
REM  Look only - reports whether changing the database password
REM  would affect PostgREST on this machine. Changes NOTHING.
REM ============================================================
setlocal
set HERE=%~dp0
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%rotate-db-password.ps1" -WhatIf
