@echo off
:: Compila keccak_miner.exe per RTX 40xx (sm_89). Richiede CUDA Toolkit + VS 2022 Build Tools.
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%~dp0"
python gen_rounds.py || exit /b 1
nvcc -O3 -arch=sm_89 -std=c++17 -lineinfo -Xptxas -v -Xcompiler "/O2 /arch:AVX2" -o keccak_miner.exe keccak_miner.cu cpu_miner.cpp