@echo off
rem Build TaskbarWatcher.exe with the system csc.exe (no external dependency).
setlocal
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo [x] csc.exe not found. Is .NET Framework 4 installed?
    exit /b 1
)
set "ACC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\Accessibility.dll"
if not exist "%ACC%" set "ACC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\Accessibility.dll"

"%CSC%" /nologo /target:winexe /optimize+ /r:"%ACC%" /out:"%~dp0TaskbarWatcher.exe" "%~dp0TaskbarWatcher.cs"
if errorlevel 1 (
    echo [x] Build failed.
    exit /b 1
)
echo [OK] %~dp0TaskbarWatcher.exe
endlocal
