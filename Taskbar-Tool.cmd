@echo off
chcp 65001 >nul
rem ============================================================
rem   The ONLY entry point of this tool: double-click me.
rem   鏈伐鍏峰敮涓€鍏ュ彛锛氬弻鍑绘垜锛屽脊鍑轰腑/鑻辨枃鑿滃崟锛堣嚜鍔ㄨ窡闅忕郴缁熻瑷€锛夈€?rem   - Taskbar: icon centering + transparency / 寮€濮嬭彍鍗曪細缁熶竴纾佽创搴曡壊涓庡浘鏍?rem   - Language auto-detects (zh/en); override: see README
rem ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\Win10-Taskbar-Tweak.ps1" -Menu