@echo off
chcp 65001 >nul
echo ==============================================
echo          Start Music App Services
echo ==============================================
echo.
echo API Server Port: 8080
echo Flutter App Port: 8001
echo.
echo Starting services...
echo.

start "API Server" cmd /k "cd /d E:\Documents\Trae\project_Flutter\md3Music && npm run start:api"

timeout /t 3 /nobreak >nul

start "Flutter App" cmd /k "cd /d E:\Documents\Trae\project_Flutter\md3Music && flutter run -d edge --web-port=8001"

echo.
echo Services starting...
echo API Server: http://localhost:8080
echo Flutter App: http://localhost:8001
echo.
echo Press any key to exit...
pause >nul