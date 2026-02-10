@echo off
:: ══════════════════════════════════════════════════════════════
::  Grease Pencil – Update Images.json
::  Double-click this file to update the image list
::  No Python required - uses PowerShell (built into Windows)
:: ══════════════════════════════════════════════════════════════

PowerShell -ExecutionPolicy Bypass -File "%~dp0UpdateImages.ps1"
