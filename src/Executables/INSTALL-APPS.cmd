@echo off
:: Double-click launcher: .ps1 files open in Notepad by default.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0INSTALL-APPS.ps1" %*
