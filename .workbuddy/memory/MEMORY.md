# md3Music Project Memory

## Project Conventions

- **Coding guidelines**: Project uses Karpathy Guidelines skill at `.trae/skills/karpathy-guidelines/SKILL.md`. Four principles: Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution. Always follow when writing/reviewing code.
- **Language**: Chinese (Simplified) for communication, Flutter/Dart for the app
- **Tech stack**: Flutter (Material Design 3), kugou_api_server (Node.js, 部署在云服务器)
- **Project stage**: Debugging / fixing phase
- **API 服务器**: kugou_api_server 在云服务器上，非本地运行。修改服务端代码时必须明确告知用户改了哪些文件，由用户自行部署到云端。
- **调试环境**: 安卓模拟器，日志: `adb logcat -s flutter`
- **打包 APK**: `flutter build apk --release --split-per-abi 2>&1 | Select-String -Pattern "error|Built"`
- **安装 APK**: `adb -s emulator-5554 install -r "E:\Documents\Trae\project_Flutter\md3Music\build\app\outputs\flutter-apk\app-x86_64-release.apk" 2>&1`
