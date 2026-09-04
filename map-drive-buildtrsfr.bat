@echo off
setlocal

set SHARE=\\172.30.4.21\c$

echo Running as %USERDOMAIN%\%USERNAME% on %COMPUTERNAME%

REM Z: is preferred; fall back to W: if Z: is already in use by something else.
net use Z: >nul 2>&1
if errorlevel 1 (
    set DRIVE=Z:
) else (
    echo Z: is already in use, falling back to W:
    set DRIVE=W:
)

net use %DRIVE% %SHARE% /user:%SMB_USER% %SMB_PASSWORD%
if errorlevel 1 (
    echo Failed to map %DRIVE% to %SHARE%
    exit /b 1
)

echo Mapped %DRIVE% to %SHARE%
dir %DRIVE%\
if errorlevel 1 (
    echo Drive mapped but not listable - check share permissions.
    exit /b 1
)

endlocal
