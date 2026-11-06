@echo off
rem ===========================================================================
rem  Static Qt 5.12 LTS 构建（MSVC 2015 Update 3 / v140），本机执行用
rem  用法: build-5.12.bat [x64|x86]
rem
rem  为什么单独给 5.12 留一个批处理：
rem    * Qt 5.12 的开放源码只以 qtsdkrepository 的「按模块拆分 7z」形式提供，
rem      download.qt.io/archive 与各镜像站都没有 qt-everywhere-src-5.12.12.tar.xz；
rem    * 拆分树没有顶层 configure，只能先编 qtbase，再逐模块 qmake/nmake/install。
rem    * GitHub 托管 runner 上没有 v140 工具集，CI 里这条线要么回退到 v142/v143，
rem      要么在装了 VS2015 的自托管 runner 上跑这个脚本。
rem ===========================================================================
setlocal EnableDelayedExpansion
set QT_VER=5.12.12
set ARCH_ARG=%~1
if "%ARCH_ARG%"=="" set ARCH_ARG=x64

if /i "%ARCH_ARG%"=="x64" (set VCVARS=vcvars64.bat) else (set VCVARS=vcvars32.bat)

rem ---- 定位 VS2015（vswhere 随 VS2017+ 安装，这里用 Program Files 兜底）
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
if exist "%VSWHERE%" (
  for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -version "[14.0,15.0)" -property installationPath`) do set VSDIR=%%i
)
if not defined VSDIR set VSDIR=%ProgramFiles(x86)%\Microsoft Visual Studio 14.0
if not exist "%VSDIR%\VC\%VCVARS%" (
  echo [ERROR] 未找到 Visual Studio 2015: "%VSDIR%\VC\%VCVARS%"
  exit /b 1
)
call "%VSDIR%\VC\%VCVARS%" || exit /b 1

set PREFIX=%CD%\out\%QT_VER%\win64_msvc2015_64_static
set SRC=%CD%\src\%QT_VER%
set BUILD=%CD%\build\%QT_VER%

if not exist "%SRC%\qtbase\configure.bat" (
  echo [ERROR] 源码未就绪: %SRC%\qtbase\configure.bat
  echo         先用 get-qt-source.ps1 -Version %QT_VER% 拉取源码
  exit /b 1
)

if not exist "%BUILD%" mkdir "%BUILD%"
if not exist "%PREFIX%" mkdir "%PREFIX%"

rem ---- 1) 构建 qtbase
pushd "%SRC%\qtbase"
configure.bat ^
  -prefix "%PREFIX%" ^
  -static -release ^
  -opensource -confirm-license ^
  -nomake examples -nomake tests ^
  -no-pch ^
  -qt-zlib -qt-libpng -qt-libjpeg -qt-freetype -qt-pcre ^
  -opengl desktop ^
  -static-runtime ^
  -no-icu -no-openssl
if errorlevel 1 (popd & goto :fail)

where jom >nul 2>nul && (set MAKE=jom) || (set MAKE=nmake)
if "%MAKE%"=="nmake" set CL=/MP
%MAKE% > "%BUILD%\qtbase-build.log" 2>&1
if errorlevel 1 (type "%BUILD%\qtbase-build.log" & popd & goto :fail)
%MAKE% install > "%BUILD%\qtbase-install.log" 2>&1
if errorlevel 1 (type "%BUILD%\qtbase-install.log" & popd & goto :fail)
popd

rem ---- 2) 逐模块构建（顺序即依赖顺序）
for %%M in (qtdeclarative qtsvg qtgraphicaleffects qtquickcontrols2 qtquickcontrols ^
            qtwinextras qtimageformats qtnetworkauth qtwebsockets qtwebchannel ^
            qtserialport qtserialbus qtsensors qtcharts qtmultimedia qtspeech ^
            qtconnectivity qtlocation qtvirtualkeyboard qtscxml qtremoteobjects ^
            qttools qttranslations qtactiveqt) do (
  if exist "%SRC%\%%M\.qmake.conf" (
    echo [module] %%M
    pushd "%SRC%\%%M"
    "%PREFIX%\bin\qmake.exe" -r > "%BUILD%\%%M.log" 2>&1
    if errorlevel 1 (type "%BUILD%\%%M.log" & popd & goto :fail)
    %MAKE% >> "%BUILD%\%%M.log" 2>&1
    if errorlevel 1 (type "%BUILD%\%%M.log" & popd & goto :fail)
    %MAKE% install >> "%BUILD%\%%M.log" 2>&1
    if errorlevel 1 (type "%BUILD%\%%M.log" & popd & goto :fail)
    popd
  )
)

echo [OK] 安装到 %PREFIX%
exit /b 0

:fail
echo [ERROR] 构建失败，日志在 %BUILD%
exit /b 1
