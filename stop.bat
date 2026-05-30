@echo off
chcp 65001 >nul
echo Stopping services...

for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":80" ^| findstr "LISTENING"') do (
    taskkill /F /PID %%a >nul 2>&1
    echo Stopped process on port 80: %%a
)

for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":8080" ^| findstr "LISTENING"') do (
    taskkill /F /PID %%a >nul 2>&1
    echo Stopped process on port 8080: %%a
)

for /f "tokens=2" %%a in ('tasklist ^| findstr "edge.exe"') do (
    taskkill /F /PID %%a >nul 2>&1
    echo Stopped Edge browser: %%a
)

echo All services stopped!
pause