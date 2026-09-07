@echo off
rem Plain-Lua compatibility wrapper for modkit on Windows checkouts where the
rem bundled LÖVE runtime exists but a standalone luajit.exe is not on PATH.
set "POKEPORT_LUA_TEST=%~f1"
set "LOVE_LUA_BIN=%~dp0..\gen1recomp\.runtime\love\love-11.5-win64\lovec.exe"
if not exist "%LOVE_LUA_BIN%" set "LOVE_LUA_BIN=lovec.exe"
"%LOVE_LUA_BIN%" "%~dp0..\tests\love_lua_runner"
exit /b %errorlevel%
